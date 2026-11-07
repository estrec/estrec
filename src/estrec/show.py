# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Ted Matherly and the estrec contributors
"""`estrec show`: a quick look at records in the terminal. One record gets a detail view
(estimates, metrics, fixed effects, vcov, tests, messages); several records, a folder or a
collection get a side-by-side regression table (estimates over standard errors, then N,
R-squareds, the standard errors' type and fixed-effect rows), built as a table spec
(`table.new_table`) and rendered as text."""

from __future__ import annotations

import math
import os
from pathlib import Path
from typing import Any

from .collection import is_collection, loads_collection
from .records import loads
from .table import DEFAULT_STARS, build_table, new_table, render
from .table import _stars as _star_mark
from .views import _locator_label, _num, glance, pick_vcov, tidy, vcovs

# the same cuts as new tables (`table.DEFAULT_STARS`), so a quick look and a table agree
STARS = DEFAULT_STARS
STAR_SYMBOLS = ["*" * (i + 1) for i in range(len(STARS))]
# the metrics the side-by-side table shows when any record has them (labels: table.STAT_LABELS)
TABLE_ROWS = (
    ("nobs", "N"),
    ("r2", "R²"),
    ("adj_r2", "Adj. R²"),
    ("r2_within", "Within R²"),
    ("pseudo_r2", "Pseudo R²"),
    ("aic", "AIC"),
    ("bic", "BIC"),
    ("rmse", "RMSE"),
)


def _stars(p: float) -> str:
    return _star_mark(p, STARS, STAR_SYMBOLS)


def _fmt(x: Any, digits: int = 3) -> str:
    """A number for a table: counts in full with separators, others to `digits` decimals
    (scientific when that would show nothing)."""
    if x is None:
        return ""
    if isinstance(x, (bool, str)):
        return str(x)
    x = float(x)
    if math.isnan(x):
        return "NaN"
    if math.isinf(x):
        return "Inf" if x > 0 else "-Inf"
    if x == int(x) and abs(x) < 1e15 and abs(x) >= 1:
        return f"{int(x):,}"
    if x != 0 and abs(x) < 0.5 * 10**-digits:
        return f"{x:.{max(digits - 1, 1)}e}"
    return f"{x:.{digits}f}"


def _fmt_p(p: float) -> str:
    if p is None or math.isnan(p):
        return ""
    return "<1e-16" if p < 1e-16 else f"{p:.3g}"


def _table(rows: list[list[str]], right: set[int], header: list[str] | None = None) -> list[str]:
    """Rows of strings as aligned columns; `right` are the right-aligned column indexes."""
    allrows = ([header] if header else []) + rows
    if not allrows:
        return []
    widths = [max(len(r[i]) for r in allrows) for i in range(len(allrows[0]))]

    def line(r):
        cells = [c.rjust(w) if i in right else c.ljust(w) for i, (c, w) in enumerate(zip(r, widths))]
        return "  ".join(cells).rstrip()

    out = [line(r) for r in allrows]
    if header:
        out.insert(1, "  ".join("-" * w for w in widths))
    return out


def _software(rec: dict) -> str | None:
    sw = (rec.get("provenance") or {}).get("software") or []
    if isinstance(sw, dict):
        sw = [sw]
    pick = [s for s in sw if s.get("role") == "estimator"][:1] or sw[:1]
    pick += [s for s in sw if s.get("role") == "language"][:1]
    names = [" ".join(str(x) for x in (s.get("name"), s.get("version")) if x) for s in pick]
    return ", ".join(n for n in names if n) or None


def show_record(rec: dict, *, vcov: Any = None, digits: int = 4, member: dict | None = None) -> str:
    """A detail view of one record."""
    meta = rec.get("meta") or {}
    est = meta.get("estimator") or {}
    spec = rec.get("specification") or {}
    out = [f"estimation record{': ' + meta['title'] if meta.get('title') else ''}"]
    what = " / ".join(x for x in (est.get("family"), est.get("method")) if x) or "?"
    resp = ", ".join(meta.get("responses") or [])
    out.append(f"  {what}{' of ' + resp if resp else ''}    status: {meta.get('status', '?')}")
    formula = (
        (spec.get("formula") or {}).get("text")
        if isinstance(spec.get("formula"), dict)
        else spec.get("formula")
    )
    if formula:
        out.append(f"  {formula}")
    if member:
        locs = member.get("locators") or ([member["locator"]] if member.get("locator") else [])
        loc = "; ".join(filter(None, map(_locator_label, locs)))
        out.append(f"  member: {member.get('label') or member.get('id')}{'  (' + loc + ')' if loc else ''}")
    sw = _software(rec)
    if sw:
        out.append(f"  software: {sw}")
    v = pick_vcov(rec, vcov)
    if v is not None:
        cl = v.get("cluster") or []
        cl = [cl] if isinstance(cl, str) else cl
        ssc = (v.get("ssc") or {}).get("convention")
        more = len(vcovs(rec)) - 1
        out.append(
            f"  vcov: {v.get('type', '?')}"
            + (f", clustered by {' & '.join(cl)}" if cl else "")
            + (f" ({ssc} ssc)" if ssc else "")
            + (f"; {more} more in the record" if more > 0 and vcov is None else "")
        )
    out.append("")

    rows = tidy(rec, vcov=vcov, component="all", dropped=True)
    multi = len({r.get("response") for r in rows if r.get("response")}) > 1
    body = []
    for r in rows:
        name = r["term"]
        if multi and r.get("response"):
            name = f"{r['response']}: {name}"
        if r.get("component"):
            name = f"[{r['component']}] {name}"
        if r.get("dropped"):
            body.append([name, "", "", "", f"({r['dropped']})"])
            continue
        body.append(
            [
                name,
                f"{r['estimate']:.{digits}g}",
                f"{r['std_error']:.{digits}g}" if not math.isnan(r["std_error"]) else "",
                _fmt_p(r["p_value"]),
                _stars(r["p_value"]),
            ]
        )
    out += _table(body, right={1, 2, 3}, header=["", "Estimate", "Std. Error", "p value", ""])
    out.append("")

    ms = glance(rec, vcov=vcov, metrics="all")
    ms.pop("vcov_type", None)
    fes = ms.pop("fixed_effects", None)
    items = [f"{k} {_fmt(v, digits)}" for k, v in ms.items() if not isinstance(v, (list, dict))]
    line = " "
    for it in items:
        if len(line) + len(it) + 2 > 92:
            out.append(line.rstrip("; "))
            line = " "
        line += f" {it};"
    if items:
        out.append(line.rstrip("; "))
    fe_structs = (rec.get("structures") or {}).get("fixed_effects")
    if isinstance(fe_structs, dict):
        fe_structs = [fe_structs]
    if fe_structs:
        txt = ", ".join(f"{f.get('name')} ({_fmt(_num(f.get('levels')), 0)})" for f in fe_structs)
        out.append(f"  fixed effects: {txt}")
    elif fes:
        out.append(f"  fixed effects: {', '.join(fes)}")
    tests = rec.get("tests") or []
    for t in tests:
        lab = t.get("label") or t.get("name") or "test"
        stat = _num(t.get("statistic"))
        p = _num(t.get("p_value"))
        out.append(
            f"  test {lab}: "
            + (f"{t.get('distribution', 'stat')} = {_fmt(stat, 3)}" if not math.isnan(stat) else "")
            + (f", p = {_fmt_p(p)}" if not math.isnan(p) else "")
        )
    for m in meta.get("messages") or []:
        out.append(f"  {m.get('level', 'note')}: {m.get('message')}")
    return "\n".join(out)


def show_table(
    named: list[tuple[str, dict]], *, vcov: Any = None, digits: int = 3, component: Any = None
) -> str:
    """A side-by-side regression table of several records: the table spec `new_table` makes
    for them, built and rendered as text, so `estrec show` matches `estrec table`. Columns
    are headed by the names, then the dependent variable; the statistics rows are the
    metrics in TABLE_ROWS that any record has, the standard errors' type and a row per fixed
    effect. A component with several responses (first stages) gets a column per response."""
    recs = [r for _, r in named]
    glances = [glance(r, vcov=vcov) for r in recs]
    stats: list = [k for k, _ in TABLE_ROWS if any(g.get(k) is not None for g in glances)]
    if any(g.get("vcov_type") for g in glances):
        stats.append({"vcov": "type"})
    spec = new_table(recs, headers=[n for n, _ in named], stats=stats, head=["label", "response"])
    cols = []
    for c, r in zip(spec["columns"], recs):
        if vcov is not None:
            c["vcov"] = vcov
        if component is not None:
            c["component"] = component
            resp = []
            for row in tidy(r, vcov=vcov, component=component):
                if row.get("response") and row["response"] not in resp:
                    resp.append(row["response"])
            if len(resp) > 1:
                cols += [dict(c, response=x) for x in resp]
                continue
        cols.append(c)
    spec["columns"] = cols
    spec["format"] = {"digits": digits}
    return render(build_table(spec, records=recs), "text").rstrip("\n")


def load_for_show(paths: list[str | os.PathLike]) -> list[tuple[str, dict, dict | None]]:
    """(name, record, member entry) for each record in `paths`: record files, folders of them
    (every *.estrec.json, by file stem) and collections (each member, by label)."""
    out = []
    for p in map(Path, paths):
        if p.is_dir():
            files = sorted(p.glob("*.estrec.json"))
            if not files:
                raise ValueError(f"no *.estrec.json files in {p}")
            out += [(f.name.removesuffix(".estrec.json"), loads(f.read_bytes()), None) for f in files]
            continue
        data = p.read_bytes()
        if p.name.endswith(".estrec-collection.json") or b'"estrec-collection/' in data[:400]:
            coll = loads_collection(data)
            if is_collection(coll):
                from .collection import iter_members

                for i, m, rec in iter_members(coll, p.parent):
                    if rec is None:
                        raise ValueError(f"{p}: members[{i}]: record not found")
                    out.append((str(m.get("label") or m.get("id")), rec, m))
                continue
        out.append((p.name.removesuffix(".estrec.json").removesuffix(".json"), loads(data), None))
    return out


def show(
    paths: list[str | os.PathLike],
    *,
    vcov: Any = None,
    digits: int | None = None,
    table: bool | None = None,
    component: Any = None,
) -> str:
    """The text `estrec show` prints: a detail view of a single record, else (or with
    `table=True`) a side-by-side table."""
    items = load_for_show(paths)
    if table is None:
        table = len(items) > 1
    if not table:
        return "\n\n".join(show_record(rec, vcov=vcov, digits=digits or 4, member=m) for _, rec, m in items)
    return show_table([(n, r) for n, r, _ in items], vcov=vcov, digits=digits or 3, component=component)


def add_arguments(p) -> None:
    """The `show` options, for the `estrec` CLI and `python -m estrec.show`."""
    p.add_argument("paths", nargs="+", help="records, folders of records, or collections")
    p.add_argument("--vcov", help='another vcov in the record: a type ("iid", "HC1") or cluster variables')
    p.add_argument("--digits", type=int, help="digits (default 4 in the detail view, 3 in the table)")
    view = p.add_mutually_exclusive_group()
    view.add_argument("--table", dest="table", action="store_true", default=None, help="side-by-side table")
    view.add_argument("--detail", dest="table", action="store_false", help="a detail view of each record")
    p.add_argument("--component", help='with --table: a component to show instead ("first_stage")')


def run(args) -> int:
    try:
        vcov = int(args.vcov) if args.vcov is not None and args.vcov.isdigit() else args.vcov
        print(show(args.paths, vcov=vcov, digits=args.digits, table=args.table, component=args.component))
    except (OSError, ValueError) as e:
        print(f"estrec show: {e}", file=__import__("sys").stderr)
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    import argparse

    p = argparse.ArgumentParser(prog="estrec show", description=__doc__.split("\n\n")[0])
    add_arguments(p)
    return run(p.parse_args(argv))


if __name__ == "__main__":
    raise SystemExit(main())
