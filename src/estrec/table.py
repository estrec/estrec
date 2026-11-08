# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Ted Matherly and the estrec contributors
"""Table specs (`estrec-table/0.1`, spec/table.md): build, read, write, validate and
render regression tables from records.

    import estrec.table as et
    spec = et.new_table(ef.read_collection("table2.estrec-collection.json"),
                        stats=["nobs", "r2_within", {"vcov": "type"}])
    et.write_table(spec, "table2.estrec-table.json")
    print(et.render_table("table2.estrec-table.json", "latex"))

A spec holds no numbers: rendering reads the records it names (by `meta.id`) from its
`sources`, or from records passed in.
"""

from __future__ import annotations

import base64
import html
import json
import math
import os
import re
import uuid
from collections.abc import Iterable, Mapping
from pathlib import Path
from typing import Any

from .collection import is_collection, iter_members, loads_collection, member_sha256
from .records import PACKAGED_SCHEMAS, Issue, jsonschema_check, loads
from .views import _num, glance, pick_vcov, tidy, vcov_label

TABLE_SCHEMA = "estrec-table/0.1"
DEFAULT_STARS = [0.1, 0.05, 0.01]
STAT_LABELS = {
    "nobs": "N",
    "r2": "R²",
    "adj_r2": "Adj. R²",
    "r2_within": "Within R²",
    "adj_r2_within": "Adj. within R²",
    "pseudo_r2": "Pseudo R²",
    "aic": "AIC",
    "bic": "BIC",
    "log_lik": "Log lik.",
    "rmse": "RMSE",
    "f_stat": "F",
}


# lines under each estimate (spec/table.md section 5)
NAMED_LINES = {
    "std_error": "({std_error})",
    "statistic": "({statistic})",
    "p_value": "[{p_value}]",
    "conf_int": "[{conf_low}, {conf_high}]",
}
PLACEHOLDERS = ("estimate", "std_error", "statistic", "p_value", "conf_low", "conf_high")
_PLACEHOLDER = re.compile(r"\{([^{}]*)\}")
_NAMED_NOTES = {
    "std_error": "Standard errors in parentheses.",
    "statistic": "Test statistics in parentheses.",
    "p_value": "p-values in brackets.",
    "conf_int": "Confidence intervals in brackets.",
}
_WORDS = {
    "estimate": "estimate",
    "std_error": "standard error",
    "statistic": "test statistic",
    "p_value": "p-value",
    "conf_low": "lower bound",
    "conf_high": "upper bound",
}


SPARK_COLOR = "#2b5f8e"
SPARK_SCALES = ("column", "row", "table")
SPARK_PLACES = ("below", "beside")
SPARK_ALIGNS = ("estimate", "middle")
_SPARK_TEXT = "[{conf_low}, {conf_high}]"
_HEX = re.compile(r"^#[0-9a-fA-F]{6}$")


def _line_items(spec: dict) -> list:
    unc = spec.get("uncertainty", "std_error")
    if unc is None:
        return []
    return [unc] if isinstance(unc, (str, dict)) else list(unc)


def uncertainty_lines(spec: dict) -> list:
    """The lines under each estimate: `uncertainty` as a name, a template, a sparkline or a
    list of them, or None (no lines). Names become templates; a sparkline becomes
    {"sparkline": {"color", "scale", "place", "align"}} with the defaults filled in."""
    out = []
    for x in _line_items(spec):
        if isinstance(x, dict):
            sp = x.get("sparkline") or {}
            out.append(
                {
                    "sparkline": {
                        "color": sp.get("color", SPARK_COLOR),
                        "scale": sp.get("scale", "column"),
                        "place": sp.get("place", "below"),
                        "align": sp.get("align", "estimate"),
                    }
                }
            )
        else:
            out.append(NAMED_LINES.get(x, x))
    return out


def _line_issues(spec: dict) -> list[Issue]:
    unc = spec.get("uncertainty", "std_error")
    if unc is None:
        return []
    items = [unc] if isinstance(unc, (str, dict)) else unc
    if not isinstance(items, list):
        return [Issue("error", "uncertainty", "a name, a list of names and templates, or null")]
    out = []
    beside = 0
    for j, x in enumerate(items):
        path = "uncertainty" if isinstance(unc, (str, dict)) else f"uncertainty[{j}]"
        if isinstance(x, dict):
            sp = x.get("sparkline")
            if list(x) != ["sparkline"] or not isinstance(sp, dict):
                out.append(Issue("error", path, 'an object line is {"sparkline": {color, scale}}'))
                continue
            if "color" in sp and not (isinstance(sp["color"], str) and _HEX.match(sp["color"])):
                out.append(Issue("error", f"{path}.sparkline.color", "a colour as #rrggbb"))
            if "scale" in sp and sp["scale"] not in SPARK_SCALES:
                out.append(Issue("error", f"{path}.sparkline.scale", "'column', 'row' or 'table'"))
            if "place" in sp and sp["place"] not in SPARK_PLACES:
                out.append(Issue("error", f"{path}.sparkline.place", "'below' or 'beside'"))
            elif sp.get("place") == "beside":
                beside += 1
                if beside > 1:
                    out.append(Issue("error", f"{path}.sparkline.place", "one sparkline at most is beside the estimates"))
            if "align" in sp and sp["align"] not in SPARK_ALIGNS:
                out.append(Issue("error", f"{path}.sparkline.align", "'estimate' or 'middle'"))
        elif not isinstance(x, str):
            out.append(Issue("error", path, "a name, a template string or a sparkline"))
        elif x in NAMED_LINES:
            continue
        elif "{" not in x:
            out.append(
                Issue("error", path, f"{x!r} is neither a name ({', '.join(NAMED_LINES)}) nor a template")
            )
        else:
            bad = [m for m in _PLACEHOLDER.findall(x) if m not in PLACEHOLDERS]
            if bad:
                out.append(
                    Issue("error", path, f"unknown placeholder {{{bad[0]}}}; use {', '.join(PLACEHOLDERS)}")
                )
            elif not _PLACEHOLDER.search(x):
                out.append(Issue("error", path, "a template needs at least one placeholder"))
    return out


def _uncertainty_note(spec: dict, lines: list[str]) -> str | None:
    unc = spec.get("uncertainty", "std_error")
    if unc is None or not lines:
        return None
    if isinstance(unc, str) and unc in _NAMED_NOTES:
        return _NAMED_NOTES[unc]
    parts = []
    for t in lines:
        if isinstance(t, dict):
            parts.append("confidence interval drawn as a line, the estimate as a dot, 0 as a grey rule")
            continue
        t = t.replace("{conf_low}, {conf_high}", "confidence interval")
        parts.append(_PLACEHOLDER.sub(lambda m: _WORDS.get(m.group(1), m.group(1)), t))
    return "Under each estimate: " + "; ".join(parts) + "."


# ---------------------------------------------------------------- records


class _Found:
    __slots__ = ("member", "record", "source")

    def __init__(self, record: dict, member: dict | None, source: str | None):
        self.record, self.member, self.source = record, member, source


def _records_in(path: Path) -> list[tuple[dict, dict | None]]:
    """(record, member entry) for a record file, a folder of records, or a collection."""
    if path.is_dir():
        return [(loads(f.read_bytes()), None) for f in sorted(path.glob("*.estrec.json"))]
    data = path.read_bytes()
    doc = json.loads(data)
    if is_collection(doc):
        coll = loads_collection(data)
        out = []
        for i, m, rec in iter_members(coll, path.parent):
            if rec is None:
                raise ValueError(f"{path}: members[{i}]: record not found")
            out.append((rec, m))
        return out
    return [(loads(data), None)]


def _as_records(records: Any) -> list[tuple[dict, dict | None]]:
    """Records given directly: a record, a list or {label: record} mapping, or a collection."""
    if records is None:
        return []
    if is_collection(records):
        return [(r, m) for _, m, r in iter_members(records) if r is not None]
    if isinstance(records, Mapping) and records.get("schema") == "estrec/0.1":
        return [(records, None)]
    if isinstance(records, Mapping):
        return [(r, {"label": str(k)}) for k, r in records.items()]
    return [(r, None) for r in records]


def index_records(
    spec: dict, base_dir: str | os.PathLike | None = None, records: Any = None
) -> tuple[dict[tuple[str | None, str], _Found], list[Issue]]:
    """The records a spec can use, by (source id, meta.id) and (None, meta.id): those passed
    in, then each source's under `base_dir` (the spec's folder)."""
    found: dict[tuple[str | None, str], _Found] = {}
    issues: list[Issue] = []

    def add(rec, member, src):
        rid = (rec.get("meta") or {}).get("id")
        if not rid:
            return
        f = _Found(rec, member, src)
        found.setdefault((src, rid), f)
        found.setdefault((None, rid), f)

    for rec, m in _as_records(records):
        add(rec, m, None)
    base = Path(base_dir) if base_dir is not None else None
    for i, s in enumerate(spec.get("sources") or []):
        if base is None:
            continue
        p = base / s.get("path", "")
        try:
            for rec, m in _records_in(p):
                add(rec, m, s.get("id"))
        except (OSError, ValueError) as e:
            issues.append(Issue("error", f"sources[{i}]", f"can't read {s.get('path')!r}: {e}"))
    return found, issues


# ---------------------------------------------------------------- building specs


def new_table(
    records: Any,
    *,
    headers: Iterable[str] | None = None,
    rows: Iterable[dict | str] | None = None,
    stats: Iterable[dict | str] | None = ("nobs", "r2", {"vcov": "type"}),
    uncertainty: str | list[str] | None = "std_error",
    stars: list[float] | None = DEFAULT_STARS,
    title: str | None = None,
    sources: Iterable[dict] | None = None,
    pin: bool = False,
    fixed_effects: bool = True,
    **extra: Any,
) -> dict:
    """A spec with one column per record (a list, a {label: record} mapping or a collection),
    in order. `stats` entries may be metric names; `fixed_effects=True` adds a row per fixed
    effect any record has; `pin=True` records each record's sha256."""
    items = _as_records(records)
    if not items:
        raise ValueError("no records")
    heads = list(headers) if headers is not None else None
    cols = []
    for i, (rec, m) in enumerate(items):
        col = {"record": rec["meta"]["id"]}
        if heads:
            col["header"] = str(heads[i])
        if pin:
            col["sha256"] = member_sha256(rec)
        cols.append(col)
    st = [{"metric": s} if isinstance(s, str) else dict(s) for s in (stats or [])]
    if fixed_effects:
        seen = []
        for rec, _ in items:
            for fe in (rec.get("specification") or {}).get("fixed_effects") or []:
                if fe not in seen:
                    seen.append(fe)
        st += [{"fixed_effect": fe, "label": f"FE: {fe}"} for fe in seen]
    spec = {
        "schema": TABLE_SCHEMA,
        "meta": {"id": str(uuid.uuid4()), "created": _now(), "producer": _producer()},
    }
    if title:
        spec["title"] = title
    if sources:
        spec["sources"] = list(sources)
    spec["columns"] = cols
    if rows:
        spec["rows"] = [{"term": r} if isinstance(r, str) else dict(r) for r in rows]
    spec["uncertainty"] = uncertainty
    if stars:
        spec["stars"] = list(stars)
    if st:
        spec["stats"] = st
    spec.update(extra)
    return spec


def _now() -> str:
    import datetime as _dt

    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _producer() -> dict:
    from . import __version__

    return {"name": "estrec", "version": __version__}


def read_table(path: str | os.PathLike) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def write_table(spec: dict, path: str | os.PathLike) -> Path:
    path = Path(path)
    path.write_text(json.dumps(spec, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return path


# ---------------------------------------------------------------- validation


def _schema_issues(spec: dict) -> list[Issue]:
    try:
        check = jsonschema_check(PACKAGED_SCHEMAS / "estrec-table-0.1.json")
    except ImportError:
        return []
    return check(spec)


def _structural(spec: dict) -> list[Issue]:
    out = []
    if spec.get("schema") != TABLE_SCHEMA:
        out.append(Issue("error", "schema", f"expected {TABLE_SCHEMA!r}"))
    cols = spec.get("columns")
    if not isinstance(cols, list) or not cols:
        out.append(Issue("error", "columns", "at least one column"))
        cols = []
    ids = [s.get("id") for s in spec.get("sources") or [] if isinstance(s, dict)]
    for d in sorted({i for i in ids if ids.count(i) > 1}):
        out.append(Issue("error", "sources", f"duplicate source id {d!r}"))
    for i, c in enumerate(cols):
        if not isinstance(c, dict) or not c.get("record"):
            out.append(Issue("error", f"columns[{i}]", "a column needs `record` (a meta.id)"))
        elif c.get("source") is not None and c["source"] not in ids:
            out.append(Issue("error", f"columns[{i}].source", f"no source {c['source']!r}"))
    for key in ("keep", "drop"):
        for j, pat in enumerate(spec.get(key) or []):
            try:
                re.compile(pat)
            except re.error as e:
                out.append(Issue("error", f"{key}[{j}]", f"pattern doesn't compile: {e}"))
    out += _line_issues(spec)
    if "estimate" in spec and not isinstance(spec["estimate"], bool):
        out.append(Issue("error", "estimate", "true or false"))
    elif spec.get("estimate") is False and not uncertainty_lines(spec):
        out.append(Issue("error", "estimate", "with no estimate and no lines, terms have nothing to show"))
    head = spec.get("head")
    if head is not None:
        if not isinstance(head, list):
            out.append(Issue("error", "head", "a list of 'number', 'response', 'label'"))
        else:
            for j, k in enumerate(head):
                if k not in HEAD_KINDS:
                    out.append(
                        Issue("error", f"head[{j}]", f"{k!r} is not one of 'number', 'response', 'label'")
                    )
                elif head.index(k) != j:
                    out.append(Issue("error", f"head[{j}]", f"{k!r} appears twice"))
    for j, s in enumerate(spec.get("stats") or []):
        if "values" in s and len(s["values"]) != len(cols):
            out.append(
                Issue("error", f"stats[{j}].values", f"{len(s['values'])} values for {len(cols)} columns")
            )
    return out


def validate_table(
    spec: dict,
    *,
    base_dir: str | os.PathLike | None = None,
    records: Any = None,
    schema: str | None = "auto",
) -> list[Issue]:
    """Errors and warnings for a spec (spec/table.md section 9). With `base_dir` or
    `records`, the columns' records are looked up and checked too. `schema="auto"` adds the
    JSON Schema check when jsonschema is installed; None skips it."""
    issues = _structural(spec)
    if schema == "auto":
        issues += _schema_issues(spec)
    if base_dir is None and records is None:
        return issues
    found, read_issues = index_records(spec, base_dir, records)
    issues += read_issues
    recs = []
    for i, c in enumerate(spec.get("columns") or []):
        f = found.get((c.get("source"), c.get("record"))) or found.get((None, c.get("record")))
        if f is None:
            issues.append(Issue("error", f"columns[{i}]", f"record {c.get('record')} not found"))
            recs.append(None)
            continue
        recs.append(f.record)
        if c.get("sha256") and member_sha256(f.record) != c["sha256"]:
            issues.append(
                Issue("warning", f"columns[{i}].sha256", "the record has changed since the table was made")
            )
        if c.get("vcov") is not None:
            try:
                pick_vcov(f.record, c["vcov"])
            except (ValueError, IndexError) as e:
                issues.append(Issue("warning", f"columns[{i}].vcov", str(e)))
    have = [r for r in recs if r is not None]
    terms = {p.get("term") for r in have for p in r.get("parameters") or []}
    for j, row in enumerate(spec.get("rows") or []):
        names = row.get("terms") or [row.get("term")]
        if not row.get("reference") and not any(n in terms for n in names):
            issues.append(Issue("warning", f"rows[{j}]", f"no column has {', '.join(map(str, names))}"))
    for j, s in enumerate(spec.get("stats") or []):
        if "metric" in s:
            m = s["metric"]
            ok = any(
                m in (r.get("metrics") or {}) or (m == "rmse" and "rss" in (r.get("metrics") or {}))
                for r in have
            )
            if not ok:
                issues.append(Issue("warning", f"stats[{j}]", f"no record has metric {m!r}"))
        elif "fixed_effect" in s:
            if not any(
                s["fixed_effect"] in ((r.get("specification") or {}).get("fixed_effects") or []) for r in have
            ):
                issues.append(
                    Issue("warning", f"stats[{j}]", f"no record has fixed effect {s['fixed_effect']!r}")
                )
        elif "test" in s:
            if not any(_find_test(r, s["test"]) for r in have):
                issues.append(Issue("warning", f"stats[{j}]", f"no record has test {s['test']!r}"))
    return issues


# ---------------------------------------------------------------- the table


def _find_test(rec: dict, key: str) -> dict | None:
    tests = rec.get("tests") or []
    return next((t for t in tests if t.get("label") == key), None) or next(
        (t for t in tests if t.get("name") == key), None
    )


def _fixed(x: float, digits: int) -> str:
    """Fixed decimals; "-0.000" shows as "0.000"."""
    if x is None or math.isnan(x):
        return ""
    if math.isinf(x):
        return "Inf" if x > 0 else "-Inf"
    s = f"{x:.{digits}f}"
    if s.startswith("-") and float(s) == 0:
        s = s[1:]
    return s


def _stat_value(x: Any, digits: int, thousands: str) -> str:
    if x is None:
        return ""
    if isinstance(x, bool):
        return "Yes" if x else "No"
    if isinstance(x, str):
        return x
    x = float(x)
    if math.isnan(x):
        return ""
    if math.isfinite(x) and x == int(x) and abs(x) < 1e15:
        s = f"{int(x):,}"
        return s.replace(",", thousands)
    return _fixed(x, digits)


def _p_value(p: float, digits: int, style: str) -> str:
    """A p-value: fixed decimals ("0.000"), or with style "less_than", "<0.001" below the
    smallest value the decimals can show."""
    if p is None or math.isnan(p):
        return ""
    if style == "less_than" and p < 10.0**-digits:
        return "<" + _fixed(10.0**-digits, digits)
    return _fixed(p, digits)


def _fill(template: str, row: dict, digits: int, p_digits: int, p_style: str, missing: str) -> str:
    """A line under an estimate: the template with its placeholders filled; `missing` when
    any value it needs is missing."""
    vals = {}
    for name in _PLACEHOLDER.findall(template):
        x = row.get(name, math.nan)
        if x is None or math.isnan(x):
            return missing
        vals[name] = _p_value(x, p_digits, p_style) if name == "p_value" else _fixed(x, digits)
    return _PLACEHOLDER.sub(lambda m: vals[m.group(1)], template)


def _spark_mark(r: dict) -> dict | None:
    vals = [r.get(k) for k in ("conf_low", "estimate", "conf_high")]
    if any(v is None or not math.isfinite(v) for v in vals):
        return None
    return {"low": vals[0], "estimate": vals[1], "high": vals[2]}


def _spark_domains(rows: list[dict]) -> None:
    """Give each sparkline mark the axis it is drawn on, [lo, hi], always holding 0: shared
    down a column, along a row or across the table (the line's `scale`), among the marks of
    sparkline lines with the same scale. A cell without an interval (a term the column lacks,
    or a reference row's) takes its group's axis, for its 0 rule; in a group with no
    intervals it is left blank (None)."""
    groups: dict = {}
    for i, r in enumerate(rows):
        sp = r.get("sparkline")
        if not sp:
            continue
        for j, m in enumerate(sp["marks"]):
            if m is None:
                continue
            key = {"column": j, "row": i, "table": 0}[sp["scale"]]
            groups.setdefault((sp["scale"], key), []).append((i, j, m))
    for ms in groups.values():
        real = [m for _, _, m in ms if "estimate" in m]
        if not real:
            for i, j, _ in ms:
                rows[i]["sparkline"]["marks"][j] = None
            continue
        lo = min([0.0] + [m["low"] for m in real])
        hi = max([0.0] + [m["high"] for m in real])
        if lo == hi:
            lo, hi = -1.0, 1.0
        for _, _, m in ms:
            m["domain"] = [lo, hi]


def _spark_dark(color: str) -> str:
    """The estimate dot's colour: the line's, about a third darker."""
    rgb = [int(color[k : k + 2], 16) * 13 // 20 for k in (1, 3, 5)]
    return "#" + "".join(f"{v:02x}" for v in rgb)


SPARK_W, SPARK_H = 80, 16
_HALO = 'style="stroke:var(--bg,#ffffff)"'


def _spark_xs(m: dict, width: int = 80) -> tuple[int, int, int, int]:
    """Where 0, the low end, the estimate and the high end fall across the drawing's width
    (80 pixels unless a Word table's width sets it), in tenths of a pixel, rounded half up
    with integers so every renderer draws the same."""
    return tuple(_spark_x(m, v, width) for v in (0.0, m["low"], m["estimate"], m["high"]))


def _spark_x0(m: dict, width: int = SPARK_W) -> int:
    """Where 0 falls, as in `_spark_xs` (all a cell without an interval needs)."""
    return _spark_x(m, 0.0, width)


def _spark_x(m: dict, v: float, width: int = SPARK_W) -> int:
    lo, hi = m["domain"]
    pad = 4.0
    return math.floor((pad + (v - lo) / (hi - lo) * (width - 2 * pad)) * 10 + 0.5)


def _tenths(n: int) -> str:
    return f"{n // 10}.{n % 10}"


def _third(a: int, b: int) -> str:
    """(a + 2b) / 3 tenths, in hundredths rounded half up: a quadratic curve's control point
    as a cubic's (TikZ has no quadratic curves). All values are positive."""
    n = (20 * (a + 2 * b) + 3) // 6
    return f"{n // 100}.{n % 100:02d}"


def _tikz_rgb(color: str) -> str:
    r, g, b = (int(color[k : k + 2], 16) for k in (1, 3, 5))
    return f"{{rgb,255:red,{r};green,{g};blue,{b}}}"


# A sparkline in LaTeX draws the SVG's marks in its units (1 px = 0.75 pt, so 60 x 12 pt), y
# up from the baseline: the 0 rule from -4.8 to 11.2 (a 12 pt row: 10 pt type, \arraystretch
# 1, so a column of them joins), the interval at 3.2.
TIKZ_NOTE = (
    "% Sparklines are TikZ pictures (\\usepackage{tikz}), drawn for 12pt rows "
    "(10pt type, \\arraystretch 1) so a column of them joins"
)


def _spark_tikz(m: dict | None, color: str, rows: int = 1, rule_only: bool = False) -> str:
    """One interval as a TikZ picture with the SVG's marks: the grey 0 rule at full height,
    the faint band swelling toward the estimate, the round-capped line, the end dots and the
    darker estimate dot, each dot with a white halo. A cell without an interval has the rule
    alone, and a reference row's a hollow dot at 0. `rows` > 1 (a sparkline beside the
    estimates, centred on the term's rows) keeps the picture's size to its own row but draws
    the rule down through the rows below and the marks at their middle; `rule_only` draws
    only the rule (the term's other rows)."""
    if m is None:
        return ""
    top, bottom, mid = 112, 112 - 160 * rows, 112 - 80 * rows
    x0 = _tenths(_spark_x0(m))
    c, d = _tikz_rgb(color), _tikz_rgb(_spark_dark(color))
    y = _spark_y(mid)
    out = (
        "\\tikz[x=.75pt,y=.75pt,baseline=0pt]{"
        "\\useasboundingbox (0,-4.8) rectangle (80,11.2);"
        f"\\draw[line width=.75pt,color={_tikz_rgb('#555555')}] ({x0},{_spark_y(bottom)}) -- ({x0},{_spark_y(top)});"
    )
    if rule_only:
        pass
    elif "estimate" in m:
        _, nl, ne, nh = _spark_xs(m)
        xl, xe, xh = map(_tenths, (nl, ne, nh))
        a, b = _third(nl, ne), _third(nh, ne)
        up, down = _spark_y(mid + 40), _spark_y(mid - 40)
        out += (
            f"\\fill[color={c},fill opacity=.22] ({xl},{y}) .. controls ({a},{up}) and ({b},{up}) .. ({xh},{y})"
            f" .. controls ({b},{down}) and ({a},{down}) .. ({xl},{y}) -- cycle;"
            f"\\draw[line width=.975pt,line cap=round,color={c}] ({xl},{y}) -- ({xh},{y});"
            f"\\filldraw[fill={c},draw=white,line width=.675pt] ({xl},{y}) circle[radius=1.425pt];"
            f"\\filldraw[fill={c},draw=white,line width=.675pt] ({xh},{y}) circle[radius=1.425pt];"
            f"\\filldraw[fill={d},draw=white,line width=.825pt] ({xe},{y}) circle[radius=2.175pt];"
        )
    elif m.get("reference"):
        out += f"\\filldraw[fill=white,draw={d},line width=.9pt] ({x0},{y}) circle[radius=1.95pt];"
    return out + "}"


def _spark_y(n: int) -> str:
    """A y position given in tenths of a pixel (may be negative)."""
    return ("-" if n < 0 else "") + _tenths(abs(n))


def _spark_marks(xl: str, xe: str, xh: str, yt: int, color: str) -> str:
    """The band, the line and the dots of one interval, centred at yt tenths of a pixel."""
    y, top, bottom = _spark_y(yt), _spark_y(yt - 60), _spark_y(yt + 60)
    return (
        f'<path d="M{xl} {y}Q{xe} {top} {xh} {y}Q{xe} {bottom} {xl} {y}Z" fill="{color}" fill-opacity="0.22"/>'
        f'<line x1="{xl}" y1="{y}" x2="{xh}" y2="{y}" stroke="{color}" stroke-width="1.3" stroke-linecap="round"/>'
        f'<circle cx="{xl}" cy="{y}" r="1.9" fill="{color}" stroke-width="0.9" {_HALO}/>'
        f'<circle cx="{xh}" cy="{y}" r="1.9" fill="{color}" stroke-width="0.9" {_HALO}/>'
        f'<circle cx="{xe}" cy="{y}" r="2.9" fill="{_spark_dark(color)}" stroke-width="1.1" {_HALO}/>'
    )


def _spark_ring(x0: str, yt: int, color: str) -> str:
    """A reference row's mark: a hollow dot at 0 in the estimate dot's colour."""
    return (
        f'<circle cx="{x0}" cy="{_spark_y(yt)}" r="2.6" stroke="{_spark_dark(color)}" '
        'stroke-width="1.2" style="fill:var(--bg,#ffffff)"/>'
    )


def _spark_label(m: dict, label: str) -> str:
    """The drawing's text: the interval's, or 'reference' for a reference row's dot."""
    return label or ("reference" if m.get("reference") else "")


def _spark_svg(
    m: dict | None,
    color: str,
    label: str = "",
    height: int = SPARK_H,
    mid: int | None = None,
    style: str = "",
    width: int = SPARK_W,
) -> str:
    """One interval as a small SVG of fixed size, on its axis: a grey rule at 0 running the
    full height (so stacked rows join), the interval as a thin line in `color` inside a
    faint band that swells toward the estimate, a dot at each end and a darker dot at the
    estimate, each with a thin halo of the background so the line is scalloped there.
    `height` (pixels) is the image's; the marks sit halfway down, or `mid` tenths of a pixel
    down; `style` goes on the <svg>; `width` (pixels) narrows the axis, not the marks."""
    if m is None:
        return ""
    yt = height * 5 if mid is None else mid
    label = _spark_label(m, label)
    if "estimate" in m:
        x0, xl, xe, xh = map(_tenths, _spark_xs(m, width))
        marks = _spark_marks(xl, xe, xh, yt, color)
    else:
        x0 = _tenths(_spark_x0(m, width))
        marks = _spark_ring(x0, yt, color) if m.get("reference") else ""
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" '
        + ('role="img"' if marks else 'aria-hidden="true"')
        + (f' aria-label="{html.escape(label)}"' if label and marks else "")
        + (f' style="{style}"' if style else "")
        + ">"
        f'<line x1="{x0}" y1="0" x2="{x0}" y2="{height}" stroke="#555555" stroke-width="1"/>'
        + marks
        + "</svg>"
    )


def _spark_rule(m: dict | None, height: int | None = None, width: int = SPARK_W) -> str:
    """Only the 0 rule of a sparkline beside the estimates, for the term's other rows: an
    image `height` pixels tall, or (None) an SVG filling its `position:relative` cell."""
    if m is None:
        return ""
    x0 = _tenths(_spark_x0(m, width))
    if height is None:
        return (
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{SPARK_W}" height="100%" aria-hidden="true"'
            ' style="position:absolute;top:0;left:calc(50% - 40px)">'
            f'<line x1="{x0}" y1="0" x2="{x0}" y2="100%" stroke="#555555" stroke-width="1"/></svg>'
        )
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">'
        f'<line x1="{x0}" y1="0" x2="{x0}" y2="{height}" stroke="#555555" stroke-width="1"/></svg>'
    )


def _spark_svg_tall(m: dict | None, color: str, label: str = "") -> str:
    """A sparkline beside the estimates: as tall as its cell (the term's rows), the 0 rule
    its full height and the marks halfway down, so the cells of a column join into one axis.
    The cell is `position:relative`; the SVG fills it."""
    if m is None:
        return ""
    label = _spark_label(m, label)
    if "estimate" in m:
        x0, xl, xe, xh = map(_tenths, _spark_xs(m))
        marks = _spark_marks(xl, xe, xh, 0, color)
    else:
        x0 = _tenths(_spark_x0(m))
        marks = _spark_ring(x0, 0, color) if m.get("reference") else ""
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{SPARK_W}" height="100%" '
        + ('role="img"' if marks else 'aria-hidden="true"')
        + (f' aria-label="{html.escape(label)}"' if label and marks else "")
        + ' style="position:absolute;top:0;left:calc(50% - 40px);overflow:visible">'
        f'<line x1="{x0}" y1="0" x2="{x0}" y2="100%" stroke="#555555" stroke-width="1"/>'
        + ('<svg y="50%" overflow="visible">' + marks + "</svg>" if marks else "")
        + "</svg>"
    )


def _stars(p: float, thresholds: list[float], symbols: list[str]) -> str:
    if p is None or math.isnan(p):
        return ""
    out = ""
    for t, s in zip(thresholds, symbols):
        if p < t:
            out = s
    return out


HEAD_KINDS = ("number", "response", "label")
REFERENCE_TEXT = "—"  # a reference row's text with `"reference": true`
DEFAULT_HEAD = ["number", "response"]


def _column_response(c: dict, record: dict, rows: list[dict], labels: dict) -> str:
    """A column's dependent variable: its `response`, else the one response its rows share (a
    first stage's endogenous variable), else the record's `meta.responses`; then relabelled."""
    name = c.get("response")
    if not name:
        named = sorted({r["response"] for r in rows if r.get("response")})
        if len(named) == 1:
            name = named[0]
    if not name:
        name = ", ".join(str(x) for x in (record.get("meta") or {}).get("responses") or [])
    return str(labels.get(name, name))


def _head_rows(spec: dict, cols: list[dict]) -> list[dict]:
    """The heading rows, top to bottom (spec `head`); a response or label row that would be
    empty in every column is left out."""
    out = []
    for kind in spec.get("head", DEFAULT_HEAD):
        cells = [c[kind] for c in cols]
        if kind != "number" and not any(cells):
            continue
        out.append({"kind": kind, "cells": cells})
    return out


def build_table(spec: dict, *, base_dir: str | os.PathLike | None = None, records: Any = None) -> dict:
    """The table as cells: {"title", "head": [{"kind", "cells"}] (heading rows, top to bottom;
    `kind` "number", "response" or "label"), "header": ["(1)", ...], "column_records":
    [meta.id per column], "rows": [{"label", "cells", "kind"}], "notes": [..], "warnings":
    [..]}. A row's `kind` is "estimate", "uncertainty" or "stat". Raises ValueError on errors
    (spec/table.md section 9)."""
    issues = validate_table(spec, base_dir=base_dir, records=records, schema=None)
    errors = [i for i in issues if i.level == "error"]
    if errors:
        raise ValueError("; ".join(map(str, errors)))
    found, _ = index_records(spec, base_dir, records)
    fmt = spec.get("format") or {}
    digits = fmt.get("digits", 3)
    thousands = fmt.get("thousands", ",")
    missing = fmt.get("missing", "")
    stars = spec.get("stars") or []
    symbols = fmt.get("star_symbols") or ["*" * (i + 1) for i in range(len(stars))]
    lines = uncertainty_lines(spec)
    show_est = spec.get("estimate", True) is not False
    p_digits = fmt.get("p_digits", digits)
    p_style = fmt.get("p_style", "fixed")

    cols = []
    for i, c in enumerate(spec["columns"]):
        f = found.get((c.get("source"), c["record"])) or found[(None, c["record"])]
        rows = tidy(f.record, vcov=c.get("vcov"), component=c.get("component"))
        if c.get("response"):
            rows = [r for r in rows if r.get("response") == c["response"]]
        label = c.get("header")
        if label is None:
            label = (f.member or {}).get("label") or (f.record.get("meta") or {}).get("title") or ""
        cols.append(
            {
                "spec": c,
                "found": f,
                "tidy": {r["term"]: r for r in rows},
                "order": [r["term"] for r in rows],
                "number": f"({i + 1})",
                "response": _column_response(c, f.record, rows, spec.get("response_labels") or {}),
                "label": label,
            }
        )

    # rows: listed first, then the unlisted terms by first appearance, filtered by keep/drop
    listed = []
    taken = set()
    for row in spec.get("rows") or []:
        names = row.get("terms") or [row["term"]]
        ref = row.get("reference")
        listed.append((row.get("label") or names[0], names, REFERENCE_TEXT if ref is True else ref or None))
        taken.update(names)
    if spec.get("keep_unlisted", True):
        keep = [re.compile(p) for p in spec.get("keep") or []]
        drop = [re.compile(p) for p in spec.get("drop") or []]
        seen = []
        for c in cols:
            for t in c["order"]:
                if t in taken or t in seen:
                    continue
                if keep and not any(k.search(t) for k in keep):
                    continue
                if any(d.search(t) for d in drop):
                    continue
                seen.append(t)
        listed += [(t, [t], None) for t in seen]

    out_rows = []
    for label, names, ref in listed:
        est = []
        below: list[list[str]] = [[] for _ in lines]
        marks: list[list] = [[] for _ in lines]
        refs = []  # the columns showing the reference text
        for j, c in enumerate(cols):
            r = next((c["tidy"][n] for n in names if n in c["tidy"]), None)
            if r is None:
                # a sparkline keeps its 0 rule (and a reference row's, a hollow dot at 0)
                est.append(missing if ref is None else ref)
                if ref is not None:
                    refs.append(j)
                for b, m, t in zip(below, marks, lines):
                    b.append(missing if ref is None else "")
                    m.append(({"reference": True} if ref is not None else {}) if isinstance(t, dict) else None)
                continue
            est.append(_fixed(r["estimate"], digits) + _stars(r["p_value"], stars, symbols))
            for b, m, t in zip(below, marks, lines):
                if isinstance(t, dict):
                    b.append(_fill(_SPARK_TEXT, r, digits, p_digits, p_style, missing))
                    m.append(_spark_mark(r))
                else:
                    b.append(_fill(t, r, digits, p_digits, p_style, missing))
        block = []
        if show_est:
            block.append({"label": label, "cells": est, "kind": "estimate"})
        for b, m, t in zip(below, marks, lines):
            row = {"label": "", "cells": b, "kind": "uncertainty"}
            if isinstance(t, dict):
                row["sparkline"] = dict(t["sparkline"], marks=m)
            block.append(row)
        # without the estimate, a term's first line opens its block and carries its label
        block[0].update(label=label, kind="estimate")
        for j in refs:
            block[0]["cells"][j] = ref
        out_rows += block
    _spark_domains(out_rows)

    for s in spec.get("stats") or []:
        d = s.get("digits", digits)
        cells = []
        if "values" in s:
            cells = [str(v) for v in s["values"]]
            label = s["label"]
        elif "metric" in s:
            m = s["metric"]
            label = s.get("label") or STAT_LABELS.get(m, m)
            for c in cols:
                g = glance(c["found"].record, vcov=c["spec"].get("vcov"), metrics="all")
                if m == "rmse" and "rmse" not in g:
                    g["rmse"] = glance(c["found"].record, metrics="table").get("rmse")
                v = g.get(m)
                cells.append(missing if v is None else _stat_value(v, d, thousands))
        elif "vcov" in s:
            label = s.get("label") or ("Std. errors" if s["vcov"] == "type" else "Clusters")
            for c in cols:
                v = pick_vcov(c["found"].record, c["spec"].get("vcov"))
                if v is None:
                    cells.append(missing)
                elif s["vcov"] == "type":
                    cells.append(vcov_label(v))
                else:
                    n = v.get("n_clusters") or {}
                    vals = [_stat_value(x, 0, thousands) for x in n.values()] if isinstance(n, dict) else []
                    cells.append(" / ".join(vals) or missing)
        elif "fixed_effect" in s:
            fe = s["fixed_effect"]
            label = s.get("label") or f"FE: {fe}"
            yes, no = fmt.get("fe_yes", "Y"), fmt.get("fe_no", "N")
            for c in cols:
                has = fe in ((c["found"].record.get("specification") or {}).get("fixed_effects") or [])
                cells.append(yes if has else no)
        elif "test" in s:
            label = s.get("label") or s["test"]
            which = s.get("value", "statistic")
            for c in cols:
                t = _find_test(c["found"].record, s["test"])
                v = _num(t.get(which)) if t else math.nan
                if math.isnan(v):
                    cells.append(missing)
                elif which == "p_value":
                    cells.append(_p_value(v, s.get("digits", p_digits), p_style))
                else:
                    cells.append(_fixed(v, d))
        out_rows.append({"label": label, "cells": cells, "kind": "stat"})

    notes = list(spec.get("notes") or [])
    if stars and show_est:
        notes.append(", ".join(f"{sym} p < {t:g}" for t, sym in zip(stars, symbols)))
    note = _uncertainty_note(spec, lines)
    if note:
        notes.append(note)
    return {
        "title": spec.get("title"),
        "head": _head_rows(spec, cols),
        "header": [c["number"] for c in cols],
        "column_records": [c["found"].record["meta"]["id"] for c in cols],
        "rows": out_rows,
        "notes": notes,
        "warnings": [str(i) for i in issues if i.level == "warning"],
    }


# ---------------------------------------------------------------- rendering

_LATEX = {
    "&": r"\&",
    "%": r"\%",
    "$": r"\$",
    "#": r"\#",
    "_": r"\_",
    "{": r"\{",
    "}": r"\}",
    "~": r"\textasciitilde{}",
    "^": r"\textasciicircum{}",
    "\\": r"\textbackslash{}",
}


def _tex(s: str) -> str:
    return "".join(_LATEX.get(ch, ch) for ch in s)


def _render_markdown(t: dict) -> str:
    def esc(s):
        return s.replace("\\", "\\\\").replace("|", "\\|").replace("*", "\\*")

    lines = []
    if t["title"]:
        lines += [f"**{esc(t['title'])}**", ""]
    n = len(t["header"])
    head = [h["cells"] for h in t["head"]] or [[""] * n]
    # Markdown has one heading row: the first; the others open the body
    lines.append("| | " + " | ".join(map(esc, head[0])) + " |")
    lines.append("|---|" + "---:|" * n)
    for cells in head[1:]:
        lines.append("| | " + " | ".join(map(esc, cells)) + " |")
    for r in t["rows"]:
        lines.append(f"| {esc(r['label'])} | " + " | ".join(map(esc, r["cells"])) + " |")
    if t["notes"]:
        lines += [""] + [f"{esc(n)}  " for n in t["notes"]]
    return "\n".join(lines).rstrip() + "\n"


def _latex_cells(r: dict, e) -> list[str]:
    sp = r.get("sparkline")
    if sp is None:
        return [e(x) for x in r["cells"]]
    return [_spark_tikz(m, sp["color"]) for m in sp["marks"]]


def _latex_beside(t: dict, plan: dict, i: int, e) -> list[str]:
    """Row i's cells with a sparkline beside the estimates (`_beside_plan`): each column's
    own cell, then its drawing. Level with the estimate, the term's first row has the marks
    and its other rows the 0 rule; centred, the first row's picture draws the rule down
    through the term's rows and the marks at their middle, and the other rows are empty
    there. Rows outside a term's block (statistics) span both columns."""
    rows = t["rows"]
    own = _latex_cells(rows[i], e)
    if i in plan["start"] or i in plan["inside"]:
        k = plan["start"][i][0] if i in plan["start"] else plan["inside"][i]
        sp = rows[k]["sparkline"]
        if plan["align"] == "estimate":
            side = [_spark_tikz(m, sp["color"], rule_only=i not in plan["start"]) for m in sp["marks"]]
        elif i in plan["start"]:
            side = [_spark_tikz(m, sp["color"], rows=plan["start"][i][1]) for m in sp["marks"]]
        else:
            side = [""] * len(own)
        return [f"{a} & {b}" for a, b in zip(own, side)]
    return [f"\\multicolumn{{2}}{{c}}{{{x}}}" for x in own]


def _render_latex(t: dict, escape: bool = True) -> str:
    e = _tex if escape else (lambda s: s)
    n = len(t["header"])
    plan = _beside_plan(t)
    lines = [TIKZ_NOTE] if any("sparkline" in r for r in t["rows"]) else []
    lines += ["\\begin{table}[htbp]", "\\centering"]
    if t["title"]:
        lines.append(f"\\caption{{{e(t['title'])}}}")
    lines += [f"\\begin{{tabular}}{{l{('cc' if plan else 'c') * n}}}", "\\toprule"]
    for h in t["head"]:
        cells = [f"\\multicolumn{{2}}{{c}}{{{e(x)}}}" if plan else e(x) for x in h["cells"]]
        lines.append(" & " + " & ".join(cells) + " \\\\")
    lines.append("\\midrule")
    prev = None
    for i, r in enumerate(t["rows"]):
        if plan and i in plan["skip"]:
            continue
        kind = _row_kind(t, plan, i)
        if kind == "stat" and prev != "stat":
            lines.append("\\midrule")
        label = plan["label"].get(i, r["label"]) if plan else r["label"]
        cells = _latex_beside(t, plan, i, e) if plan else _latex_cells(r, e)
        lines.append(f"{e(label)} & " + " & ".join(cells) + " \\\\")
        prev = kind
    lines.append("\\bottomrule")
    lines.append("\\end{tabular}")
    if t["notes"]:
        lines.append("\\par\\smallskip{\\footnotesize " + " ".join(map(e, t["notes"])) + "}")
    lines.append("\\end{table}")
    return "\n".join(lines) + "\n"


def _html_cell(r: dict, j: int) -> str:
    sp = r.get("sparkline")
    if sp is None:
        return f"<td>{html.escape(r['cells'][j])}</td>"
    return f'<td class="spark">{_spark_svg(sp["marks"][j], sp["color"], r["cells"][j])}</td>'


def _spark_img(
    m: dict | None,
    color: str,
    label: str,
    height: int = SPARK_H,
    mid: int | None = None,
    rule_only: bool = False,
    width: int = SPARK_W,
) -> str:
    """A sparkline as an <img> of its SVG (Word keeps images, not inline SVG); `rule_only`
    draws only its 0 rule."""
    if m is None:
        return ""
    if "estimate" not in m and not m.get("reference"):
        rule_only = True
    svg = _spark_rule(m, height, width) if rule_only else _spark_svg(m, color, height=height, mid=mid, width=width)
    data = base64.b64encode(svg.encode("ascii")).decode("ascii")
    return (
        f'<img width="{width}" height="{height}" style="display:block;margin:0 auto;vertical-align:middle" '
        f'alt="{"" if rule_only else html.escape(_spark_label(m, label))}" '
        f'src="data:image/svg+xml;base64,{data}">'
    )


def _beside_plan(t: dict) -> dict | None:
    """How a table with a sparkline beside the estimates is laid out (HTML, Word, LaTeX): each data
    column gets a second column. Aligned "middle", each term's drawing is one cell there
    spanning the term's other rows; aligned "estimate", the term's first row has the drawing
    and its other rows a cell with the 0 rule only. None without such a line. Keys: "align";
    "start" {row: (drawn row, rows spanned, block end)}, "skip" (rows drawn beside, not as
    rows), "inside" {row: drawn row} (the term's other rows), "label" {row: label moved from
    a skipped first row}. A term whose only row is the sparkline keeps it as a row."""
    rows = t["rows"]
    if not any((r.get("sparkline") or {}).get("place") == "beside" for r in rows):
        return None
    align = next(r["sparkline"].get("align", "estimate") for r in rows if (r.get("sparkline") or {}).get("place") == "beside")
    plan: dict = {"align": align, "start": {}, "skip": set(), "inside": {}, "label": {}}
    i = 0
    while i < len(rows):
        if rows[i]["kind"] == "stat":
            i += 1
            continue
        j = i + 1
        while j < len(rows) and rows[j]["kind"] == "uncertainty":
            j += 1
        side = [k for k in range(i, j) if (rows[k].get("sparkline") or {}).get("place") == "beside"]
        rest = [k for k in range(i, j) if k not in side]
        if side and rest:
            plan["start"][rest[0]] = (side[0], len(rest), j)
            plan["skip"].add(side[0])
            plan["inside"].update({k: side[0] for k in rest[1:]})
            if side[0] == i:
                plan["label"][rest[0]] = rows[i]["label"]
        i = j
    return plan


def _row_kind(t: dict, plan: dict | None, i: int) -> str:
    return "estimate" if plan and i in plan["label"] else t["rows"][i]["kind"]


_SIDE_TD = 'style="position:relative;padding:0;width:80px;min-width:80px"'
# level with the estimate: the cells keep the rows' vertical padding, so the marks sit on
# the numbers' line, and the 0 rule fills the whole cell
_SIDE_TD_ROW = 'style="position:relative;padding-left:0;padding-right:0;width:80px;min-width:80px"'


def _render_html(t: dict) -> str:
    h = html.escape
    plan = _beside_plan(t)
    span = ' colspan="2"' if plan else ""
    out = ['<table class="estrec-table">']
    if t["title"]:
        out.append(f"<caption>{h(t['title'])}</caption>")
    out.append(
        "<thead>"
        + "".join(
            f'<tr class="head-{r["kind"]}"><th></th>'
            + "".join(f"<th{span}>{h(x)}</th>" for x in r["cells"])
            + "</tr>"
            for r in t["head"]
        )
        + "</thead>"
    )
    out.append("<tbody>")
    prev = None
    rows = t["rows"]
    for i, r in enumerate(rows):
        if plan and i in plan["skip"]:
            continue
        kind = _row_kind(t, plan, i)
        cls = kind + (" first-stat" if kind == "stat" and prev != "stat" else "")
        cls += " spark-row" if "sparkline" in r else ""
        label = plan["label"].get(i, r["label"]) if plan else r["label"]
        if plan and plan["align"] == "estimate" and (i in plan["start"] or i in plan["inside"]):
            k = plan["start"][i][0] if i in plan["start"] else plan["inside"][i]
            sp = rows[k]["sparkline"]
            cells = "".join(
                _html_cell(r, j)
                + f'<td class="spark-side" {_SIDE_TD_ROW}>'
                + _spark_rule(sp["marks"][j])
                + (
                    _spark_svg(
                        sp["marks"][j], sp["color"], rows[k]["cells"][j], style="display:block;margin:0 auto;position:relative"
                    )
                    if i in plan["start"]
                    else ""
                )
                + "</td>"
                for j in range(len(r["cells"]))
            )
        elif plan and i in plan["start"]:
            k, n, end = plan["start"][i]
            sp = rows[k]["sparkline"]
            side = "spark-side" + (" to-end" if end == len(rows) else "")
            cells = "".join(
                _html_cell(r, j)
                + f'<td class="{side}" rowspan="{n}" {_SIDE_TD}>'
                + _spark_svg_tall(sp["marks"][j], sp["color"], rows[k]["cells"][j])
                + "</td>"
                for j in range(len(r["cells"]))
            )
        elif plan and i not in plan["inside"]:
            cells = "".join(_html_cell(r, j).replace("<td", "<td colspan=\"2\"", 1) for j in range(len(r["cells"])))
        else:
            cells = "".join(_html_cell(r, j) for j in range(len(r["cells"])))
        out.append(f'<tr class="{cls}"><th>{h(label)}</th>' + cells + "</tr>")
        prev = kind
    out.append("</tbody>")
    if t["notes"]:
        out.append(
            f'<tfoot><tr><td colspan="{len(t["header"]) * (2 if plan else 1) + 1}">'
            + "<br>".join(map(h, t["notes"]))
            + "</td></tr></tfoot>"
        )
    out.append("</table>")
    return "\n".join(out) + "\n"


def _render_csv(t: dict) -> str:
    import csv
    import io

    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    for h in t["head"]:
        w.writerow([""] + h["cells"])
    for r in t["rows"]:
        w.writerow([r["label"]] + r["cells"])
    return buf.getvalue()


def _render_text(t: dict) -> str:
    head = [[""] + h["cells"] for h in t["head"]]
    body = [[r["label"]] + r["cells"] for r in t["rows"]]
    rows = head + body + [[""] * (len(t["header"]) + 1)]
    widths = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]

    def line(r):
        return "  ".join(
            c.ljust(widths[0]) if i == 0 else c.rjust(widths[i]) for i, c in enumerate(r)
        ).rstrip()

    rule = "  ".join("-" * w for w in widths)
    out = []
    if t["title"]:
        out.append(t["title"])
    out += [line(r) for r in head] + [rule]
    prev = None
    for r, src in zip(body, t["rows"]):
        if src["kind"] == "stat" and prev != "stat":
            out.append(rule)
        out.append(line(r))
        prev = src["kind"]
    out += [rule, *t["notes"]]
    return "\n".join(out) + "\n"


# Word: inline styles only (Word drops classes and style sheets when pasting), borders as a
# journal table's three rules, numbers centred, no font family (the document's is kept).
_WORD_RULE = "solid windowtext"
_WORD_CELL = "padding:0 5.4pt;border:none;white-space:nowrap"


def _word_cell(
    text: str,
    *,
    left: bool,
    top: str = "",
    bottom: str = "",
    pad_top: str = "",
    raw: str | None = None,
    attrs: str = "",
    style_extra: str = "",
    font: str = "10",
) -> str:
    # the font size on every cell: Word ignores the table's when pasting
    style = _WORD_CELL + f";font-size:{font}pt" + (";text-align:left" if left else ";text-align:center")
    if top:
        style += f";border-top:{top} {_WORD_RULE}"
    if bottom:
        style += f";border-bottom:{bottom} {_WORD_RULE}"
    if pad_top:
        style += f";padding-top:{pad_top}"
    return f'<td{attrs} style="{style}{style_extra}">{html.escape(text) if raw is None else raw}</td>'


def _word_widths(t: dict, plan: dict | None, width: float, font: float = 10) -> dict:
    """Column widths for a Word table `width` inches wide, in tenths of a point: the label
    column as wide as its longest label (about half the font size a character, plus padding),
    between 36 pt and 40% of the table; the data columns share the rest equally. Beside the
    estimates, a data column splits into the numbers (as wide as the longest, at least 20 pt)
    and the drawing (the rest, at least 24 pt); the drawings' widths in pixels follow."""
    total = math.floor(width * 720 + 0.5)
    n = len(t["header"])
    rows = t["rows"]
    lab = max([len(r["label"]) for r in rows] + [0])
    label = min(max(math.floor(font * 5 + 0.5) * lab + 108, 360), total * 2 // 5)
    col = (total - label) // n
    out = {"total": total, "label": total - col * n, "col": col, "below_px": max((col - 108) * 4 // 30, 1)}
    if plan:
        block = [rows[i] for i in list(plan["start"]) + list(plan["inside"])]
        numc = max([len(c) for r in block for c in r["cells"]] + [0])
        num = min(max(math.floor(font * 5.5 + 0.5) * numc + 108, 200), col - 240) if col >= 440 else col // 2
        out.update(num=num, side=col - num, side_px=max((col - num) * 4 // 30, 1))
    return out


def _pt(n: int) -> str:
    return f"{n // 10}.{n % 10}pt"


def _px_pt(px: int) -> str:
    """Pixels as points (x 0.75), exactly."""
    n = px * 75
    return f"{n // 100}.{n % 100:02d}pt"


def _js_num(x: float) -> str:
    """A number as JavaScript's String() writes it (10, 9.5)."""
    x = float(x)
    return str(int(x)) if x.is_integer() else repr(x)


def _render_word(t: dict, width: float | None = None, font: float = 10, term_space: bool | None = None) -> str:
    """A whole HTML document that Word, Google Docs, LibreOffice and Excel paste or open as a
    formatted table (the viewer's Copy for Word puts it on the clipboard). With a sparkline
    beside the estimates, a term's rows are exactly 12 pt high (15 pt with the space above a
    term) and its drawing is an image of their height, so a column of them joins. `width`
    (inches, e.g. 6.5) fixes the table's and every column's width and draws the sparklines
    to fit (`_word_widths`); without it the table takes its natural width. `font` (points)
    is set on every cell and sizes the rows (1.2 x font) and the space above each term
    (0.3 x font; by default only when the table has no sparklines, so they join)."""
    h = html.escape
    plan = _beside_plan(t)
    fs = _js_num(font)
    line_px = math.floor(font * 1.6 + 0.5)
    if term_space is None:
        term_space = not any("sparkline" in r for r in t["rows"])
    pad_px = math.floor(font * 0.4 + 0.5) if term_space else 0
    W = _word_widths(t, plan, width, font) if width else None

    def wd(n):  # a cell's width, when the table's is fixed
        return f";width:{_pt(n)}" if W else ""

    spw = W["below_px"] if W else SPARK_W
    sidew = W["side_px"] if W and plan else SPARK_W
    span = ' colspan="2"' if plan else ""
    title = t["title"] or "Estimation table"
    out = [
        "<!doctype html>",
        '<html><head><meta charset="utf-8">',
        f"<title>{h(title)}</title></head><body>",
    ]
    if t["title"]:
        out.append(f'<p style="margin:0 0 6pt 0;font-size:{fs}pt"><b>{h(t["title"])}</b></p>')
    fixed = f";width:{_pt(W['total'])};table-layout:fixed" if W else ""
    out.append(f'<table style="border-collapse:collapse;border:none;font-size:{fs}pt{fixed}">')
    nh = len(t["head"])
    for k, hr in enumerate(t["head"]):
        top = "1.5pt" if k == 0 else ""
        bottom = ".75pt" if k == nh - 1 else ""
        out.append(
            "<tr>"
            + "".join(
                _word_cell(
                    x,
                    left=i == 0,
                    top=top,
                    bottom=bottom,
                    attrs=span if i else "",
                    style_extra=wd(W["col"] if i else W["label"]) if W else "",
                    font=fs,
                )
                for i, x in enumerate([""] + hr["cells"])
            )
            + "</tr>"
        )
    rows = t["rows"]
    prev = None
    last = len(rows) - 1
    shown = [i for i in range(len(rows)) if not (plan and i in plan["skip"])]
    first = shown[0] if shown else 0

    def pads(i):  # the space above a term; sparkline rows stay unpadded so they join
        return pad_px > 0 and _row_kind(t, plan, i) == "estimate" and i > first and "sparkline" not in rows[i]

    def row_px(i):
        return line_px + (pad_px if pads(i) else 0)

    for i in shown:
        r = rows[i]
        kind = _row_kind(t, plan, i)
        top = ".75pt" if kind == "stat" and prev != "stat" else ""
        if i == first and not nh:
            top = "1.5pt"
        bottom = "1.5pt" if i == last else ""
        sp = r.get("sparkline")
        pad = pads(i)
        label = plan["label"].get(i, r["label"]) if plan else r["label"]
        exact = plan and (i in plan["start"] or i in plan["inside"])
        tr = f'<tr style="height:{_px_pt(row_px(i))};mso-height-rule:exactly">' if exact else "<tr>"
        cells = []
        for c, x in enumerate([label] + r["cells"]):
            raw = _spark_img(sp["marks"][c - 1], sp["color"], x, width=spw) if sp and c else None
            many = plan and c and i not in plan["start"] and i not in plan["inside"]
            cw = ""
            if W:
                cw = wd(W["label"] if c == 0 else W["num"] if plan and not many else W["col"])
            cells.append(
                _word_cell(
                    x,
                    left=c == 0,
                    top=top,
                    bottom=bottom,
                    pad_top=_px_pt(pad_px) if pad else "",
                    raw=raw,
                    attrs=' colspan="2"' if many else "",
                    style_extra=cw,
                    font=fs,
                )
            )
            if plan and c and plan["align"] == "estimate" and (i in plan["start"] or i in plan["inside"]):
                k = plan["start"][i][0] if i in plan["start"] else plan["inside"][i]
                ssp = rows[k]["sparkline"]
                px = row_px(i)
                cells.append(
                    _word_cell(
                        "",
                        left=False,
                        top=top,
                        bottom=bottom,
                        raw=_spark_img(
                            ssp["marks"][c - 1],
                            ssp["color"],
                            rows[k]["cells"][c - 1],
                            px,
                            mid=(px - line_px) * 10 + line_px * 5,
                            rule_only=i not in plan["start"],
                            width=sidew,
                        ),
                        style_extra=";padding:0;vertical-align:top" + (wd(W["side"]) if W else ""),
                        font=fs,
                    )
                )
            elif plan and c and i in plan["start"]:
                k, n, end = plan["start"][i]
                ssp = rows[k]["sparkline"]
                height = sum(row_px(q) for q in range(i, end) if q not in plan["skip"])
                cells.append(
                    _word_cell(
                        "",
                        left=False,
                        top=top,
                        bottom="1.5pt" if end == len(rows) else "",
                        raw=_spark_img(ssp["marks"][c - 1], ssp["color"], rows[k]["cells"][c - 1], height, width=sidew),
                        attrs=f' rowspan="{n}"',
                        style_extra=";padding:0;vertical-align:top" + (wd(W["side"]) if W else ""),
                        font=fs,
                    )
                )
        out.append(tr + "".join(cells) + "</tr>")
        prev = kind
    out.append("</table>")
    for n in t["notes"]:
        out.append(f'<p style="margin:3pt 0 0 0;font-size:{_js_num(font - 1)}pt">{h(n)}</p>')
    out.append("</body></html>")
    return "\n".join(out) + "\n"


RENDERERS = {
    "markdown": _render_markdown,
    "latex": _render_latex,
    "html": _render_html,
    "csv": _render_csv,
    "text": _render_text,
    "word": _render_word,
}


def render(table: dict, format: str = "text", **options: Any) -> str:
    """A built table (`build_table`) as text: "text", "markdown", "latex", "html", "csv"
    or "word" (an HTML document styled inline, for pasting into or opening in Word).
    LaTeX takes `escape=False` to keep labels as written (for math in labels)."""
    if format not in RENDERERS:
        raise ValueError(f"format is one of {', '.join(RENDERERS)}")
    return RENDERERS[format](table, **options)


def render_table(
    spec: dict | str | os.PathLike,
    format: str = "text",
    *,
    base_dir: str | os.PathLike | None = None,
    records: Any = None,
    **options: Any,
) -> str:
    """Build and render a spec (a dict or a path; a path's folder is `base_dir`)."""
    if not isinstance(spec, dict):
        path = Path(spec)
        spec = read_table(path)
        base_dir = path.parent if base_dir is None else base_dir
    return render(build_table(spec, base_dir=base_dir, records=records), format, **options)


def to_great_table(table: dict):
    """A built table as a great_tables GT object (needs great_tables and pandas or polars)."""
    try:
        import great_tables as gt
    except ImportError as e:  # pragma: no cover - depends on the environment
        raise ImportError("to_great_table needs great_tables: pip install great_tables") from e
    try:
        import polars as pl

        frame = pl.DataFrame(
            {
                "": [r["label"] for r in table["rows"]],
                **{h: [r["cells"][i] for r in table["rows"]] for i, h in enumerate(table["header"])},
            }
        )
    except ImportError:
        import pandas as pd

        frame = pd.DataFrame(
            {
                "": [r["label"] for r in table["rows"]],
                **{h: [r["cells"][i] for r in table["rows"]] for i, h in enumerate(table["header"])},
            }
        )
    g = gt.GT(frame)
    if table["head"]:
        g = g.cols_label(
            **{
                h: gt.html("<br>".join(html.escape(r["cells"][i]) for r in table["head"]))
                for i, h in enumerate(table["header"])
            }
        )
    if table["title"]:
        g = g.tab_header(title=table["title"])
    for n in table["notes"]:
        g = g.tab_source_note(n)
    return _great_sparklines(g, table, gt)


def _great_sparklines(g, table: dict, gt):
    """Sparkline cells drawn as in `render`: the SVG in HTML, TikZ in LaTeX, the interval as
    text elsewhere; their rows unpadded and the body without hairlines, so a column joins."""
    rows = [i for i, r in enumerate(table["rows"]) if "sparkline" in r]
    if not rows:
        return g
    try:
        from great_tables._formats import FormatFns
    except ImportError:  # pragma: no cover - older great_tables: HTML only
        FormatFns = None
    for i in rows:
        sp = table["rows"][i]["sparkline"]
        for j, h in enumerate(table["header"]):
            m, text = sp["marks"][j], table["rows"][i]["cells"][j]
            svg = _spark_svg(m, sp["color"], text)
            if FormatFns is None:
                fns = lambda _, s=svg: s  # noqa: E731
            else:
                tikz = _spark_tikz(m, sp["color"])
                fns = FormatFns(html=lambda _, s=svg: s, latex=lambda _, s=tikz: s, default=lambda _, s=text: s)
            g = g.fmt(fns, columns=h, rows=[i])
    g = g.tab_style(
        style=gt.style.css("padding-top:0;padding-bottom:0;line-height:16px"), locations=gt.loc.body(rows=rows)
    )
    return g.tab_options(table_body_hlines_style="none")


# ---------------------------------------------------------------- command line


def add_arguments(p) -> None:
    """The `table` options, for the `estrec` CLI and `python -m estrec.table`."""
    p.add_argument("spec", help="an *.estrec-table.json file")
    p.add_argument("--format", "-f", default="text", choices=sorted(RENDERERS))
    p.add_argument("--check", action="store_true", help="validate only; exit 1 on errors")
    p.add_argument("-o", "--output", help="write to a file instead of printing")


def run(a) -> int:
    import sys

    path = Path(a.spec)
    try:
        spec = read_table(path)
    except (OSError, ValueError) as e:
        print(f"estrec table: {e}", file=sys.stderr)
        return 1
    if a.check:
        issues = validate_table(spec, base_dir=path.parent)
        for i in issues:
            print(i)
        return 1 if any(i.level == "error" for i in issues) else 0
    try:
        t = build_table(spec, base_dir=path.parent)
    except ValueError as e:
        print(f"estrec table: {e}", file=sys.stderr)
        return 1
    for w in t["warnings"]:
        print(w, file=sys.stderr)
    text = render(t, a.format)
    if a.output:
        Path(a.output).write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0


def main(argv: list[str] | None = None) -> int:
    import argparse

    p = argparse.ArgumentParser(prog="estrec table", description="Render or check a table spec.")
    add_arguments(p)
    return run(p.parse_args(argv))


if __name__ == "__main__":
    raise SystemExit(main())


__all__ = [
    "TABLE_SCHEMA",
    "build_table",
    "index_records",
    "new_table",
    "read_table",
    "render",
    "render_table",
    "to_great_table",
    "validate_table",
    "write_table",
]
