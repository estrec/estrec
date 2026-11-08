"""Table specs (spec/table.md): building, validating and rendering."""

import importlib.util
import copy
import html
import json

import pytest

import estrec as ef
from estrec import records as est
from estrec import table as et

EXAMPLES = est.PACKAGED_SCHEMAS / "examples"
SPEC = EXAMPLES / "paper.estrec-table.json"
SESSION = EXAMPLES / "session.estrec-collection.json"


def spec():
    return et.read_table(SPEC)


def cells(t, label):
    return next(r["cells"] for r in t["rows"] if r["label"] == label)


def test_example_builds():
    t = et.build_table(spec(), base_dir=EXAMPLES)
    assert t["header"] == ["(1)", "(2)", "(3)"]
    assert [r["label"] for r in t["rows"] if r["kind"] == "estimate"] == ["Weight (1000 lbs)", "Horsepower"]
    assert cells(t, "Weight (1000 lbs)")[0] == "-3.206***"
    assert cells(t, "Horsepower")[0] == ""  # not in column (1)
    assert cells(t, "N") == ["32", "32", "32"]
    assert cells(t, "Std. errors") == ["iid", "HC1", "HC1"]
    assert cells(t, "Cylinders FE") == ["Y", "Y", "Y"]
    assert cells(t, "Controls") == ["No", "No", "qsec"]
    assert "* p < 0.1, ** p < 0.05, *** p < 0.01" in t["notes"]
    assert t["warnings"] == []


@pytest.mark.parametrize("fmt", sorted(et.RENDERERS))
def test_example_renders(fmt):
    out = et.render_table(SPEC, fmt)
    assert "3.206" in out


def test_validates_against_schema():
    pytest.importorskip("jsonschema")
    assert et.validate_table(spec()) == []
    bad = spec()
    bad["stats"].append({"metric": "nobs", "fixed_effect": "cyl"})  # two kinds in one row
    bad["uncertainty"] = "variance"
    assert len([i for i in et.validate_table(bad) if i.level == "error"]) >= 2


def test_structural_errors():
    s = spec()
    s["columns"][0]["source"] = "nowhere"
    s["drop"] = ["("]
    s["stats"][-1]["values"] = ["only one"]
    s["sources"].append({"id": "paper", "path": "x.json"})
    msgs = [i.message for i in et.validate_table(s, schema=None) if i.level == "error"]
    assert any("no source 'nowhere'" in m for m in msgs)
    assert any("doesn't compile" in m for m in msgs)
    assert any("1 values for 3 columns" in m for m in msgs)
    assert any("duplicate source id" in m for m in msgs)


def test_missing_record_is_an_error():
    s = spec()
    s["columns"][1]["record"] = "00000000-0000-4000-8000-000000000000"
    assert any("not found" in i.message for i in et.validate_table(s, base_dir=EXAMPLES))
    with pytest.raises(ValueError, match="not found"):
        et.build_table(s, base_dir=EXAMPLES)


def test_warnings():
    s = spec()
    s["columns"][0]["sha256"] = "0" * 64
    s["columns"][1]["vcov"] = "CRV3"
    s["rows"].append({"term": "nope"})
    s["stats"] += [{"metric": "auc"}, {"fixed_effect": "gear"}, {"test": "sargan"}]
    msgs = [i.message for i in et.validate_table(s, base_dir=EXAMPLES, schema=None) if i.level == "warning"]
    assert any("has changed" in m for m in msgs)
    assert any("no vcov 'CRV3'" in m for m in msgs)
    assert any("no column has nope" in m for m in msgs)
    assert any("metric 'auc'" in m for m in msgs)
    assert any("fixed effect 'gear'" in m for m in msgs)
    assert any("test 'sargan'" in m for m in msgs)


def test_pinned_hash_matches():
    s = spec()
    recs = {
        r["meta"]["id"]: r
        for _, _, r in ef.iter_members(ef.read_collection(EXAMPLES / "paper.estrec-collection.json"))
    }
    for c in s["columns"]:
        c["sha256"] = ef.member_sha256(recs[c["record"]])
    assert [i for i in et.validate_table(s, base_dir=EXAMPLES, schema=None) if i.level != "info"] == []


def test_rows_keep_drop_and_shared_rows():
    s = spec()
    s["drop"] = []
    t = et.build_table(s, base_dir=EXAMPLES)
    assert [r["label"] for r in t["rows"] if r["kind"] == "estimate"] == [
        "Weight (1000 lbs)",
        "Horsepower",
        "qsec",
    ]
    s["keep"] = ["^q"]
    s["rows"] = [{"terms": ["hp", "wt"], "label": "hp or wt"}]  # first one each column has
    t = et.build_table(s, base_dir=EXAMPLES)
    assert [r["label"] for r in t["rows"] if r["kind"] == "estimate"] == ["hp or wt", "qsec"]
    assert cells(t, "hp or wt")[0].startswith("-3.206")  # column (1) has only wt
    assert cells(t, "hp or wt")[1].startswith("-0.023")
    s["keep_unlisted"] = False
    t = et.build_table(s, base_dir=EXAMPLES)
    assert [r["label"] for r in t["rows"] if r["kind"] == "estimate"] == ["hp or wt"]


@pytest.mark.parametrize(
    "unc,second",
    [
        ("std_error", "(0.754)"),
        ("statistic", "(-4.252)"),
        ("p_value", "[0.000]"),
        ("conf_int", "[-4.750, -1.661]"),
    ],
)
def test_uncertainty(unc, second):
    s = spec()
    s["uncertainty"] = unc
    t = et.build_table(s, base_dir=EXAMPLES)
    assert t["rows"][1]["cells"][0] == second


def test_no_uncertainty_no_stars():
    s = spec()
    s["uncertainty"] = None
    s["stars"] = None
    t = et.build_table(s, base_dir=EXAMPLES)
    assert t["rows"][1]["kind"] == "estimate" and t["rows"][0]["cells"][0] == "-3.206"
    assert not any("p <" in n for n in t["notes"])


def test_column_vcov_and_clusters():
    coll = ef.read_collection(SESSION)
    s = et.new_table(coll, stats=["nobs", {"vcov": "type"}, {"vcov": "n_clusters"}])
    s["columns"].append(dict(s["columns"][0], header="iid", vcov="iid"))
    t = et.build_table(s, records=coll)
    rec = next(r for _, _, r in ef.iter_members(coll))
    iid = ef.tidy(rec, vcov="iid")[0]
    assert t["header"] == ["(1)", "(2)", "(3)"]
    s["head"] = ["label"]
    assert et.build_table(s, records=coll)["head"][0]["cells"] == ["firm", "firm_year", "iid"]
    assert t["rows"][1]["cells"][2] == f"({iid['std_error']:.3f})"
    assert cells(t, "Std. errors") == ["by: firm", "by: firm", "iid"]
    assert cells(t, "Clusters")[0] == "980" and cells(t, "Clusters")[2] == ""
    assert cells(t, "FE: firm") == ["Y", "Y", "Y"]


def test_new_table_and_round_trip(tmp_path):
    coll = ef.read_collection(EXAMPLES / "paper.estrec-collection.json")
    s = et.new_table(coll, title="T", pin=True, sources=[{"id": "p", "path": "paper.estrec-collection.json"}])
    assert all("header" not in c for c in s["columns"])
    assert all(len(c["sha256"]) == 64 for c in s["columns"])
    path = et.write_table(s, tmp_path / "t.estrec-table.json")
    assert et.read_table(path) == json.loads(json.dumps(s))
    assert et.render_table(s, "text", base_dir=EXAMPLES).startswith("T\n")
    if pytest.importorskip("jsonschema"):
        assert et.validate_table(s) == []


def test_latex_escapes_and_rules():
    s = spec()
    s["title"] = "Fares & HHI_1 (100%)"
    out = et.render_table(s, "latex", base_dir=EXAMPLES)
    assert r"Fares \& HHI\_1 (100\%)" in out and out.count(r"\midrule") == 2
    s["rows"][0]["label"] = r"$\beta$"
    assert r"$\beta$" in et.render_table(s, "latex", base_dir=EXAMPLES, escape=False)


def test_html_escapes():
    s = spec()
    s["rows"][0]["label"] = "<b>wt</b>"
    out = et.render_table(s, "html", base_dir=EXAMPLES)
    assert "&lt;b&gt;wt&lt;/b&gt;" in out and '<tr class="stat first-stat">' in out


def test_digits_and_format():
    s = spec()
    s["format"] = {"digits": 2, "thousands": " ", "fe_yes": "X", "star_symbols": ["+", "*", "**"]}
    t = et.build_table(s, base_dir=EXAMPLES)
    assert cells(t, "Weight (1000 lbs)")[0] == "-3.21**" and cells(t, "Cylinders FE")[0] == "X"
    assert "+ p < 0.1, * p < 0.05, ** p < 0.01" in t["notes"]


def test_cli(tmp_path, capsys):
    assert et.main([str(SPEC), "--format", "csv"]) == 0
    assert capsys.readouterr().out.splitlines()[0] == ",(1),(2),(3)"
    assert et.main([str(SPEC), "--check"]) == 0
    out = tmp_path / "t.tex"
    assert et.main([str(SPEC), "-f", "latex", "-o", str(out)]) == 0 and r"\toprule" in out.read_text()
    bad = copy.deepcopy(spec())
    bad["columns"][0]["record"] = "missing"
    p = tmp_path / "bad.estrec-table.json"
    p.write_text(json.dumps(bad))
    assert et.main([str(p)]) == 1


def test_great_tables():
    pytest.importorskip("great_tables")
    g = et.to_great_table(et.build_table(spec(), base_dir=EXAMPLES))
    assert "3.206" in g.as_raw_html()


def test_estimation_cli_subcommands(capsys):
    from estrec.records import main

    assert main(["table", str(SPEC), "-f", "markdown"]) == 0
    assert "| Weight (1000 lbs) |" in capsys.readouterr().out
    assert main(["show", str(EXAMPLES / "paper.estrec-collection.json")]) == 0
    assert capsys.readouterr().out.split("\n")[0].split() == ["baseline", "horsepower", "full"]
    assert main(["validate", str(SPEC)]) == 0
    assert "valid (0 errors)" in capsys.readouterr().out


def test_several_lines_under_estimates():
    s = spec()
    s["uncertainty"] = ["std_error", "[{p_value}]", "t = {statistic}"]
    t = et.build_table(s, base_dir=EXAMPLES)
    assert [r["kind"] for r in t["rows"][:4]] == ["estimate", "uncertainty", "uncertainty", "uncertainty"]
    assert [r["cells"][0] for r in t["rows"][:4]] == ["-3.206***", "(0.754)", "[0.000]", "t = -4.252"]
    assert t["rows"][5]["cells"][0] == ""  # Horsepower isn't in column (1): every line blank
    assert "Under each estimate: (standard error); [p-value]; t = test statistic." in t["notes"]


@pytest.mark.parametrize(
    "fmt,want",
    [
        ({}, "[0.000]"),
        ({"p_style": "less_than"}, "[<0.001]"),
        ({"p_digits": 4}, "[0.0002]"),
        ({"p_digits": 2, "p_style": "less_than"}, "[<0.01]"),
        ({"p_digits": 4, "p_style": "less_than"}, "[0.0002]"),
    ],
)
def test_p_value_format(fmt, want):
    s = spec()
    s["uncertainty"] = "[{p_value}]"
    s["format"] = {"digits": 3, **fmt}
    t = et.build_table(s, base_dir=EXAMPLES)
    assert t["rows"][1]["cells"][0] == want


def test_p_style_applies_to_test_rows():
    s = spec()
    s["format"] = {"digits": 3, "p_style": "less_than"}
    assert cells(et.build_table(s, base_dir=EXAMPLES), "Wald p") == ["<0.001", "<0.001", "<0.001"]


def test_bad_lines_are_errors():
    s = spec()
    s["uncertainty"] = ["({stderr})", "bogus", "no placeholders {}"]
    msgs = [i.message for i in et.validate_table(s, schema=None) if i.level == "error"]
    assert any("unknown placeholder {stderr}" in m for m in msgs)
    assert any("'bogus' is neither a name" in m for m in msgs)
    assert len(msgs) == 3
    pytest.importorskip("jsonschema")
    ok = spec()
    ok["uncertainty"] = ["std_error", "p = {p_value}"]
    ok["format"] = {"p_digits": 4, "p_style": "less_than"}
    assert et.validate_table(ok) == []


def test_word_render_has_three_rules_and_inline_styles():
    t = et.build_table(spec(), base_dir=EXAMPLES)
    doc = et.render(t, "word")
    assert doc.startswith("<!doctype html>") and doc.rstrip().endswith("</body></html>")
    assert "class=" not in doc and "<style" not in doc  # Word keeps inline styles only
    assert doc.count("border-top:1.5pt") == len(t["header"]) + 1  # top rule over the header
    assert doc.count("border-bottom:1.5pt") == len(t["header"]) + 1  # bottom rule
    n_stat_starts = sum(
        1
        for i, r in enumerate(t["rows"])
        if r["kind"] == "stat" and (i == 0 or t["rows"][i - 1]["kind"] != "stat")
    )
    assert doc.count("border-top:.75pt") == n_stat_starts * (len(t["header"]) + 1)
    for n in t["notes"]:
        assert html.escape(n) in doc


def test_heading_rows_number_then_response_by_default():
    coll = ef.read_collection(EXAMPLES / "paper.estrec-collection.json")
    s = et.new_table(coll)
    t = et.build_table(s, records=coll)
    assert [h["kind"] for h in t["head"]] == ["number", "response"]
    assert t["head"][0]["cells"] == t["header"] == ["(1)", "(2)", "(3)"]
    resp = [", ".join(r["meta"]["responses"]) for _, _, r in ef.iter_members(coll)]
    assert t["head"][1]["cells"] == resp
    s["response_labels"] = {resp[0]: "Miles per gallon"}
    assert et.build_table(s, records=coll)["head"][1]["cells"][0] == "Miles per gallon"


def test_heading_rows_order_and_label_row():
    coll = ef.read_collection(EXAMPLES / "paper.estrec-collection.json")
    s = et.new_table(coll, head=["label", "number"])
    t = et.build_table(s, records=coll)
    assert [h["cells"] for h in t["head"]] == [["baseline", "horsepower", "full"], ["(1)", "(2)", "(3)"]]
    text = et.render(t, "text").splitlines()
    assert "baseline" in text[0] and "(1)" in text[1] and set(text[2]) <= {"-", " "}
    md = et.render(t, "markdown").splitlines()
    assert "baseline" in md[0] and md[1].startswith("|---|") and "(1)" in md[2]
    assert et.render(t, "latex").count(" & (1) & ") == 1
    assert '<tr class="head-label">' in et.render(t, "html")
    assert et.render(t, "csv").splitlines()[:2] == [",baseline,horsepower,full", ",(1),(2),(3)"]
    s["head"] = []
    t = et.build_table(s, records=coll)
    assert t["head"] == [] and "1.5pt" in et.render(t, "word").split("<tr>")[1]
    s["head"] = ["number", "bogus", "number"]
    msgs = [i.path for i in et.validate_table(s, schema=None)]
    assert msgs == ["head[1]", "head[2]"]


def sparkline_table(scale):
    s = spec()
    s["uncertainty"] = ["std_error", {"sparkline": {"color": "#c0392b", "scale": scale}}]
    return et.build_table(s, base_dir=EXAMPLES)


def test_sparkline_rows_carry_intervals_and_text():
    t = sparkline_table("column")
    sp = [r for r in t["rows"] if "sparkline" in r]
    assert sp and all(r["kind"] == "uncertainty" for r in sp)
    m = sp[0]["sparkline"]["marks"][0]
    assert m["low"] < m["estimate"] < m["high"]
    assert sp[0]["cells"][0] == f"[{m['low']:.3f}, {m['high']:.3f}]"  # text formats show the interval
    assert sp[0]["cells"][0] in et.render(t, "text") and "<svg" not in et.render(t, "latex")
    assert sp[0]["cells"][0] not in et.render(t, "latex")  # LaTeX draws it (TikZ)
    assert any("drawn as a line" in n for n in t["notes"])


def test_sparkline_scales():
    def domains(t):
        sp = [r["sparkline"]["marks"] for r in t["rows"] if "sparkline" in r]
        return [[m and tuple(m["domain"]) for m in row] for row in sp]

    col, row, tab = (domains(sparkline_table(k)) for k in ("column", "row", "table"))
    for j in range(len(col[0])):  # one axis down each column
        assert len({r[j] for r in col if r[j]}) == 1
    for r in row:  # one axis along each row
        assert len({d for d in r if d}) == 1
    assert len({d for r in tab for d in r if d}) == 1
    for d in {d for r in col + row + tab for d in r if d}:
        assert d[0] <= 0 <= d[1]


def test_sparkline_html_and_word():
    t = sparkline_table("column")
    h = et.render(t, "html")
    # five intervals, and the 0 rule alone where a column lacks the term, so the axis joins
    assert h.count('<td class="spark"><svg') == 6 and 'stroke="#555555"' in h and 'fill="#7c251b"' in h
    assert h.count('aria-hidden="true"') == 1
    w = et.render(t, "word")
    assert w.count('src="data:image/svg+xml;base64,') == 6 and "<svg" not in w and w.count('alt=""') == 1


# The event study's first sparkline, pinned: r/tests/test-table.R checks R draws the same
EVENT_T3_TIKZ = (
    r"\tikz[x=.75pt,y=.75pt,baseline=0pt]{\useasboundingbox (0,-4.8) rectangle (80,11.2);"
    r"\draw[line width=.75pt,color={rgb,255:red,85;green,85;blue,85}] (59.9,-4.8) -- (59.9,11.2);"
    r"\fill[color={rgb,255:red,43;green,95;blue,142},fill opacity=.22] (60.2,3.2) .. controls (65.47,7.2)"
    r" and (70.73,7.2) .. (76.0,3.2) .. controls (70.73,-0.8) and (65.47,-0.8) .. (60.2,3.2) -- cycle;"
    r"\draw[line width=.975pt,line cap=round,color={rgb,255:red,43;green,95;blue,142}] (60.2,3.2) -- (76.0,3.2);"
    r"\filldraw[fill={rgb,255:red,43;green,95;blue,142},draw=white,line width=.675pt] (60.2,3.2) circle[radius=1.425pt];"
    r"\filldraw[fill={rgb,255:red,43;green,95;blue,142},draw=white,line width=.675pt] (76.0,3.2) circle[radius=1.425pt];"
    r"\filldraw[fill={rgb,255:red,27;green,61;blue,92},draw=white,line width=.825pt] (68.1,3.2) circle[radius=2.175pt];}"
)
EVENT_T3_SVG = (
    '<svg xmlns="http://www.w3.org/2000/svg" width="80" height="16" viewBox="0 0 80 16" role="img"'
    ' aria-label="[0.001, 0.060]"><line x1="59.9" y1="0" x2="59.9" y2="16" stroke="#555555" stroke-width="1"/>'
    '<path d="M60.2 8.0Q68.1 2.0 76.0 8.0Q68.1 14.0 60.2 8.0Z" fill="#2b5f8e" fill-opacity="0.22"/>'
)


def test_sparkline_latex_is_tikz_with_the_svg_marks():
    t = sparkline_table("column")
    tex = et.render(t, "latex")
    assert tex.startswith("% Sparklines are TikZ pictures (\\usepackage{tikz})")
    assert tex.count("\\tikz[") == 6 and tex.count("circle[radius=2.175pt]") == 5  # + a missing cell's rule
    for r in t["rows"]:
        for m in (r.get("sparkline") or {}).get("marks", []):
            if m and "estimate" in m:  # the same x positions as the SVG
                x0, xl, xe, xh = map(et._tenths, et._spark_xs(m))
                assert f'x1="{x0}"' in et._spark_svg(m, "#c0392b") and f"({xe},3.2) circle" in et._spark_tikz(m, "#c0392b")
    assert "tikz" not in et.render(et.build_table(spec(), base_dir=EXAMPLES), "latex")
    assert et._third(602, 681) == "65.47" and et._third(10, 10) == "1.00" and et._third(1, 0) == "0.03"
    ev = et.build_table(et.read_table(EXAMPLES / "event-study.estrec-table.json"), base_dir=EXAMPLES)
    r = ev["rows"][0]
    assert et._spark_tikz(r["sparkline"]["marks"][0], r["sparkline"]["color"]) == EVENT_T3_TIKZ
    assert EVENT_T3_TIKZ in et.render(ev, "latex") and EVENT_T3_SVG in et.render(ev, "html")


def test_great_tables_sparklines():
    pytest.importorskip("great_tables")
    t = sparkline_table("table")
    g = et.to_great_table(t)
    h = g.as_raw_html()
    svgs = [et._spark_svg(m, r["sparkline"]["color"], c) for r in t["rows"] if "sparkline" in r
            for m, c in zip(r["sparkline"]["marks"], r["cells"]) if m]
    assert len(svgs) == 6 and all(s in h for s in svgs) and "padding-top:0" in h  # + a missing cell's rule
    import warnings

    with warnings.catch_warnings():
        warnings.simplefilter("ignore")  # great_tables: styles aren't supported in LaTeX
        tex = g.as_latex()
    assert tex.count("\\tikz[") == 6 and "<svg" not in tex
    assert "<svg" not in et.to_great_table(et.build_table(spec(), base_dir=EXAMPLES)).as_raw_html()


def test_sparkline_beside_level_with_the_estimate():
    """The default: the marks on the estimate's row, the 0 rule alone in the term's other
    rows (an SVG filling each cell), so the rule still runs down the column."""
    s = spec()
    s["uncertainty"] = ["std_error", "[{p_value}]", {"sparkline": {"place": "beside"}}]
    t = et.build_table(s, base_dir=EXAMPLES)
    assert all(r["sparkline"]["align"] == "estimate" for r in t["rows"] if "sparkline" in r)
    h = et.render(t, "html")
    assert "rowspan" not in h and h.count('class="spark-side"') == 3 * 6  # 2 terms x 3 rows
    rows = h.split("<tr ")
    est = next(r for r in rows if r.startswith('class="estimate"><th>Weight'))
    assert est.count('role="img"') == 3 and est.count('aria-hidden="true"') == 3  # marks + rule
    se = rows[rows.index(est) + 1]
    assert 'role="img"' not in se and se.count('aria-hidden="true"') == 3  # rule only
    assert 'style="display:block;margin:0 auto;position:relative"' in est
    w = et.render(t, "word", term_space=True)
    assert "rowspan" not in w and w.count("mso-height-rule:exactly") == 6
    # Word: the marks at the text's middle, below the 3 pt space above the second term
    import base64
    import re

    svgs = [base64.b64decode(x).decode() for x in re.findall(r"base64,([A-Za-z0-9+/=]+)", w)]
    assert sum('cy="8.0"' in x for x in svgs) == 3 and sum('cy="12.0"' in x for x in svgs) == 2
    assert sum("circle" not in x for x in svgs) == 3 * 2 + 2 * 2 + 3  # the rule-only rows; a missing cell's


def test_sparkline_beside_the_estimates():
    s = spec()
    s["uncertainty"] = ["std_error", {"sparkline": {"place": "beside", "align": "middle"}}]
    t = et.build_table(s, base_dir=EXAMPLES)
    sp = [r for r in t["rows"] if "sparkline" in r]
    assert sp and all(r["sparkline"]["place"] == "beside" for r in sp)
    h = et.render(t, "html")
    assert h.count('<th colspan="2">') == 3 * len(t["head"])
    # one drawing per column per term (hp is missing in (1): the 0 rule alone), spanning the
    # estimate and its standard error; the sparkline rows themselves are gone
    assert h.count('class="spark-side" rowspan="2"') == 6 and "spark-row" not in h
    assert h.count('height="100%"') == 6 and '<td colspan="2">32</td>' in h
    assert f'colspan="{1 + 2 * 3}"' in h  # notes span every column
    # text formats keep the interval as a row
    assert sp[0]["cells"][0] in et.render(t, "text")
    w = et.render(t, "word", term_space=True)
    assert w.count('rowspan="2"') == 6 and w.count("mso-height-rule:exactly") == 4
    # the first term's two rows are 12 + 12 pt (32 px), the second's 15 + 12 pt (36 px)
    assert w.count('height="32"') == 3 and w.count('height="36"') == 3
    # without the estimate, the beside line's label moves to the first row left
    s.update(uncertainty=[{"sparkline": {"place": "beside", "align": "middle"}}, "std_error"], estimate=False)
    h = et.render(et.build_table(s, base_dir=EXAMPLES), "html")
    assert '<tr class="estimate"><th>Weight (1000 lbs)</th><td>(0.754)</td><td class="spark-side" rowspan="1"' in h
    # a term whose only line is the drawing keeps it as a row
    s["uncertainty"] = {"sparkline": {"place": "beside"}}
    h = et.render(et.build_table(s, base_dir=EXAMPLES), "html")
    assert "spark-side" not in h and h.count('<td colspan="2" class="spark"><svg') == 6
    s["uncertainty"] = [
        {"sparkline": {"place": "beside"}},
        {"sparkline": {"place": "beside"}},
        {"sparkline": {"place": "x", "align": "top"}},
    ]
    assert [(i.path, i.message[:3]) for i in et.validate_table(s, schema=None)] == [
        ("uncertainty[1].sparkline.place", "one"),
        ("uncertainty[2].sparkline.place", "'be"),
        ("uncertainty[2].sparkline.align", "'es"),
    ]


def test_word_table_width():
    """A Word table of a set width: every column fixed, sparklines drawn to fit."""
    import base64
    import re

    for unc in (["std_error", {"sparkline": {}}], ["std_error", "[{p_value}]", {"sparkline": {"place": "beside"}}]):
        s = spec()
        s["uncertainty"] = unc
        t = et.build_table(s, base_dir=EXAMPLES)
        natural = et.render(t, "word")
        assert "table-layout" not in natural and "width:" not in natural.split("<table", 1)[1].split(">", 1)[0]
        w = et.render(t, "word", width=6.5)
        assert 'style="border-collapse:collapse;border:none;font-size:10pt;width:468.0pt;table-layout:fixed"' in w
        first = w.split("<tr>")[1]  # the first heading row: label column + 3 data columns = 468 pt
        widths = [int(x.replace(".", "")) for x in re.findall(r"width:([0-9.]+)pt", first)]
        assert len(widths) == 4 and sum(widths) == 4680
        svgs = [base64.b64decode(x).decode() for x in re.findall(r"base64,([A-Za-z0-9+/=]+)", w)]
        assert svgs and all('width="80"' not in x for x in svgs)
        narrow = et.render(t, "word", width=4)
        n_w = int(re.search(r'<img width="(\d+)"', narrow).group(1))
        assert n_w < int(re.search(r'<img width="(\d+)"', w).group(1))
        # the marks keep their size: only the axis narrows
        assert 'r="2.9"' in base64.b64decode(re.search(r"base64,([A-Za-z0-9+/=]+)", narrow).group(1)).decode()


def test_word_font_size_and_term_space():
    """The font size goes on every cell (Word ignores the table's on paste) and sizes the
    rows; the space above each term is off by default when the table has sparklines."""
    import base64
    import re

    s = spec()
    plain = et.render(et.build_table(s, base_dir=EXAMPLES), "word")
    assert plain.count("padding-top:3.00pt") > 0  # no sparklines: terms spaced
    s["uncertainty"] = ["std_error", {"sparkline": {"place": "beside"}}]
    t = et.build_table(s, base_dir=EXAMPLES)
    w = et.render(t, "word")
    assert "padding-top" not in w and w.count('style="height:12.00pt;mso-height-rule:exactly"') == 4
    assert all("font-size:10pt" in td for td in re.findall(r"<td[^>]*>", w))
    big = et.render(t, "word", font=12, width=6.5)
    assert all("font-size:12pt" in td for td in re.findall(r"<td[^>]*>", big))
    assert 'style="height:14.25pt;mso-height-rule:exactly"' in big  # 19 px = 1.2 x 12 pt, rounded
    svgs = [base64.b64decode(x).decode() for x in re.findall(r"base64,([A-Za-z0-9+/=]+)", big)]
    assert all('height="19"' in x for x in svgs)
    assert 'font-size:11pt">' in big  # notes, a point smaller
    assert et.render(t, "word", font=9.5).count("font-size:9.5pt") > 0


def test_sparkline_validation():
    s = spec()
    s["uncertainty"] = [{"sparkline": {"color": "red", "scale": "diagonal"}}, {"sparkline": 1}]
    paths = [i.path for i in et.validate_table(s, schema=None)]
    assert paths == ["uncertainty[0].sparkline.color", "uncertainty[0].sparkline.scale", "uncertainty[1]"]


def test_no_estimate_row_lines_carry_the_term():
    s = spec()
    s["uncertainty"] = {"sparkline": {}}
    s["estimate"] = False
    t = et.build_table(s, base_dir=EXAMPLES)
    est = [r for r in t["rows"] if r["kind"] != "stat"]
    assert [r["label"] for r in est] == ["Weight (1000 lbs)", "Horsepower"]
    assert all("sparkline" in r and r["kind"] == "estimate" for r in est)
    assert not any("p <" in n for n in t["notes"])  # no stars without estimates
    assert 'class="estimate spark-row"' in et.render(t, "html")
    assert "padding-top:3pt" not in et.render(t, "word")
    s["uncertainty"] = None
    assert [i.path for i in et.validate_table(s, schema=None)] == ["estimate"]
    s["estimate"] = "no"
    assert [i.path for i in et.validate_table(s, schema=None)] == ["estimate"]


def test_event_study_example_is_a_column_of_sparklines():
    t = et.render_table(EXAMPLES / "event-study.estrec-table.json", "html")
    assert t.count("<svg") == 7 and "***" not in t
    built = et.build_table(et.read_table(EXAMPLES / "event-study.estrec-table.json"), base_dir=EXAMPLES)
    assert [r["label"] for r in built["rows"]][:7] == [
        "t \u2212 3",
        "t \u2212 2",
        "t \u2212 1",
        "t",
        "t + 1",
        "t + 2",
        "t + 3",
    ]
    doms = {tuple(r["sparkline"]["marks"][0]["domain"]) for r in built["rows"] if "sparkline" in r}
    assert len(doms) == 1  # one axis down the column
    if pytest.importorskip("jsonschema"):
        assert (
            et.validate_table(et.read_table(EXAMPLES / "event-study.estrec-table.json"), base_dir=EXAMPLES)
            == []
        )


def reference_spec(**kw):
    s = spec()
    s["rows"] = [
        {"term": "wt", "label": "Weight"},
        {"term": "base", "label": "Base period", "reference": True},
        {"term": "hp", "label": "Horsepower", "reference": "(omitted)"},
    ]
    s.update(kw)
    return s


def test_reference_rows():
    s = reference_spec(uncertainty=["std_error", {"sparkline": {}}])
    assert et.validate_table(s, base_dir=EXAMPLES, schema=None) == []  # no "no column has base"
    if importlib.util.find_spec("jsonschema"):
        assert et.validate_table(s, base_dir=EXAMPLES) == []
    t = et.build_table(s, base_dir=EXAMPLES)
    assert cells(t, "Base period") == ["—", "—", "—"]
    assert cells(t, "Horsepower") == ["(omitted)", "-0.023**", "-0.021*"]
    i = [r["label"] for r in t["rows"]].index("Horsepower")
    assert t["rows"][i + 1]["cells"][0] == ""  # its standard error: blank, not format.missing
    marks = t["rows"][i + 2]["sparkline"]["marks"]
    assert marks[0]["reference"] and "estimate" not in marks[0] and marks[0]["domain"] == marks[0]["domain"]
    h = et.render(t, "html")
    assert h.count('stroke="#1b3d5c" stroke-width="1.2"') == 4  # the hollow dots: 3 base + 1 hp
    assert 'aria-label="reference or omitted"' in h
    tex = et.render(t, "latex")
    assert tex.count("circle[radius=1.95pt]") == 4
    # without the estimate the text goes in the first line
    t = et.build_table(reference_spec(uncertainty={"sparkline": {}}, estimate=False), base_dir=EXAMPLES)
    assert cells(t, "Base period") == ["—", "—", "—"] and cells(t, "Horsepower")[0] == "(omitted)"
    # a plain missing cell keeps the rule; an axis with no interval at all is blank
    t = et.build_table(dict(spec(), uncertainty={"sparkline": {"scale": "row"}}, estimate=False), base_dir=EXAMPLES)
    hp = next(r for r in t["rows"] if r["label"] == "Horsepower")["sparkline"]["marks"]
    assert hp[0] == {"domain": hp[1]["domain"]}
    rows = [{"label": "a", "kind": "estimate", "cells": [""], "sparkline": {"scale": "column", "marks": [{}]}}]
    et._spark_domains(rows)
    assert rows[0]["sparkline"]["marks"] == [None]


def test_latex_beside():
    for align in ("estimate", "middle"):
        s = reference_spec(uncertainty=["std_error", {"sparkline": {"place": "beside", "align": align}}])
        tex = et.render(et.build_table(s, base_dir=EXAMPLES), "latex")
        body = tex.split("\\midrule")[1]
        assert "\\begin{tabular}{lcccccc}" in tex and tex.count("\\multicolumn{2}{c}{(1)}") == 1
        assert "\\multicolumn{2}{c}{32}" in tex  # statistics span both columns
        weight = next(l for l in body.split("\n") if l.startswith("Weight"))
        assert weight.count("\\tikz[") == 3 and weight.count("circle[radius=2.175pt]") == 3
        se = next(l for l in body.split("\n") if l.startswith(" & (0.754)"))
        if align == "estimate":  # the standard error's row: the rule alone
            assert se.count("\\tikz[") == 3 and "circle" not in se and "(76.0,-4.8) -- (76.0,11.2)" in se
        else:  # one picture per term, its rule down through both rows, the marks between
            assert "\\tikz" not in se and se.endswith("&  \\\\")
            assert "(76.0,-20.8) -- (76.0,11.2)" in weight and "(27.4,-4.8) circle[radius=2.175pt]" in weight
