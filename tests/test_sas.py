"""estrec for SAS (sas/estrec.sas): %estrec_begin / %estrec_end write a valid record per
supported procedure, with a digest this package agrees with and SAS's own numbers.

Runs SAS in batch on tests/data/writers_probe.csv. Needs SAS ($ESTREC_SAS, or `sas` on
PATH); skipped otherwise. The record's core digest needs SAS to find OpenSSL (on Linux, set
LD_LIBRARY_PATH to the system library folder, e.g. /usr/lib/x86_64-linux-gnu).

The estimates were checked against R on the same data (2026-11-13): REG (iid and HC1), GLM
and SURVEYREG (cluster: CRV1) to ~1e-13; GENMOD logit to 1e-6 and GEE (cluster sandwich
without G/(G-1)) to 4e-6; LOGISTIC to 1e-4 (its default GCONV=1e-8 stops earlier than glm).
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

import estrec as ef

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "tests" / "data" / "writers_probe.csv"
SAS = os.environ.get("ESTREC_SAS") or shutil.which("sas")

pytestmark = pytest.mark.skipif(not SAS, reason="needs SAS ($ESTREC_SAS or sas on PATH)")

INF, GLM, MIX = "inference/0.1", "glm/0.1", "mixed/0.1"

# (procedure step, profiles, vcov type, known warnings)
CASES = [
    ("proc reg data=probe plots=none; model y = x1 x2 / covb hcc hccmethod=1 acov; run; quit;", [INF], "iid", []),
    ("proc glm data=probe plots=none; class cat; model y = cat x1 x2 / solution; run; quit;", [INF], "iid", []),
    ("proc surveyreg data=probe; cluster grp; class cat; model y = cat x1 x2 / solution covb; run;", [INF], "CRV1", []),
    ("proc surveyreg data=probe; strata stratum; cluster psu; weight w; model y = x1 x2 / solution covb; run;", [INF], "taylor", []),
    ("proc logistic data=probe; class cat / param=ref ref=first; model ybin(event='1') = cat x1 x2 / covb; run;", [INF, GLM], "iid", []),
    ("proc surveylogistic data=probe; strata stratum; cluster psu; weight w; model ybin(event='1') = x1 x2 / covb; run;", [INF, GLM], "taylor", []),
    ("proc genmod data=probe; class cat / param=ref ref=first; model ybin(event='1') = cat x1 x2 / dist=binomial link=logit covb; run;", [INF, GLM], "iid", []),
    ("proc genmod data=probe; model cnt = x1 x2 / dist=poisson link=log; run;", [INF, GLM], "iid", []),
    # GEE reports QIC, not a likelihood
    ("proc genmod data=probe; class grp; model cnt = x1 x2 / dist=poisson link=log; repeated subject=grp / type=ind covb; run;", [INF, GLM], "CRV0", ["metrics.log_lik"]),
    # no COVTEST: variance components without standard errors, so mixed/0.1 only
    ("proc mixed data=probe method=reml; class id cat; model y = cat x1 x2 / solution covb ddfm=kr; random intercept / subject=id; run;", [MIX], "iid", []),
    ("proc mixed data=probe method=reml covtest; class id cat; model y = cat x1 x2 / solution covb; random intercept / subject=id; run;", [INF, MIX], "iid", []),
    ("proc glimmix data=probe method=laplace; class id; model ybin(event='1') = x1 x2 / dist=binary link=logit solution covb; random intercept / subject=id; run;", [INF, MIX], "iid", []),
    ("proc panel data=probe; id id year; model y = x1 x2 / fixtwo; run;", [INF], "iid", []),
    ("proc panel data=probe; id id year; model y = x1 x2 / ranone; run;", [INF], "iid", []),
    ("proc syslin data=probe 2sls; endogenous x1; instruments z x2; model y = x1 x2; run;", [INF], "iid", []),
]


@pytest.fixture(scope="module")
def records(tmp_path_factory):
    out = tmp_path_factory.mktemp("sas")
    work = out / "work"
    work.mkdir()
    steps = "\n".join(c[0] for c in CASES)
    prog = out / "run.sas"
    prog.write_text(f"""%include "{ROOT / 'sas' / 'estrec.sas'}";
data probe; infile "{DATA}" dsd firstobs=2 truncover;
  input id year grp stratum psu cat x1 x2 z w y ybin cnt; run;
proc sort data=probe; by id year; run;
%estrec_begin;
{steps}
proc means data=probe; var y; run;
%estrec_end(out={out / 'fit.estrec.json'});
""")
    env = dict(os.environ)
    env.setdefault("LD_LIBRARY_PATH", "/usr/lib/x86_64-linux-gnu")
    res = subprocess.run([SAS, "-nodms", "-work", str(work), "-memsize", "2G", "-cpucount", "2",
                          "-log", str(out / "run.log"), "-print", str(out / "run.lst"), str(prog)],
                         env=env, capture_output=True, text=True, timeout=1200)
    log = (out / "run.log").read_text(errors="replace")
    errors = [l for l in log.splitlines() if l.startswith("ERROR")]
    assert not errors, "\n".join(errors[:20])
    assert "no record for PROC MEANS (not supported yet)" in log
    return out, log


@pytest.mark.parametrize("i", range(len(CASES)))
def test_record(records, i):
    out, log = records
    rec = json.loads((out / f"fit-{i + 1}.estrec.json").read_text())
    _, profiles, vtype, known = CASES[i]
    issues = ef.validate(rec)
    assert not [x for x in issues if x.level == "error"], issues
    assert not [x for x in issues if x.level == "warning" and not any(k in str(x) for k in known)], issues
    assert rec["meta"]["profiles"] == profiles
    assert rec["structures"]["vcov"][0]["type"] == vtype
    assert rec["meta"]["id"][14] == "4"                      # a version 4 UUID
    if "no core digest" not in log:
        assert ef.check_digest(rec) is True


def test_numbers(records):
    out, _ = records
    reg = json.loads((out / "fit-1.estrec.json").read_text())
    p = {x["canonical"]["name"]: x for x in reg["parameters"]}
    assert p["(Intercept)"]["estimate"] == pytest.approx(1.247322757327141, rel=1e-13)   # R lm
    assert p["x1"]["std_error"] == pytest.approx(0.0275622076993369, rel=1e-12)
    assert reg["metrics"]["r2"] == pytest.approx(0.2837011192575, rel=1e-12)          # not 10 digits
    hc = reg["structures"]["vcov"][1]
    assert hc["type"] == "HC1" and all(v is not None for row in hc["data"] for v in row)
    assert reg["specification"]["sample"] == {"restriction": None, "rows_input": 2000, "dropped": {"missing": 3}}
    glm = json.loads((out / "fit-2.estrec.json").read_text())
    ref = [x for x in glm["parameters"] if x.get("dropped")]
    assert [x["term"] for x in ref] == ["cat 3"]
    assert all(v is None for v in glm["structures"]["vcov"][0]["data"][0][1:])     # GLM prints no CovB
    sreg = json.loads((out / "fit-3.estrec.json").read_text())
    names = [x["canonical"]["name"] for x in sreg["parameters"] if not x.get("dropped")]
    assert names == ["(Intercept)", "cat1", "cat2", "x1", "x2"]
    assert len(sreg["structures"]["vcov"][0]["data"]) == 5                          # reference row dropped
    slog = json.loads((out / "fit-6.estrec.json").read_text())
    assert slog["specification"]["weights"] == {"variable": "w", "type": "sampling"}
    assert slog["specification"]["clusters"] == ["psu"]
    gee = json.loads((out / "fit-9.estrec.json").read_text())
    v = gee["structures"]["vcov"][0]
    assert v["cluster"] == ["grp"] and v["n_clusters_min"] == 20 and gee["meta"]["estimator"]["method"] == "gee"


def test_mixed_panel_syslin(records):
    out, _ = records
    mixed = json.loads((out / "fit-11.estrec.json").read_text())
    p = {x["canonical"]["name"]: x for x in mixed["parameters"] if "canonical" in x and not x.get("dropped")}
    assert p["x1"]["std_error"] == pytest.approx(0.022530760605352, rel=1e-5)   # SPSS MIXED, same model
    vc = {x["vc"]["group"]: x["estimate"] for x in mixed["parameters"] if x.get("component") == "random"}
    assert vc["id"] == pytest.approx(0.970729, rel=1e-4) and vc["Residual"] == pytest.approx(1.327431, rel=1e-4)
    assert mixed["structures"]["random_effects"][0] == {"kind": "object", "group": "id", "levels": 100,
                                                       "terms": ["(Intercept)"]}
    kr = json.loads((out / "fit-10.estrec.json").read_text())
    assert kr["specification"]["options"]["df_method"] == "kenward_roger"
    assert any(m["code"] == "vc_no_se" for m in kr["meta"]["messages"])
    fe = json.loads((out / "fit-13.estrec.json").read_text())
    assert [f["levels"] for f in fe["structures"]["fixed_effects"]] == [100, 20]
    assert {x["term"]: x["estimate"] for x in fe["parameters"]}["x1"] == pytest.approx(0.5476586219312, rel=1e-12)  # fixest
    iv = json.loads((out / "fit-15.estrec.json").read_text())
    assert iv["meta"]["estimator"]["method"] == "2sls"
    assert {x["term"]: x["estimate"] for x in iv["parameters"]}["x1"] == pytest.approx(0.46541595892874, rel=1e-12)


def test_numbers_text_is_canonical(records):
    """Numbers are written as RFC 8785 text (<= 15 significant digits), so reading and
    re-serialising them gives the same text: the digest SAS computed holds."""
    out, _ = records
    for f in sorted(out.glob("fit-*.estrec.json")):
        rec = json.loads(f.read_text())
        for p in rec["parameters"]:
            for k in ("estimate", "std_error"):
                if isinstance(p.get(k), float):
                    assert len(repr(abs(p[k])).replace(".", "").split("e")[0].strip("0")) <= 15
