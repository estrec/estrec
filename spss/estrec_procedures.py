"""SPSS procedures (as read by oxml.parse) -> estrec records.

One builder per procedure: REGRESSION, UNIANOVA, LOGISTIC REGRESSION, GENLIN, MIXED and
GENLINMIXED. Each reads the procedure's own tables (English labels: ESTREC BEGIN sets
OLANG=ENGLISH) and its Notes table (the syntax as run, dataset, filter, weight, split).
docs/notes/writers-julia-sas-spss.md lists what each procedure prints.

`hints` carries what the tables don't: `nobs` (MIXED prints no case count),
`levels` ({subject variable: count}), `spss_version`. ESTREC END computes them in SPSS.
"""

from __future__ import annotations

import math
import re

import estrec_oxml as oxml
import estrec_record as R

INTERCEPTS = {"(Constant)", "Constant", "Intercept", "(Intercept)"}
SUPPORTED = ("Regression", "UNIANOVA", "Logistic Regression", "Generalized Linear Models",
             "Mixed", "Generalized Linear Mixed Models")


class Unsupported(Exception):
    pass


def _f(x):
    """A table value as a float, or None for '.', blanks and text."""
    return x if isinstance(x, float) else None


def _clean(s: str) -> str:
    return " ".join(str(s).split())


# ---------------------------------------------------------------- terms


def canonical(term: str, codings: dict | None = None) -> dict:
    """SPSS term -> canonical {name, factors} (spec 4.4.1). Levels are written `[cat=2]`
    (UNIANOVA, GENLIN, MIXED) or by position `cat(1)` (LOGISTIC REGRESSION, mapped through
    `codings`); interactions with `*`."""
    t = _clean(term)
    if t in INTERCEPTS:
        return {"name": "(Intercept)", "factors": []}
    factors = []
    for p in [x.strip() for x in re.split(r"\s\*\s|\*", t)]:
        m = re.fullmatch(r"\[(.+?)=(.+)\]", p)
        if m:
            factors.append({"variable": m[1].strip(), "level": _level(m[2].strip())})
            continue
        m = re.fullmatch(r"(.+?)\((\d+)\)", p)
        if m and codings and m[1] in codings:
            lv = codings[m[1]].get(int(m[2]))
            factors.append({"variable": m[1], "level": lv} if lv is not None else {"variable": p})
            continue
        factors.append({"variable": p})
    has = [("level" in f) for f in factors]
    if any(has) and not all(has):
        name = "#".join(f"{f['level']}.{f['variable']}" if "level" in f else f"c.{f['variable']}" for f in factors)
    else:
        name = ":".join(f["variable"] + f.get("level", "") for f in factors)
    return {"name": name, "factors": factors}


def _level(s: str) -> str:
    # 2.00 -> 2 (SPSS shows numeric levels with the variable's decimals)
    try:
        v = float(s)
        return str(int(v)) if v.is_integer() else s
    except ValueError:
        return s


def _param(term, est, se, stat=None, p=None, lo=None, hi=None, df=None, codings=None, **extra):
    row = {"term": term, "canonical": canonical(term, codings), "estimate": R.num(est),
           "std_error": R.num(se), "statistic": R.num(stat), "p_value": R.num(p),
           "conf_low": R.num(lo), "conf_high": R.num(hi), "df": R.num(df)}
    row.update(extra)
    return R.compact(row)


def _ref_row(term, codings=None):
    return {"term": term, "canonical": canonical(term, codings), "dropped": "reference"}


def _matrix(tab: oxml.Table | None, labels: list, rowkey=lambda r: r[-1].text) -> list | None:
    """Square matrix for `labels` from a covariance table whose rows and columns are the terms."""
    if tab is None:
        return None
    vals = {}
    for c in tab.cells:
        if not c.row or not c.col:
            continue
        vals[(_clean(rowkey(c.row)), _clean(c.col[-1].text))] = _f(c.number)
    try:
        return [[R.num(vals[(a, b)]) for b in labels] for a in labels]
    except KeyError:
        return None


def _conf_level(tab: oxml.Table, default=0.95) -> float:
    for c in tab.cells:
        for l in c.col:
            m = re.match(r"(\d+(?:\.\d+)?)% ", l.text)
            if m:
                return float(m[1]) / 100
    return default


# ---------------------------------------------------------------- Notes


def notes(cmd: oxml.Command) -> dict:
    t = cmd.table("Notes")
    out = {}
    if t is None:
        return out
    for c in t.cells:
        key = tuple(_clean(l.text) for l in c.row)
        val = c.value
        if isinstance(val, str):
            val = val.strip()
            if val in ("<none>", ""):
                val = None
        out[key[-1] if len(key) == 1 else " / ".join(key)] = val
    return {
        "syntax": _clean(out.get("Syntax") or "") or None,
        "dataset": out.get("Input / Active Dataset"),
        "data_file": out.get("Input / Data"),
        "filter": out.get("Input / Filter"),
        "weight": out.get("Input / Weight"),
        "split": out.get("Input / Split File"),
        "rows": R.as_int(out.get("Input / N of Rows in Working Data File")),
        "missing_rule": out.get("Missing Value Handling / Cases Used"),
        "created": out.get("Output Created"),
    }


def _opt(syntax: str | None, pattern: str, default=None):
    if not syntax:
        return default
    m = re.search(pattern, syntax, re.I)
    return m[1] if m else default


# ---------------------------------------------------------------- assembly


def _record(cmd, nt, hints, *, estimator, profiles, parameters, vcovs, metrics, spec=None,
            structures=None, tests=None, messages=None, responses=None, title=None,
            identifying=False, options=None):
    spec = dict(spec or {})
    spec.setdefault("call", nt.get("syntax"))
    if nt.get("syntax"):
        spec.setdefault("formula", {"text": nt["syntax"], "syntax": "SPSS"})
    w = nt.get("weight")
    if w and "weights" not in spec:
        spec["weights"] = {"variable": w, "type": "frequency"}
    restriction = []
    if nt.get("filter"):
        restriction.append(f"FILTER BY {nt['filter']}")
    if nt.get("split"):
        restriction.append(f"SPLIT FILE {nt['split']}")
    sample = spec.get("sample")
    if sample is not None and restriction:
        sample["restriction"] = "; ".join(restriction)
    state = R.compact({"dataset": nt.get("dataset"), "filter": nt.get("filter"),
                       "weight": nt.get("weight"), "split": nt.get("split"),
                       "missing": nt.get("missing_rule")})
    if state:
        spec["state"] = state
    if options:
        spec["options"] = {**spec.get("options", {}), **options}
    st = {"vcov": vcovs}
    st.update(structures or {})
    meta = R.compact({
        "id": R.new_id(), "created": R.now(), "status": "ok", "estimator": estimator,
        "responses": responses, "profiles": profiles, "title": title or cmd.text,
        "producer": R.producer()})
    msgs = list(messages or [])
    if any(m["level"] == "warning" for m in msgs):
        meta["status"] = "warning"
    if msgs:
        meta["messages"] = msgs
    rec = {"schema": R.SCHEMA, "meta": meta, "specification": R.compact(spec),
           "metrics": R.compact(metrics), "parameters": parameters, "structures": st}
    if tests:
        rec["tests"] = [{"id": f"t{i}", **t} for i, t in enumerate(tests, 1)]
    ver = hints.get("spss_version")
    software = [R.compact({"name": "IBM SPSS Statistics", "version": ver,
                           "purl": f"pkg:generic/spss@{ver}" if ver else None,
                           "role": "estimator", "command": cmd.name}),
                {"name": "estrec for SPSS", "version": R.VERSION, "role": "writer"}]
    data = R.compact({"role": "estimation", "name": nt.get("dataset"), "rows": nt.get("rows"),
                      "path": nt.get("data_file") if identifying else None})
    rec["provenance"] = {"software": software, "data": [data]}
    rec["history"] = [{"when": R.now(), "by": R.producer(), "action": "created"}]
    return R.add_digest(rec)


def _vcov(labels, data, type_, convention, formula, *, df_t=None, default=True, tool_type=None, **kw):
    v = {"kind": "matrix" if data is not None else "object"}
    if data is not None:
        v["labels"] = labels
        v["data"] = data
    v.update(R.compact({"type": type_, "tool_type": tool_type}))
    v.update(R.compact(kw))
    v["ssc"] = {"convention": convention, "formula": formula}
    if df_t is not None:
        v["df_t"] = R.num(df_t)
    v["default"] = default
    return v


def _diag(terms, ses, known=None):
    """The covariance matrix as far as SPSS printed it: `known` {(a, b): cov} where given,
    variances from the standard errors on the diagonal, and null for covariances it didn't print."""
    known = known or {}
    out = []
    for a in terms:
        row = []
        for b in terms:
            if (a, b) in known:
                row.append(R.num(known[(a, b)]))
            elif a == b and ses.get(a) is not None:
                row.append(R.num(ses[a] ** 2))
            else:
                row.append(None)
        out.append(row)
    return out


def _no_matrix_msg(cmd, how):
    return {"level": "info", "code": "no_vcov_matrix", "source": "estrec",
            "message": f"{cmd} printed no covariance matrix of the estimates: the record's matrix has "
                       f"the variances (squared standard errors) and null covariances; {how}"}


def _sample(rows_input, nobs, missing=None, other=None):
    if rows_input is None:
        return None
    dropped = {}
    if missing is not None:
        dropped["missing"] = R.as_int(missing)
    rest = rows_input - (nobs or 0) - (missing or 0)
    if other is not None:
        dropped["other"] = R.as_int(other)
    elif rest and nobs is not None:
        dropped["other" if missing is not None else "missing"] = R.as_int(rest)
    return {"restriction": None, "rows_input": rows_input, "dropped": dropped}


# ---------------------------------------------------------------- REGRESSION


def regression(cmd, nt, hints, identifying=False):
    coef = cmd.table("Coefficients")
    if coef is None:
        raise Unsupported("REGRESSION printed no Coefficients table")
    models = sorted({c.row[0].text for c in coef.cells})
    last = models[-1]
    rows = [r for r in coef.rows() if r[0].text == last]
    dep = None
    for fn in coef.footnotes:
        m = re.match(r"Dependent Variable: (.+)", fn)
        if m:
            dep = m[1].strip()
    params, terms, ses_ = [], [], {}
    for r in rows:
        term = _clean(r[-1].text)
        g = lambda col: _f(coef.get((last, r[-1].text), col))
        params.append(_param(term, g("B"), g("Std. Error"), g("t"), g("Sig."),
                             g(("Lower Bound",)), g(("Upper Bound",))))
        terms.append(term)
        ses_[term] = g("Std. Error")
    anova = cmd.table("ANOVA")
    a = lambda row, col: _f(anova.get((last, row), col)) if anova else None
    df_res, df_tot = a("Residual", "df"), a("Total", "df")
    nobs = R.as_int(df_tot + 1) if df_tot is not None else hints.get("nobs")
    ms = cmd.table("Model Summary")
    s = lambda col: _f(ms.get(last, col)) if ms else None
    weighted = any("Weighted by" in fn for t in cmd.tables for fn in t.footnotes)
    wvar = None
    for t in cmd.tables:
        for fn in t.footnotes:
            m = re.search(r"Weighted by (\S+)", fn)
            if m:
                wvar = m[1]
    # BCOV: covariances of the slopes only (no constant)
    cc = cmd.table("Coefficient Correlations")
    slopes = [t for t in terms if t not in INTERCEPTS]
    vals = {}
    if cc is not None:
        for c in cc.cells:
            if len(c.row) >= 3 and c.row[0].text == last and c.row[1].text == "Covariances":
                vals[(_clean(c.row[-1].text), _clean(c.col[-1].text))] = _f(c.number)
    msgs = []
    if not vals:
        msgs.append(_no_matrix_msg("REGRESSION", "add BCOV to /STATISTICS to record the slopes' covariances"))
    elif any(t in INTERCEPTS for t in terms):
        msgs.append({"level": "info", "code": "vcov_partial", "source": "SPSS",
                     "message": "REGRESSION's BCOV covers the slopes only: the constant's covariances with them are null"})
    vc = _vcov(terms, _diag(terms, ses_, vals), "iid", "SPSS REGRESSION",
               "sigma^2 (X'X)^-1, sigma^2 = RSS / (N - K)", df_t=df_res)
    tests = []
    if anova is not None and a("Regression", "F") is not None:
        tests.append({"category": "model", "name": "f", "origin": "estimation",
                      "statistic": R.num(a("Regression", "F")), "distribution": "F",
                      "df1": R.as_int(a("Regression", "df")), "df2": R.as_int(df_res),
                      "p_value": R.num(a("Regression", "Sig.")), "vcov": "iid"})
    metrics = {"nobs": nobs, "df_residual": R.as_int(df_res), "r2": R.num(s("R Square")),
               "adj_r2": R.num(s("Adjusted R Square")), "sigma": R.num(s("Std. Error of the Estimate")),
               "rss": R.num(a("Residual", "Sum of Squares")), "tss": R.num(a("Total", "Sum of Squares")),
               "conf_level": _conf_level(coef)}
    spec = {"terms": terms, "sample": _sample(nt.get("rows"), nobs)}
    if wvar:
        spec["weights"] = {"variable": wvar, "type": "analytic"}
    if len(models) > 1:
        msgs.append({"level": "info", "code": "last_model", "source": "estrec",
                     "message": f"REGRESSION fitted {len(models)} models; the record is the last ({last})"})
    return _record(cmd, nt, hints, estimator={"family": "linear", "method": "wls" if weighted else "ols"},
                   profiles=["inference/0.1"], parameters=params, vcovs=[vc], metrics=metrics,
                   spec=spec, tests=tests, messages=msgs, responses=[dep] if dep else None,
                   identifying=identifying)


# ---------------------------------------------------------------- UNIANOVA


def _redundant(est, se) -> bool:
    return est == 0 and se is None


def unianova(cmd, nt, hints, identifying=False):
    robust = cmd.table("Parameter Estimates with Robust Standard Errors")
    plain = cmd.table("Parameter Estimates")
    pe = robust or plain
    if pe is None:
        raise Unsupported("UNIANOVA printed no Parameter Estimates (add /PRINT=PARAMETER)")
    dep = next((l.var for c in pe.cells for l in c.col if l.var), None)
    se_col = "Robust Std. Error" if robust is not None else "Std. Error"
    params, terms, ses_ = [], [], {}
    for r in pe.rows():
        term = _clean(r[-1].text)
        g = lambda col: _f(pe.get(r[-1].text, col))
        est, se = g("B"), g(se_col)
        if _redundant(est, se):
            params.append(_ref_row(term))
            continue
        params.append(_param(term, est, se, g("t"), g("Sig."), g(("Lower Bound",)), g(("Upper Bound",))))
        terms.append(term)
        ses_[term] = se
    tb = cmd.table("Test of Between Subjects Fixed Effects")
    t = lambda row, col: _f(tb.get(row, col)) if tb else None
    df_err = t("Error", "df")
    ss_err, ss_ct = t("Error", "Type III Sum of Squares"), t("Corrected Total", "Type III Sum of Squares")
    if ss_err is None:  # other SS types
        for typ in ("Type I", "Type II", "Type IV"):
            ss_err = t("Error", f"{typ} Sum of Squares") or ss_err
            ss_ct = t("Corrected Total", f"{typ} Sum of Squares") or ss_ct
    nobs = R.as_int(t("Corrected Total", "df") + 1) if t("Corrected Total", "df") is not None else None
    r2 = 1 - ss_err / ss_ct if ss_err is not None and ss_ct else None
    adj = 1 - (1 - r2) * (nobs - 1) / df_err if r2 is not None and df_err else None
    hc = None
    if robust is not None:
        for fn in robust.footnotes:
            m = re.match(r"(HC\d) method", fn)
            if m:
                hc = m[1]
    vcovs = []
    if robust is not None:
        vcovs.append(_vcov(terms, _diag(terms, ses_), hc or "HC", "SPSS UNIANOVA", f"{hc or 'HC'} sandwich", df_t=df_err,
                           tool_type=f"Robust Std. Error ({hc} method)" if hc else "Robust Std. Error"))
        if plain is not None:
            pses = {_clean(r[-1].text): _f(plain.get(r[-1].text, "Std. Error")) for r in plain.rows()}
            vcovs.append(_vcov(terms, _diag(terms, pses), "iid", "SPSS UNIANOVA",
                               "sigma^2 (X'X)^-1, sigma^2 = RSS / (N - K)", df_t=df_err, default=False))
    else:
        vcovs.append(_vcov(terms, _diag(terms, ses_), "iid", "SPSS UNIANOVA",
                           "sigma^2 (X'X)^-1, sigma^2 = RSS / (N - K)", df_t=df_err))
    tests = []
    if t("Corrected Model", "F") is not None:
        tests.append({"category": "model", "name": "f", "origin": "estimation",
                      "statistic": R.num(t("Corrected Model", "F")), "distribution": "F",
                      "df1": R.as_int(t("Corrected Model", "df")), "df2": R.as_int(df_err),
                      "p_value": R.num(t("Corrected Model", "Sig.")), "vcov": "iid"})
    metrics = {"nobs": nobs, "df_residual": R.as_int(df_err), "r2": R.num(r2), "adj_r2": R.num(adj),
               "rss": R.num(ss_err), "tss": R.num(ss_ct),
               "sigma": R.num(math.sqrt(ss_err / df_err)) if ss_err is not None and df_err else None,
               "conf_level": _conf_level(pe)}
    msgs = [_no_matrix_msg("UNIANOVA", "SPSS can save it with /OUTFILE=COVB")]
    return _record(cmd, nt, hints, estimator={"family": "linear", "method": "ols"},
                   profiles=["inference/0.1"], parameters=params, vcovs=vcovs, metrics=metrics,
                   spec={"terms": terms, "sample": _sample(nt.get("rows"), nobs)}, tests=tests,
                   messages=msgs, responses=[dep] if dep else None, identifying=identifying)


# ---------------------------------------------------------------- LOGISTIC REGRESSION


def logistic(cmd, nt, hints, identifying=False):
    vie = [t for t in cmd.tables if t.subtype == "Variables in the Equation"]
    if not vie:
        raise Unsupported("LOGISTIC REGRESSION printed no Variables in the Equation table")
    tab = vie[-1]
    step = sorted({c.row[0].text for c in tab.cells})[-1]
    # cat(k) -> level, from Categorical Variables Codings (indicator coding: one 1 per column)
    codings = {}
    cv = cmd.table("Categorical Variables Codings")
    if cv is not None:
        by_var: dict = {}
        for c in cv.cells:
            if len(c.col) == 2 and c.col[0].text == "Parameter coding":
                k = int(re.sub(r"\D", "", c.col[1].text))
                by_var.setdefault(c.row[0].text, {}).setdefault(k, []).append((_level(c.row[1].text), c.number))
        for var, cols in by_var.items():
            codings[var] = {}
            for k, vals in cols.items():
                ones = [lv for lv, v in vals if v == 1]
                if len(ones) == 1 and all(v in (0, 1) for _, v in vals):
                    codings[var][k] = ones[0]
    params, terms, tests = [], [], []
    ses = {}
    for r in tab.rows():
        if r[0].text != step:
            continue
        term = _clean(r[-1].text)
        g = lambda col: _f(tab.get((step, r[-1].text), col))
        b, se = g("B"), g("S.E.")
        if b is None:  # a factor's joint Wald test row
            if g("Wald") is not None:
                tests.append({"category": "restriction", "name": "wald", "label": term,
                              "origin": "estimation", "statistic": R.num(g("Wald")),
                              "distribution": "chi2", "df": R.as_int(g("df")), "p_value": R.num(g("Sig."))})
            continue
        lo = hi = None
        for c in tab.cells:
            if c.row[0].text == step and c.row[-1].text == r[-1].text and len(c.col) == 2 and c.col[0].text.startswith(("95", "90", "99")):
                v = _f(c.number)
                if v and v > 0:
                    if c.col[1].text == "Lower":
                        lo = math.log(v)
                    elif c.col[1].text == "Upper":
                        hi = math.log(v)
        params.append(_param(term, b, se, b / se if se else None, g("Sig."), lo, hi, codings=codings))
        terms.append(term)
        ses[term] = se
    # covariance from the Correlation Matrix (/PRINT=CORR): cov = corr * se_i * se_j
    data = None
    cm = [t for t in cmd.tables if t.subtype == "Correlation Matrix"]
    if cm:
        corr = {}
        for c in cm[-1].cells:
            if c.row and c.row[0].text == step:
                corr[(_clean(c.row[-1].text), _clean(c.col[-1].text))] = _f(c.number)
        try:
            data = [[R.num(corr[(a, b)] * ses[a] * ses[b]) for b in terms] for a in terms]
        except (KeyError, TypeError):
            data = None
    msgs = [] if data is not None else [_no_matrix_msg("LOGISTIC REGRESSION", "add CORR to /PRINT to record it")]
    vc = _vcov(terms, data if data is not None else _diag(terms, ses), "iid", "SPSS LOGISTIC REGRESSION",
               "inverse of the information matrix" + ("; from the printed correlations and standard errors" if data else ""))
    cps = cmd.table("Case Processing Summary")
    c = lambda *row: _f(cps.get(row, "N")) if cps else None
    nobs = R.as_int(c("Selected Cases", "Included in Analysis"))
    miss = c("Selected Cases", "Missing Cases")
    unsel = c("Unselected Cases")
    ms = [t for t in cmd.tables if t.subtype == "Model Summary"]
    m2ll = next((_f(c.number) for c in ms[-1].cells if c.col and c.col[-1].text == "-2 Log likelihood"), None) if ms else None
    msv = lambda col: next((_f(c.number) for c in ms[-1].cells if c.col and c.col[-1].text == col), None) if ms else None
    iters, conv = None, None
    for t in ms:
        for fn in t.footnotes:
            m = re.search(r"terminated at iteration number (\d+) because (.+)", fn)
            if m:
                iters = int(m[1])
                conv = "changed by less than" in m[2]
    om = [t for t in cmd.tables if t.subtype == "Omnibus Tests of Model Coefficients"]
    if om:
        o = om[-1]
        stat = _f(o.get((step, "Model"), "Chi-square"))
        if stat is not None:
            tests.insert(0, {"category": "model", "name": "likelihood_ratio", "origin": "estimation",
                             "statistic": R.num(stat), "distribution": "chi2",
                             "df": R.as_int(o.get((step, "Model"), "df")), "p_value": R.num(o.get((step, "Model"), "Sig."))})
    # modelled category: the original value coded 1
    enc = cmd.table("Dependent Variable Encoding")
    dep, event = None, None
    if enc is not None:
        for cell in enc.cells:
            if cell.number == 1:
                event = _level(cell.row[-1].text)
                dep = cell.row[-1].var
    metrics = {"nobs": nobs, "log_lik": R.num(-m2ll / 2) if m2ll is not None else None,
               "neg2_log_lik": R.num(m2ll),
               "pseudo_r2_cox_snell": R.num(msv("Cox & Snell R Square")),
               "pseudo_r2_nagelkerke": R.num(msv("Nagelkerke R Square")),
               "conf_level": 0.95}
    if conv is False:
        msgs.append({"level": "warning", "code": "not_converged", "source": "SPSS",
                     "message": f"estimation stopped at iteration {iters} before the estimates converged"})
    numerics = R.compact({"kind": "object", "iterative": True, "algorithm": "newton_raphson",
                          "converged": True if conv is None else conv, "iterations": iters})
    return _record(cmd, nt, hints,
                   estimator={"family": "glm", "method": "ml", "distribution": "binomial", "link": "logit"},
                   profiles=["inference/0.1", "glm/0.1"], parameters=params, vcovs=[vc], metrics=metrics,
                   spec={"terms": terms, "sample": _sample(nt.get("rows"), nobs, miss, unsel or None)},
                   structures={"numerics": numerics}, tests=tests, messages=msgs,
                   responses=[dep] if dep else None, options=R.compact({"response_level": event}),
                   identifying=identifying)


# ---------------------------------------------------------------- GENLIN

_DIST = {"Normal": "gaussian", "Binomial": "binomial", "Poisson": "poisson", "Gamma": "gamma",
         "Inverse Gaussian": "inverse_gaussian", "Negative binomial": "negative_binomial",
         "Multinomial": "multinomial", "Tweedie": "tweedie"}
_LINK = {"Identity": "identity", "Logit": "logit", "Probit": "probit", "Log": "log",
         "Complementary log-log": "cloglog", "Negative log-log": "loglog", "Power": "power",
         "Cumulative logit": "logit", "Cumulative probit": "probit", "Log-complement": "logc"}


def genlin(cmd, nt, hints, identifying=False):
    pe = cmd.table("ParameterEstimates")
    if pe is None:
        raise Unsupported("GENLIN printed no Parameter Estimates (add SOLUTION to /PRINT)")
    mi = cmd.table("ModelInformation")
    info = {(_clean(c.row[0].text) if c.row else ""): c.value for c in (mi.cells if mi else [])}
    dist = _clean(info.get("Probability Distribution") or "")
    link = _clean(info.get("Link Function") or "")
    dep = info.get("Dependent Variable")
    event = None
    for fn in (mi.footnotes if mi else []):
        m = re.match(r"The procedure models (.+?) as the response", fn)
        if m:
            event = _level(m[1])
    syntax = nt.get("syntax") or ""
    repeated = bool(re.search(r"/REPEATED", syntax, re.I))
    robust = repeated or bool(re.search(r"COVB\s*=\s*ROBUST", syntax, re.I))
    params, terms, ses_, aux = [], [], {}, {}
    for r in pe.rows():
        term = _clean(r[-1].text)
        g = lambda col: _f(pe.get(r[-1].text, col))
        b, se = g("B"), g("Std. Error")
        if term.startswith("(Scale)") or term.startswith("(Negative binomial)"):
            aux[term] = b
            if se is not None:  # an estimated scale or ancillary parameter
                params.append(R.compact({"term": term, "estimate": R.num(b), "std_error": R.num(se),
                                         "conf_low": R.num(g(("Lower",))), "conf_high": R.num(g(("Upper",))),
                                         "component": "auxiliary"}))
            continue
        if _redundant(b, se):
            params.append(_ref_row(term))
            continue
        params.append(_param(term, b, se, b / se if se else None, g(("Hypothesis Test", "Sig.")),
                             g(("Lower",)), g(("Upper",))))
        terms.append(term)
        ses_[term] = se
    cov = cmd.table("CovariancesOfParameterEstimates")
    data = _matrix(cov, terms)
    cds = cmd.table("CorrelatedDataSummary")
    subj, n_subj = None, None
    if cds is not None:
        for c in cds.cells:
            if c.row and c.row[0].text == "Number of Levels":
                subj = c.row[-1].var or _clean(c.row[-1].text)
            if c.row and c.row[0].text == "Number of Subjects":
                n_subj = R.as_int(c.number)
    if repeated:
        type_, formula = "CRV0", "GEE sandwich on the subject clusters, no small-sample factor"
    elif robust:
        type_, formula = "HC0", "sandwich (robust) estimator, no small-sample factor"
    else:
        type_, formula = "iid", "inverse of the information matrix" + (" times the scale" if dist in ("Normal", "Gamma", "Inverse Gaussian") else "")
    vc = _vcov(terms, data if data is not None else _diag(terms, ses_), type_, "SPSS GENLIN", formula,
               tool_type="robust" if robust else "model-based",
               cluster=[subj] if repeated and subj else None,
               n_clusters={subj: n_subj} if repeated and subj and n_subj else None)
    gof = cmd.table("GoodnessOfFit")
    gv = lambda row: _f(gof.get(row, "Value")) if gof else None
    cps = cmd.table("CaseProcessingSummary")
    nobs = R.as_int(cps.get("Included", "N")) if cps else None
    excl = _f(cps.get("Excluded", "N")) if cps else None
    tests = []
    om = cmd.table("OmnibusTest")
    if om is not None and om.get((), "Likelihood Ratio Chi-Square") is not None:
        tests.append({"category": "model", "name": "likelihood_ratio", "origin": "estimation",
                      "statistic": R.num(om.get((), "Likelihood Ratio Chi-Square")), "distribution": "chi2",
                      "df": R.as_int(om.get((), "df")), "p_value": R.num(om.get((), "Sig."))})
    metrics = {"nobs": nobs, "deviance": R.num(gv("Deviance")), "pearson_chi2": R.num(gv("Pearson Chi-Square")),
               "log_lik": R.num(gv("Log Likelihood")),
               "aic": R.num(gv("Akaike's Information Criterion (AIC)")),
               "bic": R.num(gv("Bayesian Information Criterion (BIC)")),
               "qic": R.num(gv("Quasi Likelihood under Independence Model Criterion (QIC)")),
               "dispersion": R.num(next((v for k, v in aux.items() if k.startswith("(Scale)")), None)),
               "conf_level": _conf_level(pe)}
    msgs = [] if data is not None else [_no_matrix_msg("GENLIN", "add COVB to /PRINT to record it")]
    spec = {"terms": terms, "sample": _sample(nt.get("rows"), nobs, excl)}
    if repeated and subj:
        spec["clusters"] = [subj]
    estimator = R.compact({"family": "glm", "method": "gee" if repeated else "ml",
                           "distribution": _DIST.get(dist, dist.lower() or None),
                           "link": _LINK.get(link, link.lower() or None)})
    return _record(cmd, nt, hints, estimator=estimator, profiles=["inference/0.1", "glm/0.1"],
                   parameters=params, vcovs=[vc], metrics=metrics, spec=spec,
                   structures={"numerics": {"kind": "object", "iterative": True, "converged": True}},
                   tests=tests, messages=msgs, responses=[dep] if dep else None,
                   options=R.compact({"response_level": event}), identifying=identifying)


# ---------------------------------------------------------------- MIXED


def mixed(cmd, nt, hints, identifying=False):
    pe = cmd.table("Parameter Estimates")
    if pe is None:
        raise Unsupported("MIXED printed no Estimates of Fixed Effects (add SOLUTION to /PRINT)")
    params, terms = [], []
    for r in pe.rows():
        term = _clean(r[-1].text)
        g = lambda col: _f(pe.get(r[-1].text, col))
        b, se = g("Estimate"), g("Std. Error")
        if b == 0 and (se == 0 or se is None) and g("t") is None:
            params.append(_ref_row(term))
            continue
        params.append(_param(term, b, se, g("t"), g("Sig."), g(("Lower Bound",)), g(("Upper Bound",)), df=g("df")))
        terms.append(term)
    cov = cmd.table("Covariance Matrix", "Covariance Matrix for Estimates of Fixed Effects")
    data = _matrix(cov, terms)
    # random effects and variance components
    md = cmd.table("Model Dimension")
    groups = []
    if md is not None:
        for r in md.rows():
            if r[0].text == "Random Effects":
                subj = md.get(tuple(l.text for l in r), "Subject Variables")
                cs = md.get(tuple(l.text for l in r), "Covariance Structure")
                if subj:
                    groups.append({"group": str(subj), "terms": [_clean(r[-1].text).replace("Intercept", "(Intercept)")],
                                   "covariance": str(cs) if cs else None})
    cp = cmd.table("Covariance Parameter Estimates")
    for r in (cp.rows() if cp else []):
        key = tuple(l.text for l in r)
        g = lambda col: _f(cp.get(key, col))
        label = " ".join(_clean(l.text) for l in r)
        if key[0] == "Residual":
            vc = {"group": "Residual", "terms": ["(Residual)"], "type": "var"}
        else:
            m = re.match(r"(.+?) \[subject = (.+?)\]", _clean(key[0]))
            kind = _clean(key[-1]).lower() if len(key) > 1 else "var"
            vc = {"group": m[2] if m else None, "terms": [(m[1] if m else key[0]).replace("Intercept", "(Intercept)")],
                  "type": "var" if kind.startswith("var") else "cov"}
        params.append(R.compact({"term": label, "estimate": R.num(g("Estimate")), "std_error": R.num(g("Std. Error")),
                                 "statistic": R.num(g("Wald Z")), "p_value": R.num(g("Sig.")),
                                 "conf_low": R.num(g(("Lower Bound",))), "conf_high": R.num(g(("Upper Bound",))),
                                 "component": "random", "group": vc["group"], "vc": R.compact(vc)}))
    ic = cmd.table("Information Criteria")
    i = lambda row: _f(ic.get(row, ())) if ic else None
    syntax = nt.get("syntax") or ""
    method = (_opt(syntax, r"/METHOD\s*=\s*(\w+)", "REML")).lower()
    m2ll = i("-2 Restricted Log Likelihood") if method == "reml" else i("-2 Log Likelihood")
    df_method = {"SATTERTHWAITE": "satterthwaite", "KENWARDROGER": "kenward_roger", "RESIDUAL": "residual"}.get(
        (_opt(syntax, r"DFMETHOD\s*\(\s*(\w+)\s*\)", "SATTERTHWAITE") or "").upper(), "satterthwaite")
    levels = hints.get("levels") or {}
    re_struct = [R.compact({"kind": "object", "group": g["group"], "levels": levels.get(g["group"]),
                            "terms": g["terms"], "covariance": g.get("covariance")}) for g in groups]
    ses_ = {p["term"]: p.get("std_error") for p in params if "component" not in p}
    vc_ = _vcov(terms, data if data is not None else _diag(terms, ses_), "iid", "SPSS MIXED",
                "model-based covariance of the fixed effects", tool_type="model-based")
    vc_["df_t"] = None
    metrics = {"nobs": hints.get("nobs"), "log_lik": R.num(-m2ll / 2) if m2ll is not None else None,
               "reml_criterion" if method == "reml" else "neg2_log_lik": R.num(m2ll),
               "aic": R.num(i("Akaike's Information Criterion (AIC)")),
               "bic": R.num(i("Schwarz's Bayesian Criterion (BIC)")), "conf_level": _conf_level(pe)}
    msgs = [] if data is not None else [_no_matrix_msg("MIXED", "add COVB to /PRINT to record it")]
    if hints.get("nobs") is None:
        msgs.append({"level": "warning", "code": "nobs_unknown", "source": "estrec",
                     "message": "MIXED prints no case count and none was given"})
    spec = {"terms": terms, "random_effects": [R.compact({k: v for k, v in g.items()}) for g in groups],
            "sample": _sample(nt.get("rows"), hints.get("nobs"))}
    return _record(cmd, nt, hints, estimator={"family": "mixed", "method": method},
                   profiles=["inference/0.1", "mixed/0.1"], parameters=params, vcovs=[vc_],
                   metrics=metrics, spec=spec,
                   structures={"random_effects": re_struct,
                               "numerics": {"kind": "object", "iterative": True, "converged": True}},
                   messages=msgs, options={"df_method": df_method},
                   responses=[_opt(syntax, r"^\s*MIXED\s+(\S+)")] if syntax else None,
                   identifying=identifying)


# ---------------------------------------------------------------- GENLINMIXED


def genlinmixed(cmd, nt, hints, identifying=False):
    fc = cmd.table("FixedCoefficients")
    if fc is None:
        raise Unsupported("GENLINMIXED gave no Fixed Coefficients table (its output may be a Model Viewer only)")
    ms = cmd.table("ModelSummary")
    info = {(_clean(c.row[0].text) if c.row else ""): c.value for c in (ms.cells if ms else [])}
    dist, link = _clean(info.get("Probability Distribution") or ""), _clean(info.get("Link Function") or "")
    dep = info.get("Target")
    fe = cmd.table("FixedEffects")
    df2 = _f(fe.get("Corrected Model", "df2")) if fe else None
    params, terms = [], []
    for r in fc.rows():
        term = _clean(r[-1].text)
        g = lambda col: _f(fc.get(r[-1].text, col))
        b, se = g("Coefficient"), g("Std. Error")
        if _redundant(b, se):
            params.append(_ref_row(term))
            continue
        lo = hi = None
        for c in fc.cells:
            if c.row[-1].text == r[-1].text and len(c.col) == 2 and c.col[0].text.startswith(("95%", "90%", "99%")) and "Exp" not in c.col[0].text:
                if c.col[1].text == "Lower":
                    lo = _f(c.number)
                elif c.col[1].text == "Upper":
                    hi = _f(c.number)
        params.append(_param(term, b, se, g("t"), g("Sig."), lo, hi))
        terms.append(term)
    data = _matrix(cmd.table("CovariancesOfFixedCoefficients"), terms)
    cp = cmd.table("CovarianceParameters")
    for r in (cp.rows() if cp else []):
        key = r[-1].text
        g = lambda col: _f(cp.get(key, col))
        m = re.match(r"Var\((.+)\)", _clean(key))
        subj = None
        ds = cmd.table("DataStructure")
        if ds is not None:
            subj = next((l.var for c in ds.cells for l in c.col if l.var and c.col[0].text == "Subjects"), None)
        params.append(R.compact({"term": _clean(key), "estimate": R.num(g("Estimate")), "std_error": R.num(g("Std. Error")),
                                 "statistic": R.num(g("Z")), "p_value": R.num(g("Sig.")),
                                 "component": "random", "group": subj,
                                 "vc": R.compact({"group": subj, "terms": [(m[1] if m else key).replace("Intercept", "(Intercept)")],
                                                  "type": "var"})}))
    # subjects and their count (Data Structure also lists the first subject's rows: not recorded)
    ds = cmd.table("DataStructure")
    subj, n_levels = None, None
    if ds is not None:
        for c in ds.cells:
            if c.row and c.row[0].text == "Total Number of Levels":
                subj = c.col[-1].var or _clean(c.col[-1].text)
                n_levels = R.as_int(c.number)
    cps = cmd.table("CaseProcessingSummary")
    nobs = R.as_int(cps.get("Included", "N")) if cps else hints.get("nobs")
    excl = _f(cps.get("Excluded", "N")) if cps else None
    syntax = nt.get("syntax") or ""
    ses_ = {p["term"]: p.get("std_error") for p in params if "component" not in p}
    vc = _vcov(terms, data if data is not None else _diag(terms, ses_),
               "HC0" if re.search(r"COVB\s*=\s*ROBUST", syntax, re.I) else "iid", "SPSS GENLINMIXED",
               "model-based covariance of the fixed effects", df_t=df2)
    order = (_opt(syntax, r"TARGET_CATEGORY_ORDER\s*=\s*(\w+)", "ASCENDING") or "").lower()
    msgs = [] if data is not None else [_no_matrix_msg("GENLINMIXED", "it prints Covariances of Fixed Coefficients when asked")]
    if dist == "Binomial":
        msgs.append({"level": "info", "code": "response_level", "source": "SPSS",
                     "message": f"GENLINMIXED takes the last target category ({order} order) as the reference unless "
                                "/FIELDS sets REFERENCE: check the signs against the category you meant to model"})
    groups = [{"group": subj, "terms": ["(Intercept)"]}] if subj else []
    crit = lambda name: _f(ms.get(("Information Criterion", name), ())) if ms else None
    metrics = {"nobs": nobs, "df_residual": R.as_int(df2), "aicc": R.num(crit("Akaike Corrected")), "bic": R.num(crit("Bayesian")),
               "conf_level": _conf_level(fc)}
    return _record(cmd, nt, hints,
                   estimator=R.compact({"family": "mixed", "method": "pql",
                                        "distribution": _DIST.get(dist, dist.lower() or None),
                                        "link": _LINK.get(link, link.lower() or None)}),
                   profiles=["inference/0.1", "mixed/0.1"], parameters=params, vcovs=[vc], metrics=metrics,
                   spec={"terms": terms, "random_effects": groups,
                         "sample": _sample(nt.get("rows"), nobs, excl)},
                   structures={"random_effects": [R.compact({"kind": "object", "group": subj, "levels": n_levels,
                                                             "terms": ["(Intercept)"]})] if subj else [],
                               "numerics": {"kind": "object", "iterative": True, "converged": True}},
                   messages=msgs, options={"df_method": "residual", "target_category_order": order},
                   responses=[dep] if dep else None, identifying=identifying)


def process(cmd, nt, hints, identifying=False):
    """PROCESS (Hayes), which runs as a MATRIX procedure (estrec_process.py)."""
    import estrec_process
    return estrec_process.record(cmd, nt, hints, identifying=identifying)


BUILDERS = {"Regression": regression, "UNIANOVA": unianova, "Logistic Regression": logistic,
            "Generalized Linear Models": genlin, "Mixed": mixed, "Generalized Linear Mixed Models": genlinmixed,
            "Matrix": process}


def records(commands, hints: dict | None = None, identifying: bool = False) -> tuple[list, list]:
    """Records for the supported commands among `commands`, and notes on those skipped."""
    out, skipped = [], []
    for i, cmd in enumerate(commands):
        b = BUILDERS.get(cmd.name)
        if b is None:
            skipped.append(f"{cmd.text or cmd.name}: not supported")
            continue
        h = dict(hints or {})
        if isinstance(h.get("by_command"), list) and i < len(h["by_command"]):
            h.update(h["by_command"][i] or {})
        try:
            out.append(b(cmd, notes(cmd), h, identifying=identifying))
        except Unsupported as e:
            skipped.append(f"{cmd.text}: {e}")
    return out, skipped
