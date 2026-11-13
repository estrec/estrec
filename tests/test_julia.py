"""EstRec.jl (julia/): records from FixedEffectModels.jl and GLM.jl fits validate, claim the
right profiles, carry a digest this package agrees with, and match the fits' own numbers.

The fits run on tests/data/writers_probe.csv, shared with the SAS and SPSS writers. Needs
Julia (on PATH, or $ESTREC_JULIA) and an environment with EstRec developed plus CSV,
DataFrames, FixedEffectModels, GLM and CategoricalArrays ($ESTREC_JULIA_PROJECT; its
depot in $JULIA_DEPOT_PATH as usual). Skipped otherwise.
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
JULIA = os.environ.get("ESTREC_JULIA") or shutil.which("julia")
PROJECT = os.environ.get("ESTREC_JULIA_PROJECT")

pytestmark = pytest.mark.skipif(
    not (JULIA and PROJECT), reason="needs Julia and $ESTREC_JULIA_PROJECT (EstRec + test packages)"
)

INF, FE, IV, GLM = "inference/0.1", "linear-fe/0.1", "iv/0.1", "glm/0.1"

# name -> (Julia fit expression, profiles, known warnings)
CASES = {
    "fe_cluster": ('reg(d, @formula(y ~ x1 + x2 + fe(id) + fe(year)), Vcov.cluster(:grp))', [INF, FE], []),
    "fe_twoway_cluster": ('reg(d, @formula(y ~ x1 + x2 + fe(id)), Vcov.cluster(:grp, :year))', [INF, FE], []),
    "ols_robust": ("reg(d, @formula(y ~ x1 + x2 + catc), Vcov.robust())", [INF], []),
    "ols_iid": ("reg(d, @formula(y ~ x1 + x2))", [INF], []),
    # FixedEffectModels reports Kleibergen-Paap but no first-stage F
    "iv": ("reg(d, @formula(y ~ x2 + (x1 ~ z) + fe(year)), Vcov.cluster(:grp))", [INF, FE, IV],
           ["expected a 'first_stage' test"]),
    "lm": ("lm(@formula(y ~ x1 + x2 + catc), d)", [INF], []),
    "logit": ("glm(@formula(ybin ~ x1 + x2), d, Binomial(), LogitLink())", [INF, GLM], []),
    "probit": ("glm(@formula(ybin ~ x1 + x2), d, Binomial(), ProbitLink())", [INF, GLM], []),
    "poisson": ("glm(@formula(cnt ~ x1 + x2 + catc), d, Poisson(), LogLink())", [INF, GLM], []),
}


@pytest.fixture(scope="module")
def records(tmp_path_factory):
    out = tmp_path_factory.mktemp("julia")
    lines = [
        "using EstRec, FixedEffectModels, GLM, DataFrames, CSV, CategoricalArrays",
        f'd = CSV.read({json.dumps(str(DATA))}, DataFrame)',
        "d.catc = categorical(d.cat)",
        "fits = Dict{String,Any}()",
    ]
    for name, (expr, _, _) in CASES.items():
        lines.append(f'm = {expr}')
        lines.append(f'write_estimation(m, {json.dumps(str(out / (name + ".estrec.json")))}; data = d)')
        # the fit's own estimates, in coefnames order, for the comparison
        lines.append(
            f'open({json.dumps(str(out / (name + ".coef.json")))}, "w") do io; '
            'print(io, "{\\"terms\\":[", join(["\\"" * t * "\\"" for t in coefnames(m)], ","), "],",'
            '"\\"coef\\":[", join(string.(coef(m)), ","), "],",'
            '"\\"se\\":[", join(string.(stderror(m)), ","), "]}"); end'
        )
    script = out / "fits.jl"
    script.write_text("\n".join(lines) + "\n")
    env = dict(os.environ, JULIA_PKG_OFFLINE="true")
    res = subprocess.run([JULIA, f"--project={PROJECT}", str(script)], capture_output=True, text=True, env=env, timeout=1800)
    assert res.returncode == 0, res.stderr[-3000:]
    return out


@pytest.mark.parametrize("name", CASES)
def test_record_validates(records, name):
    path = records / f"{name}.estrec.json"
    rec = json.loads(path.read_text())
    _, profiles, known = CASES[name]
    issues = ef.validate(rec)
    errors = [i for i in issues if i.level == "error"]
    warnings = [i for i in issues if i.level == "warning" and not any(k in i.message for k in known)]
    assert not errors, errors
    assert not warnings, warnings
    assert rec["meta"]["profiles"] == profiles
    assert ef.check_digest(rec) is True


@pytest.mark.parametrize("name", CASES)
def test_record_matches_the_fit(records, name):
    rec = json.loads((records / f"{name}.estrec.json").read_text())
    fit = json.loads((records / f"{name}.coef.json").read_text())
    params = {p["term"]: p for p in rec["parameters"]}
    for t, b, s in zip(fit["terms"], fit["coef"], fit["se"]):
        assert params[t]["estimate"] == pytest.approx(b, rel=1e-15, abs=1e-15)
        assert params[t]["std_error"] == pytest.approx(s, rel=1e-15, abs=1e-15)
    assert rec["structures"]["vcov"][0]["labels"] == fit["terms"]
    assert rec["metrics"]["nobs"] == 1997
    assert rec["specification"]["sample"]["dropped"]["missing"] == 3
