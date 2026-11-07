"""estrec for Stata (stata/estrec.ado): every supported command writes a valid record.

Each command runs on data that ship with Stata: auto (plus a count and a panel id), nlsw88
(clogit, mixed, melogit, svy), cancer (stcox, streg) and auto under mi (mi estimate). The
records must validate with no warnings at every disclosure level (bar the KNOWN_WARNINGS,
fields Stata doesn't report that a profile expects), claim the profiles listed below, and
reproduce Stata's own results table (r(table)) to rounding. reghdfe records must equal the
worked converter's (converters/reghdfe) apart from the writer's name and the formula text.

Needs Stata (on PATH, or $ESTREC_STATA). Commands from SSC (reghdfe, ivreg2, ivreghdfe,
ppmlhdfe) are skipped when they aren't installed.
"""

from __future__ import annotations

import csv
import json
import math
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

import estrec as ef

ROOT = Path(__file__).resolve().parents[1]
STATA_DIR = ROOT / "stata"

INF = "inference/0.1"
FE = "linear-fe/0.1"
IV = "iv/0.1"
GLM = "glm/0.1"
PPML = "ppmlhdfe/0.1"
CLOGIT = "conditional-logit/0.1"
SURV = "survival/0.1"
MIXED = "mixed/0.1"
SURVEY = "survey/0.1"
RES = "resampling/0.1"
MI = "mi/0.1"

SETUPS = {
    "auto": """
sysuse auto, clear
generate cnt = round(price/1000)
generate id = mod(_n, 15) + 1
generate t = ceil(_n/15)
xtset id t
""",
    "nlsw": """
sysuse nlsw88, clear
egen grp = group(industry)
generate psu = mod(idcode, 40)
generate fpc = 0.1
svyset psu [pw=hours], strata(south) fpc(fpc)
""",
    "cancer": """
sysuse cancer, clear
stset studytime, failure(died)
""",
    "mi": """
sysuse auto, clear
mi set mlong
mi register imputed rep78
mi impute regress rep78 = price mpg weight, add(5) rseed(12345)
""",
}
SETUP = SETUPS["auto"]

# name: (command, profiles at level 4, needs[, setup[, estrec write options]])
CASES = {
    "regress_crv": ("regress price mpg weight i.rep78, vce(cluster id)", [INF], None),
    "regress_hc3_aw": ("regress price mpg weight [aw=turn], vce(hc3)", [INF], None),
    "regress_fw": ("regress price mpg [fw=rep78]", [INF], None),
    "areg_crv": ("areg price mpg weight, absorb(rep78) vce(cluster id)", [INF, FE], None),
    "xtreg_fe": ("xtreg price mpg weight, fe", [INF, FE], None),
    "xtreg_fe_robust": ("xtreg price mpg weight, fe vce(robust)", [INF, FE], None),
    "xtreg_re": ("xtreg price mpg weight, re vce(robust)", [INF], None),
    "reghdfe": ("reghdfe price mpg weight, absorb(rep78 id) vce(cluster id)", [INF, FE], "reghdfe"),
    "ivregress_2sls": ("ivregress 2sls price weight (mpg = length turn)", [INF, IV], None),
    "ivregress_liml": ("ivregress liml price weight (mpg = length turn), small vce(robust)", [INF, IV], None),
    "ivregress_gmm": ("ivregress gmm price weight (mpg = length turn)", [INF, IV], None),
    "ivreg2_robust": ("ivreg2 price weight (mpg = length turn), robust first", [INF, IV], "ivreg2"),
    "ivreg2_endog": ("ivreg2 price weight (mpg = length turn), endog(mpg) ffirst", [INF, IV], "ivreg2"),
    "ivreghdfe": (
        "ivreghdfe price weight (mpg = length turn), absorb(rep78) cluster(id) first",
        [INF, IV, FE],
        "ivreghdfe",
    ),
    "logit": ("logit foreign mpg weight", [INF, GLM], None),
    "logistic": ("logistic foreign mpg i.rep78", [INF, GLM], None),
    "probit": ("probit foreign mpg weight, vce(robust)", [INF, GLM], None),
    "poisson": ("poisson cnt mpg weight, exposure(length)", [INF, GLM], None),
    "nbreg": ("nbreg cnt mpg weight, vce(cluster id)", [INF, GLM], None),
    "glm": ("glm cnt mpg weight, family(poisson) link(log)", [INF, GLM], None),
    "glm_poisson": ("glm cnt mpg weight, family(poisson) link(log) exposure(length)", [INF, GLM], None),
    "poisson_fw": ("poisson cnt mpg weight [fw=rep78], exposure(length)", [INF, GLM], None),
    "glm_poisson_fw": (
        "glm cnt mpg weight [fw=rep78], family(poisson) link(log) exposure(length)",
        [INF, GLM],
        None,
    ),
    "glm_irls": ("glm foreign mpg weight, family(binomial) link(logit) irls", [INF], None),
    "tobit": ("tobit price mpg, ll(3500)", None, None),
    # Tier 2
    "ppmlhdfe": ("ppmlhdfe cnt mpg weight, absorb(rep78) vce(cluster id)", [INF, GLM, PPML], "ppmlhdfe"),
    "bootstrap_regress": ("bootstrap, reps(50) seed(1): regress price mpg weight", [INF, RES], None),
    "bootstrap_logit": ("logit foreign mpg weight, vce(bootstrap, reps(30) seed(3))", [INF, GLM, RES], None),
    "clogit": ("clogit union wage hours, group(grp)", [INF, CLOGIT], None, "nlsw"),
    "clogit_robust": ("clogit union wage hours, group(grp) vce(robust)", [INF, CLOGIT], None, "nlsw"),
    "mixed_reml": (
        "mixed wage hours ttl_exp || industry: ttl_exp, covariance(unstructured) reml",
        [MIXED],
        None,
        "nlsw",
    ),
    "mixed_ml_nested": ("mixed wage ttl_exp || industry: || occupation:", [MIXED], None, "nlsw"),
    "mixed_kr": ("mixed wage ttl_exp hours || industry:, reml dfmethod(kroger)", [MIXED], None, "nlsw"),
    "melogit": ("melogit union wage || industry:", [MIXED], None, "nlsw"),
    "svy_regress": ("svy: regress wage ttl_exp tenure", [INF, SURVEY], None, "nlsw"),
    "svy_logit_subpop": ("svy, subpop(union): logit married wage", [INF, SURVEY], None, "nlsw"),
    "stcox": ("stcox drug age", [INF, SURV], None, "cancer"),
    "stcox_efron_robust": ("stcox drug age, efron vce(robust)", [INF, SURV], None, "cancer"),
    "streg_weibull": ("streg drug age, distribution(weibull)", [INF, SURV], None, "cancer"),
    "streg_lognormal": ("streg drug age, distribution(lognormal)", [INF, SURV], None, "cancer"),
    "mi_regress": (
        "mi estimate: regress price mpg rep78 weight",
        [INF, MI],
        None,
        "mi",
        "imputation(regress)",
    ),
    "mi_logit_post": ("mi estimate, post: logit foreign mpg rep78", [INF], None, "mi"),
}

# r(table) to compare with, when it isn't the command's own: mixed's table shows variances,
# e(b) and the record hold log SDs (its estimation metric)
REPLAY = {name: "mixed, estmetric" for name in CASES if name.startswith("mixed")}

# Fields a claimed profile expects that Stata doesn't report: warnings until the profiles say
# "expected when the tool reports it" (proposed to Ted, 2026-11-07)
KNOWN_WARNINGS = {
    "metrics.n_groups: [conditional-logit/0.1] expected, missing",
    "structures.numerics.singular: [mixed/0.1] expected, missing",
}

# Tests estrec writes that Stata's table doesn't show: nbreg's /lnalpha keeps the z test of
# Tier 1, because inference/0.1 wants a p-value on every row (an exemption for ancillary and
# variance-component rows is proposed to Ted, 2026-11-07)
KNOWN_COMPUTED = {("nbreg", "/lnalpha")}

# Stata's ML commands (not glm)
ML = {"logit", "logistic", "probit", "poisson", "poisson_fw", "nbreg"}
# z tests: no e(df_r), so no df_residual and a null df_t (inference/0.1)
Z_TESTS = ML | {"xtreg_re", "ivregress_2sls", "ivregress_gmm", "ivreg2_robust", "ivreg2_endog"}
Z_TESTS |= {"ppmlhdfe", "bootstrap_regress", "bootstrap_logit", "clogit", "clogit_robust", "stcox"}
Z_TESTS |= {"stcox_efron_robust", "streg_weibull", "streg_lognormal", "mixed_reml", "melogit"}


def _spec(name: str) -> tuple:
    cmd, profiles, needs, *rest = CASES[name]
    setup = rest[0] if rest else "auto"
    opts = rest[1] if len(rest) > 1 else ""
    return cmd, profiles, needs, setup, opts


def _stata() -> str | None:
    env = os.environ.get("ESTREC_STATA")
    if env:
        return env
    for name in ("stata-mp", "stata-se", "stata"):
        if shutil.which(name):
            return shutil.which(name)
    for path in sorted(Path("/usr/local").glob("stata*/stata-mp"), reverse=True):
        return str(path)
    return None


def _run(stata: str, out: Path, body: str, name: str = "run") -> str:
    (out / f"{name}.do").write_text(f'adopath ++ "{STATA_DIR}"\n' + body + "\n")
    subprocess.run([stata, "-b", "do", f"{name}.do"], cwd=out, check=False, capture_output=True, text=True)
    return (out / f"{name}.log").read_text()


@pytest.fixture(scope="module")
def stata() -> str:
    path = _stata()
    if path is None:
        pytest.skip("Stata not found (set ESTREC_STATA)")
    return path


@pytest.fixture(scope="module")
def installed(stata, tmp_path_factory) -> set:
    out = tmp_path_factory.mktemp("probe")
    log = _run(
        stata,
        out,
        "foreach p in reghdfe ivreg2 ivreghdfe ppmlhdfe {\ncapture which `p'\nif !_rc di \"HAVE `p'\"\n}",
    )
    return {line.split()[1] for line in log.splitlines() if line.startswith("HAVE ")}


@pytest.fixture(scope="module")
def written(stata, installed, tmp_path_factory) -> Path:
    """Every case at levels 1-5, plus r(table) as CSV (b, se, statistic, p, ll, ul, eform)."""
    out = tmp_path_factory.mktemp("estrec")
    lines = ["set linesize 200"]
    current = None
    for name in CASES:
        cmd, _, needs, setup, opts = _spec(name)
        if needs and needs not in installed:
            continue
        if setup != current:
            lines.append(SETUPS[setup])
            current = setup
        lines.append(f"quietly {cmd}")
        for csvname, replay in ((name, ""), (f"{name}_replay", REPLAY.get(name))):
            if replay is None:
                continue
            lines += [
                f"quietly {replay}" if replay else "",
                "capture matrix T = r(table)",
                "if _rc matrix T = J(9, 0, .)",
                (
                    f'mata: _T = st_matrix("T"); _f = fopen("{csvname}.csv", "w"); '
                    "for (_j = 1; _j <= cols(_T) & rows(_T) >= 9; _j++) "
                    'fput(_f, invtokens(strofreal(_T[(1, 2, 3, 4, 5, 6, 9), _j]\', "%24.17g"), ",")); fclose(_f)'
                ),
            ]
        lines += [
            f'estrec write using "{name}_l{n}.estrec.json", replace level({n}) {opts}' for n in range(1, 6)
        ]
    log = _run(stata, out, "\n".join(lines))
    assert "\nr(" not in log, log[-3000:]
    return out


def _case(written: Path, installed: set, name: str, level: int = 4) -> dict:
    needs = CASES[name][2]
    if needs and needs not in installed:
        pytest.skip(f"{needs} isn't installed in this Stata")
    path = written / f"{name}_l{level}.estrec.json"
    rec = ef.read(path)
    issues = [i for i in ef.validate(rec, base_dir=path.parent) if i.level != "info"]
    issues = [i for i in issues if not (i.level == "warning" and any(k in str(i) for k in KNOWN_WARNINGS))]
    assert not issues, f"{path.name}: {issues}"
    assert rec["meta"]["disclosure"] == {"level": level}
    assert ef.record_level(rec) <= level
    return rec


@pytest.mark.parametrize("level", [1, 2, 3, 4, 5])
@pytest.mark.parametrize("name", list(CASES))
def test_valid_at_every_level(written, installed, name, level):
    rec = _case(written, installed, name, level)
    if level == 4:
        assert rec["meta"].get("profiles") == CASES[name][1]
        assert [s["name"] for s in rec["provenance"]["software"]][1:] == ["stata", "estrec"]
    if level == 1:
        assert set(rec) == {"schema", "meta", "metrics", "parameters", "history"}


@pytest.mark.parametrize("name", list(CASES))
def test_matches_stata_results_table(written, installed, name):
    rec = _case(written, installed, name)

    def table(csvname):
        with open(written / f"{csvname}.csv") as f:
            # Stata missing is . or .a-.z; a number below 1 is written without its 0 (.448)
            return [[None if re.fullmatch(r"\.[a-z]?", x) else float(x) for x in r] for r in csv.reader(f)]

    rows = table(name)
    if not rows:
        pytest.skip(f"{name} leaves no r(table)")
    # mixed's own table shows variances; its variance components are compared in e(b)'s metric
    random = table(f"{name}_replay") if name in REPLAY else rows
    keys = ("estimate", "std_error", "statistic", "p_value", "conf_low", "conf_high")
    # r(table) may go on past e(b) with derived parameters (nbreg's alpha, streg's p and 1/p)
    assert len(rows) >= len(rec["parameters"])
    for j, p in enumerate(rec["parameters"]):
        *row, eform = random[j] if p.get("component") == "random" else rows[j]
        if "estimate" not in p:
            continue
        got = [p.get(k) for k in keys]
        if eform == 1:  # Stata shows odds or hazard ratios; the record keeps e(b)'s scale (spec 4.4)
            b = math.exp(p["estimate"])
            got = [b, b * p["std_error"], p.get("statistic"), p.get("p_value")]
            got += [math.exp(p[k]) if k in p else None for k in ("conf_low", "conf_high")]
        for k, g, want in zip(keys, got, row):
            if want is None:  # Stata shows none, so the record has none
                assert g is None or (name, p["term"]) in KNOWN_COMPUTED, (p["term"], k, g)
            elif g is not None:
                assert g == pytest.approx(want, rel=1e-10, abs=1e-12), (p["term"], k, g, want)
            else:  # only an unmapped command's ancillary rows go untested
                assert name == "tobit" and p["term"].startswith("/"), (p["term"], k, want)


def _tests(rec: dict) -> dict:
    return {(t["category"], t["name"], t.get("distribution")): t for t in rec.get("tests", [])}


def test_xtreg_fe_tests_use_regressor_df(written, installed):
    rec = _case(written, installed, "xtreg_fe")
    tests = _tests(rec)
    assert tests[("model", "f", "F")]["df1"] == 2  # Stata shows F(2,57); e(df_m) is 16
    assert tests[("fixed_effects", "f", "F")]["df1"] == 14
    fe = rec["structures"]["fixed_effects"][0]
    assert fe["name"] == "id" and fe["levels"] == 15
    assert rec["specification"]["state"]["xtset"] == {"panelvar": "id", "timevar": "t"}


def test_areg_counts_absorbed_levels(written, installed):
    rec = _case(written, installed, "areg_crv")
    vc = rec["structures"]["vcov"][0]
    assert vc["type"] == "CRV1" and "nested" in vc["ssc"]["K_counts"]
    assert rec["specification"]["options"]["drop_singletons"] is False


def test_regress_keeps_the_model_based_vcov(written, installed):
    rec = _case(written, installed, "regress_crv")
    default, model = rec["structures"]["vcov"]
    assert default["type"] == "CRV1" and default["default"] and default["df_t"] == 14
    assert model["type"] == "iid" and not model["default"] and model["df_t"] == 69 - 7


def test_frequency_weights_keep_statas_n(written, installed):
    # nobs is e(N) as Stata reports it (235, the sum of the weights), not the 69 rows used
    for name in ("regress_fw", "poisson_fw", "glm_poisson_fw"):
        m = _case(written, installed, name)["metrics"]
        assert m["nobs"]["value"] == 235 and "frequency weights" in m["nobs"]["definition"], name
        assert m["sum_weights"]["value"] == 235, name


def test_ivregress_records_estat(written, installed):
    rec = _case(written, installed, "ivregress_2sls")
    tests = _tests(rec)
    assert {
        ("first_stage", "f", "F"),
        ("overidentification", "sargan", "chi2"),
        ("endogeneity", "wu_hausman", "F"),
        ("weak_identification", "cragg_donald_f", None),
    } <= set(tests)
    assert rec["structures"]["vcov"][0]["df_t"] is None  # z tests without small
    assert "df_residual" not in rec["metrics"]
    assert rec["specification"]["instruments"] == ["length", "turn"]
    assert rec["specification"]["endogenous"] == ["mpg"]


def test_ivreg2_tests(written, installed):
    rec = _case(written, installed, "ivreg2_robust")
    tests = _tests(rec)
    assert ("overidentification", "hansen_j", "chi2") in tests
    assert ("weak_identification", "kleibergen_paap_rk_wald_f", None) in tests
    assert ("first_stage", "sanderson_windmeijer_f", "F") in tests
    assert rec["structures"]["vcov"][0]["type"] == "HC0"
    iid = _tests(_case(written, installed, "ivreg2_endog"))
    assert ("overidentification", "sargan", "chi2") in iid and ("endogeneity", "c", "chi2") in iid


def test_glm_family(written, installed):
    nb = _case(written, installed, "nbreg")
    assert nb["meta"]["estimator"]["distribution"] == "negative_binomial"
    aux = [p for p in nb["parameters"] if p["term"] == "/lnalpha"]
    assert aux and aux[0]["component"] == "auxiliary"
    po = _case(written, installed, "poisson")
    assert po["specification"]["offset"] == {"variable": "length", "exposure": True}
    assert po["structures"]["numerics"]["converged"] is True
    irls = _case(written, installed, "glm_irls")
    assert irls["meta"]["messages"][0]["code"] == "convergence_unknown"


@pytest.mark.parametrize("name", sorted(Z_TESTS))
def test_z_tests_record_no_residual_df(written, installed, name):
    rec = _case(written, installed, name)
    assert "df_residual" not in rec["metrics"]
    assert rec["structures"]["vcov"][0]["df_t"] is None


def test_deviance_as_stata_reports_it(written, installed):
    for name in ("logit", "logistic", "probit", "nbreg"):  # Stata reports none; estrec computes none
        assert "deviance" not in _case(written, installed, name)["metrics"], name
    for ml, glm in (("poisson", "glm_poisson"), ("poisson_fw", "glm_poisson_fw")):
        rec = _case(written, installed, ml)
        dev, pearson = rec["metrics"]["deviance"], rec["metrics"]["pearson_chi2"]
        assert "estat gof" in dev["definition"] and "estat gof" in pearson["definition"]
        tests = _tests(rec)
        assert tests[("model_fit", "deviance", "chi2")]["statistic"] == dev["value"]
        assert tests[("model_fit", "deviance", "chi2")]["origin"] == "postestimation"
        assert tests[("model_fit", "pearson", "chi2")]["statistic"] == pearson["value"]
        # the same quantity as glm's e(deviance) and e(deviance_p), which is why it's named deviance
        g = _case(written, installed, glm)["metrics"]
        assert dev["value"] == pytest.approx(g["deviance"], rel=1e-10)
        # poisson and glm stop at coefficients up to 1e-6 apart (relative); the deviance is flat at the
        # optimum and agrees to 1e-12, Pearson's statistic moves with the coefficients
        assert pearson["value"] == pytest.approx(g["pearson_chi2"], rel=1e-6)
    for name in ("logit", "logistic", "probit"):
        t = _tests(_case(written, installed, name))[("model_fit", "pearson", "chi2")]
        assert "covariate patterns" in t["label"] and t["origin"] == "postestimation"


def test_unmapped_command_is_core_only(written, installed):
    rec = _case(written, installed, "tobit")
    assert "profiles" not in rec["meta"]
    aux = [p for p in rec["parameters"] if p["term"].startswith("/")]
    assert aux and "p_value" not in aux[0]


def _flat(d, p=""):
    if isinstance(d, dict):
        return {k2: v2 for k, v in d.items() for k2, v2 in _flat(v, f"{p}.{k}").items()}
    if isinstance(d, list):
        return {k2: v2 for i, v in enumerate(d) for k2, v2 in _flat(v, f"{p}[{i}]").items()}
    return {p: d}


def test_reghdfe_matches_the_worked_converter(stata, installed, tmp_path):
    if "reghdfe" not in installed:
        pytest.skip("reghdfe isn't installed in this Stata")
    cmds = [
        "reghdfe price mpg weight, absorb(rep78 id) vce(cluster id)",
        "reghdfe price mpg i.foreign c.mpg#c.weight [aw=turn], absorb(rep78) vce(robust)",
    ]
    lines = [f'adopath ++ "{ROOT / "converters" / "reghdfe"}"', SETUP]
    for i, cmd in enumerate(cmds):
        lines.append(f"quietly {cmd}")
        for n in (1, 3, 5):
            lines += [
                f'estimation_write using "old{i}_{n}.json", replace level({n})',
                f'estrec write using "new{i}_{n}.json", replace level({n})',
            ]
    log = _run(stata, tmp_path, "\n".join(lines))
    assert "\nr(" not in log, log[-3000:]
    allowed = {
        ".meta.id",
        ".meta.created",
        ".history[0].when",
        ".history[0].by.name",
        ".history[0].by.version",
        ".meta.producer.name",
        ".meta.producer.version",
        ".provenance.software[2].name",
        ".provenance.software[2].version",
        ".specification.formula.text",
    }
    for i in range(len(cmds)):
        for n in (1, 3, 5):
            old = _flat(json.loads((tmp_path / f"old{i}_{n}.json").read_text()))
            new = _flat(json.loads((tmp_path / f"new{i}_{n}.json").read_text()))
            diff = [k for k in sorted(set(old) | set(new)) if old.get(k) != new.get(k) and k not in allowed]
            assert not diff, (cmds[i], n, diff)


@pytest.mark.parametrize(
    "setup, call, rc",
    [
        ("regress price mpg", 'estrec write using "x.json", level(6)', 198),
        ("ereturn clear", 'estrec write using "x.json"', 301),
        ("jackknife: regress price mpg", 'estrec write using "x.json"', 198),
        ('regress price mpg\nestrec write using "x.json"', 'estrec write using "x.json"', 602),
        ("", "estrec frobnicate", 199),
    ],
)
def test_errors(stata, tmp_path, setup, call, rc):
    log = _run(stata, tmp_path, f'sysuse auto, clear\n{setup}\ncapture noisily {call}\ndisplay "rc=" _rc')
    assert f"rc={rc}" in log, log[-1500:]


# ---- Tier 2 ----------------------------------------------------------------------------


def test_ppmlhdfe(written, installed):
    rec = _case(written, installed, "ppmlhdfe")
    opts = rec["specification"]["options"]
    assert opts["separation"] and "ir" not in opts["separation"]
    assert isinstance(opts["drop_singletons"], bool)
    m = rec["metrics"]
    assert {"n_separated", "n_singletons", "deviance", "log_lik_fe_only"} <= set(m)
    assert "fixef_iterations" in rec["structures"]["numerics"]
    vc = rec["structures"]["vcov"][0]
    assert vc["type"] == "CRV1" and vc["ssc"] == {"convention": "ppmlhdfe", "formula": "G/(G-1)"}
    assert [fe["name"] for fe in rec["structures"]["fixed_effects"]] == ["rep78"]


def test_clogit(written, installed):
    rec = _case(written, installed, "clogit")
    assert rec["specification"]["groups"] == ["grp"]
    assert rec["specification"]["options"] == {
        "likelihood": "exact",
        "drop_uninformative": True,
        "optimizer": "nr",
    }
    m = rec["metrics"]
    assert m["n_dropped_uninformative"] == 2 and m["n_groups_dropped"] == 1 and "n_groups" not in m
    assert rec["structures"]["groups"] == {"kind": "object", "multiple_positive": True}
    assert _tests(rec)[("model", "likelihood_ratio", "chi2")]["df"] == 2
    # vce(robust) is clogit's cluster-robust vcov on the groups, as vce(cluster grp) gives it
    vc = _case(written, installed, "clogit_robust")["structures"]["vcov"]
    assert vc[0]["type"] == "CRV1" and vc[0]["tool_type"] == "robust" and vc[0]["cluster"] == ["grp"]
    assert "n_clusters" not in vc[0]  # Stata posts no e(N_clust) for it
    assert vc[1]["tool_type"] == "V_modelbased" and not vc[1]["default"]


def test_survival(written, installed):
    cox = _case(written, installed, "stcox")
    assert cox["meta"]["estimator"] == {"family": "survival", "method": "cox"}
    assert cox["specification"]["survival"] == {
        "time": "studytime",
        "start": None,
        "event": "died",
        "id": None,
    }
    assert cox["specification"]["options"]["ties"] == "breslow"
    assert cox["metrics"]["n_events"] == 31 and cox["metrics"]["n_subjects"] == 48
    assert cox["provenance"]["software"][0]["name"] == "stcox"
    ph = [t for t in cox["tests"] if t["category"] == "proportional_hazards"]
    assert [t.get("terms") for t in ph] == [None, ["drug"], ["age"]]
    assert all(t["options"] == {"transform": "identity"} and t["origin"] == "postestimation" for t in ph)
    efron = _case(written, installed, "stcox_efron_robust")
    assert efron["specification"]["options"]["ties"] == "efron"
    vc = efron["structures"]["vcov"][0]
    assert vc["type"] == "HC0" and vc["ssc"]["formula"] == "N/(N-1)"  # R coxph robust x N/(N-1), checked
    wb = _case(written, installed, "streg_weibull")
    assert wb["meta"]["estimator"] == {
        "family": "survival",
        "method": "parametric",
        "distribution": "weibull",
        "metric": "ph",
    }
    assert wb["metrics"]["shape"]["value"] == pytest.approx(1.7577486751, rel=1e-9)
    assert wb["parameters"][-1]["term"] == "/ln_p" and wb["parameters"][-1]["component"] == "auxiliary"
    ln = _case(written, installed, "streg_lognormal")
    assert (
        ln["meta"]["estimator"]["metric"] == "aft" and ln["meta"]["estimator"]["distribution"] == "lognormal"
    )


def test_mixed(written, installed):
    rec = _case(written, installed, "mixed_reml")
    assert rec["meta"]["estimator"] == {"family": "mixed", "method": "reml"}
    assert rec["specification"]["random_effects"] == [
        {
            "group": "industry",
            "terms": ["ttl_exp", "(Intercept)"],
            "covariance": "unstructured",
            "text": "|| industry: ttl_exp",
        }
    ]
    re = {p["term"]: p for p in rec["parameters"] if p.get("component") == "random"}
    assert re["lns1_1_1:_cons"]["vc"] == {"group": "industry", "terms": ["ttl_exp"], "type": "log_sd"}
    assert re["atr1_1_1_2:_cons"]["vc"]["terms"] == ["ttl_exp", "(Intercept)"]
    assert re["lnsig_e:_cons"]["vc"]["group"] == "Residual"
    # Stata reports no test of a log SD, so the record has none
    assert "p_value" not in re["lns1_1_1:_cons"] and "p_value" in re["atr1_1_1_2:_cons"]
    assert rec["structures"]["random_effects"][0]["levels"] == 12
    assert "REML" in rec["metrics"]["log_lik"]["definition"]
    assert _tests(rec)[("random_effects", "likelihood_ratio", "chi2")]["df"] == 3
    nested = _case(written, installed, "mixed_ml_nested")
    assert nested["meta"]["estimator"]["method"] == "ml"
    spec = nested["specification"]["random_effects"]
    assert [(r["group"], r.get("nested_in")) for r in spec] == [
        ("industry", None),
        ("occupation", "industry"),
    ]
    assert [r["group"] for r in nested["structures"]["random_effects"]] == ["industry", "occupation"]
    kr = _case(written, installed, "mixed_kr")
    assert kr["specification"]["options"]["df_method"] == "kenward_roger"
    fixed = [p for p in kr["parameters"] if "component" not in p]
    assert all(p["df"] > 0 for p in fixed)


def test_melogit(written, installed):
    rec = _case(written, installed, "melogit")
    assert (
        rec["meta"]["estimator"]["method"] == "agq" and rec["specification"]["options"]["n_quadrature"] == 7
    )
    assert rec["meta"]["estimator"]["distribution"] == "binomial"
    var = rec["parameters"][-1]
    assert var["vc"] == {"group": "industry", "terms": ["(Intercept)"], "type": "var"}
    assert "p_value" not in var and "conf_low" in var  # Stata's table: an interval, no test
    lr = _tests(rec)[("random_effects", "likelihood_ratio", "chibar2")]
    assert lr["df"] == 1
    assert rec["provenance"]["software"][0]["name"] == "melogit"


def test_svy(written, installed):
    rec = _case(written, installed, "svy_regress")
    d = rec["specification"]["survey_design"]
    assert d["weights"] == "hours" and d["strata"] == ["south"] and d["psu"] == ["psu"]
    assert d["fpc"] == {"variable": "fpc", "convention": "sampling_fraction"}
    assert d["variance"] == "linearization" and d["single_psu"] == "missing" and d["subpopulation"] is None
    vc = rec["structures"]["vcov"]
    assert len(vc) == 1 and vc[0]["type"] == "linearized" and vc[0]["df_t"] == 78
    assert rec["metrics"]["df_design"] == 78 and rec["metrics"]["n_psu"] == 80
    f = _tests(rec)[("model", "wald", "F")]
    assert (f["df1"], f["df2"]) == (2, 77)  # svy's adjusted F(df_m, df_r - df_m + 1)
    sub = _case(written, installed, "svy_logit_subpop")
    assert sub["specification"]["survey_design"]["subpopulation"] == "union"
    assert sub["metrics"]["n_subpop"]["value"] == 461


def test_bootstrap(written, installed):
    rec = _case(written, installed, "bootstrap_regress")
    assert rec["specification"]["resampling"] == {
        "method": "pairs_bootstrap",
        "reps": 50,
        "seed": 1,
        "ci_method": "normal",
        "statistic": "coefficient",
        "mse": False,
    }
    default, model = rec["structures"]["vcov"]
    assert default["type"] == "bootstrap" and default["default"] and default["df_t"] is None
    assert model["type"] == "iid" and not model["default"]  # e(V_modelbased), regress's own
    for p in rec["parameters"]:
        r = p["resampling"]
        assert r["std_error"] == pytest.approx(p["std_error"], rel=1e-12)
        assert set(r["intervals"]) == {"normal", "percentile", "bias_corrected"}
        assert r["reps"] == 50
    assert rec["metrics"]["n_reps_failed"] == 0
    assert _case(written, installed, "bootstrap_logit")["specification"]["resampling"]["reps"] == 30


def test_mi(written, installed):
    rec = _case(written, installed, "mi_regress")
    assert rec["specification"]["imputation"] == {
        "m": 5,
        "method": "regress",
        "imputed": ["rep78"],
        "style": "mlong",
    }
    assert rec["specification"]["options"]["df_method"] == "barnard_rubin"
    assert rec["specification"]["options"]["dfcom"] == 70
    vc = rec["structures"]["vcov"][0]
    assert vc["type"] == "iid" and vc["df_t"] is None and "Rubin" not in vc["ssc"]["convention"]
    for p in rec["parameters"]:
        assert {"ubar", "b", "riv", "fmi", "df", "relative_efficiency"} <= set(p["mi"])
    assert set(rec["metrics"]) == {"nobs", "conf_level"}
    assert "sample" not in rec["specification"] or set(rec["specification"]["sample"]) == {"restriction"}
    post = _case(written, installed, "mi_logit_post")
    assert post["specification"]["options"]["df_method"] == "rubin_1987"
    assert [m["code"] for m in post["meta"]["messages"]] == ["profile_not_claimed"]
    assert post["structures"]["vcov"][0]["type"] == "oim"
