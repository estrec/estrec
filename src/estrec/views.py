# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Ted Matherly and the estrec contributors
"""Views of records for tables: `tidy` (parameters as rows), `glance` (one row of metrics)
and `parameters_table` (the flat parameters table across a collection's members, spec 11).

Rows are plain dicts, so any table tool takes them: `polars.DataFrame(rows)`,
`pandas.DataFrame(rows)`, then great_tables or `to_latex`. Column names are the record's own
(`std_error`, `p_value`, ...). These are the same views as estrec's `tidy`/`glance` in R.
"""

from __future__ import annotations

import math
import os
from collections.abc import Iterable, Mapping
from statistics import NormalDist
from typing import Any

from .collection import is_collection, iter_members

PARAMETER_COLUMNS = ("estimate", "std_error", "statistic", "p_value", "conf_low", "conf_high")


# ---------------------------------------------------------------- distributions (stdlib)


def _betacf(a: float, b: float, x: float) -> float:
    """Continued fraction for the regularized incomplete beta (modified Lentz)."""
    tiny = 1e-300
    qab, qap, qam = a + b, a + 1.0, a - 1.0
    c, d = 1.0, 1.0 - qab * x / qap
    d = 1.0 / (d if abs(d) > tiny else tiny)
    h = d
    for m in range(1, 10000):
        m2 = 2 * m
        aa = m * (b - m) * x / ((qam + m2) * (a + m2))
        d = 1.0 + aa * d
        d = 1.0 / (d if abs(d) > tiny else tiny)
        c = 1.0 + aa / c
        c = c if abs(c) > tiny else tiny
        h *= d * c
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
        d = 1.0 + aa * d
        d = 1.0 / (d if abs(d) > tiny else tiny)
        c = 1.0 + aa / c
        c = c if abs(c) > tiny else tiny
        delta = d * c
        h *= delta
        if abs(delta - 1.0) < 1e-15:
            break
    return h


def _lgamma_ratio_half(a: float) -> float:
    """log(Gamma(a + 1/2) / Gamma(a)), without the cancellation of two large lgammas."""
    if a < 50.0:
        return math.lgamma(a + 0.5) - math.lgamma(a)
    # asymptotic series (Tricomi-Erdelyi), accurate to ~1e-17 for a >= 50
    return 0.5 * math.log(a) - 1 / (8 * a) + 1 / (192 * a**3) - 1 / (640 * a**5)


def _betainc(a: float, b: float, x: float, logx: float | None = None, log1mx: float | None = None) -> float:
    """Regularized incomplete beta I_x(a, b). `logx` and `log1mx` may be given precisely."""
    if x <= 0.0:
        return 0.0
    if x >= 1.0:
        return 1.0
    logx = math.log(x) if logx is None else logx
    log1mx = math.log1p(-x) if log1mx is None else log1mx
    lg = (
        _lgamma_ratio_half(a) - math.lgamma(0.5)
        if b == 0.5
        else math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b)
    )
    lbt = lg + a * logx + b * log1mx
    if x < (a + 1.0) / (a + b + 2.0):
        return math.exp(lbt) * _betacf(a, b, x) / a
    return 1.0 - math.exp(lbt) * _betacf(b, a, 1.0 - x) / b


def two_sided_p(stat: float, df: float | None = None) -> float:
    """P(|T| > |stat|) for Student's t on `df` (normal when df is None or infinite)."""
    if stat is None or math.isnan(stat):
        return math.nan
    t = abs(stat)
    if math.isinf(t):
        return 0.0
    if df is None or math.isinf(df):
        return math.erfc(t / math.sqrt(2.0))
    if t == 0.0:
        return 1.0
    if df >= 1e4:
        # Hill (1970), ACM Algorithm 395: a normalizing transform, ~1e-12 relative for df >= 1e4,
        # where the continued fraction would need about sqrt(df) terms
        a = df - 0.5
        b = 48.0 * a * a
        y = a * math.log1p(t * t / df)
        y = (
            ((((-0.4 * y - 3.3) * y - 24.0) * y - 85.5) / (0.8 * y * y + 100.0 + b) + y + 3.0) / b + 1.0
        ) * math.sqrt(y)
        return math.erfc(y / math.sqrt(2.0))
    # x = df / (df + t^2); log x and log(1 - x) via log1p, for large df
    r = t * t / df
    return _betainc(df / 2.0, 0.5, 1.0 / (1.0 + r), -math.log1p(r), math.log(r) - math.log1p(r))


def critical_value(level: float, df: float | None = None) -> float:
    """The two-sided critical value for a `level` interval (t on `df`, else normal)."""
    alpha = 1.0 - level
    z = NormalDist().inv_cdf(1.0 - alpha / 2.0)
    if df is None or math.isinf(df):
        return z
    lo, hi = z, max(2.0 * z, 1.0)
    while two_sided_p(hi, df) > alpha:
        hi *= 2.0
    for _ in range(200):  # bisection: p is decreasing in t
        mid = (lo + hi) / 2.0
        if two_sided_p(mid, df) > alpha:
            lo = mid
        else:
            hi = mid
        if hi - lo < 1e-14 * hi:
            break
    return (lo + hi) / 2.0


# ---------------------------------------------------------------- helpers


def _num(v: Any) -> float:
    """A number, a non-finite string or {value, ...} -> float (nan when absent or not numeric)."""
    if isinstance(v, Mapping):
        v = v.get("value")
    if isinstance(v, bool) or v is None:
        return math.nan
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        return {"NaN": math.nan, "Inf": math.inf, "-Inf": -math.inf}.get(v, math.nan)
    return math.nan


def _metric(v: Any) -> Any:
    """A metric for a table: the scalar, or the `value` of {value, definition}."""
    if isinstance(v, Mapping):
        return v.get("value")
    if isinstance(v, str) and v in ("NaN", "Inf", "-Inf"):
        return _num(v)
    return v


def vcovs(record: dict) -> list[dict]:
    """The record's vcov structures (a list, possibly empty)."""
    v = (record.get("structures") or {}).get("vcov")
    if v is None:
        return []
    return [v] if isinstance(v, Mapping) else list(v)


def vcov_label(v: dict) -> str:
    """ "by: firm" for a clustered vcov, else its type."""
    cl = v.get("cluster") or []
    if isinstance(cl, str):
        cl = [cl]
    return "by: " + " & ".join(cl) if cl else str(v.get("type", "?"))


def pick_vcov(record: dict, vcov: int | str | None = None) -> dict | None:
    """A vcov: None = the default; an int = its position (0-based); a string = its `type`
    ("iid", "HC1", "CRV1", ...) or its cluster variables ("firm", "firm & year", "by: firm")."""
    vs = vcovs(record)
    if vcov is None:
        return next((v for v in vs if v.get("default") is True), None)
    if isinstance(vcov, int):
        return vs[vcov]

    def keys(v):
        cl = v.get("cluster") or []
        cl = [cl] if isinstance(cl, str) else cl
        return {v.get("type"), vcov_label(v), " & ".join(cl)}

    hits = [v for v in vs if vcov in keys(v)]
    if not hits:
        have = ", ".join(f"{v.get('type')} ({vcov_label(v)})" for v in vs)
        raise ValueError(f"no vcov {vcov!r}; the record has: {have}")
    if len(hits) > 1:
        raise ValueError(f"vcov {vcov!r} matches {len(hits)} matrices; pick one by position")
    return hits[0]


# ---------------------------------------------------------------- views


def tidy(
    record: dict,
    *,
    vcov: int | str | None = None,
    conf_level: float | None = None,
    component: str | Iterable[str] | None = None,
    dropped: bool = False,
) -> list[dict]:
    """The parameters, one dict per row: `term`, `estimate`, `std_error`, `statistic`,
    `p_value`, `conf_low`, `conf_high`, and `response`/`component`/`mediation` where the record has them.

    By default the values are as written (from the default vcov). With `vcov`, they come from
    another vcov in the record: SEs from its diagonal, t tests on its `df_t` (normal without
    one). A `conf_level` other than the record's recomputes the interval the same way.
    `component=None` keeps the main model (rows with no component); "all" keeps every row.
    Dropped (collinear, reference) terms are left out unless `dropped=True`."""
    rows = []
    for p in record.get("parameters") or []:
        comp = p.get("component")
        if component is None and comp is not None:
            continue
        if component not in (None, "all"):
            want = {component} if isinstance(component, str) else set(component)
            if comp not in want:
                continue
        if p.get("dropped") is not None and not dropped:
            continue
        row = {"term": p.get("term")}
        for k in ("response", "component", "dropped", "mediation"):
            if p.get(k) is not None:
                row[k] = p[k]
        for k in PARAMETER_COLUMNS:
            row[k] = _num(p.get(k))
        rows.append(row)

    v = pick_vcov(record, vcov)
    recompute = vcov is not None and not (v or {}).get("default")
    df_t = _num((v or {}).get("df_t"))
    df_t = None if math.isnan(df_t) else df_t
    if recompute:
        if v.get("kind") == "link":
            raise ValueError(
                f"this vcov is in attachment {v.get('attachment')!r}: load it with load_structure first"
            )
        labels = list(v.get("labels") or v.get("row_labels") or [])
        diag = {lab: _num(v["data"][i][i]) for i, lab in enumerate(labels)}
        for r in rows:
            var = diag.get(r["term"], math.nan)
            se = math.sqrt(var) if var >= 0 else math.nan
            r["std_error"] = se
            r["statistic"] = r["estimate"] / se if se else math.nan
            r["p_value"] = two_sided_p(r["statistic"], df_t)
    level = _num((record.get("metrics") or {}).get("conf_level"))
    want_level = conf_level if conf_level is not None else (0.95 if math.isnan(level) else level)
    if (
        recompute
        or math.isnan(level)
        or abs(want_level - level) > 1e-12
        or all(math.isnan(r["conf_low"]) for r in rows)
    ):
        q = critical_value(want_level, df_t)
        for r in rows:
            r["conf_low"] = r["estimate"] - q * r["std_error"]
            r["conf_high"] = r["estimate"] + q * r["std_error"]
    return rows


TABLE_METRICS = (
    "nobs",
    "r2",
    "adj_r2",
    "r2_within",
    "adj_r2_within",
    "pseudo_r2",
    "aic",
    "bic",
    "log_lik",
    "f_stat",
    "rmse",
)


def glance(record: dict, *, vcov: int | str | None = None, metrics: str = "table") -> dict:
    """One row: the record's metrics (structured ones by their `value`; `conf_level` left
    out), `vcov_type` ("by: firm", or the default vcov's type) and `fixed_effects` (the
    names, a list). `metrics="table"` keeps those a regression table usually shows
    (`TABLE_METRICS`), with `rmse` as sqrt(rss / nobs) when the record has both; "all" keeps
    every scalar metric."""
    if metrics not in ("table", "all"):
        raise ValueError("metrics is 'table' or 'all'")
    ms = {k: v for k, v in (record.get("metrics") or {}).items() if k != "conf_level"}
    if metrics == "table":
        if "rmse" not in ms and "rss" in ms and "nobs" in ms:
            rss, n = _num(ms["rss"]), _num(ms["nobs"])
            ms["rmse"] = math.sqrt(rss / n) if n > 0 else math.nan
        ms = {k: ms[k] for k in TABLE_METRICS if k in ms}
    out = {}
    for k, v in ms.items():
        if isinstance(v, Mapping) and "value" not in v:
            continue
        out[k] = _metric(v)
    v = pick_vcov(record, vcov)
    if v is not None:
        out["vcov_type"] = vcov_label(v)
    fes = (record.get("specification") or {}).get("fixed_effects")
    if fes:
        out["fixed_effects"] = list(fes)
    return out


def _locator_label(loc: Any) -> str | None:
    if not isinstance(loc, Mapping):
        return None
    if loc.get("label"):
        return loc["label"]
    keys = ("study", "table", "panel", "column", "row", "figure", "equation", "page", "appendix", "section")
    parts = [f"{k} {loc[k]}" for k in keys if loc.get(k) is not None]
    return ", ".join(parts) or None


def _members(source: Any, base_dir: str | os.PathLike | None) -> list[tuple[str, dict, dict]]:
    """(name, member entry, record) from a collection, a {name: record} mapping or a list."""
    if is_collection(source):
        out = []
        for i, m, rec in iter_members(source, base_dir):
            if rec is None:
                raise ValueError(f"members[{i}]: record not found (pass base_dir, the collection's folder)")
            out.append((str(m.get("label") or m.get("id")), m, rec))
        return out
    if isinstance(source, Mapping) and source.get("schema") == "estrec/0.1":
        source = [source]
    if isinstance(source, Mapping):
        return [(str(k), {}, r) for k, r in source.items()]
    return [
        (str((r.get("meta") or {}).get("title") or (r.get("meta") or {}).get("id")), {}, r) for r in source
    ]


def parameters_table(
    source: Any,
    *,
    base_dir: str | os.PathLike | None = None,
    vcov: int | str | None = None,
    conf_level: float | None = None,
    component: str | Iterable[str] | None = None,
    dropped: bool = False,
) -> list[dict]:
    """The flat parameters table (spec 11) across a collection's members, a {name: record}
    mapping or a list of records: `tidy` rows with `member` (label, else id), `id` and
    `locator` (as printed) first. `base_dir` is the collection's folder, for members files."""
    rows = []
    for name, m, rec in _members(source, base_dir):
        locs = m.get("locators") or ([m["locator"]] if m.get("locator") else [])
        loc = "; ".join(filter(None, map(_locator_label, locs))) or None
        head = {"member": name, "id": (rec.get("meta") or {}).get("id"), "locator": loc}
        for r in tidy(rec, vcov=vcov, conf_level=conf_level, component=component, dropped=dropped):
            rows.append({**head, **r})
    return rows


def glance_table(
    source: Any, *, base_dir: str | os.PathLike | None = None, metrics: str = "table"
) -> list[dict]:
    """`glance` for each member, with `member`, `id` and `locator` first."""
    rows = []
    for name, m, rec in _members(source, base_dir):
        locs = m.get("locators") or ([m["locator"]] if m.get("locator") else [])
        loc = "; ".join(filter(None, map(_locator_label, locs))) or None
        rows.append(
            {
                "member": name,
                "id": (rec.get("meta") or {}).get("id"),
                "locator": loc,
                **glance(rec, metrics=metrics),
            }
        )
    return rows
