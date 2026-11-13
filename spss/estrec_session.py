"""ESTREC BEGIN / ESTREC END inside SPSS: capture procedures' output with OMS, the way
OMS ... OMSEND does, then write one estrec record per supported procedure.

BEGIN sets OLANG=ENGLISH (the writer reads English table labels) and starts an OMS request
to a temporary OXML file; the Viewer output is unchanged. END stops it, restores OLANG,
reads the file, counts what the tables don't show (MIXED's cases and subject levels), and
writes the records."""

from __future__ import annotations

import os
import re
import tempfile

import estrec_oxml
import estrec_procedures
import estrec_record

TAG = "estrec_capture"
_state: dict = {}


def _spss():
    import spss  # only inside SPSS
    return spss


def _show(setting: str):
    try:
        import spssaux
        return spssaux.getShow(setting)
    except Exception:
        return None


def _version():
    """SPSS's version, e.g. 32.0 (the plug-in reports 'spss320')."""
    v = _raw_version()
    m = re.fullmatch(r"spss(\d+)(\d)", v or "")
    return f"{m[1]}.{m[2]}" if m else v


def _raw_version():
    spss = _spss()
    for f in ("GetSPSSVersion", "GetDefaultPlugInVersion"):
        try:
            v = getattr(spss, f)()
            if v:
                return str(v)
        except Exception:
            pass
    try:
        import spssaux
        return str(spssaux.GetSPSSMajorVersion())
    except Exception:
        return None


def begin() -> None:
    spss = _spss()
    if _state.get("file"):
        print("ESTREC BEGIN: a capture is already running; it is restarted")
        try:
            spss.Submit(f"OMSEND TAG='{TAG}'.")
        except Exception:
            pass
    fd, path = tempfile.mkstemp(prefix="estrec_", suffix=".xml")
    os.close(fd)
    _state.clear()
    _state.update(file=path, olang=_show("OLANG"))
    spss.Submit(["SET OLANG=ENGLISH.",
                 f"OMS /SELECT ALL /DESTINATION FORMAT=OXML OUTFILE='{path}' VIEWER=YES /TAG='{TAG}'."])
    print("ESTREC BEGIN: capturing output for estrec records (ESTREC END writes them)")


def _count_cases(cmd_syntax: str, subject_vars: list) -> dict:
    """Cases with no missing value in the variables a command names, and the levels of each
    subject variable among them. Honours the active filter (spss.Cursor skips filtered cases)."""
    spss = _spss()
    names = [spss.GetVariableName(i) for i in range(spss.GetVariableCount())]
    lower = {n.lower(): n for n in names}
    words = re.findall(r"[A-Za-z@#$][\w.@#$]*", cmd_syntax)
    used = []
    for w in words:
        n = lower.get(w.lower())
        if n and n not in used:
            used.append(n)
    if not used:
        return {}
    idx = [names.index(n) for n in used]
    cur = spss.Cursor(idx)
    n_ok, levels = 0, {s: set() for s in subject_vars if s in used}
    try:
        for row in cur.fetchall():
            if any(v is None or v == "" for v in row):
                continue
            n_ok += 1
            for s in levels:
                levels[s].add(row[used.index(s)])
    finally:
        cur.close()
    return {"nobs": n_ok, "levels": {s: len(v) for s, v in levels.items()}}


def end(outfile: str, title: str | None = None, identifying: bool = False) -> list:
    spss = _spss()
    path = _state.get("file")
    if not path:
        raise RuntimeError("ESTREC END without ESTREC BEGIN")
    spss.Submit(f"OMSEND TAG='{TAG}'.")
    if _state.get("olang"):
        spss.Submit(f"SET OLANG={_state['olang']}.")
    _state.clear()
    try:
        commands = estrec_oxml.parse(path)
    finally:
        try:
            os.remove(path)
        except OSError:
            pass
    per_cmd = []
    for c in commands:
        h = {}
        if c.name == "Mixed":
            nt = estrec_procedures.notes(c)
            syn = nt.get("syntax") or ""
            subj = re.findall(r"SUBJECT\s*\(\s*([^)]+?)\s*\)", syn, re.I)
            subj = [s for part in subj for s in re.split(r"[\s*]+", part) if s]
            try:
                h = _count_cases(syn.split("/")[0] + " " + " ".join(subj), subj)
            except Exception as e:  # noqa: BLE001
                print(f"ESTREC END: couldn't count MIXED's cases ({e})")
        per_cmd.append(h)
    hints = {"spss_version": _version(), "by_command": per_cmd}
    recs, skipped = estrec_procedures.records(commands, hints, identifying=identifying)
    if title:
        for r in recs:
            r["meta"]["title"] = title
            estrec_record.add_digest(r)
    paths = estrec_record.numbered(outfile, len(recs)) if recs else []
    for r, p in zip(recs, paths):
        estrec_record.write(r, p)
    for p, r in zip(paths, recs):
        print(f"ESTREC END: wrote {p} ({r['meta']['title']})")
    for s in skipped:
        if not s.startswith(("Notes", "Descriptives")):
            print(f"ESTREC END: no record for {s}")
    if not recs:
        print("ESTREC END: no supported procedure ran between ESTREC BEGIN and ESTREC END")
    return paths
