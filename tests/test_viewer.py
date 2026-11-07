"""The browser viewer (viewer/): its examples are current, and when node is installed, its
table logic (viewer/estrec-table.js) builds the same tables as the Python reference."""

import copy
import importlib.util
import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

import estrec as ef
from estrec import records as est
from estrec import table as et
from estrec import views

ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = ROOT / "schema" / "examples"
NODE = shutil.which("node")


def _make():
    spec = importlib.util.spec_from_file_location("make_examples", ROOT / "viewer" / "make_examples.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_examples_js_is_current():
    assert (ROOT / "viewer" / "examples.js").read_text(encoding="utf-8") == _make().content(), (
        "run: python viewer/make_examples.py"
    )


def test_identifying_js_is_current():
    mod = _make()
    assert (ROOT / "viewer" / "identifying.js").read_text(encoding="utf-8") == mod.identifying_js(), (
        "run: python viewer/make_examples.py"
    )
    paths = mod.identifying()
    assert set(est.DEFAULT_IDENTIFYING) <= set(paths)  # the schemas mark at least the fallback list
    assert not any(p.split(".")[0] in est.CORE for p in paths)


def identified_record():
    rec = ef.read(EXAMPLES / "lm-minimal.estrec.json")
    rec["provenance"] = {
        "agent": {"user": "ted", "host": "valiant"},
        "environment": {"os": "Linux", "host": "valiant"},
        "execution": {
            "invocation": {"argv": ["Rscript", "/home/ted/fit.R"], "working_directory": "/home/ted"}
        },
        "data": [{"name": "d", "location": "/home/ted/d.csv"}, {"name": "e"}],
    }
    return rec


def run_node(script, payload):
    run = subprocess.run(
        [NODE, "-e", script, str(ROOT / "viewer")],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        check=False,
    )
    assert run.returncode == 0, run.stderr
    return json.loads(run.stdout)


def test_redaction_matches_python():
    if NODE is None:
        pytest.skip("node not installed")
    rec = identified_record()
    paths = _make().identifying()
    script = (
        "const E=require(process.argv[1]+'/estrec-table.js');const P=require(process.argv[1]+'/identifying.js');"
        "const r=JSON.parse(require('fs').readFileSync(0,'utf8'));process.stdout.write(JSON.stringify(E.redactRecord(r,P)))"
    )
    js = run_node(script, rec)
    py = est.redact(rec, paths=paths)
    assert js["removed"] == py["history"][-1]["fields"]
    for d in (js["record"], py):
        d["history"][-1].pop("when")
        d["history"][-1].pop("by")
    assert js["record"] == py
    assert js["record"]["provenance"]["environment"] == {"os": "Linux"}


def test_web_page():
    if NODE is None:
        pytest.skip("node not installed")
    t = et.build_table(specs()[0], base_dir=EXAMPLES)
    recs = {}
    coll = ef.read_collection(EXAMPLES / "paper.estrec-collection.json")
    recs = [r for _, _, r in ef.iter_members(coll)]
    script = (
        "const E=require(process.argv[1]+'/estrec-table.js');const x=JSON.parse(require('fs').readFileSync(0,'utf8'));"
        "process.stdout.write(JSON.stringify(E.renderWebPage(x.t,x.recs)))"
    )
    page = run_node(script, {"t": t, "recs": recs})
    assert page.startswith("<!doctype html>") and page.count('class="col"') == 3
    m = re.search(r'<script type="application/json" id="estrec-records">(.*?)</script>', page, re.DOTALL)
    data = json.loads(m.group(1))
    assert data["columns"] == t["column_records"]
    assert {r["meta"]["id"] for r in data["records"]} == set(t["column_records"])
    assert "</" not in m.group(1)  # the embedded JSON can't close its script element
    inner = re.search(r"<script>\n(.*?)</script>", page, re.DOTALL).group(1)
    check = subprocess.run([NODE, "--check", "-"], input=inner, capture_output=True, text=True, check=False)
    assert check.returncode == 0, check.stderr
    # the table itself is the HTML renderer's, with the headings as buttons
    assert "-3.206***" in page and "<caption>Table 2: Fuel economy and weight</caption>" in page


def test_column_records_match(node_result):
    _req, out = node_result
    for spec, js in zip(specs(), out["tables"]):
        assert js["column_records"] == et.build_table(spec, base_dir=EXAMPLES)["column_records"]


FILES = {
    "paper.estrec-collection.json": "paper",
    "session.estrec-collection.json": "session",
    "replication.estrec-collection.json": "replication",
    "replication.members.jsonl": None,
    "csdid.estrec.json": "csdid",
}


def specs():
    base = et.read_table(EXAMPLES / "paper.estrec-table.json")
    out = [base]
    for unc in ("statistic", "p_value", "conf_int", None):
        s = copy.deepcopy(base)
        s["uncertainty"] = unc
        out.append(s)
    s = copy.deepcopy(base)
    s.update(
        stars=[0.05, 0.01, 0.001],
        format={"digits": 2, "thousands": " ", "fe_yes": "X", "star_symbols": ["+", "*", "**"]},
    )
    s["drop"] = []
    s["rows"] = [{"terms": ["hp", "wt"], "label": "hp or wt"}]
    out.append(s)
    for unc, f in [
        (["std_error", "[{p_value}]"], {"p_style": "less_than"}),
        (["({std_error})", "p = {p_value}", "[{conf_low}, {conf_high}]"], {"digits": 2, "p_digits": 4}),
        ("t = {statistic}", {"p_digits": 2, "p_style": "less_than"}),
    ]:
        s = copy.deepcopy(base)
        s["uncertainty"] = unc
        s["format"] = f
        out.append(s)
    coll = ef.read_collection(EXAMPLES / "session.estrec-collection.json")
    s = et.new_table(coll, stats=["nobs", "r2", "r2_within", {"vcov": "type"}, {"vcov": "n_clusters"}])
    s["columns"].append(dict(s["columns"][0], header="iid", vcov="iid"))
    s["columns"].append(dict(s["columns"][1], header="pos", vcov=1))
    for c in s["columns"]:
        c["source"] = "session"
    s["sources"] = [{"id": "session", "path": "session.estrec-collection.json"}]
    out.append(s)
    s = copy.deepcopy(s)
    s["keep"] = ["^x1$"]
    s["uncertainty"] = "conf_int"
    out.append(s)
    for head in (["label", "number", "response"], ["number", "label"], ["response"], []):
        s = copy.deepcopy(base)
        s["head"] = head
        s["response_labels"] = {"mpg": "Miles per gallon"}
        s["columns"][1]["header"] = "with hp"
        out.append(s)
    for unc in (
        ["std_error", {"sparkline": {}}],
        [{"sparkline": {"color": "#c0392b", "scale": "row"}}, "[{p_value}]"],
        {"sparkline": {"scale": "table", "color": "#0A7F3F"}},
        ["std_error", {"sparkline": {"place": "beside"}}],
        [{"sparkline": {"place": "beside", "color": "#c0392b"}}, "[{p_value}]"],
    ):
        s = copy.deepcopy(base)
        s["uncertainty"] = unc
        out.append(s)
    s = copy.deepcopy(base)
    s.update(uncertainty={"sparkline": {"scale": "table"}}, estimate=False)
    out.append(s)
    s = copy.deepcopy(base)
    s.update(uncertainty=[{"sparkline": {"place": "beside"}}, "std_error"], estimate=False, stats=[])
    out.append(s)
    out.append(et.read_table(EXAMPLES / "event-study.estrec-table.json"))
    return out


@pytest.fixture(scope="module")
def node_result():
    if NODE is None:
        pytest.skip("node not installed")
    grid = [
        (t, df)
        for df in (1, 2.5, 5, 30, 997, 9999, 1e4, 1e6, 1e9, None)
        for t in (0, 0.3, 1, 1.96, 4, 9.5, 25)
    ]
    crit = [(lv, df) for lv in (0.9, 0.95, 0.99) for df in (1, 3, 49, 997, 1e5, None)]
    req = {
        "files": [{"name": n, "text": (EXAMPLES / n).read_text(encoding="utf-8")} for n in FILES],
        "sources": FILES,
        "specs": specs(),
        "pvals": grid,
        "crit": crit,
    }
    run = subprocess.run(
        [NODE, str(ROOT / "tests" / "viewer_check.js")],
        input=json.dumps(req),
        capture_output=True,
        text=True,
        check=False,
    )
    assert run.returncode == 0, run.stderr
    return req, json.loads(run.stdout)


def test_tables_match_python(node_result):
    _req, out = node_result
    for i, (spec, js) in enumerate(zip(specs(), out["tables"])):
        py = et.build_table(spec, base_dir=EXAMPLES)
        assert "error" not in js, (i, js)
        assert js["header"] == py["header"], i
        assert js["head"] == py["head"], i
        assert [r.get("sparkline") for r in js["rows"]] == [r.get("sparkline") for r in py["rows"]], i
        assert [r["label"] for r in js["rows"]] == [r["label"] for r in py["rows"]], i
        assert [r["cells"] for r in js["rows"]] == [r["cells"] for r in py["rows"]], i
        assert js["notes"] == py["notes"], i


def test_renderers_match_python(node_result):
    """Each format renders the built table the same way (the JS renderers on Python's table)."""
    if NODE is None:
        pytest.skip("node not installed")
    all_specs = specs()
    sparks = [s for s in all_specs if "sparkline" in json.dumps(s.get("uncertainty"))]
    assert len(sparks) == 8
    for spec in [all_specs[0]] + [s for s in all_specs if "head" in s] + sparks:
        py = et.build_table(spec, base_dir=EXAMPLES)
        script = (
            "const E=require(process.argv[1]);const t=JSON.parse(require('fs').readFileSync(0,'utf8'));"
            "process.stdout.write(JSON.stringify(Object.fromEntries(['text','markdown','latex','html','csv','word'].map(f=>[f,E.render(t,f)]))))"
        )
        run = subprocess.run(
            [NODE, "-e", script, str(ROOT / "viewer" / "estrec-table.js")],
            input=json.dumps(py),
            capture_output=True,
            text=True,
            check=False,
        )
        assert run.returncode == 0, run.stderr
        for fmt, text in json.loads(run.stdout).items():
            assert text == et.render(py, fmt), (spec.get("head"), fmt)


def test_distributions_match_python(node_result):
    req, out = node_result
    for (t, df), p in zip(req["pvals"], out["pvals"]):
        want = views.two_sided_p(t, df)
        assert p == pytest.approx(want, rel=1e-9, abs=1e-300), (t, df)
    for (lv, df), q in zip(req["crit"], out["crit"]):
        assert q == pytest.approx(views.critical_value(lv, df), rel=1e-10), (lv, df)


def test_hashes_match_python(node_result):
    _req, out = node_result
    recs = {}
    for name in ("paper", "session"):
        coll = ef.read_collection(EXAMPLES / f"{name}.estrec-collection.json")
        recs.update({r["meta"]["id"]: r for _, _, r in ef.iter_members(coll)})
    for rid, h in out["hashes"]:
        if rid in recs:
            assert h == ef.member_sha256(recs[rid]), rid


def test_missing_record_errors_in_both():
    if NODE is None:
        pytest.skip("node not installed")
    s = copy.deepcopy(specs()[0])
    s["columns"][0]["record"] = "missing"
    with pytest.raises(ValueError, match="not found"):
        et.build_table(s, base_dir=EXAMPLES)
    req = {"files": [], "sources": {}, "specs": [s], "pvals": [], "crit": []}
    run = subprocess.run(
        [NODE, str(ROOT / "tests" / "viewer_check.js")],
        input=json.dumps(req),
        capture_output=True,
        text=True,
        check=False,
    )
    assert "not found" in json.loads(run.stdout)["tables"][0]["error"]
