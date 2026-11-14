"""Records of PROCESS (Hayes) runs, read by spss/estrec_process.py.

PROCESS isn't distributed with estrec (its license forbids redistribution): get it from
https://www.afhayes.com/download.html and point the tests at it.

- ESTREC_PROCESS_DIR: the unzipped PROCESS folder (holding "PROCESS v5.1 for R/process.r" and
  "PROCESS v5.1  for SAS/process.sas", or the files themselves). The R tests run PROCESS for R
  (Rscript) on tests/data/writers_probe.csv and read its printed output; the SAS tests run
  PROCESS for SAS when $ESTREC_SAS (or `sas`) is there too.
- ESTREC_PROCESS_SPSS_OUT: folders of OXML files written by spss/dev/probe_process.sps in SPSS,
  separated by os.pathsep (one per PROCESS version, e.g. 5.0 and 5.1.1). Each is tested, and with
  two or more test_spss_versions_agree compares their records.

Each test is skipped when what it needs isn't there. Checked 2026-11-14 with PROCESS 5.1.1 for R
and SAS (valiant) and PROCESS 5.0 and 5.1.1 for SPSS 32 (Ted's Mac; the same probes under each). 5.1 changed the Model Summary
(MSE and the F's df moved to an SS/df/MS table): TEXT_51 below has that layout, made-up numbers.
"""

from __future__ import annotations

import csv
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

import estrec as ef

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "spss"))
import estrec_oxml  # noqa: E402
import estrec_procedures  # noqa: E402
import estrec_process as PR  # noqa: E402

DATA = ROOT / "tests" / "data" / "writers_probe.csv"
PDIR = os.environ.get("ESTREC_PROCESS_DIR")
SPSS_OUT = [d for d in os.environ.get("ESTREC_PROCESS_SPSS_OUT", "").split(os.pathsep) if d]
SAS = os.environ.get("ESTREC_SAS") or shutil.which("sas")


def _find(name):
    if not PDIR:
        return None
    hits = sorted(Path(PDIR).rglob(name))
    return hits[0] if hits else None


PROCESS_R = _find("process.r") or _find("process.R")
PROCESS_SAS = _find("process.sas")

# name: (PROCESS options, mediators?, effects expected (effect, mediator or path))
MODELS = {
    "m4": ('y="y", x="x1", m="x2", model=4, seed=20261114', [("indirect", "x2")]),
    "m4cov": ('y="y", x="x1", m="x2", cov="w", model=4, total=1, normal=1, boot=1000, seed=20261114',
              [("total", None), ("indirect", "x2")]),
    "m4par": ('y="y", x="x1", m=c("x2","z"), model=4, contrast=1, hc=3, seed=20261114',
              [("total_indirect", None), ("indirect", "x2"), ("indirect", "z"), ("contrast", None)]),
    "m6": ('y="y", x="x1", m=c("x2","z"), model=6, seed=20261114',
           [("indirect", "x2"), ("indirect", "z"), ("indirect", ["x1", "x2", "z", "y"])]),
    "m7": ('y="y", x="x1", m="x2", w="z", model=7, seed=20261114',
           [("indirect", "x2"), ("index_moderated_mediation", "x2")]),
    "m4bin": ('y="ybin", x="x1", m="x2", model=4, seed=20261114', [("indirect", "x2")]),
    "m1": ('y="y", x="x1", w="z", model=1, jn=1, center=1', []),
}

# R lm on the same data (the y equation of model 4: y ~ x1 + x2), as in tests/test_spss.py
LM_Y = {"(Intercept)": 1.247322757327141, "x1": 0.745224488120075, "x2": -0.282246654116707}


def _record_from_text(text, name):
    info = PR.interpret(PR.sections_from_text(text))
    cmd = SimpleNamespace(name="PROCESS", text=f"PROCESS {name}", tables=[], texts=[text])
    return PR.build(info, cmd, {}, {}, precision=4), info


def _check(rec, expected):
    issues = ef.validate(rec)
    assert not [x for x in issues if x.level == "error"], issues
    assert ef.check_digest(rec) is True
    got = [(p["mediation"]["effect"], p["mediation"].get("mediator") or p["mediation"].get("path"))
           for p in rec["parameters"] if "mediation" in p]
    for e in expected:
        assert e in got, (e, got)
    if expected:
        assert rec["meta"]["profiles"] == ["mediation/0.1"]


# ---------------------------------------------------------------- R


@pytest.fixture(scope="module")
def r_runs(tmp_path_factory):
    if not (PROCESS_R and shutil.which("Rscript")):
        pytest.skip("needs PROCESS for R ($ESTREC_PROCESS_DIR) and Rscript")
    out = tmp_path_factory.mktemp("process_r")
    lines = [f'invisible(capture.output(source("{PROCESS_R}")))',
             f'd <- read.csv("{DATA}")']
    for name, (opts, _) in MODELS.items():
        lines += [f'txt <- capture.output(res <- process(data=d, {opts}, save=2, progress=0))',
                  f'writeLines(txt, "{out}/{name}.txt")',
                  f'write.csv(as.data.frame(res), "{out}/{name}_save.csv", row.names=FALSE)']
    (out / "run.R").write_text("\n".join(lines))
    subprocess.run(["Rscript", "--vanilla", str(out / "run.R")], check=True, capture_output=True,
                   text=True, timeout=1800)
    return out


@pytest.mark.parametrize("name", list(MODELS))
def test_r_text(r_runs, name):
    rec, info = _record_from_text((r_runs / f"{name}.txt").read_text(), name)
    _check(rec, MODELS[name][1])
    assert info["header"]["platform"] == "R"
    assert rec["metrics"]["nobs"] == (2000 if name == "m1" else 1997)
    assert not info["skipped"] or name == "m4cov"         # m4cov: the standardized effects


def test_r_text_matches_save2(r_runs):
    """The printed numbers (4 decimals) agree with save=2's full-precision matrix row by row."""
    rec, info = _record_from_text((r_runs / "m4.txt").read_text(), "m4")
    rows = [[float(v) if v not in ("", "NA") else None for v in r]
            for r in list(csv.reader(open(r_runs / "m4_save.csv")))[1:]]
    coefs = [r for r in rows if r[6] is None and all(v is not None for v in r[:6])]  # coeff, se, t, p, LLCI, ULCI
    y = {p["term"]: p["estimate"] for p in info["equations"] if p["response"] == "y"}
    for term, b in LM_Y.items():
        assert y[term] == pytest.approx(b, abs=5e-5)
        assert any(abs(r[0] - b) < 1e-12 for r in coefs)


# ---------------------------------------------------------------- SAS


@pytest.fixture(scope="module")
def sas_runs(tmp_path_factory):
    if not (PROCESS_SAS and SAS):
        pytest.skip("needs PROCESS for SAS ($ESTREC_PROCESS_DIR) and SAS")
    out = tmp_path_factory.mktemp("process_sas")
    (out / "work").mkdir()
    sas_opts = {
        "m4": "y=y, x=x1, m=x2, model=4, seed=20261114",
        "m6": "y=y, x=x1, m=x2 z, model=6, seed=20261114",
        "m7": "y=y, x=x1, m=x2, w=z, model=7, seed=20261114",
        "m1": "y=y, x=x1, w=z, model=1, jn=1, center=1",
    }
    prog = [f'options nonotes; %include "{PROCESS_SAS}"; options notes;',
            f'data probe; infile "{DATA}" dsd firstobs=2 truncover;',
            "  input id year grp stratum psu cat x1 x2 z w y ybin cnt; run;", "ods listing close;"]
    for name, opts in sas_opts.items():
        prog += [f'ods listing file="{out}/{name}.lst";', f"%process(data=probe, {opts});", "ods listing close;"]
    (out / "run.sas").write_text("\n".join(prog))
    env = dict(os.environ)
    subprocess.run([SAS, "-nodms", "-work", str(out / "work"), "-log", str(out / "run.log"),
                    "-print", str(out / "run.lst"), str(out / "run.sas")], env=env, timeout=1800)
    return out, list(sas_opts)


def test_sas_text(sas_runs):
    out, names = sas_runs
    for name in names:
        rec, info = _record_from_text((out / f"{name}.lst").read_text(errors="replace"), name)
        exp = [(e, (m.upper() if isinstance(m, str) else [x.upper() for x in m]) if m else m)
               for e, m in MODELS[name][1]]
        _check(rec, exp)
        assert info["header"]["platform"] == "SAS"


# ---------------------------------------------------------------- SPSS


def _spss(name, folder=None):
    folder = folder or (SPSS_OUT[0] if SPSS_OUT else None)
    if not folder or not (Path(folder) / f"{name}.xml").exists():
        pytest.skip("needs $ESTREC_PROCESS_SPSS_OUT (outputs of spss/dev/probe_process.sps)")
    cmds = estrec_oxml.parse(str(Path(folder) / f"{name}.xml"))
    recs, skipped = estrec_procedures.records(cmds, {"spss_version": "32.0"})
    assert len(recs) == 1, skipped
    return recs[0]


SPSS_PROBES = ["p_m4", "p_m4cov", "p_m4par", "p_m6", "p_m7", "p_m14", "p_m4bin", "p_m4mcx", "p_m1",
               "t_m4cov", "t_m7", "t_m1"]


@pytest.mark.parametrize("folder", range(max(1, len(SPSS_OUT))))
@pytest.mark.parametrize("name", SPSS_PROBES)
def test_spss(name, folder):
    rec = _spss(name, SPSS_OUT[folder] if SPSS_OUT else None)
    key = name.split("_", 1)[1]
    _check(rec, MODELS.get(key, (None, []))[1] if key != "m6" else
           [("indirect", ["x1", "x2", "z", "y"])])
    codes = [m["code"] for m in rec["meta"].get("messages", [])]
    assert ("printed_precision" in codes) == name.startswith("p_")
    for p in rec["parameters"]:
        if p["term"].startswith("Int_"):      # PROCESS's product terms are interactions
            assert len(p["canonical"]["factors"]) >= 2, p
    assert rec["provenance"]["software"][1]["name"] == "PROCESS"
    eqs = rec["structures"]["equations"]["per_response"]
    assert [e["response"] for e in eqs if "component" not in e] == rec["meta"]["responses"]
    for e in eqs:
        assert ("pseudo_r2" in e) == (e["response"] == "ybin") and ("r2" in e) != ("pseudo_r2" in e)


@pytest.mark.parametrize("folder", range(max(1, len(SPSS_OUT))))
def test_spss_tables_full_precision(folder):
    """display=tables: the y equation matches R lm to 1e-12 (the text gives 4 decimals)."""
    rec = _spss("t_m7", SPSS_OUT[folder] if SPSS_OUT else None)
    y = {p["term"]: p["estimate"] for p in rec["parameters"] if p.get("response") == "y" and "mediation" not in p}
    for term, b in LM_Y.items():
        assert y[term] == pytest.approx(b, rel=1e-12)
    y_fit = next(e for e in rec["structures"]["equations"]["per_response"] if e["response"] == "y")
    assert y_fit["r2"] == pytest.approx(0.283701119257509, rel=1e-12)    # summary(lm)$r.squared
    assert y_fit["mse"] == pytest.approx(2.24149715083227, rel=1e-12)    # sigma^2
    assert rec["specification"]["mediation"]["inference"] == {
        "method": "bootstrap", "reps": 5000, "ci_type": "percentile", "seed": 20261114}


# PROCESS 5.1's layout (made-up numbers): the Model Summary has Adj R-sq, SEest and PRE but no MSE
# or df; those are in the SS/df/MS table under it.
TEXT_51 = """
Model  : 4
    Y  : y
    X  : x1
    M  : x2

Sample
Size:  500

**************************************************************************
OUTCOME VARIABLE:
 x2

Model Summary
          R       R-sq   Adj R-sq          F          p      SEest        PRE
      .1000      .0100      .0080     5.0400      .0252     1.0000      .0101

                SS          df          MS
Regress     5.0000      1.0000      5.0000
Residual  498.0000    498.0000      1.0000
Total     503.0000    499.0000      1.0080

Model
              coeff         se          t          p       LLCI       ULCI
constant      .0500      .0450     1.1111      .2671     -.0384      .1384
x1            .1000      .0445     2.2450      .0252      .0125      .1875
"""


def test_process51_anova_table():
    info = PR.interpret(PR.sections_from_text(TEXT_51))
    assert info["fits"] == [{"response": "x2", "r2": 0.01, "adj_r2": 0.008, "mse": 1.0, "df_residual": 498.0}]
    t = info["tests"][0]
    assert (t["name"], t["statistic"], t["df"], t["df2"]) == ("f", 5.04, 1.0, 498.0)


@pytest.mark.parametrize("version, warned", [("5.0", False), ("5.1.1", False), ("5.2", True)])
def test_version_warning(version, warned):
    text = f"**************** PROCESS Procedure for SPSS Version {version} ****************\n" + TEXT_51
    rec, info = _record_from_text(text, "m4")
    assert info["header"]["version"] == version
    codes = [m["code"] for m in rec["meta"].get("messages", [])]
    assert ("process_version_unchecked" in codes) == warned


def _flat(x, p=""):
    if isinstance(x, dict):
        for k, v in x.items():
            yield from _flat(v, f"{p}.{k}" if p else k)
    elif isinstance(x, list):
        for i, v in enumerate(x):
            yield from _flat(v, f"{p}[{i}]")
    else:
        yield p, x


@pytest.mark.parametrize("name", SPSS_PROBES)
def test_spss_versions_agree(name):
    """The same model under two PROCESS versions gives the same record, apart from what the
    versions themselves print differently: 5.1 adds Adj R-sq, and its bootstrap draws differ
    from 5.0's under the same seed (bootstrap SEs and intervals of the effects)."""
    if len(SPSS_OUT) < 2:
        pytest.skip("needs two folders in $ESTREC_PROCESS_SPSS_OUT (two PROCESS versions)")
    recs = [_spss(name, d) for d in SPSS_OUT]
    boot = {i for i, p in enumerate(recs[0]["parameters"]) if "p_value" not in p}  # bootstrap rows
    flats = [dict(_flat(r)) for r in recs]
    for f in flats[1:]:
        for k in sorted(set(flats[0]) | set(f)):
            if k.startswith(("meta.id", "meta.created", "meta.core_digest", "history",
                             "provenance.software[1].version")) or k.endswith(".adj_r2"):
                continue
            m = re.match(r"parameters\[(\d+)\]\.(std_error|conf_low|conf_high)$", k)
            if m and int(m[1]) in boot:
                continue
            a, b = flats[0].get(k, "<absent>"), f.get(k, "<absent>")
            if isinstance(a, float) and isinstance(b, float):
                assert a == pytest.approx(b, rel=1e-9, abs=1e-12), k
            else:
                assert a == b, k


def test_matrix_that_isnt_process():
    cmd = estrec_oxml.Command("Matrix", "Matrix", texts=["Run MATRIX procedure:\nA\n 1 2\n------ END MATRIX -----"])
    recs, skipped = estrec_procedures.records([cmd])
    assert not recs and "isn't PROCESS" in skipped[0]
