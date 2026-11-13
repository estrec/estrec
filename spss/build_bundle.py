"""Builds estrec.spe, the SPSS extension bundle: ESTREC BEGIN and ESTREC END (and the
modules they use). Install in SPSS with Extensions > Install Local Extension Bundle.
Run: python spss/build_bundle.py  ->  spss/dist/estrec.spe"""

import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
VERSION = "0.1.0"
SPECS = ["ESTREC_BEGIN.xml", "ESTREC_END.xml"]
CODE = ["ESTREC_BEGIN.py", "ESTREC_END.py", "estrec_session.py", "estrec_oxml.py",
        "estrec_procedures.py", "estrec_record.py"]
MISC = ["README.md"]

MANIFEST = f"""Manifest-Version: 1.0
Name: estrec
Summary: Write estrec estimation records (JSON) from SPSS procedures
Description: ESTREC BEGIN starts capturing output (with OMS); ESTREC END OUTFILE='fit.estrec.json'
 writes one estrec record per supported procedure run in between: REGRESSION, UNIANOVA,
 LOGISTIC REGRESSION, GENLIN, MIXED, GENLINMIXED. See https://estrec.org
Author: Ted Matherly
Version: {VERSION}
Product-Version: 27.0.0
Command-Specs: {", ".join(SPECS)}
Code-Files: {", ".join(CODE)}
Misc-Files: {", ".join(MISC)}
Plugins: Python
Python-Version: 3
"""


def main():
    out = HERE / "dist" / "estrec.spe"
    out.parent.mkdir(exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("META-INF/MANIFEST.MF", MANIFEST)
        for f in SPECS + CODE + MISC:
            z.write(HERE / f, f)
    print(out)


if __name__ == "__main__":
    main()
