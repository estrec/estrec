"""estrec for SPSS (spss/): records built from SPSS OMS output validate, claim the right
profiles, carry a digest this package agrees with, and hold SPSS's numbers.

The fixtures in tests/data/spss/ are OMS OXML from spss/dev/probe.sps and probe2.sps, run in
SPSS 31 on tests/data/writers_probe.csv (the data file's path replaced). The R reference
values were checked against lm, glm and sandwich on the same data (2026-11-13): UNIANOVA's
HC1, GENLIN's robust covariance (HC0) and GEE's (cluster sandwich with no G/(G-1)).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

import estrec as ef

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "spss"))
import estrec_oxml  # noqa: E402
import estrec_procedures  # noqa: E402
import estrec_record  # noqa: E402

FIX = ROOT / "tests" / "data" / "spss"
INF, GLM, MIXED = "inference/0.1", "glm/0.1", "mixed/0.1"
HINTS = {"nobs": 1997, "levels": {"id": 100}, "spss_version": "31.0.0.0"}

# fixture -> (profiles, known warnings)
CASES = {
    "reg": ([INF], []),
    "regw": ([INF], []),
    "glm": ([INF], []),
    "glmhc": ([INF], []),
    "glmfe": ([INF], ["elements, above 10,000"]),          # 102 x 102 matrix, mostly null
    "logit": ([INF, GLM], []),
    "gllogit": ([INF, GLM], []),
    "gllogitr": ([INF, GLM], []),
    "glpois": ([INF, GLM], ["metrics.log_lik"]),           # GEE: QIC, no likelihood
    "mixed": ([INF, MIXED], []),
    "glmm2": ([INF, MIXED], ["metrics.log_lik"]),          # PQL: no likelihood printed
}


def build(name, **kw):
    recs, skipped = estrec_procedures.records(estrec_oxml.parse(FIX / f"{name}.xml"), HINTS, **kw)
    assert len(recs) == 1, skipped
    # round-trip through JSON as the file would be
    return json.loads(json.dumps(recs[0]))


def params(rec):
    return {p["canonical"]["name"]: p for p in rec["parameters"] if "canonical" in p and "dropped" not in p}


@pytest.mark.parametrize("name", CASES)
def test_record_validates(name):
    rec = build(name)
    profiles, known = CASES[name]
    issues = ef.validate(rec)
    assert not [i for i in issues if i.level == "error"], issues
    warnings = [i for i in issues if i.level == "warning" and not any(k in str(i) for k in known)]
    assert not warnings, warnings
    assert rec["meta"]["profiles"] == profiles
    assert ef.check_digest(rec) is True
    assert estrec_record.canonical_json(rec) == ef.canonical_json(rec)


def test_regression_matches_lm():
    rec = build("reg")
    p = params(rec)
    assert p["(Intercept)"]["estimate"] == pytest.approx(1.247322757327141, rel=1e-13)
    assert p["x1"]["std_error"] == pytest.approx(0.0275622076993369, rel=1e-12)
    m = rec["metrics"]
    assert m["nobs"] == 1997 and m["df_residual"] == 1994
    assert rec["specification"]["sample"]["dropped"] == {"missing": 3}
    v = rec["structures"]["vcov"][0]
    i = v["labels"].index("(Constant)")
    assert v["data"][i][i] == pytest.approx(p["(Intercept)"]["std_error"] ** 2)
    assert v["data"][i][v["labels"].index("x1")] is None      # BCOV has no constant
    assert "Users/" not in json.dumps(rec)                      # no data path by default
    assert build("reg", identifying=True)["provenance"]["data"][0]["path"].endswith("writers_probe.csv")


def test_weighted_regression():
    rec = build("regw")
    assert rec["specification"]["weights"] == {"variable": "w", "type": "analytic"}
    assert rec["meta"]["estimator"]["method"] == "wls"


def test_unianova_reference_level_and_hc1():
    rec = build("glmhc")
    ref = [r for r in rec["parameters"] if r.get("dropped") == "reference"]
    assert [r["term"] for r in ref] == ["[cat=3]"]
    v = rec["structures"]["vcov"]
    assert v[0]["type"] == "HC1" and v[0]["default"] and v[1]["type"] == "iid" and not v[1]["default"]
    p = params(rec)
    assert p["cat1"]["term"] == "[cat=1]" and p["cat1"]["canonical"]["factors"] == [{"variable": "cat", "level": "1"}]
    assert rec["metrics"]["r2"] == pytest.approx(1805.6239195571 / 6239.7770524597, rel=1e-12)


def test_logistic_positional_levels_and_covariance():
    rec = build("logit")
    p = params(rec)
    # cat(1), cat(2) with Indicator(1): levels 2 and 3
    assert p["cat2"]["term"] == "cat(1)" and p["cat3"]["term"] == "cat(2)"
    assert p["x1"]["estimate"] == pytest.approx(0.775332153883860, rel=1e-7)   # R glm
    assert p["x1"]["statistic"] == pytest.approx(p["x1"]["estimate"] / p["x1"]["std_error"])
    v = rec["structures"]["vcov"][0]
    assert all(x is not None for row in v["data"] for x in row)               # from CORR
    assert rec["specification"]["options"]["response_level"] == "1"
    assert rec["metrics"]["log_lik"] == pytest.approx(-2321.2840082376 / 2)
    assert [t["name"] for t in rec["tests"]] == ["likelihood_ratio", "wald"]


def test_genlin_covariance_types():
    assert build("gllogit")["structures"]["vcov"][0]["type"] == "iid"
    assert build("gllogitr")["structures"]["vcov"][0]["type"] == "HC0"
    rec = build("glpois")
    v = rec["structures"]["vcov"][0]
    assert v["type"] == "CRV0" and v["cluster"] == ["grp"] and v["n_clusters"] == {"grp": 20}
    assert rec["meta"]["estimator"]["method"] == "gee"


def test_mixed():
    rec = build("mixed")
    assert rec["meta"]["estimator"] == {"family": "mixed", "method": "reml"}
    assert rec["specification"]["options"]["df_method"] == "satterthwaite"
    p = params(rec)
    assert p["x1"]["df"] == pytest.approx(1931.8370286149)
    vc = [r for r in rec["parameters"] if r.get("component") == "random"]
    assert {r["vc"]["group"] for r in vc} == {"id", "Residual"}
    assert rec["structures"]["random_effects"][0]["levels"] == 100
    assert rec["metrics"]["nobs"] == 1997


def test_genlinmixed_does_not_record_raw_data():
    rec = build("glmm2")
    assert rec["structures"]["random_effects"][0] == {"kind": "object", "group": "id", "levels": 100,
                                                      "terms": ["(Intercept)"]}
    assert "First Subject" not in json.dumps(rec)
    assert any(m["code"] == "response_level" for m in rec["meta"]["messages"])


def test_numbered_files():
    assert estrec_record.numbered("a/fit.estrec.json", 2) == ["a/fit-1.estrec.json", "a/fit-2.estrec.json"]
    assert estrec_record.numbered("fit.estrec.json", 1) == ["fit.estrec.json"]


def test_committed_bundle_is_current():
    """spss/estrec.spe (what the front page links to) holds the current files: rebuild with
    `python spss/build_bundle.py` and commit it after changing anything in spss/."""
    import zipfile
    with zipfile.ZipFile(ROOT / "spss" / "estrec.spe") as z:
        names = set(z.namelist())
        assert {"META-INF/MANIFEST.MF", "ESTREC_BEGIN.xml", "ESTREC_END.py", "estrec_procedures.py"} <= names
        for n in names - {"META-INF/MANIFEST.MF"}:
            assert z.read(n) == (ROOT / "spss" / n).read_bytes(), f"{n} is out of date in estrec.spe"
        assert b"Plugins:" not in z.read("META-INF/MANIFEST.MF")


def test_last_in_journal():
    """ESTREC WRITE finds the last supported command in the SPSS journal: multi-line commands,
    other commands after it, and a comment missing its closing period."""
    import estrec_session
    j = ("GET DATA /TYPE=TXT /FILE=csv.\n"
         "* a comment without its period\n"
         "REGRESSION /STATISTICS COEFF OUTS CI(95) R ANOVA BCOV\n"
         "  /DEPENDENT y /METHOD=ENTER x1 x2.\n"
         "ESTREC WRITE OUTFILE='out/f.json'.\n"
         "LOGISTIC REGRESSION VARIABLES ybin /METHOD=ENTER x1 x2.\n"
         "DESCRIPTIVES VARIABLES=y.\n"
         "ESTREC WRITE OUTFILE='out/g.json'.\n")
    assert estrec_session.last_in_journal(j) == (
        "Logistic Regression", "LOGISTIC REGRESSION VARIABLES ybin /METHOD=ENTER x1 x2.")
    assert estrec_session.last_in_journal(j.split("LOGISTIC")[0]) == (
        "Regression", "REGRESSION /STATISTICS COEFF OUTS CI(95) R ANOVA BCOV\n  /DEPENDENT y /METHOD=ENTER x1 x2.")
    assert estrec_session.last_in_journal("LOGISTIC VARIABLES=y.\nDESCRIPTIVES y.\n") == (None, None)
