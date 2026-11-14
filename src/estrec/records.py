# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Ted Matherly and the estrec contributors
"""Read, write, validate and redact estrec records (spec/estrec.md).

One record describes one estimation run as a JSON object. This module uses only
the standard library. It accepts numpy arrays and scalars without importing numpy,
writes spilled matrices and tables as Parquet when pyarrow is installed (JSON
otherwise), and validates against the JSON Schemas when jsonschema is installed.

    write(record, path)       spill large structures, add the core digest, check sizes
    read(path)                load, decoding "NaN"/"Inf"/"-Inf" in numeric fields
    validate(record)          core rules, sizes, digest, profiles, optional JSON Schema
    redact(record)            remove or HMAC the identifying fields
    core_digest(record)       sha256 over the RFC 8785 canonical form of the result sections

The JSON Schemas ship in the package (estrec/schema/: catalog.json, the core,
the profiles), and draft profiles can be added from local folders
($ESTREC_SCHEMA_PATH). `validate` checks the core schema plus each profile the record
claims, and compares the record with the profiles those build on; `redact` takes the
fields marked `x-identifying` in the core and each claimed profile. Without the
`jsonschema` package (`pip install 'estrec[jsonschema]'`), `validate` falls back
to built-in checks and says so.

Command line: `estimation {validate,redact,digest} ...` (also `python -m estrec`);
each command also takes collections (collection.py).
"""

from __future__ import annotations

import argparse
import copy
import datetime as _dt
import functools
import hashlib
import hmac
import json
import math
import os
import re
import sys
import uuid
import warnings
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urljoin

SCHEMA = "estrec/0.1"
WARN_BYTES = 1_000_000  # whole record
WARN_ELEMENTS = 10_000  # one array (nested lists count their leaves)
FAIL_BYTES = 16_000_000

REQUIRED = ("schema", "meta", "parameters")
EXPECTED = ("metrics", "specification", "provenance")
OPTIONAL = ("structures", "tests", "publication", "validation", "attachments", "extensions", "history")
# Sections covered by meta.core_digest (meta without the digest itself)
CORE = ("meta", "specification", "metrics", "parameters", "structures")
STATUSES = ("ok", "warning", "failed")
STRUCTURE_KINDS = ("matrix", "table", "tree", "series", "object", "link")
NONFINITE = {"NaN": math.nan, "Inf": math.inf, "-Inf": -math.inf}
# parameters columns that hold text; every other column is numeric for decoding
TEXT_COLUMNS = {"term", "canonical", "response", "component", "group", "dropped", "label"}

# Identifying fields when the schemas aren't used: what the core schema marks "x-identifying"
# (tests/test_schema.py keeps the two equal). `*` matches any key of a dict, `[*]` any item
# of a list. Content hashes are not identifying and stay.
DEFAULT_IDENTIFYING = (
    "provenance.agent",
    "provenance.environment.host",
    "provenance.environment.hostname",
    "provenance.execution.invocation.command_line",
    "provenance.execution.invocation.argv",
    "provenance.execution.invocation.script_path",
    "provenance.execution.invocation.working_directory",
    "provenance.execution.scheduler.JobID",
    "provenance.execution.scheduler.JobName",
    "provenance.execution.scheduler.Account",
    "provenance.execution.scheduler.User",
    "provenance.execution.scheduler.NodeList",
    "provenance.execution.scheduler.SubmitLine",
    "provenance.execution.scheduler.WorkDir",
    "provenance.execution.workers[*].host",
    "provenance.data[*].location",
    "provenance.software[*].lock.path",
    "provenance.software[*].container.path",
)


class EstimationError(ValueError):
    """A record that can't be written or read as an estrec record."""


@dataclass(frozen=True)
class Issue:
    level: str  # "error", "warning" or "info"
    path: str
    message: str

    def __str__(self) -> str:
        return f"{self.level}: {self.path or '(record)'}: {self.message}"


def _now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _producer() -> dict:
    from . import __version__

    return {"name": "estrec", "version": __version__}


# ---------------------------------------------------------------- encoding


def to_json(obj: Any) -> Any:
    """A copy of `obj` made of JSON types: numpy arrays and scalars converted, non-finite
    floats as the strings "NaN"/"Inf"/"-Inf", datetimes as ISO 8601 UTC, paths as strings."""
    if obj is None or isinstance(obj, (bool, str)):
        return obj
    if isinstance(obj, int):
        return int(obj)
    if isinstance(obj, float):
        if math.isnan(obj):
            return "NaN"
        if math.isinf(obj):
            return "Inf" if obj > 0 else "-Inf"
        return float(obj)
    if isinstance(obj, dict):
        return {str(k): to_json(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [to_json(v) for v in obj]
    if isinstance(obj, _dt.datetime):
        if obj.tzinfo is None:
            raise EstimationError(f"naive datetime {obj!r}: times must be timezone-aware (UTC)")
        return obj.astimezone(_dt.timezone.utc).isoformat().replace("+00:00", "Z")
    if isinstance(obj, os.PathLike):
        return os.fspath(obj)
    if hasattr(obj, "tolist"):  # numpy arrays and scalars, without importing numpy
        return to_json(obj.tolist())
    raise EstimationError(f"can't encode {type(obj).__name__} as JSON")


def _decode(v: Any) -> Any:
    if isinstance(v, str):
        return NONFINITE.get(v, v)
    if isinstance(v, list):
        return [_decode(x) for x in v]
    return v


def decode_nonfinite(record: dict) -> dict:
    """A copy with "NaN"/"Inf"/"-Inf" turned into floats where the format puts numbers:
    metric values, numeric parameters columns and matrix data. Text fields are left as is,
    so a term named "Inf" stays a string."""
    rec = copy.deepcopy(record)
    metrics = rec.get("metrics")
    if isinstance(metrics, dict):
        for k, v in metrics.items():
            if isinstance(v, dict) and "value" in v:
                v["value"] = _decode(v["value"])
            else:
                metrics[k] = _decode(v)
    for row in rec.get("parameters") or []:
        if isinstance(row, dict):
            for k, v in row.items():
                if k not in TEXT_COLUMNS:
                    row[k] = _decode(v)
    for s in _structures(rec):
        if s.get("kind") == "matrix" and "data" in s:
            s["data"] = _decode(s["data"])
    return rec


def _dumps(record: dict, indent: int | None = None) -> str:
    return json.dumps(record, ensure_ascii=False, allow_nan=False, indent=indent)


def _reject_constant(name: str):
    raise EstimationError(f"bare {name} in JSON; the format writes non-finite values as strings")


# ---------------------------------------------------------------- RFC 8785 canonical JSON


def _es_number(x: float) -> str:
    """ECMAScript Number.prototype.toString, which RFC 8785 prescribes for numbers."""
    if x == 0:
        return "0"
    sign = "-" if x < 0 else ""
    mant, _, exp = repr(abs(x)).partition("e")  # repr is the shortest round-trip form
    ip, _, fp = mant.partition(".")
    digits = ip + fp
    n = len(ip) + (int(exp) if exp else 0)  # decimal point after n digits
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


def _canon(o: Any, out: list[str]) -> None:
    if o is None:
        out.append("null")
    elif o is True:
        out.append("true")
    elif o is False:
        out.append("false")
    elif isinstance(o, int):
        if abs(o) > 2**53:
            raise EstimationError(f"integer {o} is outside the IEEE double range RFC 8785 allows")
        out.append(str(o))
    elif isinstance(o, float):
        if not math.isfinite(o):
            raise EstimationError("non-finite number in canonical JSON; encode it with to_json first")
        out.append(_es_number(o))
    elif isinstance(o, str):
        out.append(json.dumps(o, ensure_ascii=False))
    elif isinstance(o, list):
        out.append("[")
        for i, v in enumerate(o):
            if i:
                out.append(",")
            _canon(v, out)
        out.append("]")
    elif isinstance(o, dict):
        out.append("{")
        # keys sorted by their UTF-16 code units
        for i, k in enumerate(sorted(o, key=lambda s: s.encode("utf-16-be"))):
            if i:
                out.append(",")
            out.append(json.dumps(k, ensure_ascii=False))
            out.append(":")
            _canon(o[k], out)
        out.append("}")
    else:
        raise EstimationError(f"can't canonicalise {type(o).__name__}")


def canonical_json(obj: Any) -> bytes:
    """RFC 8785 (JSON Canonicalization Scheme) serialisation of a JSON value, as UTF-8."""
    out: list[str] = []
    _canon(obj, out)
    return "".join(out).encode("utf-8")


# ---------------------------------------------------------------- core digest


def core_digest(record: dict) -> str:
    """sha256 (hex) of the canonical form of the result sections: `meta` without
    `core_digest`, `specification`, `metrics`, `parameters`, `structures`. Absent sections
    are left out, so adding a section later changes the digest."""
    rec = to_json(record)
    view = {k: rec[k] for k in CORE if k in rec}
    if isinstance(view.get("meta"), dict):
        view["meta"] = {k: v for k, v in view["meta"].items() if k != "core_digest"}
    return hashlib.sha256(canonical_json(view)).hexdigest()


def add_digest(record: dict) -> dict:
    """Set `meta.core_digest` in place and return the record."""
    record.setdefault("meta", {})["core_digest"] = {
        "algorithm": "sha256",
        "canonicalization": "RFC8785",
        "value": core_digest(record),
    }
    return record


def check_digest(record: dict) -> bool | None:
    """True if `meta.core_digest` matches the record, False if not, None if absent."""
    d = (record.get("meta") or {}).get("core_digest")
    if d is None:
        return None
    if not isinstance(d, dict) or d.get("algorithm") != "sha256":
        return False
    return hmac.compare_digest(str(d.get("value", "")), core_digest(record))


# ---------------------------------------------------------------- sizes


def count_elements(v: Any) -> int:
    """Elements of an array as the size limits count them: items of a list, with nested
    lists counted by their leaves (a 100 x 100 matrix is 10,000). Dicts count as one."""
    if isinstance(v, list):
        return sum(count_elements(x) if isinstance(x, list) else 1 for x in v)
    return 1


def _large_arrays(v: Any, path: str, limit: int) -> Iterable[tuple[str, int]]:
    """Outermost arrays above `limit` elements, with their paths."""
    if isinstance(v, list):
        n = count_elements(v)
        if n > limit:
            yield path, n
            return
        for i, x in enumerate(v):
            yield from _large_arrays(x, f"{path}[{i}]", limit)
    elif isinstance(v, dict):
        for k, x in v.items():
            yield from _large_arrays(x, f"{path}.{k}" if path else k, limit)


# ---------------------------------------------------------------- attachments and spilling

# Fields of a structure that hold its data; everything else (type, ssc, cluster, ...) stays
# in the record when the structure is spilled, so profiles can still check it.
_DATA_FIELDS = {
    "matrix": ("labels", "row_labels", "col_labels", "data"),
    "table": ("columns", "rows"),
    "series": ("index", "values"),
}


def _structures(record: dict) -> Iterable[dict]:
    for v in (record.get("structures") or {}).values():
        for s in v if isinstance(v, list) else [v]:
            if isinstance(s, dict):
                yield s


def _structure_slots(record: dict) -> list[tuple[str, dict, Any, Any]]:
    """(id, structure, container, key) for every structure not yet spilled."""
    slots: list[tuple[str, dict, Any, Any]] = []
    structures = record.get("structures") or {}
    for name, v in structures.items():
        if isinstance(v, list):
            slots += [
                (f"{name}_{i}", s, v, i)
                for i, s in enumerate(v)
                if isinstance(s, dict) and s.get("kind") != "link"
            ]
        elif isinstance(v, dict) and v.get("kind") != "link":
            slots.append((name, v, structures, name))
    return slots


def _data_of(s: dict) -> dict:
    fields = _DATA_FIELDS.get(s.get("kind", ""))
    if fields is None:  # tree, object, unknown: the whole structure is data
        return {k: v for k, v in s.items() if k != "kind"}
    return {k: s[k] for k in fields if k in s}


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _write_spill(s: dict, data: dict, path_stem: Path) -> tuple[Path, dict]:
    """Write a structure's data; Parquet for matrices and tables (when pyarrow is
    installed), JSON otherwise."""
    kind = s.get("kind")
    try:
        import pyarrow as pa
        import pyarrow.parquet as pq
    except ImportError:
        kind = None
    if kind in ("matrix", "table"):
        try:
            if kind == "matrix":
                rows = data.get("data", [])
                labels = data.get("row_labels") or data.get("labels") or [None] * len(rows)
                table = pa.table(
                    {
                        "label": pa.array(labels, pa.string()),
                        "row": pa.array(_decode(rows), pa.list_(pa.float64())),
                    }
                )
                extra = {k: data[k] for k in ("labels", "col_labels") if k in data}
                table = table.replace_schema_metadata({"estrec": json.dumps(extra)})
            else:
                cols = data.get("columns", [])
                rows = data.get("rows", [])
                table = pa.table({c: [r[j] for r in rows] for j, c in enumerate(cols)})
            path = path_stem.with_suffix(".parquet")
            pq.write_table(table, path)
            return path, {
                "media_type": "application/vnd.apache.parquet",
                "rows": table.num_rows,
                "columns": table.column_names,
            }
        except (pa.ArrowInvalid, pa.ArrowTypeError):
            pass  # mixed column types: fall back to JSON
    path = path_stem.with_suffix(".json")
    path.write_text(_dumps(data), encoding="utf-8")
    return path, {"media_type": "application/json"}


def spill(
    record: dict,
    directory: str | os.PathLike,
    stem: str,
    max_elements: int = WARN_ELEMENTS,
    max_bytes: int = WARN_BYTES,
) -> list[str]:
    """Move large structures into side files in `directory` and leave links, in place.

    A structure goes out if one of its arrays has more than `max_elements` elements; then,
    while the record is still above `max_bytes`, the largest remaining one goes. Only the
    data fields move (a vcov keeps its type, ssc and cluster in the record). Returns the
    ids of the new attachments. `record` must already be JSON-encoded (`to_json`)."""
    directory = Path(directory)
    attachments = record.setdefault("attachments", [])
    taken = {a.get("id") for a in attachments if isinstance(a, dict)}
    done: list[str] = []

    def out(sid: str, s: dict, container: Any, key: Any) -> None:
        aid, i = sid, 1
        while aid in taken:
            i += 1
            aid = f"{sid}_{i}"
        taken.add(aid)
        data = _data_of(s)
        path, info = _write_spill(s, data, directory / f"{stem}.{aid}")
        attachments.append(
            {
                "id": aid,
                "role": "structure",
                "path": path.name,
                "created": _now(),
                "sha256": _sha256_file(path),
                "bytes": path.stat().st_size,
                **info,
            }
        )
        link = {k: v for k, v in s.items() if k not in data}
        link.update({"kind": "link", "attachment": aid, "spilled_kind": s.get("kind")})
        container[key] = link
        done.append(aid)

    for sid, s, container, key in _structure_slots(record):
        if any(True for _ in _large_arrays(_data_of(s), "", max_elements)):
            out(sid, s, container, key)
    while len(_dumps(record).encode()) > max_bytes:
        slots = _structure_slots(record)
        if not slots:
            break
        out(*max(slots, key=lambda t: len(_dumps(t[1]))))
    if not attachments:
        del record["attachments"]
    return done


def attachment(record: dict, aid: str) -> dict:
    for a in record.get("attachments") or []:
        if isinstance(a, dict) and a.get("id") == aid:
            return a
    raise KeyError(f"no attachment {aid!r}")


def attachment_path(record_path: str | os.PathLike, att: dict) -> Path:
    """Where an attachment's file is: `path` is relative to the record's folder."""
    p = Path(att["path"])
    return p if p.is_absolute() else Path(record_path).parent / p


def load_structure(record_path: str | os.PathLike, record: dict, link: dict, verify: bool = True) -> dict:
    """Rebuild a spilled structure from its link and attachment file."""
    att = attachment(record, link["attachment"])
    path = attachment_path(record_path, att)
    if verify and att.get("sha256") and _sha256_file(path) != att["sha256"]:
        raise EstimationError(f"{path}: sha256 does not match attachment {att['id']!r}")
    s = {k: v for k, v in link.items() if k not in ("kind", "attachment", "spilled_kind")}
    s["kind"] = link.get("spilled_kind", "object")
    if path.suffix == ".parquet":
        import pyarrow.parquet as pq

        t = pq.read_table(path)
        if s["kind"] == "matrix":
            extra = json.loads((t.schema.metadata or {}).get(b"estrec", b"{}"))
            s.update(extra)
            s["data"] = t.column("row").to_pylist()
            if "labels" not in extra:
                s["row_labels"] = t.column("label").to_pylist()
        else:
            s["columns"] = t.column_names
            s["rows"] = [list(r.values()) for r in t.to_pylist()]
    else:
        s.update(json.loads(path.read_text(encoding="utf-8")))
    return s


# ---------------------------------------------------------------- writer and reader


def new_record(
    parameters: list[dict],
    *,
    estimator: dict | None = None,
    responses: list[str] | None = None,
    profiles: list[str] | None = None,
    **sections: Any,
) -> dict:
    """A record skeleton with `schema` and `meta` (id, created, status) filled."""
    meta: dict[str, Any] = {"id": str(uuid.uuid4()), "created": _now(), "status": "ok"}
    if estimator is not None:
        meta["estimator"] = estimator
    if responses is not None:
        meta["responses"] = responses
    if profiles is not None:
        meta["profiles"] = profiles
    meta.update(sections.pop("meta", {}))
    return {"schema": SCHEMA, "meta": meta, "parameters": parameters, **sections}


def prepare(
    record: dict,
    *,
    digest: bool = True,
    redact_identifying: bool | Iterable[str] = False,
    by: dict | None = None,
    level: int | None = None,
    purpose: str | Iterable[str] | None = None,
    schema: Schemas | str | None = "auto",
    _digest_later: bool = False,
) -> dict:
    """The record as it would be written, without spilling: encoded, `schema`, `meta.id`
    and `meta.created` filled if missing, cut to a disclosure level, optionally redacted,
    history and digest added.

    `level` (1-5, spec 4.9) is the most the record discloses: fields above it are left out,
    claims of model profiles that then fail are dropped, and `meta.disclosure` records it.
    The default is the lowest level that meets every `purpose`, else DEFAULT_LEVEL (4); a
    record that already declares a lower level keeps it. `purpose` names purpose profiles
    the record must meet: they are added to `meta.profiles`, and a level below one's
    `x-min-level`, or a record that falls short of one, raises EstimationError naming the
    fields. At level 1 `meta.created` and the history entry's time are dates, and below 4
    the history entry doesn't name the writer.

    `redact_identifying=True` removes the fields `redact` finds; a list of paths removes
    those instead (a tool can add its own extension's fields this way)."""
    rec = to_json(record)
    rec.setdefault("schema", SCHEMA)
    meta = rec.setdefault("meta", {})
    meta.setdefault("id", str(uuid.uuid4()))
    schemas = _schemas_or_none(schema)
    purposes = [purpose] if isinstance(purpose, str) else list(purpose or [])
    for p in purposes:
        if schemas is None or p not in schemas.profiles:
            raise EstimationError(f"purpose {p!r}: no such profile")
        if not is_purpose(p, schemas):
            raise EstimationError(f"purpose {p!r} is a {_kind(p, schemas)} profile, not a purpose profile")
    need = max((min_level(p, schemas) for p in purposes), default=1) if schemas else 1
    if level is None:
        level = need if purposes else DEFAULT_LEVEL
    if level not in LEVELS:
        raise EstimationError(f"disclosure level must be one of 1-5, got {level!r}")
    if level < need:
        raise EstimationError(
            f"disclosure level {level} is below the {need} that {', '.join(purposes)} needs"
        )
    level = min(level, _declared_level(rec) or level)
    if purposes:
        meta["profiles"] = list(dict.fromkeys([*(meta.get("profiles") or []), *purposes]))
    if "created" not in meta:
        meta["created"] = _now()[:10] if level == 1 else _now()
    meta["disclosure"] = {"level": level}
    _, dropped = _apply_level(rec, level, schemas)
    for p in dropped:
        warnings.warn(f"{p} isn't claimed: disclosure level {level} leaves out what it requires")
    for p in purposes:
        trial = copy.deepcopy(rec)
        if digest or _digest_later:  # judged as written: with the digest it will carry
            add_digest(trial)
        errs = _profile_errors(trial, p, schemas)
        if errs:
            raise EstimationError(
                f"the record doesn't meet {p} at disclosure level {level}: " + "; ".join(map(str, errs))
            )
    entry: dict[str, Any] = {"when": _now() if level > 1 else _now()[:10]}
    if level >= 4:
        entry["by"] = by or _producer()
    entry.update(action="created", level=level)
    if level >= 2:
        entry["sections"] = [k for k in (*REQUIRED, *EXPECTED, *OPTIONAL) if k in rec and k != "schema"]
    rec.setdefault("history", []).append(entry)
    if redact_identifying is True:
        rec = redact(rec, by=by)
    elif redact_identifying:
        rec = redact(rec, paths=list(redact_identifying), by=by)
    if digest:
        add_digest(rec)
    else:
        meta.pop("core_digest", None)
    return rec


def write(
    record: dict,
    path: str | os.PathLike,
    *,
    digest: bool = True,
    spill_large: bool = True,
    redact_identifying: bool | Iterable[str] = False,
    by: dict | None = None,
    indent: int | None = 1,
    level: int | None = None,
    purpose: str | Iterable[str] | None = None,
) -> dict:
    """Write `record` to `path` (`<name>.estrec.json`) and return it as written.

    Large structures are spilled to side files next to it (`spill`), the core digest is
    computed after spilling (on by default), and the size limits are applied: a warning
    above 1 MB or 10,000 elements in one array, an error above 16 MB. `redact_identifying`,
    `level` (default 4) and `purpose` are as in `prepare`."""
    path = Path(path)
    rec = prepare(
        record,
        digest=False,
        redact_identifying=redact_identifying,
        by=by,
        level=level,
        purpose=purpose,
        _digest_later=digest,
    )
    if spill_large:
        stem = path.name.removesuffix(".json").removesuffix(".estrec")
        spill(rec, path.parent, stem)
    if digest:
        add_digest(rec)
    text = _dumps(rec, indent)
    size = len(text.encode())
    if size > FAIL_BYTES:
        raise EstimationError(f"{path}: record is {size:,} bytes, above the {FAIL_BYTES:,} byte limit")
    for issue in _size_issues(rec, size):
        warnings.warn(f"{path}: {issue}")
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text + "\n", encoding="utf-8")
    os.replace(tmp, path)
    return rec


def loads(text: str | bytes, *, nonfinite: str = "float") -> dict:
    rec = json.loads(text, parse_constant=_reject_constant)
    if not isinstance(rec, dict):
        raise EstimationError("an estimation record is a JSON object")
    if nonfinite == "float":
        return decode_nonfinite(rec)
    if nonfinite != "string":
        raise ValueError("nonfinite must be 'float' or 'string'")
    return rec


def read(path: str | os.PathLike, *, nonfinite: str = "float", check: bool = False) -> dict:
    """Load a record. Non-finite values come back as floats in numeric fields (`"string"`
    keeps them as written). With `check=True`, raise if `validate` finds an error."""
    rec = loads(Path(path).read_bytes(), nonfinite="string")
    if check:
        errors = [i for i in validate(rec, base_dir=Path(path).parent) if i.level == "error"]
        if errors:
            raise EstimationError(f"{path}: " + "; ".join(map(str, errors)))
    return decode_nonfinite(rec) if nonfinite == "float" else rec


# ---------------------------------------------------------------- validator


def _is_number(v: Any) -> bool:
    return (isinstance(v, (int, float)) and not isinstance(v, bool)) or v in NONFINITE


def _size_issues(rec: dict, size: int) -> list[Issue]:
    issues = []
    if size > FAIL_BYTES:
        issues.append(Issue("error", "", f"{size:,} bytes, above the {FAIL_BYTES:,} byte limit"))
    elif size > WARN_BYTES:
        big = max((k for k in rec if k != "schema"), key=lambda k: len(_dumps(rec[k]).encode()), default="")
        issues.append(Issue("warning", "", f"{size:,} bytes, above {WARN_BYTES:,}; largest section {big!r}"))
    for p, n in _large_arrays(rec, "", WARN_ELEMENTS):
        issues.append(Issue("warning", p, f"{n:,} elements, above {WARN_ELEMENTS:,}; use an attachment"))
    return issues


def _check_core(rec: dict, structural: bool = True) -> list[Issue]:
    """Checks JSON Schema can't express (expected sections, cross-references, duplicate
    ids), plus, when `structural` (no schema in use), the core's shape by hand."""
    issues: list[Issue] = []

    def err(p: str, m: str) -> None:
        if structural:
            issues.append(Issue("error", p, m))

    xerr = lambda p, m: issues.append(Issue("error", p, m))  # always: the schema can't check these
    warn = lambda p, m: issues.append(Issue("warning", p, m))
    schema = rec.get("schema")
    if not isinstance(schema, str) or not schema.startswith("estrec/"):
        err("schema", f"expected 'estrec/<version>', got {schema!r}")
    elif schema != SCHEMA:
        warn("schema", f"{schema} is not {SCHEMA}; checked as {SCHEMA}")
    for k in REQUIRED:
        if k not in rec:
            err(k, "required section missing")
    for k in EXPECTED:
        if k not in rec:
            warn(k, "expected section missing")
    for k in rec:
        if k not in (*REQUIRED, *EXPECTED, *OPTIONAL):
            warn(k, "unknown section (tool-specific content belongs in extensions)")

    meta = rec.get("meta")
    if "meta" in rec and not isinstance(meta, dict):
        err("meta", "must be an object")
        meta = {}
    meta = meta or {}
    for k in ("id", "created", "status"):
        if "meta" in rec and k not in meta:
            err(f"meta.{k}", "required")
    if "status" in meta and meta["status"] not in STATUSES:
        err("meta.status", f"must be one of {', '.join(STATUSES)}")
    for k in ("profiles", "responses", "tags", "messages"):
        if k in meta and not isinstance(meta[k], list):
            err(f"meta.{k}", "must be a list")
    if "estimator" in meta and not isinstance(meta["estimator"], dict):
        err("meta.estimator", "must be an object ({family, method, ...})")

    params = rec.get("parameters")
    if "parameters" in rec:
        if not isinstance(params, list):
            err("parameters", "must be a list of rows")
        else:
            for i, row in enumerate(params):
                if not isinstance(row, dict):
                    err(f"parameters[{i}]", "must be an object")
                elif not isinstance(row.get("term"), str):
                    err(f"parameters[{i}].term", "required string")
                elif "canonical" in row and not isinstance(row["canonical"], dict):
                    err(f"parameters[{i}].canonical", "must be an object ({name, factors})")

    metrics = rec.get("metrics")
    if "metrics" in rec:
        if not isinstance(metrics, dict):
            err("metrics", "must be a flat object of scalars")
        else:
            for k, v in metrics.items():
                if isinstance(v, dict):
                    if "value" not in v:
                        err(f"metrics.{k}", "an object metric needs 'value'")
                elif v is not None and not _is_number(v) and not isinstance(v, (str, bool)):
                    err(f"metrics.{k}", "must be a scalar or {value, definition, ...}")

    for k in ("specification", "provenance", "publication", "validation", "structures", "extensions"):
        if k in rec and not isinstance(rec[k], dict):
            err(k, "must be an object")

    att_ids = set()
    if "attachments" in rec:
        if not isinstance(rec["attachments"], list):
            err("attachments", "must be a list")
        else:
            for i, a in enumerate(rec["attachments"]):
                if not isinstance(a, dict) or not a.get("id") or not a.get("path"):
                    err(f"attachments[{i}]", "needs 'id' and 'path'")
                    continue
                if a["id"] in att_ids:
                    xerr(f"attachments[{i}].id", f"duplicate id {a['id']!r}")
                att_ids.add(a["id"])
                if "sha256" not in a:
                    warn(f"attachments[{i}]", "no sha256: a file found later can't be checked")

    for name, v in (rec.get("structures") or {}).items() if isinstance(rec.get("structures"), dict) else []:
        items = v if isinstance(v, list) else [v]
        for i, s in enumerate(items):
            p = f"structures.{name}" + (f"[{i}]" if isinstance(v, list) else "")
            if not isinstance(s, dict):
                err(p, "must be an object with 'kind'")
            elif s.get("kind") not in STRUCTURE_KINDS:
                if not structural:
                    continue
                err(f"{p}.kind", f"must be one of {', '.join(STRUCTURE_KINDS)}")
            elif s["kind"] == "link" and s.get("attachment") not in att_ids:
                xerr(f"{p}.attachment", f"no attachment with id {s.get('attachment')!r}")

    issues += _check_tests(rec, err, xerr, warn)

    for ns, block in (rec.get("extensions") or {}).items() if isinstance(rec.get("extensions"), dict) else []:
        if not isinstance(block, dict):
            err(f"extensions.{ns}", "must be an object")
        elif "schema" not in block:
            warn(f"extensions.{ns}", "no 'schema' naming the schema that validates this block")

    if "history" in rec:
        if not isinstance(rec["history"], list):
            err("history", "must be a list")
        else:
            # below level 4 the writer withholds `by` (spec 4.9)
            need = {"when", "action"} | ({"by"} if (_declared_level(rec) or 5) >= 4 else set())
            for i, h in enumerate(rec["history"]):
                if not isinstance(h, dict) or not need <= h.keys():
                    warn(f"history[{i}]", "needs " + " and ".join(f"'{k}'" for k in sorted(need)))
    return issues


def _check_tests(rec: dict, err, xerr, warn) -> list[Issue]:
    """`tests`: shape (when no schema is in use), unique ids, and references to parameters
    and vcovs that must resolve. Problems are reported through the callbacks."""
    if "tests" not in rec:
        return []
    tests = rec["tests"]
    if not isinstance(tests, list):
        err("tests", "must be a list")
        return []
    terms = {r.get("term") for r in rec.get("parameters") or [] if isinstance(r, dict)}
    v = (rec.get("structures") or {}).get("vcov") if isinstance(rec.get("structures"), dict) else None
    vcovs = [x for x in (v if isinstance(v, list) else [v]) if isinstance(x, dict)]
    ids: set = set()
    for i, t in enumerate(tests):
        p = f"tests[{i}]"
        if not isinstance(t, dict):
            err(p, "must be an object")
            continue
        if not isinstance(t.get("name"), str):
            err(f"{p}.name", "required string")
        if "statistic" not in t and "p_value" not in t:
            err(p, "needs 'statistic' or 'p_value'")
        if "id" in t:
            if t["id"] in ids:
                xerr(f"{p}.id", f"duplicate id {t['id']!r}")
            ids.add(t["id"])
        hyp = t.get("hypothesis") if isinstance(t.get("hypothesis"), dict) else {}
        named = list(hyp.get("terms") or []) + list(t.get("terms") or [])
        r = hyp.get("restrictions")
        if isinstance(r, dict):
            labels, R, q = r.get("labels") or [], r.get("R") or [], r.get("q") or []
            named += list(labels)
            if len(R) != len(q) or any(not isinstance(row, list) or len(row) != len(labels) for row in R):
                xerr(f"{p}.hypothesis.restrictions", "R must be len(q) rows of len(labels) columns")
        missing = sorted({n for n in named if isinstance(n, str)} - terms)
        if missing and terms:
            warn(f"{p}", f"terms not in parameters: {', '.join(missing)}")
        tv = t.get("vcov")
        if tv is not None and vcovs:
            want = tv if isinstance(tv, dict) else {"type": tv}
            match = [
                x
                for x in vcovs
                if x.get("type") == want.get("type")
                and ("cluster" not in want or list(x.get("cluster") or []) == list(want["cluster"]))
            ]
            if not match:
                warn(
                    f"{p}.vcov",
                    f"no structures.vcov entry with type {want.get('type')!r}"
                    + (f" and cluster {want['cluster']}" if "cluster" in want else ""),
                )
    return []


def add_test(record: dict, test: dict, *, by: dict | None = None) -> dict:
    """Append one test to `record["tests"]` in place and return the record.

    `tests` is append-only and outside the core digest, so adding a test after the record
    was written keeps the digest valid. The test gets an `id` (`t<n>`) if it has none and
    `added`; a history entry records the extension."""
    tests = record.setdefault("tests", [])
    if not isinstance(tests, list):
        raise EstimationError("record['tests'] must be a list")
    t = to_json(dict(test))
    taken = {x.get("id") for x in tests if isinstance(x, dict)}
    if "id" not in t:
        n = len(tests) + 1
        while f"t{n}" in taken:
            n += 1
        t["id"] = f"t{n}"
    elif t["id"] in taken:
        raise EstimationError(f"a test with id {t['id']!r} is already in the record")
    t.setdefault("added", _now())
    level = _declared_level(record)
    if level is not None and level < 2:
        raise EstimationError(f"tests are disclosure level 2; this record declares level {level}")
    tests.append(t)
    if level is not None and level < 4:
        # the test's own fields above the record's level (its `source`, at 4) are left out
        _apply_level(record, level, load_schemas())
    entry = {"when": t["added"], "by": by or _producer(), "action": "extended", "sections": ["tests"]}
    if level is not None and level < 4:
        del entry["by"]
    record.setdefault("history", []).append(entry)
    return record


def _default_vcov(rec: dict) -> dict | None:
    v = (rec.get("structures") or {}).get("vcov")
    vs = [s for s in (v if isinstance(v, list) else [v]) if isinstance(s, dict)]
    defaults = [s for s in vs if s.get("default")]
    return defaults[0] if defaults else (vs[0] if len(vs) == 1 else None)


def _profile_inference(rec: dict) -> list[Issue]:
    issues = []
    for i, row in enumerate(rec.get("parameters") or []):
        if isinstance(row, dict) and not row.get("dropped"):
            missing = [k for k in ("estimate", "std_error", "p_value") if k not in row]
            if missing:
                issues.append(Issue("error", f"parameters[{i}]", f"missing {', '.join(missing)}"))
    metrics = rec.get("metrics") or {}
    vc = _default_vcov(rec)
    if "nobs" not in metrics:
        issues.append(Issue("error", "metrics.nobs", "required"))
    # df_residual can be left out only by z-test fits: a default vcov with no df_t (Ted, 2026-11-07)
    if "df_residual" not in metrics and (vc is None or vc.get("df_t") is not None):
        issues.append(
            Issue("error", "metrics.df_residual", "required unless the default vcov has no df_t (z tests)")
        )
    if vc is None:
        issues.append(Issue("error", "structures.vcov", "a default vcov is required"))
    else:
        if "type" not in vc:
            issues.append(Issue("error", "structures.vcov.type", "required on the default vcov"))
        if not isinstance(vc.get("ssc"), dict) or "convention" not in vc["ssc"]:
            issues.append(Issue("error", "structures.vcov.ssc", "required, with at least 'convention'"))
    return issues


def _profile_linear_fe(rec: dict) -> list[Issue]:
    # Convergence is vocabulary, not required (Ted, 2026-10-24)
    issues = _profile_inference(rec)
    if "n_singletons" not in (rec.get("metrics") or {}):
        issues.append(Issue("warning", "metrics.n_singletons", "expected, missing"))
    opts = (rec.get("specification") or {}).get("options") or {}
    if "drop_singletons" not in opts:
        issues.append(Issue("error", "specification.options.drop_singletons", "required"))
    fe = (rec.get("structures") or {}).get("fixed_effects")
    if fe is None:
        issues.append(Issue("error", "structures.fixed_effects", "required"))
    else:
        entries = fe.get("data") if isinstance(fe, dict) and "data" in fe else fe
        for i, e in enumerate(entries if isinstance(entries, list) else []):
            if not isinstance(e, dict) or "levels" not in e or "name" not in e:
                issues.append(Issue("error", f"structures.fixed_effects[{i}]", "needs 'name' and 'levels'"))
    return issues


# Built-in checks of the standard profiles' required sets, used only when the schemas or
# jsonschema are missing. The schemas are the reference; these cover the main required
# fields. Tool profiles are checked through their schemas only.
PROFILES: dict[str, Callable[[dict], list[Issue]]] = {
    "inference/0.1": _profile_inference,
    "linear-fe/0.1": _profile_linear_fe,
}


def _packaged_schemas() -> Path:
    """estrec/schema/ in an installed package; the repository's schema/ when
    run from a source checkout (the wheel maps one onto the other)."""
    here = Path(__file__).with_name("schema")
    checkout = Path(__file__).resolve().parents[2] / "schema"
    return here if here.is_dir() or not checkout.is_dir() else checkout


PACKAGED_SCHEMAS = _packaged_schemas()


class Schemas:
    """The core schema and the profiles by name: the packaged catalog's, plus drafts found
    in local folders. Build it with `load_schemas`; treat it as read-only."""

    def __init__(
        self,
        catalog: dict,
        core: dict,
        profiles: dict[str, dict],
        local: Iterable[str] = (),
        collection: dict | None = None,
    ):
        self.catalog = catalog
        self.core = core
        self.profiles = profiles
        self.collection = collection  # estrec-collection schema (spec 11), if catalogued
        self.local = frozenset(local)  # names from local folders, not the catalog
        self._checks: dict[str | None, Callable[[dict], list[Issue]]] = {}

    def documents(self) -> list[dict]:
        return [self.core, *self.profiles.values()]

    def extends(self, name: str) -> list[str]:
        """The profiles `name` declares it builds on (`x-extends`)."""
        return list(self.profiles.get(name, {}).get("x-extends") or [])

    def deviations(self, name: str) -> list[dict]:
        """The departures from its bases that `name` declares (`x-deviations`)."""
        return list(self.profiles.get(name, {}).get("x-deviations") or [])

    def check(self, profile: str | None = None) -> Callable[[dict], list[Issue]]:
        """The core check (None), or a profile's own rules (`$defs/rules`) without the core
        again; built once."""
        if profile not in self._checks:
            if profile is None:
                target = self.core
            else:
                doc = self.profiles[profile]
                target = {"$ref": f"{doc['$id']}#/$defs/rules"} if "rules" in doc.get("$defs", {}) else doc
            self._checks[profile] = jsonschema_check(target, self.documents())
        return self._checks[profile]


def _read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


@functools.lru_cache(maxsize=8)
def _load_schemas(packaged: str, folders: tuple[str, ...]) -> Schemas | None:
    root = Path(packaged)
    if not (root / "catalog.json").is_file():
        return None
    catalog = _read_json(root / "catalog.json")
    core = _read_json(root / catalog["core"]["file"])
    collection = _read_json(root / catalog["collection"]["file"]) if "collection" in catalog else None
    profiles: dict[str, dict] = {}
    for entry in catalog["profiles"]:
        doc = _read_json(root / entry["file"])
        if doc.get("title") != entry["name"]:
            raise EstimationError(f"{entry['file']}: title {doc.get('title')!r} is not {entry['name']!r}")
        profiles[entry["name"]] = doc
    local: list[str] = []
    for folder in map(Path, folders):
        for f in sorted([*folder.glob("*.json"), *folder.glob("profiles/*.json")]):
            try:
                doc = _read_json(f)
            except (OSError, ValueError):
                continue
            name = doc.get("title") if isinstance(doc, dict) else None
            if not name or "$id" not in doc or name.startswith("estrec") or "catalog" in doc:
                continue  # not a profile (the core or collection schema, a catalog, an example)
            if name in profiles:
                which = "the catalog's" if name not in local else "one found earlier"
                warnings.warn(f"{f}: profile {name!r} is ignored; {which} takes precedence")
                continue
            profiles[name] = doc
            local.append(name)
    return Schemas(catalog, core, profiles, local, collection)


def load_schemas(
    folders: Iterable[str | os.PathLike] = (), *, packaged: str | os.PathLike | None = None
) -> Schemas | None:
    """The packaged catalog's schemas, plus draft profiles in `folders` and in the folders
    listed in $ESTREC_SCHEMA_PATH (a profile is any JSON Schema with a `title` and an
    `$id`, in a folder or its profiles/ subfolder). A local profile can't replace a catalog
    one: it is ignored with a warning. None if the packaged schemas are missing."""
    env = [d for d in os.environ.get("ESTREC_SCHEMA_PATH", "").split(os.pathsep) if d]
    dirs = tuple(str(Path(d).resolve()) for d in [*folders, *env])
    return _load_schemas(str(Path(packaged or PACKAGED_SCHEMAS).resolve()), dirs)


def _deviation(declared: list[dict], path: str) -> dict | None:
    """The declared deviation covering `path` (a pattern covers its sub-paths)."""
    for d in declared:
        pat = re.escape(str(d.get("path", ""))).replace(r"\[\*\]", r"\[\d+\]").replace(r"\*", r"[^.\[]+")
        if pat and re.match(rf"{pat}(?:$|[.\[])", path):
            return d
    return None


def _have_jsonschema() -> bool:
    try:
        import jsonschema  # noqa: F401
    except ImportError:
        return False
    return True


def jsonschema_check(
    schema: dict | str | os.PathLike, documents: Iterable[dict] = ()
) -> Callable[[dict], list[Issue]]:
    """A schema plug-in for `validate` from a JSON Schema (needs the `jsonschema` package).
    `documents` are other schemas its `$ref`s may name (by `$id`, relative refs included),
    so a profile can refer to the core without a network."""
    try:
        import jsonschema
    except ImportError as e:  # pragma: no cover - depends on the environment
        raise ImportError("JSON Schema validation needs jsonschema: pip install 'estrec[jsonschema]'") from e
    root: dict = schema if isinstance(schema, dict) else json.loads(Path(schema).read_text(encoding="utf-8"))
    docs = [d for d in [root, *documents] if "$id" in d]
    cls = jsonschema.validators.validator_for(root, default=jsonschema.Draft202012Validator)
    from referencing import Registry, Resource  # jsonschema >= 4.18 depends on it
    from referencing.jsonschema import DRAFT202012

    registry = Registry().with_resources(
        (d["$id"], Resource.from_contents(d, default_specification=DRAFT202012)) for d in docs
    )
    v = cls(root, registry=registry)

    def check(rec: dict) -> list[Issue]:
        out = []
        for e in v.iter_errors(to_json(rec)):
            parts = list(e.absolute_path)
            if e.validator == "required":  # name the missing field, as the built-in checks do
                m = re.match(r"'(.+)' is a required property", e.message)
                parts += [m.group(1)] if m else []
            out.append(Issue("error", _path(parts), _message(e)))
        return out

    return check


def _path(parts: Iterable[Any]) -> str:
    return "".join(f"[{p}]" if isinstance(p, int) else f".{p}" for p in parts).lstrip(".")


def _message(e: Any) -> str:
    """jsonschema's message, without the value it quotes when that is long; for a failed
    anyOf/oneOf, the closest branch's reason instead."""
    msg = e.message
    r = repr(e.instance)
    if len(r) > 80:
        msg = msg.replace(r, "the value")
    if e.context:
        from jsonschema.exceptions import best_match

        best = best_match(e.context)
        where = _path(list(best.relative_path))
        msg += f" (closest: {where + ': ' if where else ''}{_message(best)})"
    return msg


def validate(
    record: dict,
    *,
    schema: Schemas | dict | str | os.PathLike | Callable[[dict], Iterable[Issue]] | None = "auto",
    profiles: dict[str, Callable[[dict], list[Issue]]] | None = None,
    base_dir: str | os.PathLike | None = None,
) -> list[Issue]:
    """Check a record (as read, or as returned by `write`) and return the issues found.

    Errors make the record invalid; warnings flag missing expected sections, size, a
    digest that doesn't match, or attachment files that don't match their hash; info
    notes what couldn't be checked.

    `schema="auto"` (default) validates against `load_schemas()`: the core plus the rules
    of each profile in `meta.profiles`. For a claimed profile that builds on others
    (`x-extends`), the record is also checked against each base it doesn't claim: info
    when it meets the base or differs where the profile declares it (`x-deviations`), a
    warning where it differs without a declaration. Without the `jsonschema` package it
    falls back to the built-in checks. A `Schemas` is used as given; None uses the
    built-in checks only; any other value (a JSON Schema as dict or path, or a callable
    returning issues) is checked in addition to the built-in ones. `profiles` adds or
    replaces profile checks by name. With `base_dir` (the record's folder), attachment
    files found there are hashed."""
    if not isinstance(record, dict):
        return [Issue("error", "", "an estimation record is a JSON object")]
    issues: list[Issue] = []
    schemas: Schemas | None = None
    extra = None
    if isinstance(schema, str) and schema == "auto":
        schemas = load_schemas()
        why = "no packaged schemas" if schemas is None else "the 'jsonschema' package is not installed"
        if schemas is not None and not _have_jsonschema():
            schemas = None
        if schemas is None:
            issues.append(Issue("info", "", f"{why}; used the built-in checks"))
    elif isinstance(schema, Schemas):
        schemas = schema
    elif schema is not None:
        extra = schema
    try:
        enc = to_json(record)
    except (EstimationError, ValueError) as e:
        return [*issues, Issue("error", "", f"not encodable as JSON: {e}")]
    issues += _check_core(enc, structural=schemas is None)
    issues += _size_issues(enc, len(_dumps(enc).encode()))

    try:
        ok = check_digest(record)
    except EstimationError as e:
        ok = False
        issues.append(Issue("warning", "meta.core_digest", f"can't compute: {e}"))
    if ok is None:
        issues.append(Issue("info", "meta.core_digest", "no digest"))
    elif not ok:
        issues.append(
            Issue("warning", "meta.core_digest", "does not match: the result sections changed after writing")
        )

    if schemas is not None:
        issues += schemas.check()(enc)
    claimed = (enc.get("meta") or {}).get("profiles") if isinstance(enc.get("meta"), dict) else None
    seen = {(i.level, i.path, i.message) for i in issues}
    for p in claimed if isinstance(claimed, list) else []:
        if profiles and p in profiles:
            found = profiles[p](enc)
        elif schemas is not None and p in schemas.profiles:
            found = schemas.check(p)(enc)
            if p in schemas.local:
                issues.append(Issue("info", "meta.profiles", f"{p!r} is a local draft, not in the catalog"))
        elif schemas is None and p in PROFILES:
            found = PROFILES[p](enc)
        else:
            issues.append(Issue("info", "meta.profiles", f"no checks known for profile {p!r}"))
            continue
        # a profile's rules include those it builds on: report each problem once
        for i in found:
            if (i.level, i.path, i.message) not in seen:
                seen.add((i.level, i.path, i.message))
                issues.append(Issue(i.level, i.path, f"[{p}] {i.message}"))
    if schemas is not None:
        issues += _base_issues(enc, schemas, claimed if isinstance(claimed, list) else [], seen)
        issues += _expected_issues(enc, schemas, claimed if isinstance(claimed, list) else [], set())

    issues = _level_issues(enc, issues, schemas if schemas is not None else load_schemas())

    if extra is not None:
        check = extra if callable(extra) else jsonschema_check(extra)
        issues += list(check(record))

    if base_dir is not None:
        for a in record.get("attachments") or []:
            if not isinstance(a, dict) or "path" not in a or "://" in str(a["path"]):
                continue
            p = attachment_path(Path(base_dir) / "_", a)
            if not p.exists():
                issues.append(Issue("info", f"attachments.{a.get('id')}", f"file not found: {a['path']}"))
            elif a.get("sha256") and _sha256_file(p) != a["sha256"]:
                issues.append(
                    Issue("warning", f"attachments.{a.get('id')}", "file does not match its sha256")
                )
    return issues


def _base_issues(enc: dict, schemas: Schemas, claimed: list, seen: set) -> list[Issue]:
    """How a record of each claimed profile compares with the bases that profile extends
    but the record doesn't claim (a base it claims was already checked in full)."""
    out: list[Issue] = []
    for p in claimed:
        if p not in schemas.profiles:
            continue
        for base in schemas.extends(p):
            if base in claimed:
                continue
            if base not in schemas.profiles:
                out.append(Issue("info", "meta.profiles", f"[{p}] extends {base!r}, which isn't known here"))
                continue
            everything = schemas.check(base)(enc)
            if not everything:
                out.append(Issue("info", "meta.profiles", f"[{p}] also meets {base}"))
            # problems the profile's own rules already reported aren't repeated
            found = [i for i in everything if (i.level, i.path, i.message) not in seen]
            for i in found:
                seen.add((i.level, i.path, i.message))
                d = _deviation(schemas.deviations(p), i.path)
                if d is not None:
                    reason = f": {d['reason']}" if d.get("reason") else ""
                    out.append(
                        Issue("info", i.path, f"[{p}] differs from {base}, as declared{reason} ({i.message})")
                    )
                else:
                    out.append(
                        Issue(
                            "warning",
                            i.path,
                            f"[{p}] differs from {base} without a declaration in x-deviations ({i.message})",
                        )
                    )
    return out


# ---------------------------------------------------------------- redactor


def _walk_schema(schema: dict, documents: Iterable[dict], visit: Callable[[dict, str], bool]) -> None:
    """Call `visit(node, path)` on every subschema, with the record path it describes in the
    syntax of DEFAULT_IDENTIFYING; stop below a node when `visit` returns True. Follows
    properties, items, additionalProperties, patternProperties, allOf/anyOf/oneOf and
    `$ref`s: local ones, and ones to `documents` by `$id` (relative to the referring file's
    `$id`, as a profile refers to the core)."""
    by_id = {d["$id"]: d for d in [schema, *documents] if isinstance(d, dict) and "$id" in d}

    def resolve(ref: str, doc: dict) -> tuple[Any, dict] | None:
        uri = urljoin(doc.get("$id", ""), ref)
        doc_uri, _, frag = uri.partition("#")
        target = doc if not doc_uri or doc_uri == doc.get("$id") else by_id.get(doc_uri)
        if target is None:
            return None  # outside the documents given
        node: Any = target
        for part in [p for p in frag.split("/") if p]:
            node = node[part.replace("~1", "/").replace("~0", "~")]
        return node, target

    def walk(node: Any, path: str, seen: frozenset, doc: dict) -> None:
        if not isinstance(node, dict) or visit(node, path):
            return
        ref = node.get("$ref")
        if isinstance(ref, str):
            key = urljoin(doc.get("$id", ""), ref)
            hit = resolve(ref, doc) if key not in seen else None
            if hit is not None:
                walk(hit[0], path, seen | {key}, hit[1])
        join = lambda k: f"{path}.{k}" if path else k
        for k, sub in (node.get("properties") or {}).items():
            walk(sub, join(k), seen, doc)
        for sub in (node.get("patternProperties") or {}).values():
            walk(sub, join("*"), seen, doc)
        if isinstance(node.get("additionalProperties"), dict):
            walk(node["additionalProperties"], join("*"), seen, doc)
        if isinstance(node.get("items"), dict):
            walk(node["items"], f"{path}[*]", seen, doc)
        for key in ("allOf", "anyOf", "oneOf"):
            for sub in node.get(key) or []:
                walk(sub, path, seen, doc)

    walk(schema, "", frozenset(), schema)


def identifying_paths(schema: dict, documents: Iterable[dict] = ()) -> list[str]:
    """Paths of the fields a JSON Schema marks `"x-identifying": true`, in the syntax of
    DEFAULT_IDENTIFYING (see `_walk_schema` for what is followed)."""
    found: list[str] = []

    def visit(node: dict, path: str) -> bool:
        if node.get("x-identifying") is True and path:
            found.append(path)
            return True
        return False

    _walk_schema(schema, documents, visit)
    return sorted(set(found))


def expected_paths(schema: dict, documents: Iterable[dict] = ()) -> list[tuple[str, str]]:
    """(object path, field) for each field a JSON Schema lists in `x-expected`: present in
    a conforming record as a rule, but not required ("" is the record itself)."""
    found: set[tuple[str, str]] = set()

    def visit(node: dict, path: str) -> bool:
        for field in node.get("x-expected") or []:
            found.add((path, field))
        return False

    _walk_schema(schema, documents, visit)
    return sorted(found)


def expected_tests(schema: dict, documents: Iterable[dict] = ()) -> list[str]:
    """Test categories a JSON Schema lists in `x-expected-tests`: a conforming record has a
    test of each in `tests`, as a rule, but not necessarily."""
    found: set[str] = set()

    def visit(node: dict, path: str) -> bool:
        found.update(node.get("x-expected-tests") or [])
        return False

    _walk_schema(schema, documents, visit)
    return sorted(found)


def _expected_issues(enc: dict, schemas: Schemas, claimed: list, seen: set) -> list[Issue]:
    """A warning for each `x-expected` field of a claimed profile's rules that is missing
    from an object the record has, and for each `x-expected-tests` category with no test."""
    issues = []
    docs = schemas.documents()
    tests = enc.get("tests") if isinstance(enc.get("tests"), list) else []
    have = {t.get("category") for t in tests if isinstance(t, dict)}
    for p in claimed:
        doc = schemas.profiles.get(p)
        if doc is None or "rules" not in doc.get("$defs", {}):
            continue
        for cat in expected_tests({"$ref": f"{doc['$id']}#/$defs/rules"}, docs):
            if cat not in have and ("warning", f"tests:{cat}") not in seen:
                seen.add(("warning", f"tests:{cat}"))
                issues.append(Issue("warning", "tests", f"[{p}] expected a {cat!r} test, none present"))
        for path, field in expected_paths({"$ref": f"{doc['$id']}#/$defs/rules"}, docs):
            objects = [(enc, "")] if not path else [(c[k], q) for c, k, q in _matches(enc, _split(path), "")]
            for obj, where in objects:
                full = f"{where}.{field}" if where else field
                if isinstance(obj, dict) and field not in obj and ("warning", full) not in seen:
                    seen.add(("warning", full))
                    issues.append(Issue("warning", full, f"[{p}] expected, missing"))
    return issues


def record_identifying_paths(record: dict, schemas: Schemas) -> list[str]:
    """The identifying paths for one record: the core's marks plus those of each profile
    the record claims."""
    docs = schemas.documents()
    paths = set(identifying_paths(schemas.core, docs))
    for p in (record.get("meta") or {}).get("profiles") or []:
        if p in schemas.profiles:
            paths |= set(identifying_paths(schemas.profiles[p], docs))
    return sorted(paths)


def _split(path: str) -> list[str]:
    return [p for p in path.replace("[*]", ".[*]").split(".") if p]


def _matches(node: Any, parts: list[str], prefix: str) -> Iterable[tuple[Any, Any, str]]:
    """(container, key, concrete path) of every value a pattern path reaches."""
    if not parts:
        return
    head, rest = parts[0], parts[1:]
    if head == "[*]":
        if isinstance(node, list):
            for i, v in enumerate(node):
                p = f"{prefix}[{i}]"
                yield from [(node, i, p)] if not rest else _matches(v, rest, p)
        return
    if not isinstance(node, dict):
        return
    for k in list(node) if head == "*" else [head] if head in node else []:
        p = f"{prefix}.{k}" if prefix else k
        yield from [(node, k, p)] if not rest else _matches(node[k], rest, p)


def _hmac(salt: bytes, value: Any) -> str:
    return "hmac-sha256:" + hmac.new(salt, canonical_json(to_json(value)), hashlib.sha256).hexdigest()


def redact(
    record: dict,
    *,
    paths: Iterable[str] | None = None,
    schema: Schemas | dict | str | None = "auto",
    salt: bytes | str | None = None,
    by: dict | None = None,
) -> dict:
    """A copy of `record` with its identifying fields removed or, with `salt`, replaced
    by an HMAC-SHA256 of the value, so records redacted with the same salt still compare
    equal. Appends a `history` entry listing the fields changed. The result sections
    covered by the core digest are never touched.

    The fields are `paths` if given; else those marked `x-identifying` in the core and
    each profile the record claims (`schema="auto"` uses `load_schemas()`, or pass `Schemas`),
    or in one JSON Schema given as a dict; else (no schemas, or None) DEFAULT_IDENTIFYING."""
    if paths is None:
        if isinstance(schema, str) and schema == "auto":
            schema = load_schemas()
        if isinstance(schema, Schemas):
            paths = record_identifying_paths(record, schema)
        elif isinstance(schema, dict):
            paths = identifying_paths(schema)
        else:
            paths = DEFAULT_IDENTIFYING
    rec = copy.deepcopy(record)
    if isinstance(salt, str):
        salt = salt.encode()
    changed: list[str] = []
    for pattern in paths:
        parts = _split(pattern)
        if parts and parts[0] in CORE:
            raise EstimationError(f"{pattern}: redaction can't change a digest-covered section")
        # list items from the end, so removing one doesn't shift the others
        hits = sorted(_matches(rec, parts, ""), key=lambda h: (isinstance(h[1], int), h[1]), reverse=True)
        for container, key, p in hits:
            if salt is None:
                del container[key]
            else:
                container[key] = _hmac(salt, container[key])
            changed.append(p)
    entry = {
        "when": _now(),
        "by": by or _producer(),
        "action": "redacted",
        "method": "removed" if salt is None else "hmac-sha256",
        "fields": sorted(changed),
    }
    if (_declared_level(rec) or 5) < 4:
        del entry["by"]  # withheld below level 4 (spec 4.9)
    if salt is not None:
        # names the salt without revealing it, so readers know which records are comparable
        entry["salt_id"] = hashlib.sha256(b"estrec-salt-id:" + salt).hexdigest()[:16]
    rec.setdefault("history", []).append(entry)
    return rec


# ---------------------------------------------------------------- disclosure levels (spec 4.9)

LEVELS = (1, 2, 3, 4, 5)
DEFAULT_LEVEL = 4

# The core schema's level marks, for when the packaged schemas are missing
# (tests/test_disclosure.py keeps the two equal): path -> (level, x-level-if conditions).
DEFAULT_LEVEL_MARKS = {
    "attachments": (2, ()),
    "extensions": (4, ()),
    "history": (1, ()),
    "history[*].by": (4, ()),
    "meta": (1, ()),
    "meta.*": (2, ()),
    "meta.core_digest": (1, ()),
    "meta.created": (1, ()),
    "meta.disclosure": (1, ()),
    "meta.estimator": (2, ()),
    "meta.id": (1, ()),
    "meta.messages": (2, ()),
    "meta.notes": (1, ()),
    "meta.parent": (1, ()),
    "meta.producer": (4, ()),
    "meta.profiles": (1, ()),
    "meta.responses": (2, ()),
    "meta.status": (1, ()),
    "meta.tags": (1, ()),
    "meta.title": (1, ()),
    "metrics": (1, ()),
    "metrics.*": (2, ()),
    "metrics.conf_level": (1, ()),
    "metrics.df_residual": (1, ()),
    "metrics.nobs": (1, ()),
    "parameters": (1, ()),
    "provenance": (4, ()),
    "provenance.*": (5, ()),
    "provenance.agent": (5, ()),
    "provenance.data": (4, ()),
    "provenance.data[*].location": (5, ()),
    "provenance.environment": (5, ()),
    "provenance.environment.host": (5, ()),
    "provenance.environment.hostname": (5, ()),
    "provenance.execution": (4, ()),
    "provenance.execution.*": (5, ()),
    "provenance.execution.invocation.argv": (5, ()),
    "provenance.execution.invocation.command_line": (5, ()),
    "provenance.execution.invocation.script_path": (5, ()),
    "provenance.execution.invocation.working_directory": (5, ()),
    "provenance.execution.scheduler.Account": (5, ()),
    "provenance.execution.scheduler.JobID": (5, ()),
    "provenance.execution.scheduler.JobName": (5, ()),
    "provenance.execution.scheduler.NodeList": (5, ()),
    "provenance.execution.scheduler.SubmitLine": (5, ()),
    "provenance.execution.scheduler.User": (5, ()),
    "provenance.execution.scheduler.WorkDir": (5, ()),
    "provenance.execution.session": (4, ()),
    "provenance.execution.workers[*].host": (5, ()),
    "provenance.software": (4, ()),
    "provenance.software[*]": (5, (("role", ("language", "estimator", "writer"), 4),)),
    "provenance.software[*].container": (5, ()),
    "provenance.software[*].container.path": (5, ()),
    "provenance.software[*].lock": (4, ()),
    "provenance.software[*].lock.path": (5, ()),
    "publication": (1, ()),
    "schema": (1, ()),
    "specification": (3, ()),
    "structures": (2, ()),
    "structures.*": (3, ()),
    "structures.equations": (2, ()),
    "structures.first_stage": (2, ()),
    "structures.fixed_effects": (3, ()),
    "structures.hyperparameters": (3, ()),
    "structures.numerics": (4, ()),
    "structures.random_effects": (2, ()),
    "structures.vcov": (2, ()),
    "structures.vcov[*].cluster": (3, ()),
    "structures.vcov[*].n_clusters": (3, ()),
    "structures.vcov[*].n_clusters_min": (3, ()),
    "tests": (2, ()),
    "tests[*].source": (4, ()),
    "tests[*].vcov.cluster": (3, ()),
    "validation": (4, ()),
}

# A compiled mark: the pattern's parts (`*` any key, `[*]` any list item), its level (None:
# inherit) and its conditions ((field, values, level), ...) from `x-level-if`.
_Mark = tuple[tuple[str, ...], "int | None", tuple]


def level_marks(schema: dict, documents: Iterable[dict] = ()) -> dict[str, tuple[int | None, tuple]]:
    """The `x-level` and `x-level-if` marks of a JSON Schema, by path (the syntax of
    DEFAULT_IDENTIFYING); a field marked `x-identifying` is level 5. Where two documents mark
    one path differently, the higher level wins."""
    found: dict[str, tuple[int | None, tuple]] = {}

    def visit(node: dict, path: str) -> bool:
        lvl = node.get("x-level")
        if node.get("x-identifying") is True:  # identifying fields are level 5 (spec 4.9)
            lvl = 5
        conds = tuple(
            (c["field"], tuple(c["in"]), c["level"])
            for c in node.get("x-level-if") or []
            if isinstance(c, dict) and {"field", "in", "level"} <= c.keys()
        )
        if path and (isinstance(lvl, int) or conds):
            old_lvl, old_conds = found.get(path, (None, ()))
            if isinstance(lvl, int):
                lvl = lvl if old_lvl is None else max(lvl, old_lvl)
            else:
                lvl = old_lvl
            found[path] = (lvl, tuple(dict.fromkeys(old_conds + conds)))
        return False

    _walk_schema(schema, documents, visit)
    return found


def _compile(marks: dict[str, tuple[int | None, tuple]]) -> list[_Mark]:
    return [(tuple(_split(p)), lvl, conds) for p, (lvl, conds) in marks.items()]


def _schemas_or_none(schema: Any) -> Schemas | None:
    """The schemas whose level marks apply: those given, else the packaged ones (the marks
    are data, so they don't need the jsonschema package or a schema check)."""
    return schema if isinstance(schema, Schemas) else load_schemas()


def record_level_marks(record: dict, schemas: Schemas | None) -> list[_Mark]:
    """The level marks for one record: the core's plus each claimed profile's (without
    schemas, DEFAULT_LEVEL_MARKS)."""
    if schemas is None:
        return _compile(DEFAULT_LEVEL_MARKS)
    claimed = (record.get("meta") or {}).get("profiles") if isinstance(record.get("meta"), dict) else None
    names = tuple(p for p in claimed or [] if isinstance(p, str) and p in schemas.profiles)
    return _record_marks(schemas, names)


@functools.lru_cache(maxsize=64)
def _record_marks_cached(schemas_id: int, names: tuple[str, ...]) -> list[_Mark]:
    schemas = _MARK_SCHEMAS[schemas_id]
    docs = schemas.documents()
    marks = level_marks(schemas.core, docs)
    for p in names:
        for path, (lvl, conds) in level_marks(schemas.profiles[p], docs).items():
            old_lvl, old_conds = marks.get(path, (None, ()))
            marks[path] = (
                lvl if old_lvl is None else old_lvl if lvl is None else max(lvl, old_lvl),
                tuple(dict.fromkeys(old_conds + conds)),
            )
    return _compile(marks)


_MARK_SCHEMAS: dict[int, Schemas] = {}


def _record_marks(schemas: Schemas, names: tuple[str, ...]) -> list[_Mark]:
    _MARK_SCHEMAS[id(schemas)] = schemas  # Schemas are cached by load_schemas and kept alive
    return _record_marks_cached(id(schemas), names)


def _seg(pat: str, key: Any) -> bool:
    if pat == "[*]":
        return isinstance(key, int)
    if pat == "*":
        return isinstance(key, str)
    return pat == key


def _mark_for(parts: tuple, marks: list[_Mark]) -> tuple[int | None, tuple] | None:
    """The most specific mark for one concrete path: literal keys beat `*`, earlier first."""
    best, best_key = None, None
    for pat, lvl, conds in marks:
        if len(pat) == len(parts) and all(_seg(a, b) for a, b in zip(pat, parts)):
            key = tuple(a != "*" for a in pat)
            if best_key is None or key > best_key:
                best, best_key = (lvl, conds), key
    return best


def _node_level(parts: tuple, node: Any, parent: int, marks: list[_Mark]) -> int:
    m = _mark_for(parts, marks)
    if m is None:
        return parent if parts[:-1] else 5  # an unmarked top-level member is level 5
    lvl = parent if m[0] is None else m[0]
    for field, values, cond_level in m[1]:
        if isinstance(node, dict) and node.get(field) in values:
            lvl = cond_level
    return max(lvl, parent) if parts[:-1] else lvl  # never below what contains it


def path_level(path: str, marks: list[_Mark]) -> int:
    """The level of a path, present or not (`x-level-if` can't apply without the value)."""
    parts: list[Any] = []
    for p in re.findall(r"[^.\[\]]+|\[\d+\]|\[\*\]", path):
        parts.append(int(p[1:-1]) if re.fullmatch(r"\[\d+\]", p) else 0 if p == "[*]" else p)
    lvl = 1
    for i in range(len(parts)):
        lvl = _node_level(tuple(parts[: i + 1]), None, lvl, marks)
    return lvl


def _above(rec: dict, level: int, marks: list[_Mark]) -> list[tuple[Any, Any, str, int]]:
    """(container, key, path, field level) of each outermost field above `level`."""
    out: list[tuple[Any, Any, str, int]] = []

    def walk(node: Any, parts: tuple, path: str, lvl: int) -> None:
        items = node.items() if isinstance(node, dict) else enumerate(node) if isinstance(node, list) else ()
        for k, v in items:
            sub = (*parts, k)
            p = f"{path}[{k}]" if isinstance(k, int) else f"{path}.{k}" if path else k
            n = _node_level(sub, v, lvl, marks)
            if n > level:
                out.append((node, k, p, n))
            else:
                walk(v, sub, p, n)

    walk(rec, (), "", 1)
    return out


def _declared_level(rec: dict) -> int | None:
    d = (rec.get("meta") or {}).get("disclosure") if isinstance(rec.get("meta"), dict) else None
    lvl = d.get("level") if isinstance(d, dict) else None
    return lvl if isinstance(lvl, int) and not isinstance(lvl, bool) and lvl in LEVELS else None


def fields_above(record: dict, level: int, *, schema: Schemas | str | None = "auto") -> list[str]:
    """Paths of the fields in `record` above disclosure `level` (outermost only)."""
    rec = to_json(record)
    return [p for _, _, p, _ in _above(rec, level, record_level_marks(rec, _schemas_or_none(schema)))]


def record_level(record: dict, *, schema: Schemas | str | None = "auto") -> int:
    """The lowest disclosure level that holds everything in `record`."""
    rec = to_json(record)
    marks = record_level_marks(rec, _schemas_or_none(schema))
    for lvl in LEVELS:
        if not _above(rec, lvl, marks):
            return lvl
    return 5


def is_purpose(name: str, schemas: Schemas) -> bool:
    """A purpose profile: catalogued as `kind: "purpose"`, or a local profile with
    `x-min-level`."""
    for e in schemas.catalog.get("profiles", []):
        if e.get("name") == name:
            return e.get("kind") == "purpose"
    return "x-min-level" in schemas.profiles.get(name, {})


def _kind(name: str, schemas: Schemas) -> str:
    for e in schemas.catalog.get("profiles", []):
        if e.get("name") == name:
            return str(e.get("kind"))
    return "local"


def min_level(name: str, schemas: Schemas) -> int:
    """The lowest disclosure level a purpose profile can be met at (`x-min-level`, else 1)."""
    lvl = schemas.profiles.get(name, {}).get("x-min-level")
    return lvl if isinstance(lvl, int) and lvl in LEVELS else 1


def _profile_errors(rec: dict, name: str, schemas: Schemas | None) -> list[Issue] | None:
    """A profile's errors for `rec`, or None when it can't be checked here."""
    if schemas is not None and name in schemas.profiles and _have_jsonschema():
        return [i for i in schemas.check(name)(rec) if i.level == "error"]
    if name in PROFILES:
        return [i for i in PROFILES[name](rec) if i.level == "error"]
    return None


def _apply_level(rec: dict, level: int, schemas: Schemas | None) -> tuple[list[str], list[str]]:
    """Remove the fields above `level` from `rec` in place, drop attachments only removed
    structures linked to, and drop the claims of model profiles the removal broke. Returns
    (removed paths, dropped profile claims)."""
    if level not in LEVELS:
        raise EstimationError(f"disclosure level must be one of 1-5, got {level!r}")
    marks = record_level_marks(rec, schemas)
    hits = _above(rec, level, marks)
    if not hits:
        return [], []

    def links(r: dict) -> set:
        return {
            s.get("attachment") for s in _structures(r) if isinstance(s, dict) and s.get("kind") == "link"
        }

    linked_before = links(rec)
    claimed = list((rec.get("meta") or {}).get("profiles") or [])
    before = {p: _profile_errors(rec, p, schemas) for p in claimed}
    removed = []
    touched: set[int] = set()
    # list items from the end, so removing one doesn't shift the others
    for container, key, p, _ in sorted(hits, key=lambda h: (isinstance(h[1], int), h[1]), reverse=True):
        del container[key]
        touched.add(id(container))
        removed.append(p)
    _prune(rec, touched)
    gone = linked_before - links(rec)
    if gone and isinstance(rec.get("attachments"), list):
        for i in reversed(range(len(rec["attachments"]))):
            a = rec["attachments"][i]
            if isinstance(a, dict) and a.get("id") in gone:
                del rec["attachments"][i]
                removed.append(f"attachments[{i}]")
        if not rec["attachments"]:
            del rec["attachments"]
    dropped = []
    for p in claimed:
        if before[p] == [] and _profile_errors(rec, p, schemas):
            if schemas is not None and is_purpose(p, schemas):
                continue  # a purpose's failures are the caller's to report
            dropped.append(p)
    if dropped:
        meta = rec["meta"]
        meta["profiles"] = [p for p in claimed if p not in dropped]
        if not meta["profiles"]:
            del meta["profiles"]
        if level >= 2:
            meta.setdefault("messages", []).extend(
                {
                    "level": "info",
                    "code": "profile_not_claimed",
                    "message": f"{p} isn't claimed: disclosure level {level} leaves out what it requires",
                    "source": "estrec",
                }
                for p in dropped
            )
    return sorted(removed), dropped


def _prune(node: Any, touched: set[int]) -> None:
    """Remove the objects and lists that removing fields left empty (not those that were
    empty to begin with), from the bottom up."""
    items = (
        list(node.items())
        if isinstance(node, dict)
        else list(enumerate(node))
        if isinstance(node, list)
        else []
    )
    for k, v in reversed(items):
        if isinstance(v, (dict, list)):
            _prune(v, touched)
            if not v and id(v) in touched:
                del node[k]
                touched.add(id(node))


def reduce(
    record: dict,
    level: int,
    *,
    schema: Schemas | str | None = "auto",
    by: dict | None = None,
) -> dict:
    """A copy of `record` at disclosure `level`: the fields above it removed (by the
    `x-level` marks of the core and the claimed profiles), and the claims of model profiles
    it no longer meets dropped. The copy is a new record: a new `meta.id` with `meta.parent`
    set to the original's, `meta.disclosure`, a new core digest if the original had one, and
    a `history` entry with `action: "reduced"`. A record already at or below `level` is
    returned as a copy, unchanged."""
    schemas = _schemas_or_none(schema)
    rec = copy.deepcopy(to_json(record))
    declared = _declared_level(rec)
    if (
        declared is not None
        and declared <= level
        and not _above(rec, level, record_level_marks(rec, schemas))
    ):
        return rec
    removed, dropped = _apply_level(rec, level, schemas)
    meta = rec.setdefault("meta", {})
    if "id" in meta:
        meta["parent"] = meta["id"]
    meta["id"] = str(uuid.uuid4())
    meta["disclosure"] = {"level": level}
    entry: dict[str, Any] = {
        "when": _now() if level > 1 else _now()[:10],
        "action": "reduced",
        "level": level,
    }
    if level >= 4:
        entry["by"] = by or _producer()
    entry["fields"] = removed
    rec.setdefault("history", []).append(entry)
    if "core_digest" in meta:
        add_digest(rec)
    for p in dropped:
        warnings.warn(f"{p} isn't claimed: disclosure level {level} leaves out what it requires")
    return rec


def levels_table(schemas: Schemas | None = None) -> dict:
    """The core's level marks and each purpose profile's minimum level, as plain JSON, for
    writers in other languages (`estrec levels`; estrec ships it as inst/levels.json)."""
    schemas = schemas or load_schemas()
    marks = level_marks(schemas.core, schemas.documents()) if schemas else DEFAULT_LEVEL_MARKS
    return {
        "schema": SCHEMA,
        "marks": [
            {"path": p, "level": lvl, "if": [{"field": f, "in": list(v), "level": n} for f, v, n in conds]}
            for p, (lvl, conds) in sorted(marks.items())
        ],
        "purposes": {n: min_level(n, schemas) for n in sorted(schemas.profiles) if is_purpose(n, schemas)}
        if schemas
        else {},
        "collection_marks": [
            {"path": p, "level": lvl, "if": [{"field": f, "in": list(v), "level": n} for f, v, n in conds]}
            for p, (lvl, conds) in sorted(level_marks(schemas.collection, schemas.documents()).items())
            if not p.startswith("members[*].record")
        ]
        if schemas and schemas.collection
        else [],
        "collection_min_level_by_kind": {"session": 4, "replication": 4},
    }


def _level_issues(enc: dict, issues: list[Issue], schemas: Schemas | None) -> list[Issue]:
    """With a declared level: an error for each field above it and for each claimed purpose
    that needs more; and warnings about missing expected fields the level withholds become
    information."""
    level = _declared_level(enc)
    if level is None:
        if isinstance(enc.get("meta"), dict) and "disclosure" in enc["meta"]:
            issues.append(Issue("error", "meta.disclosure.level", "must be an integer from 1 to 5"))
        return issues
    marks = record_level_marks(enc, schemas)
    out = []
    for i in issues:
        missing = i.level == "warning" and (
            i.message.endswith("expected section missing")
            or i.message.endswith("expected, missing")
            or "test, none present" in i.message
        )
        if missing and path_level(i.path, marks) > level:
            out.append(Issue("info", i.path, f"withheld at disclosure level {level} ({i.message})"))
        else:
            out.append(i)
    for _, _, p, n in _above(enc, level, marks):
        out.append(Issue("error", p, f"level {n} field in a record declared at disclosure level {level}"))
    if schemas is not None:
        for p in (enc.get("meta") or {}).get("profiles") or []:
            if isinstance(p, str) and p in schemas.profiles and is_purpose(p, schemas):
                need = min_level(p, schemas)
                if need > level:
                    out.append(
                        Issue(
                            "error", "meta.disclosure.level", f"[{p}] needs disclosure level {need} or more"
                        )
                    )
    return out


# ---------------------------------------------------------------- command line


def _cli_schemas(ap: argparse.ArgumentParser, folders: list[str], off: bool) -> Schemas | str | None:
    if off:
        return None
    if not folders:
        return "auto"
    for f in folders:
        if not Path(f).is_dir():
            ap.error(f"--schema-path {f}: not a folder")
    schemas = load_schemas(folders)
    if schemas is None:
        ap.error("the packaged schemas are missing from this estrec installation")
    return schemas


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="estrec", description="estimation record tools")
    sub = ap.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("validate", help="check records and collections; exit 1 on errors")
    v.add_argument("files", nargs="+")
    v.add_argument(
        "--schema-path",
        action="append",
        default=[],
        help="folder of draft profiles to use besides the packaged ones (repeatable)",
    )
    v.add_argument("--no-schema", action="store_true", help="built-in checks only")
    v.add_argument("--schema", help="another JSON Schema to check against as well")
    v.add_argument("-q", "--quiet", action="store_true", help="errors only")
    r = sub.add_parser("redact", help="remove or hash identifying fields (a collection's and its members')")
    r.add_argument("file")
    r.add_argument("-o", "--output", required=True)
    r.add_argument(
        "--hash",
        action="store_true",
        help="replace values with HMAC-SHA256; the salt comes from --salt-file or $ESTREC_REDACT_SALT",
    )
    r.add_argument("--salt-file")
    r.add_argument("--schema-path", action="append", default=[], help="folder of draft profiles (repeatable)")
    r.add_argument("--schema", help="take the fields from this one schema's x-identifying marks")
    r.add_argument("--path", action="append", default=[], help="also redact this path (repeatable)")
    d = sub.add_parser(
        "digest", help="print the core digest and whether it matches (each member's, for a collection)"
    )
    d.add_argument("file")
    d.add_argument("--write", action="store_true", help="add (or replace) the record's core digest in place")
    lv = sub.add_parser(
        "reduce", help="write a record or collection at a lower disclosure level (a new one, spec 4.9, 11.7)"
    )
    lv.add_argument("file")
    lv.add_argument("--level", type=int, required=True, choices=LEVELS)
    lv.add_argument("-o", "--output", required=True)
    lv.add_argument(
        "--schema-path", action="append", default=[], help="folder of draft profiles (repeatable)"
    )
    lm = sub.add_parser(
        "levels",
        help="print the core schema's disclosure-level marks and the purposes' minimum levels as JSON",
    )
    lm.add_argument(
        "--schema-path", action="append", default=[], help="folder of draft profiles (repeatable)"
    )
    from . import show as show_mod
    from . import table as table_mod

    sh = sub.add_parser("show", help="a quick look: one record in detail, or several side by side")
    show_mod.add_arguments(sh)
    tb = sub.add_parser("table", help="render or check a table spec (estrec-table/0.1)")
    table_mod.add_arguments(tb)
    args = ap.parse_args(argv)

    if args.cmd == "show":
        return show_mod.run(args)
    if args.cmd == "table":
        return table_mod.run(args)

    from . import collection as coll  # imports this module

    if args.cmd == "validate":
        bad = 0
        schemas = _cli_schemas(ap, args.schema_path, args.no_schema)
        for f in args.files:
            rec = json.loads(Path(f).read_bytes(), parse_constant=_reject_constant)
            if coll.is_collection(rec):
                issues = coll.validate_collection(rec, schema=schemas, base_dir=Path(f).parent)
            elif isinstance(rec, dict) and rec.get("schema") == table_mod.TABLE_SCHEMA:
                issues = table_mod.validate_table(
                    rec, base_dir=Path(f).parent, schema=None if args.no_schema else "auto"
                )
            elif isinstance(rec, dict):
                issues = validate(rec, schema=schemas, base_dir=Path(f).parent)
            else:
                issues = [Issue("error", "", "an estimation record is a JSON object")]
            if args.schema:
                issues += jsonschema_check(args.schema)(rec)
            for i in issues:
                if not args.quiet or i.level == "error":
                    print(f"{f}: {i}")
            errors = sum(i.level == "error" for i in issues)
            bad += errors > 0
            if not args.quiet:
                print(f"{f}: {'INVALID' if errors else 'valid'} ({errors} errors)")
        return 1 if bad else 0

    if args.cmd == "redact":
        rec = json.loads(Path(args.file).read_bytes(), parse_constant=_reject_constant)
        salt = None
        if args.hash:
            if args.salt_file:
                salt = Path(args.salt_file).read_bytes().strip()
            else:
                salt = os.environ.get("ESTREC_REDACT_SALT", "").encode() or None
            if not salt:
                ap.error("--hash needs a salt: --salt-file or $ESTREC_REDACT_SALT")
        if not isinstance(rec, dict):
            ap.error(f"{args.file}: not a JSON object")
        if coll.is_collection(rec):
            if args.schema:
                ap.error("--schema applies to records; a collection uses its own and its members' schemas")
            schemas = _cli_schemas(ap, args.schema_path, False)
            out = coll.redact_collection(
                rec, salt=salt, schema=schemas, base_dir=Path(args.file).parent, paths=args.path
            )
            written = coll.write_collection(out, args.output, members="auto")
            n = len(written.get("members") or [])
            print(f"{args.output}: collection and {n} member records {out['history'][-1]['method']}")
            return 0
        if args.schema:
            paths = identifying_paths(json.loads(Path(args.schema).read_text(encoding="utf-8")))
        else:
            schemas = _cli_schemas(ap, args.schema_path, False)
            if schemas == "auto":
                schemas = load_schemas()
            paths = (
                record_identifying_paths(rec, schemas)
                if isinstance(schemas, Schemas)
                else list(DEFAULT_IDENTIFYING)
            )
        out = redact(rec, paths=paths + args.path, salt=salt)
        Path(args.output).write_text(_dumps(out, 1) + "\n", encoding="utf-8")
        print(f"{args.output}: {len(out['history'][-1]['fields'])} fields {out['history'][-1]['method']}")
        return 0

    if args.cmd == "levels":
        schemas = _cli_schemas(ap, args.schema_path, False)
        schemas = load_schemas() if schemas == "auto" else schemas
        print(json.dumps(levels_table(schemas), indent=1))
        return 0

    if args.cmd == "reduce":
        rec = json.loads(Path(args.file).read_bytes(), parse_constant=_reject_constant)
        if not isinstance(rec, dict):
            ap.error(f"{args.file}: not a JSON object")
        schemas = _cli_schemas(ap, args.schema_path, False)
        if coll.is_collection(rec):
            try:
                out = coll.reduce_collection(rec, args.level, schema=schemas, base_dir=Path(args.file).parent)
            except EstimationError as e:
                ap.error(str(e))
            written = coll.write_collection(out, args.output, members="auto")
            print(
                f"{args.output}: collection and {len(written.get('members') or [])} members at level {args.level}"
            )
            return 0
        out = reduce(rec, args.level, schema=schemas)
        Path(args.output).write_text(_dumps(out, 1) + "\n", encoding="utf-8")
        print(
            f"{args.output}: level {args.level}, {len(out['history'][-1].get('fields', []))} fields removed"
        )
        return 0

    rec = json.loads(Path(args.file).read_bytes(), parse_constant=_reject_constant)
    if coll.is_collection(rec):
        # no digest of its own (spec 11.7): each member's core digest and its sha256
        bad = False
        for i, m, r in coll.iter_members(rec, Path(args.file).parent):
            if r is None:
                print(f"members[{i}] {m.get('id') if isinstance(m, dict) else ''}: record not found")
                continue
            ok = check_digest(r)
            h = coll.member_sha256(r)
            same = None if not isinstance(m.get("sha256"), str) else m["sha256"] == h
            bad |= ok is False or same is False
            print(
                f"members[{i}] {m.get('id')}: core digest "
                + {None: "absent", True: "matches", False: "DOES NOT MATCH"}[ok]
                + f"; sha256 {h} "
                + {None: "(none in collection)", True: "matches", False: "DOES NOT MATCH"}[same]
            )
        return 1 if bad else 0
    if not isinstance(rec, dict):
        ap.error(f"{args.file}: not a JSON object")
    if args.write:
        add_digest(rec)
        Path(args.file).write_text(_dumps(rec, 1) + "\n", encoding="utf-8")
        print(rec["meta"]["core_digest"]["value"], "written")
        return 0
    ok = check_digest(rec)
    print(core_digest(rec), {None: "(no digest in record)", True: "matches", False: "DOES NOT MATCH"}[ok])
    return 1 if ok is False else 0


if __name__ == "__main__":
    sys.exit(main())
