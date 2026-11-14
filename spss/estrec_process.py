"""Records of PROCESS (Andrew F. Hayes's conditional process macro) runs.

PROCESS isn't part of estrec: users get it from https://www.afhayes.com/download.html. In SPSS
it runs as a MATRIX procedure, so its results reach OMS either as pivot tables (PROCESS 5 with
display=tables: full precision) or as text at its printed decimals (the default). Both are read
into the same `Section`s (a title, column headings, labelled rows of numbers, or plain lines),
and `record()` turns the sequence of sections into an estrec record (mediation/0.1 when the
model has mediators). PROCESS for R and SAS print the same sections, so `sections_from_text`
reads their output too.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

import estrec_record as R

NUM = re.compile(r"^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$")


def _isnum(tok: str) -> bool:
    return bool(NUM.match(tok))


def _key(s: str) -> str:
    return re.sub(r"\s+", " ", (s or "").strip().rstrip(":")).strip().lower()


@dataclass
class Section:
    title: str
    kind: str = "table"                               # "table", "text" or "heading"
    columns: list = field(default_factory=list)       # headings, e.g. ["coeff", "se", ...]
    rows: list = field(default_factory=list)          # [(label or None, [float, ...])]
    lines: list = field(default_factory=list)         # plain text lines (keys, paths, values)

    @property
    def key(self) -> str:
        return _key(self.title)

    def col(self, row, *names):
        """The value in `row` (a (label, values) pair) under the first heading in `names`."""
        heads = [_key(c) for c in self.columns]
        for n in names:
            n = _key(n)
            for i, h in enumerate(heads):
                if (h == n or re.sub(r"\(.*\)$", "", h) == n) and i < len(row[1]):
                    return row[1][i]
        return None


# ---------------------------------------------------------------- reading
#
# Both readers give the same stream of items, in output order:
#   Section(kind="heading", title)   a banner heading (DIRECT AND INDIRECT EFFECTS OF X ON Y)
#   Section(kind="text", lines)      plain lines (header fields, OUTCOME VARIABLE:, paths, keys)
#   Section(kind="table", title, columns, rows)


def is_process(cmd) -> bool:
    return any("PROCESS Procedure for" in t for t in cmd.texts) or any(
        "PROCESS Procedure for" in (t.title or "") for t in cmd.tables)


def sections_from_tables(cmd) -> list:
    """Items from PROCESS's display=tables pivot tables. Tables whose columns are all generic
    ("col1", ...) hold text (header fields, keys, paths, single values)."""
    out = []
    for t in cmd.tables:
        if t.subtype == "Notes":
            continue
        cols, rows = [], {}
        generic = all(re.fullmatch(r"col\d+", c.col[-1].text.strip()) for c in t.cells if c.col)
        for c in t.cells:
            rl = c.row[-1].text.strip() if c.row else ""
            cl = c.col[-1].text.strip() if c.col else ""
            if cl not in cols:
                cols.append(cl)
            rows.setdefault(rl, []).append(c)
        title = t.title.strip()
        if generic:
            s = Section("", kind="text")
            if title and not title.startswith("*"):
                s.lines.append(title)
            for rl, cells in rows.items():
                toks = [(c.text or "").strip() if c.number is None else _numtext(c) for c in cells]
                toks = [x for x in toks if x]
                label = None if re.fullmatch(r"row\d+", rl) else rl
                line = " ".join(([label] if label else []) + toks)
                if line:
                    s.lines.append(line)
            out.append(s)
        else:
            s = Section(title, kind="table", columns=cols)
            for rl, cells in rows.items():
                vals = [c.number if c.number is not None else _float(c.text) for c in cells]
                s.rows.append((None if re.fullmatch(r"row\d+", rl) else rl, vals))
            out.append(s)
    return out


def _numtext(c):
    v = c.number
    return str(int(v)) if v is not None and float(v).is_integer() else repr(v)


def _float(s):
    s = (s or "").strip()
    return float(s) if _isnum(s) else None


def sections_from_text(text: str) -> list:
    """Items from PROCESS's printed output (SPSS text output, R console, SAS listing)."""
    lines = [ln.rstrip() for ln in text.replace("\r", "").split("\n")]
    out, i, n = [], 0, len(lines)
    pending: list = []
    last = [""]          # the last plain line, across blank lines (SAS: a blank under a title)

    def flush():
        if pending:
            out.append(Section("", kind="text", lines=list(pending)))
            pending.clear()

    while i < n:
        s = lines[i].strip()
        if not s:
            flush()
            i += 1
            continue
        if s.startswith("*"):
            flush()
            if "PROCESS Procedure for" in s:          # the banner carries platform and version
                out.append(Section("", kind="text", lines=[s.strip("* ")]))
            m = re.search(r"\*\s*([A-Za-z][A-Za-z ,()]+[A-Za-z)])\s*\*", s)
            if m:
                out.append(Section(m[1].strip(), kind="heading"))
            i += 1
            continue
        toks = s.replace("Adj R-sq", "Adj_R-sq").split()
        j = i + 1
        while j < n and not lines[j].strip() and j - i <= 2:   # SAS: a blank line under headings
            j += 1
        nxt = lines[j].split() if j < n else []
        is_head = (toks and not any(_isnum(t) for t in toks) and nxt
                   and len([t for t in nxt if _isnum(t)]) >= len(toks)
                   and all(_isnum(t) for t in nxt[-len(toks):])
                   and not any(t.endswith(":") for t in nxt))   # "Sample" / "Size: 1997"
        if is_head:
            # the table's title is the last plain line before its headings, if there is one
            ttl = pending.pop() if pending else last[0]
            last[0] = ""
            flush()
            if "->" in ttl:                       # a path line titles a conditional table
                out.append(Section("", kind="text", lines=[ttl]))
                ttl = ""
            sec = Section(ttl, kind="table", columns=toks)
            i = j
            while i < n:
                r = lines[i].split()
                if not r or len(r) < len(toks) or not all(_isnum(t) for t in r[-len(toks):]):
                    break
                sec.rows.append((" ".join(r[:-len(toks)]) or None, [float(t) for t in r[-len(toks):]]))
                i += 1
            out.append(sec)
            continue
        pending.append(s)
        last[0] = s
        i += 1
    flush()
    return out


# ---------------------------------------------------------------- interpreting

_HEADER = re.compile(r"^(Model|Y|X|M\d*|W|Z|Covariates?)\s*:\s*(.*)$", re.I)
_OUTCOME = re.compile(r"(?i)^outcome variable\s*:?\s*(\S*)\s*$")


def _items(sections):
    """(kind, value) in order: ("line", text), ("heading", title), ("table", Section)."""
    for s in sections:
        if s.kind == "table":
            yield "table", s
        elif s.kind == "heading":
            yield "heading", s.title
        else:
            for ln in s.lines:
                yield "line", ln


def header(sections) -> dict:
    h = {"mediators": [], "covariates": []}
    lines = [v for k, v in _items(sections) if k == "line"]
    for j, ln in enumerate(lines):
        if _OUTCOME.match(ln):
            break
        m = _HEADER.match(ln.strip())
        if m:
            k, v = m[1].lower(), m[2].strip()
            if k.startswith("cov"):
                h["covariates"] += v.split() if v else (lines[j + 1].split() if j + 1 < len(lines) else [])
            elif k == "model" and v:
                h["model"] = int(float(v.split()[0]))
            elif k.startswith("m") and v:
                h["mediators"].append(v)
            elif v:
                h[k] = v
    text = "\n".join(lines)
    m = re.search(r"(?i)sample\s*\n?\s*size\s*:?\s*(\d+)", text)
    if m:
        h["nobs"] = int(m[1])
    m = re.search(r"(?i)custom\s*\n?\s*seed\s*:?\s*\n?\s*(\d+)", text)
    if m:
        h["seed"] = int(m[1])
    m = re.search(r"PROCESS Procedure for (\w+) Version\s+([\d.]+)", text + "\n" +
                  "\n".join(s.title for s in sections))
    if m:
        h["platform"], h["version"] = m[1], m[2]
    return h


def _value_after(lines, pattern):
    """The number on a line matching `pattern` ("...: 95") or on the line after it."""
    for j, ln in enumerate(lines):
        if re.search(pattern, ln, re.I):
            m = re.search(r":\s*([-+]?\d*\.?\d+)\s*$", ln)
            if m:
                return float(m[1])
            if j + 1 < len(lines):
                m = re.match(r"^\s*([-+]?\d*\.?\d+)\s*$", lines[j + 1])
                if m:
                    return float(m[1])
    return None


def _term(label):
    lab = (label or "").strip()
    return "(Intercept)" if lab.lower() == "constant" else lab


def _row(sec, row, term, **extra):
    r = {"term": term, "estimate": R.num(sec.col(row, "coeff", "effect", "index")),
         "std_error": R.num(sec.col(row, "se", "bootse"))}
    r.update(R.compact({"statistic": R.num(sec.col(row, "t", "z")), "p_value": R.num(sec.col(row, "p")),
                        "conf_low": R.num(sec.col(row, "llci", "bootllci")),
                        "conf_high": R.num(sec.col(row, "ulci", "bootulci"))}))
    r.update({k: v for k, v in extra.items() if v is not None})
    return r


_EFF = r"effects?(?:\(s\))?"


def interpret(sections) -> dict:
    """Header, per-equation results, effects and tests, from PROCESS's output in order."""
    h = header(sections)
    eqs, effects, tests, skipped, fits = [], [], [], [], []
    keys, contrasts, products = {}, {}, {}
    outcome, path, total_model, await_outcome, ind_ctx = None, None, False, False, ""
    seen_outcomes: list = []
    lines_all = []
    for kind, v in _items(sections):
        if kind == "heading":
            if re.search(r"(?i)total effect model", v):
                total_model = True
            continue
        if kind == "line":
            lines_all.append(v)
            m = _OUTCOME.match(v)
            if m:
                outcome = m[1] or None
                await_outcome = not m[1]
                path = None
                continue
            if await_outcome:
                outcome, await_outcome = v.split()[0], False
                if outcome in seen_outcomes and outcome == h.get("y"):
                    total_model = True     # PROCESS fits Y on X (and covariates) again for total=1
                seen_outcomes.append(outcome)
                continue
            if outcome and not seen_outcomes:
                seen_outcomes.append(outcome)
            if re.match(rf"(?i)^(relative )?(conditional )?indirect {_EFF}", v):
                ind_ctx = _key(v)        # a table after its path line has no title of its own
            if "->" in v:
                toks = [t for t in v.split() if t != "->"]
                if toks and re.fullmatch(r"Ind\d+", toks[0]):
                    keys[toks[0]] = toks[1:]
                else:
                    path = toks
            m = re.match(r"^\((C\d+)\)\s+(.*)$", v)
            if m:
                contrasts[m[1]] = " ".join(m[2].split())
            m = re.match(r"^(Int_\d+)\s*:?\s*(.*)$", v)
            if m:
                products[m[1]] = [t for t in m[2].split() if t not in ("x", ":")]
            continue
        s = v
        k = s.key
        if not k and path and ind_ctx:
            k_ctx = ind_ctx
        else:
            k_ctx = k
        if k == "model summary":
            for row in s.rows:
                fits.append(R.compact({
                    "response": outcome, "component": "total_effect_model" if total_model else None,
                    **{name: R.num(s.col(row, *cols)) for name, cols in _FIT.items()}}))
                f = s.col(row, "f")
                tests.append(R.compact({
                    "category": "model", "name": "f" if f is not None else "likelihood_ratio",
                    "label": f"Model summary, {outcome}" + (" (total effect model)" if total_model else ""),
                    "statistic": R.num(f if f is not None else s.col(row, "modelll", "-2ll")),
                    "df": R.num(s.col(row, "df1", "df")), "df2": R.num(s.col(row, "df2")),
                    "p_value": R.num(s.col(row, "p")), "origin": "estimation", "response": outcome,
                    "component": "total_effect_model" if total_model else None}))
            continue
        if k == "model":
            for row in s.rows:
                eqs.append(_row(s, row, _term(row[0]), response=outcome,
                                component="total_effect_model" if total_model else None))
            continue
        if k.startswith("test(s) of highest order") or k.startswith("omnibus test"):
            for row in s.rows:
                f = s.col(row, "f")
                tests.append(R.compact({
                    "category": "restriction", "name": "f" if f is not None else "chi2",
                    "label": " ".join(x for x in [s.title.strip().rstrip(":"), row[0] or ""] if x),
                    "statistic": R.num(f if f is not None else s.col(row, "chi-sq")),
                    "df": R.num(s.col(row, "df1", "df")), "df2": R.num(s.col(row, "df2")),
                    "p_value": R.num(s.col(row, "p")), "origin": "estimation", "response": outcome}))
            continue
        if re.match(rf"(relative )?total {_EFF} of x on y", k):
            for row in s.rows:
                effects.append(_row(s, row, _eff_term("total", row[0]),
                                    mediation=R.compact({"effect": "total", "treatment": row[0]})))
            continue
        if re.match(rf"(relative )?(conditional )?direct {_EFF} of x on y", k):
            mod = _moderator_cols(s)
            for row in s.rows:
                mv = _mod_value(s, row, mod)
                effects.append(_row(s, row, _eff_term("direct", row[0], mv), mediation=R.compact(
                    {"effect": "direct", "treatment": row[0], "moderator_value": mv})))
            continue
        if re.match(rf"(relative )?(conditional )?indirect {_EFF} of x on y", k) or (not k and path):
            mod = _moderator_cols(s)
            for row in s.rows:
                effects.append(_indirect(s, row, mod, path, relative=k_ctx.startswith("relative")))
            continue
        if k.startswith("coding of") or [c.lower() for c in s.columns] == ["ss", "df", "ms"] \
                or k.startswith("anova summary"):
            continue
        if re.search(r"index of (partial |conditional )?moderated mediation", k):
            for row in s.rows:
                effects.append(_row(s, row, "index of moderated mediation" + (f" ({row[0]})" if row[0] else "")
                                    + (": " + " -> ".join(path) if path else ""),
                                    mediation=R.compact({
                                        "effect": "index_moderated_mediation",
                                        "mediator": path[1] if path and len(path) == 3 else None,
                                        "path": path if path and len(path) > 3 else None})))
            continue
        if k.startswith("normal theory test"):
            for row in s.rows:
                tests.append(R.compact({
                    "category": "linear_combination", "name": "wald",
                    "label": f"Normal theory (Sobel) test of the indirect effect through {row[0]}",
                    "estimate": R.num(s.col(row, "effect")), "std_error": R.num(s.col(row, "se")),
                    "statistic": R.num(s.col(row, "z")), "distribution": "normal",
                    "p_value": R.num(s.col(row, "p")), "origin": "estimation"}))
            continue
        if re.match(r"conditional effects? of (the )?focal predictor", k):
            mod = _moderator_cols(s)
            for row in s.rows:
                mv = _mod_value(s, row, mod)
                effects.append(_row(s, row, f"{h.get('x')} | {mv}", response=outcome, component="conditional"))
            continue
        if s.rows:
            skipped.append(s.title.strip().rstrip(":") or "(untitled table)")
    for e in effects:
        med = e.get("mediation") or {}
        ind = med.pop("_ind", None)
        if ind and ind in keys:
            p = keys[ind]
            if len(p) == 3:
                med["mediator"] = p[1]
            else:
                med["path"] = p
            e["term"] = "indirect: " + " -> ".join(p)
        elif med.get("effect") == "indirect" and med.get("mediator") and h.get("x") and h.get("y"):
            # the text names the mediator only ("indirect: x2"); the tables print the path: the
            # same term either way, so records of both line up in a table
            short = f"indirect: {med['mediator']}"
            if e["term"] == short or e["term"].startswith(short + " "):
                e["term"] = f"indirect: {h['x']} -> {med['mediator']} -> {h['y']}" + e["term"][len(short):]
        if med.get("effect") == "contrast":
            lab = med.pop("_label", "")
            d = contrasts.get(lab.strip("()"))
            e["term"] = f"contrast {lab}" + (f": {d}" if d else "")
    return {"header": h, "equations": eqs, "effects": effects, "tests": tests, "fits": fits,
            "products": products, "skipped": skipped,
            "conf": _value_after(lines_all, r"level of confidence"),
            "reps": _value_after(lines_all, r"number of bootstrap")}


def _indirect(s, row, mod, path, relative=False):
    lab = row[0]
    mv = _mod_value(s, row, mod)
    med, treat, eff, extra = None, None, "indirect", {}
    if lab and lab.upper() == "TOTAL":
        eff = "total_indirect"
    elif lab and re.fullmatch(r"\(C\d+\)", lab):
        eff = "contrast"
        extra["_label"] = lab
    elif lab and re.fullmatch(r"Ind\d+", lab):
        extra["_ind"] = lab
    elif relative and lab:
        treat = lab
    elif lab and not mod:
        med = lab
    if eff == "indirect" and not med and "_ind" not in extra and path:
        if len(path) == 3:
            med = path[1]
        else:
            extra["path"] = path
    term = {"total_indirect": "total indirect effect", "contrast": f"contrast {lab}"}.get(eff)
    if term is None:
        chain = path if path and (relative or mod or not lab) else None
        term = "indirect: " + (" -> ".join(chain) if chain else (med or lab or ""))
        if treat:
            term += f" [{treat}]"
    if mv is not None:
        term += f" | {mv}"
    return _row(s, row, term, mediation=R.compact({
        "effect": eff, "mediator": med, "treatment": treat, "moderator_value": mv, **extra}))


# Model Summary columns -> metric names (spec/estrec.md 4.5 `equations`): OLS (R, R-sq, MSE, F,
# df1, df2, p) and, for a dichotomous Y, logistic (-2LL, ModelLL, df, p, McFadden, CoxSnell, Nagelkrk)
_FIT = {"r2": ("r-sq",), "mse": ("mse",), "df_residual": ("df2",), "deviance": ("-2ll",),
        "pseudo_r2": ("mcfadden",), "cox_snell_r2": ("coxsnell",), "nagelkerke_r2": ("nagelkrk",)}


def _moderator_cols(s):
    """Leading columns that hold moderator values (conditional tables)."""
    heads = [_key(c) for c in s.columns]
    for i, hd in enumerate(heads):
        if hd in ("effect", "index", "coeff"):
            return s.columns[:i]
    return []


def _mod_value(s, row, mod):
    if not mod:
        return None
    vals = row[1][:len(mod)]
    if len(mod) == 1:
        return R.num(vals[0])
    return ", ".join(f"{c.strip()}={R.num(v)}" for c, v in zip(mod, vals))


def _eff_term(eff, label, mv=None):
    base = {"total": "total effect", "direct": "direct effect"}[eff]
    if label:
        base += f": {label}"
    if mv is not None:
        base += f" | {mv}"
    return base


# ---------------------------------------------------------------- the record


def _seed_from_syntax(syntax):
    m = re.search(r"\(\(\s*'(\d+)'\s*<>\s*'random'\s*\)\)", syntax or "")
    return int(m[1]) if m else None


def record(cmd, nt, hints, identifying=False):
    """An estrec record of one PROCESS run, from its OMS capture (`cmd`: estrec_oxml.Command)."""
    import estrec_procedures as P
    if not is_process(cmd):
        raise P.Unsupported("MATRIX output that isn't PROCESS")
    tabled = [t for t in cmd.tables if t.subtype == "Matrix Table"]
    if tabled:
        secs = sections_from_tables(cmd)
        # header lines that stayed text (the banner) still carry the version
        for t in cmd.texts:
            secs = sections_from_text(t) + secs if "PROCESS Procedure" in t else secs
        precision = None
    else:
        secs = []
        for t in cmd.texts:
            secs += sections_from_text(t)
        precision = _printed_decimals(cmd.texts)
    info = interpret(secs)
    h = info["header"]
    if h.get("seed") is None:
        h["seed"] = _seed_from_syntax(nt.get("syntax"))
    nt = dict(nt)
    nt["syntax"] = None            # the Notes table holds PROCESS's macro expansion, not the call
    return build(info, cmd, nt, hints, precision=precision, identifying=identifying)


def _printed_decimals(texts):
    best = 0
    for t in texts:
        for m in re.finditer(r"(?<![\w.])-?\d*\.(\d+)(?![\w.])", t):
            best = max(best, len(m[1]))
    return best or None


def call_text(h, info):
    parts = [f"y={h.get('y')}", f"x={h.get('x')}"]
    if h.get("mediators"):
        parts.append("m=" + " ".join(h["mediators"]))
    for k in ("w", "z"):
        if h.get(k):
            parts.append(f"{k}={h[k]}")
    if h.get("covariates"):
        parts.append("cov=" + " ".join(h["covariates"]))
    parts.append(f"model={h.get('model')}")
    return "PROCESS " + " /".join(parts) + "."


def build(info, cmd, nt, hints, precision=None, identifying=False):
    import estrec_procedures as P
    h = info["header"]
    meds = h["mediators"]
    model = h.get("model")
    ydich = any(t.get("name") == "likelihood_ratio" and t.get("response") == h.get("y") for t in info["tests"])
    responses = list(dict.fromkeys([e["response"] for e in info["equations"] if e.get("response")]))
    params = []
    for e in info["equations"]:
        e = dict(e)
        e["canonical"] = P.canonical(e["term"])
        params.append(e)
    params += [dict(e, response=e.get("response") or h.get("y")) for e in info["effects"]]
    messages = []
    if precision is not None:
        messages.append({"level": "info", "code": "printed_precision", "source": "estrec",
                         "message": f"PROCESS printed its results as text, so numbers carry its printed "
                                    f"{precision} decimals; add /display=tables to the PROCESS command "
                                    f"for full precision"})
    if info["skipped"]:
        messages.append({"level": "info", "code": "process_sections_skipped", "source": "estrec",
                         "message": "PROCESS output not recorded: " + "; ".join(info["skipped"])})
    boot = bool(info.get("reps")) and any(
        (e.get("mediation") or {}).get("effect") in ("indirect", "total_indirect", "index_moderated_mediation")
        for e in info["effects"])
    spec = {"call": None, "formula": {"text": call_text(h, info), "syntax": "PROCESS"}}
    if meds:
        mods = [h[k] for k in ("w", "z") if h.get(k)]
        structure = ("moderated" if mods else "serial" if model == 6 else
                     "parallel" if len(meds) > 1 else "simple")
        spec["mediation"] = R.compact({
            "treatment": h.get("x"), "mediators": meds, "outcome": h.get("y"),
            "covariates": h.get("covariates") or [], "moderators": mods or None,
            "structure": structure, "process_model": model,
            "models": [{"response": r, "estimator": "logit" if (ydich and r == h.get("y")) else "ols"}
                       for r in responses],
            "inference": R.compact({"method": "bootstrap" if boot else "normal",
                                    "reps": R.as_int(info.get("reps")) if boot else None,
                                    "ci_type": "percentile" if boot else None,
                                    "seed": h.get("seed")})})
    metrics = {"nobs": h.get("nobs")}
    if info.get("conf"):
        metrics["conf_level"] = R.num(info["conf"] / 100)
    rec = P._record(
        cmd, nt, hints,
        estimator={"family": "mediation" if meds else "moderation",
                   "method": "logit" if ydich and not meds else "ols"},
        profiles=["mediation/0.1"] if meds and any(
            (e.get("mediation") or {}).get("effect") == "indirect" for e in info["effects"]) else [],
        parameters=params, vcovs=[], metrics=metrics, spec=spec,
        structures=None, tests=[_test(t) for t in info["tests"]], messages=messages,
        responses=responses or None, title=f"PROCESS model {model}", identifying=identifying)
    rec["structures"].pop("vcov", None)
    if info.get("fits"):
        rec["structures"]["equations"] = {"kind": "object", "per_response": [
            R.compact(dict(f, nobs=f.get("nobs", h.get("nobs")))) for f in info["fits"] if f.get("response")]}
    if not rec["structures"]:
        rec.pop("structures")
    sw = rec["provenance"]["software"]
    sw.insert(1, R.compact({"name": "PROCESS", "version": h.get("version"), "role": "estimator",
                            "url": "https://www.afhayes.com/download.html",
                            "command": f"PROCESS model {model}"}))
    return R.add_digest(rec)


def _test(t):
    t = {k: v for k, v in t.items() if v is not None}
    t.pop("values", None)
    df, df2 = t.pop("df", None), t.pop("df2", None)
    if t.get("name") == "f":
        t.update(R.compact({"distribution": "F", "df1": df, "df2": df2}))
    elif df is not None:
        t["df"] = df
    return t
