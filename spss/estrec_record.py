"""Record plumbing for the SPSS writer, standalone (SPSS's own Python has no estrec package):
numbers, JSON output, RFC 8785 canonical form and the core digest, ids and times. The
canonical form and digest follow src/estrec/records.py exactly; tests/test_spss.py checks
that the reference package agrees."""

from __future__ import annotations

import hashlib
import json
import math
import os
import uuid
from datetime import datetime, timezone

SCHEMA = "estrec/0.1"
VERSION = "0.1.0"
CORE = ("meta", "specification", "metrics", "parameters", "structures")


def producer() -> dict:
    return {"name": "estrec for SPSS", "version": VERSION}


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def new_id() -> str:
    return str(uuid.uuid4())


def num(x):
    """A number as the format stores it: NaN and infinities as strings, None stays None."""
    if x is None:
        return None
    if isinstance(x, bool):
        return x
    if isinstance(x, int):
        return x
    x = float(x)
    if math.isnan(x):
        return "NaN"
    if math.isinf(x):
        return "Inf" if x > 0 else "-Inf"
    if x.is_integer() and abs(x) < 2**53:
        return x  # keep floats as floats; JSON shows 2.0
    return x


def as_int(x):
    return None if x is None else int(round(float(x)))


def compact(d: dict) -> dict:
    return {k: v for k, v in d.items() if v is not None}


# ---------------------------------------------------------------- RFC 8785


def _es_number(x: float) -> str:
    """ECMAScript Number.prototype.toString, which RFC 8785 prescribes for numbers."""
    if x == 0:
        return "0"
    sign = "-" if x < 0 else ""
    mant, _, exp = repr(abs(x)).partition("e")
    ip, _, fp = mant.partition(".")
    digits = ip + fp
    n = len(ip) + (int(exp) if exp else 0)
    stripped = digits.lstrip("0")
    n -= len(digits) - len(stripped)
    digits = stripped.rstrip("0")
    k = len(digits)
    if k <= n <= 21:
        return sign + digits + "0" * (n - k)
    if 0 < n <= 21:
        return sign + digits[:n] + "." + digits[n:]
    if -6 < n <= 0:
        return sign + "0." + "0" * -n + digits
    e = n - 1
    frac = "." + digits[1:] if k > 1 else ""
    return f"{sign}{digits[0]}{frac}e{'+' if e > 0 else '-'}{abs(e)}"


def _canon(o, out: list) -> None:
    if o is None:
        out.append("null")
    elif o is True:
        out.append("true")
    elif o is False:
        out.append("false")
    elif isinstance(o, int):
        out.append(str(o))
    elif isinstance(o, float):
        if not math.isfinite(o):
            raise ValueError("non-finite number in canonical JSON")
        out.append(_es_number(o))
    elif isinstance(o, str):
        out.append(json.dumps(o, ensure_ascii=False))
    elif isinstance(o, (list, tuple)):
        out.append("[")
        for i, v in enumerate(o):
            if i:
                out.append(",")
            _canon(v, out)
        out.append("]")
    elif isinstance(o, dict):
        out.append("{")
        for i, k in enumerate(sorted(o, key=lambda s: s.encode("utf-16-be"))):
            if i:
                out.append(",")
            out.append(json.dumps(k, ensure_ascii=False))
            out.append(":")
            _canon(o[k], out)
        out.append("}")
    else:
        raise ValueError(f"can't canonicalise {type(o).__name__}")


def canonical_json(obj) -> bytes:
    out: list = []
    _canon(obj, out)
    return "".join(out).encode("utf-8")


def core_digest(rec: dict) -> str:
    view = {k: rec[k] for k in CORE if k in rec}
    if isinstance(view.get("meta"), dict):
        view["meta"] = {k: v for k, v in view["meta"].items() if k != "core_digest"}
    return hashlib.sha256(canonical_json(view)).hexdigest()


def add_digest(rec: dict) -> dict:
    rec["meta"].pop("core_digest", None)
    rec["meta"]["core_digest"] = {"algorithm": "sha256", "canonicalization": "RFC8785",
                                  "value": core_digest(rec)}
    return rec


# ---------------------------------------------------------------- files


def numbered(path: str, n: int) -> list:
    """fit.estrec.json -> fit-1.estrec.json, fit-2.estrec.json, ... (n > 1)."""
    if n == 1:
        return [path]
    for ext in (".estrec.json", ".json"):
        if path.endswith(ext):
            stem = path[: -len(ext)]
            break
    else:
        stem, ext = path, ".estrec.json"
    return [f"{stem}-{i}{ext}" for i in range(1, n + 1)]


def write(rec: dict, path: str) -> str:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(rec, f, indent=1, ensure_ascii=False, allow_nan=False)
        f.write("\n")
    os.replace(tmp, path)
    return path
