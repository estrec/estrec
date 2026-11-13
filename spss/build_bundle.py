"""Builds estrec.spe, the SPSS extension bundle: ESTREC BEGIN and ESTREC END (and the
modules they use). Install in SPSS with Extensions > Install Local Extension Bundle.
Run: python spss/build_bundle.py  ->  spss/estrec.spe (committed: the front page links to it;
tests/test_spss.py fails when it is out of date with the files here)."""

import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
VERSION = "0.1.0"
SPECS = ["ESTREC_BEGIN.xml", "ESTREC_END.xml", "ESTREC_WRITE.xml"]
CODE = ["ESTREC_BEGIN.py", "ESTREC_END.py", "ESTREC_WRITE.py", "estrec_session.py", "estrec_oxml.py",
        "estrec_procedures.py", "estrec_record.py"]
MISC: list = []  # SPSS's own bundles carry no Misc-Files

FIELDS = [
    ("Name", "ESTREC"),
    ("Display-Name", "estrec"),
    ("Command-Specs", ",".join(SPECS)),
    ("Code-Files", ",".join(CODE)),
    ("Summary", "Write estrec estimation records (JSON) from SPSS procedures"),
    ("Description", "ESTREC BEGIN starts capturing output (with OMS); ESTREC END OUTFILE= writes one "
                    "estrec record per REGRESSION, UNIANOVA, LOGISTIC REGRESSION, GENLIN, MIXED or "
                    "GENLINMIXED run in between. See https://estrec.org"),
    ("Author", "Ted Matherly"),
    ("Version", VERSION),
    ("Product-Version", "27"),
    ("Translation-Catalogues", ""),
]


def manifest_line(key: str, value: str) -> str:
    """A Java manifest header: lines of at most 72 bytes, continuations start with a space
    (the form SPSS's own Create Extension Bundle writes)."""
    raw = f"{key}: {value}".encode("utf-8")
    out = [raw[:72]]
    raw = raw[72:]
    while raw:
        out.append(b" " + raw[:71])
        raw = raw[71:]
    return "\n".join(b.decode("utf-8") for b in out) + "\n"


MANIFEST = "".join(manifest_line(k, v) for k, v in FIELDS)


def main():
    out = HERE / "estrec.spe"
    # fixed timestamps, so the bundle only changes when its files do
    def add(z, name, data):
        info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        z.writestr(info, data)
    with zipfile.ZipFile(out, "w") as z:
        add(z, "META-INF/MANIFEST.MF", MANIFEST)
        for f in SPECS + CODE:
            add(z, f, (HERE / f).read_bytes())
    print(out)


if __name__ == "__main__":
    main()
