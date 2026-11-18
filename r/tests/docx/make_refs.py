"""The Python reference's Word files for test-table.R: for each case, the spec and options
(cases.json) and word/document.xml as render(t, "docx") writes it (<name>.xml). R's
render_table(output = "x.docx") must write the same document.xml. tests/test_table.py checks
these files are current; after a change to the Word writer, run

    python r/tests/docx/make_refs.py
"""

import copy
import json
import sys
import zipfile
from io import BytesIO
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
EX = ROOT / "schema" / "examples"


def cases() -> list[dict]:
    base = json.loads((EX / "paper.estrec-table.json").read_text(encoding="utf-8"))

    def spec(**kw):
        s = copy.deepcopy(base)
        for k, v in kw.items():
            if v is None:
                s.pop(k, None)
            else:
                s[k] = v
        return s

    spark = {"sparkline": {}}
    return [
        {"name": "plain", "spec": spec(), "options": {}},
        {"name": "width", "spec": spec(), "options": {"width": 6.5, "font": 10}},
        {"name": "lines", "spec": spec(uncertainty=["std_error", "[{p_value}]", "conf_int"]), "options": {"width": 6.5, "font": 11}},
        {"name": "below", "spec": spec(uncertainty=["std_error", spark]), "options": {"width": 6.5, "font": 10}},
        {"name": "below-auto", "spec": spec(uncertainty=["std_error", {"sparkline": {"scale": "table", "color": "#a0522d"}}]), "options": {}},
        {"name": "beside", "spec": spec(uncertainty=["std_error", {"sparkline": {"place": "beside"}}]), "options": {"width": 6.5, "font": 10}},
        {"name": "beside-middle", "spec": spec(uncertainty=["std_error", {"sparkline": {"place": "beside", "align": "middle", "scale": "row"}}]),
         "options": {"width": 7, "font": 9}},
        {"name": "no-estimate", "spec": spec(estimate=False, uncertainty=["std_error", spark]), "options": {"width": 6.5, "font": 10}},
        {"name": "no-head", "spec": spec(head=[], title=None), "options": {"width": 6.5, "font": 10}},
        {"name": "groups", "spec": spec(spanners=[{"label": "OLS", "columns": [1, 2]}], head=["number", "spanner", "response"]),
         "options": {"width": 6.5, "font": 10}},
        {"name": "groups-beside", "spec": spec(spanners=[{"label": "Robust", "columns": [2, 3]}],
                                               uncertainty=["std_error", {"sparkline": {"place": "beside"}}]),
         "options": {"width": 6.5, "font": 10}},
        {"name": "panels", "spec": spec(panels=[
            {"label": "Panel A: weight", "rows": [{"term": "wt", "label": "Weight (1000 lbs)"}], "keep_unlisted": False},
            {"label": "Panel B: horsepower", "rows": [{"term": "hp", "label": "Horsepower"}], "keep_unlisted": False,
             "uncertainty": ["std_error", spark], "stats": [{"metric": "nobs", "label": "N"}]},
        ], stats=[{"metric": "rmse", "label": "RMSE"}, {"label": "Controls", "values": ["No", "No", "qsec"]}]),
         "options": {"width": 6.5, "font": 10}},
    ]


def main(out: Path = HERE) -> None:
    sys.path.insert(0, str(ROOT / "src"))
    from estrec import table as T

    cs = cases()
    for c in cs:
        t = T.build_table(c["spec"], base_dir=EX)
        data = T.render(t, "docx", **c["options"])
        xml = zipfile.ZipFile(BytesIO(data)).read("word/document.xml")
        (out / f"{c['name']}.xml").write_bytes(xml)
    (out / "cases.json").write_text(json.dumps(cs, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main(Path(sys.argv[1]) if len(sys.argv) > 1 else HERE)
