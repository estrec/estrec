# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Ted Matherly and the estrec contributors
"""Read, write, validate and redact `estrec-collection` documents (spec section 11).

A collection is a set of records plus what is true of the set: a paper's results
(`members` with locators) or a session's or replication's timeline (`events`). It is an
export built from records and never changes them. Members are embedded, or kept in a JSON
Lines members file beside the collection when the file would pass 16 MB.

    coll = new_collection([rec1, rec2], kind="paper", labels=["col8", "col9"],
                          locators=["Table 3, col. 8", {"table": "3", "column": "9"}])
    write_collection(coll, "table3.estrec-collection.json")
    issues = validate_collection(read_collection("table3.estrec-collection.json"),
                                 base_dir=".")
"""

from __future__ import annotations

import copy
import datetime as _dt
import hashlib
import json
import os
import re
import uuid
import warnings
from collections.abc import Iterable, Iterator, Mapping
from pathlib import Path
from typing import Any

from .records import (
    DEFAULT_IDENTIFYING,
    FAIL_BYTES,
    LEVELS,
    EstimationError,
    Issue,
    Schemas,
    _above,
    _compile,
    _declared_level,
    _dumps,
    _have_jsonschema,
    _now,
    _producer,
    _prune,
    _reject_constant,
    _sha256_file,
    canonical_json,
    decode_nonfinite,
    identifying_paths,
    jsonschema_check,
    level_marks,
    load_schemas,
    record_level_marks,
    redact,
    reduce,
    to_json,
    validate,
)

COLLECTION_SCHEMA = "estrec-collection/0.1"
KINDS = ("paper", "session", "replication", "batch", "other")
# in the order a writer puts them: what the collection is, then its records, then the rest
SECTIONS = (
    "schema",
    "meta",
    "publication",
    "session",
    "provenance",
    "members",
    "events",
    "attachments",
    "extensions",
    "history",
)
MEMBERS_ROLE = "members"
MEMBERS_MEDIA_TYPE = "application/jsonl"
# The collection's identifying fields when the schemas aren't used: a record's provenance
# fields (the collection's provenance has the record's structure) and the session's clients
COLLECTION_IDENTIFYING = (
    *(p for p in DEFAULT_IDENTIFYING if p.startswith("provenance.")),
    "session.clients[*].host",
)


def is_collection(doc: Any) -> bool:
    """True if `doc` claims to be an `estrec-collection` (any version)."""
    return isinstance(doc, dict) and str(doc.get("schema", "")).startswith("estrec-collection/")


def member_sha256(record: dict) -> str:
    """SHA-256 (hex) of a record's RFC 8785 canonical JSON, as a member's `sha256` (11.3).
    Non-finite numbers count as the strings they are written as, so a record hashes the
    same before writing, after reading, embedded or in a members file."""
    return hashlib.sha256(canonical_json(to_json(record))).hexdigest()


# ---------------------------------------------------------------- building


def _locator_fields(loc: Any) -> dict:
    """A member's locator fields from a label string, a locator, or a list of locators."""
    if loc is None:
        return {}
    if isinstance(loc, str):
        return {"locator": {"label": loc}}
    if isinstance(loc, Mapping):
        return {"locator": dict(loc)}
    locs = [{"label": x} if isinstance(x, str) else dict(x) for x in loc]
    if not locs:
        return {}
    return {"locator": locs[0]} if len(locs) == 1 else {"locators": locs}


def new_member(
    record: dict,
    *,
    label: str | None = None,
    locator: Any = None,
    notes: str | None = None,
    sha256: bool = True,
) -> dict:
    """A member entry embedding `record`. `locator` is a label string (`"Table 3, col. 9"`),
    a locator object, or a list of them (the result appears in several places)."""
    rec = to_json(record)
    meta = rec.get("meta") if isinstance(rec.get("meta"), dict) else {}
    if not meta.get("id"):
        raise EstimationError("a member record needs meta.id (write or prepare the record first)")
    m: dict[str, Any] = {"id": meta["id"]}
    if meta.get("created"):
        m["created"] = meta["created"]
    if label is not None:
        m["label"] = label
    m.update(_locator_fields(locator))
    if notes is not None:
        m["notes"] = notes
    if sha256:
        m["sha256"] = member_sha256(rec)
    m["record"] = rec
    return m


def new_collection(
    records: Iterable[dict] | Mapping[str, dict],
    *,
    kind: str,
    labels: Iterable[str | None] | None = None,
    locators: Iterable[Any] | None = None,
    publication: dict | None = None,
    session: dict | None = None,
    events: list[dict] | None = None,
    provenance: dict | None = None,
    sha256: bool = True,
    level: int | None = None,
    schema: Schemas | str | None = "auto",
    **meta: Any,
) -> dict:
    """A collection embedding `records`, in the order given. A mapping gives the labels by
    its keys. `labels` and `locators` line up with the records (None where there is none).
    Other keyword arguments go into `meta` (title, tags, notes).

    `level` is the collection's disclosure level (spec 11.7): the collection's own fields
    above it are left out, and each record above it is lowered with `reduce` (a new record;
    event `member` references follow). A session or replication collection needs level 4 or
    more. The default, None, declares no level and leaves the records as they are: a tool
    that writes the records and their collection passes the level it writes records at
    (DEFAULT_LEVEL, 4, unless the user chose another)."""
    if kind not in KINDS:
        raise EstimationError(f"kind must be one of {', '.join(KINDS)}, not {kind!r}")
    if isinstance(records, Mapping):
        if labels is None:
            labels = list(records.keys())
        records = list(records.values())
    records = list(records)
    labels = list(labels) if labels is not None else [None] * len(records)
    locators = list(locators) if locators is not None else [None] * len(records)
    if len(labels) != len(records) or len(locators) != len(records):
        raise EstimationError("labels and locators must have one entry per record")
    members = [
        new_member(r, label=lab, locator=loc, sha256=sha256) for r, lab, loc in zip(records, labels, locators)
    ]
    ids = [m["id"] for m in members]
    dup = sorted({i for i in ids if ids.count(i) > 1})
    if dup:
        raise EstimationError(
            f"records {', '.join(dup)} appear more than once: one member per record, with locators"
        )
    coll: dict[str, Any] = {
        "schema": COLLECTION_SCHEMA,
        "meta": {"id": str(uuid.uuid4()), "created": _now(), "kind": kind, **meta},
    }
    for k, v in (("publication", publication), ("session", session), ("provenance", provenance)):
        if v is not None:
            coll[k] = to_json(v)
    coll["members"] = members
    if events is not None:
        coll["events"] = to_json(events)
    if level is not None:
        schemas = load_schemas() if isinstance(schema, str) and schema == "auto" else schema
        coll, _ = _at_level(coll, level, schemas, None)
    return coll


def add_event(
    collection: dict,
    type: str,
    *,
    member: str | None = None,
    detail: dict | None = None,
    message: str | None = None,
    when: str | _dt.datetime | None = None,
) -> dict:
    """Append one event to `collection["events"]` in place and return the event."""
    ev: dict[str, Any] = {"when": to_json(when) if when is not None else _now(), "type": type}
    if member is not None:
        ev["member"] = member
    if detail is not None:
        ev["detail"] = to_json(detail)
    if message is not None:
        ev["message"] = message
    collection.setdefault("events", []).append(ev)
    return ev


# ---------------------------------------------------------------- disclosure levels (11.7)

# Kinds whose required parts are level 4 (a session's block and events; a replication's events)
MIN_LEVEL_BY_KIND = {"session": 4, "replication": 4}


def collection_level_marks(schemas: Schemas | None = None) -> list:
    """The collection schema's level marks for the collection's own fields (members'
    records are judged by the record marks)."""
    schemas = schemas or load_schemas()
    if schemas is None or schemas.collection is None:
        return _compile(
            {k: (1, ()) for k in ("schema", "meta", "members", "publication", "attachments", "history")}
        )
    marks = level_marks(schemas.collection, schemas.documents())
    return _compile({p: v for p, v in marks.items() if not p.startswith("members[*].record")})


def _shell(coll: dict) -> dict:
    """The collection without `members`: its own fields, sharing objects with `coll`."""
    return {k: v for k, v in coll.items() if k != "members"}


def _member_needs(rec: dict, level: int, schemas: Schemas | None) -> bool:
    declared = _declared_level(rec)
    if declared is not None and declared > level:
        return True
    return bool(_above(rec, level, record_level_marks(rec, schemas)))


def _at_level(coll: dict, level: int, schemas: Schemas | None, by: dict | None) -> tuple[dict, list[str]]:
    """`coll` (embedded) cut to `level` in place: each member record above it lowered with
    `reduce` (a new record; member ids and event references follow), the collection's own
    fields above it removed, and `meta.disclosure` set. Returns it and the paths removed."""
    if level not in LEVELS:
        raise EstimationError(f"disclosure level must be one of 1-5, got {level!r}")
    kind = (coll.get("meta") or {}).get("kind")
    need = MIN_LEVEL_BY_KIND.get(kind, 1)
    if level < need:
        raise EstimationError(f"a {kind} collection needs disclosure level {need} or more, not {level}")
    renamed: dict[str, str] = {}
    for m in coll.get("members") or []:
        rec = m.get("record")
        if not isinstance(rec, dict) or not _member_needs(rec, level, schemas):
            continue
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")  # dropped profile claims are said in the record
            low = reduce(rec, level, schema=schemas if schemas is not None else "auto", by=by)
        renamed[m["id"]] = low["meta"]["id"]
        m["id"] = low["meta"]["id"]
        m["record"] = low
        if "created" in m and low["meta"].get("created"):
            m["created"] = low["meta"]["created"]
        if "sha256" in m:
            m["sha256"] = member_sha256(low)
    for e in coll.get("events") or []:
        if isinstance(e, dict) and e.get("member") in renamed:
            e["member"] = renamed[e["member"]]
    shell = _shell(coll)
    hits = _above(shell, level, collection_level_marks(schemas))
    touched: set[int] = set()
    removed = []
    for container, key, p, _ in sorted(hits, key=lambda h: (isinstance(h[1], int), h[1]), reverse=True):
        del container[key]
        touched.add(id(container))
        removed.append(p)
    _prune(shell, touched)
    out = {**shell, "members": coll.get("members", [])}
    out.setdefault("meta", {})["disclosure"] = {"level": level}
    return _ordered(out), sorted(removed)


def reduce_collection(
    collection: dict,
    level: int,
    *,
    schema: Schemas | str | None = "auto",
    base_dir: str | os.PathLike | None = None,
    by: dict | None = None,
) -> dict:
    """A copy of `collection` at disclosure `level` (spec 4.9, 11.7): each member record
    above it lowered with `reduce` (a new record with `meta.parent`, so its member id and the
    events that name it change too), and the collection's own fields above it removed. The
    copy is a new collection: a new `meta.id`, `meta.parent` set to the original's, and a
    `history` entry with `action: "reduced"`. Members in a members file are read from
    `base_dir` and come back embedded."""
    schemas = load_schemas() if isinstance(schema, str) and schema == "auto" else schema
    coll = _embedded(collection, base_dir)
    old_id = (coll.get("meta") or {}).get("id")
    coll, removed = _at_level(coll, level, schemas, by)
    meta = coll["meta"]
    if old_id:
        meta["parent"] = old_id
    meta["id"] = str(uuid.uuid4())
    entry: dict[str, Any] = {
        "when": _now() if level > 1 else _now()[:10],
        "action": "reduced",
        "level": level,
    }
    if level >= 4:
        entry["by"] = by or _producer()
    entry["fields"] = removed
    coll.setdefault("history", []).append(entry)
    return coll


def _level_issues(coll: dict, members: list, base_dir, schemas: Schemas | None) -> list[Issue]:
    """With a declared level: an error for each of the collection's own fields above it, for
    a kind that needs more, and for each member record above it."""
    meta = coll.get("meta") if isinstance(coll.get("meta"), dict) else {}
    level = _declared_level(coll)
    if level is None:
        if "disclosure" in meta:
            return [Issue("error", "meta.disclosure.level", "must be an integer from 1 to 5")]
        return []
    out = []
    need = MIN_LEVEL_BY_KIND.get(meta.get("kind"), 1)
    if level < need:
        out.append(
            Issue(
                "error",
                "meta.disclosure.level",
                f"a {meta.get('kind')} collection needs level {need} or more",
            )
        )
    for _, _, p, n in _above(_shell(coll), level, collection_level_marks(schemas)):
        out.append(Issue("error", p, f"level {n} field in a collection declared at disclosure level {level}"))
    for i, m, rec in iter_members(coll, base_dir):
        if not isinstance(rec, dict):
            continue
        declared = _declared_level(rec)
        if declared is not None and declared > level:
            out.append(
                Issue(
                    "error",
                    f"members[{i}].record.meta.disclosure.level",
                    f"member declared at level {declared}, above the collection's {level}",
                )
            )
        elif declared is None:
            for _, _, p, n in _above(rec, level, record_level_marks(rec, schemas)):
                out.append(
                    Issue(
                        "error",
                        f"members[{i}].record.{p}",
                        f"level {n} field in a member of a collection declared at disclosure level {level}",
                    )
                )
    return out


# ---------------------------------------------------------------- members files


def _members_attachments(coll: dict) -> dict[str, dict]:
    return {
        a["id"]: a
        for a in coll.get("attachments") or []
        if isinstance(a, dict) and isinstance(a.get("id"), str)
    }


def _read_members_file(path: Path) -> dict[str, dict]:
    """Records in a JSON Lines members file, by meta.id, as written (non-finite as strings)."""
    out: dict[str, dict] = {}
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            if not line.strip():
                continue
            rec = json.loads(line, parse_constant=_reject_constant)
            if not isinstance(rec, dict):
                raise EstimationError(f"{path}:{n}: each line of a members file is one record")
            rid = (rec.get("meta") or {}).get("id") if isinstance(rec.get("meta"), dict) else None
            if rid:
                out[rid] = rec
    return out


class _Files:
    """Members files of one collection, read once each."""

    def __init__(self, coll: dict, base_dir: str | os.PathLike | None):
        self.atts = _members_attachments(coll)
        self.base = Path(base_dir) if base_dir is not None else None
        self.cache: dict[str, dict[str, dict] | None] = {}

    def path(self, att_id: str) -> Path | None:
        a = self.atts.get(att_id)
        if a is None or self.base is None or "://" in str(a.get("path", "")):
            return None
        return self.base / a["path"]

    def records(self, att_id: str) -> dict[str, dict] | None:
        if att_id not in self.cache:
            p = self.path(att_id)
            self.cache[att_id] = _read_members_file(p) if p is not None and p.is_file() else None
        return self.cache[att_id]


def iter_members(
    collection: dict, base_dir: str | os.PathLike | None = None
) -> Iterator[tuple[int, dict, dict | None]]:
    """(index, member entry, record) for each member: the embedded record, or the one in its
    members file under `base_dir` (the collection's folder); None when it can't be found."""
    files = _Files(collection, base_dir)
    for i, m in enumerate(collection.get("members") or []):
        if not isinstance(m, dict):
            yield i, m, None
        elif isinstance(m.get("record"), dict):
            yield i, m, m["record"]
        elif isinstance(m.get("attachment"), str):
            recs = files.records(m["attachment"])
            yield i, m, None if recs is None else recs.get(m.get("id"))
        else:
            yield i, m, None


def _embedded(collection: dict, base_dir: str | os.PathLike | None) -> dict:
    """A copy with every member's record embedded (members files read) and the members
    attachments removed. Raises if a record can't be found."""
    coll = copy.deepcopy(to_json(collection))
    roles = {a.get("id") for a in coll.get("attachments") or [] if a.get("role") == MEMBERS_ROLE}
    used = set()
    members = []
    for i, m, rec in iter_members(coll, base_dir):
        if rec is None:
            where = f" in {m.get('attachment')!r}" if isinstance(m, dict) and "attachment" in m else ""
            raise EstimationError(
                f"members[{i}]: record {m.get('id') if isinstance(m, dict) else m!r} not found{where}"
                + ("" if base_dir is not None or not where else "; pass base_dir (the collection's folder)")
            )
        m = dict(m)
        used.add(m.pop("attachment", None))
        m["record"] = rec
        members.append(m)
    coll["members"] = members
    drop = (roles | used) - {None}
    if "attachments" in coll:
        coll["attachments"] = [a for a in coll["attachments"] if a.get("id") not in drop]
        if not coll["attachments"]:
            del coll["attachments"]
    return coll


def _without_records(coll: dict, placeholder: bool = False) -> dict:
    """The collection with each embedded record left out (or, with `placeholder`, replaced
    by `{}`, so a schema still sees which members embed one)."""
    view = dict(coll)
    view["members"] = [
        {
            k: ({} if placeholder and isinstance(v, dict) else v)
            for k, v in m.items()
            if placeholder or k != "record"
        }
        if isinstance(m, dict)
        else m
        for m in coll.get("members") or []
    ]
    return view


# ---------------------------------------------------------------- write and read


def _stem(path: Path) -> str:
    name = path.name
    for suffix in (".json", ".estrec-collection"):
        name = name.removesuffix(suffix)
    return name


def write_collection(
    collection: dict,
    path: str | os.PathLike,
    *,
    members: str = "auto",
    source_dir: str | os.PathLike | None = None,
    by: dict | None = None,
    indent: int | None = 1,
) -> dict:
    """Write `collection` to `path` (`<name>.estrec-collection.json`) and return it as
    written.

    `members="embed"` keeps the records in the file; `"jsonl"` writes them to
    `<name>.members.jsonl` beside it, listed in `attachments`; `"auto"` (default) embeds
    unless the file would pass 16 MB. Members already in a members file are read from
    `source_dir` (default: the folder of `path`). Records are never changed; `meta.id` and
    `created` are filled if missing and a `history` entry is appended."""
    if members not in ("auto", "embed", "jsonl"):
        raise ValueError("members must be 'auto', 'embed' or 'jsonl'")
    path = Path(path)
    coll = _embedded(collection, source_dir if source_dir is not None else path.parent)
    coll.setdefault("schema", COLLECTION_SCHEMA)
    meta = coll.setdefault("meta", {})
    meta.setdefault("id", str(uuid.uuid4()))
    meta.setdefault("created", _now())
    entry = {
        "when": _now(),
        "by": by or _producer(),
        "action": "created",
        "sections": [k for k in SECTIONS if k in coll and k != "schema"],
    }
    level = _declared_level(coll)
    if level is not None:
        entry["level"] = level
        if level < 4:
            del entry["by"]  # withheld below level 4 (spec 4.9)
        if level == 1:
            entry["when"] = entry["when"][:10]
    coll.setdefault("history", []).append(entry)
    text = _dumps(_ordered(coll), indent)
    if members == "jsonl" or (members == "auto" and len(text.encode()) > FAIL_BYTES):
        coll = _to_members_file(coll, path)
        text = _dumps(_ordered(coll), indent)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text + "\n", encoding="utf-8")
    os.replace(tmp, path)
    return coll


def _ordered(coll: dict) -> dict:
    """Top-level sections in SECTIONS order, so a reader sees what the collection is before
    its records."""
    return {k: coll[k] for k in SECTIONS if k in coll} | {k: v for k, v in coll.items() if k not in SECTIONS}


def _to_members_file(coll: dict, path: Path) -> dict:
    """Move every embedded record to `<name>.members.jsonl` beside `path`."""
    file = path.with_name(_stem(path) + ".members.jsonl")
    taken = {a.get("id") for a in coll.get("attachments") or []}
    att_id = "members"
    n = 1
    while att_id in taken:
        n += 1
        att_id = f"members{n}"
    tmp = file.with_name(file.name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.writelines(_dumps(m["record"]) + "\n" for m in coll["members"])
    os.replace(tmp, file)
    coll["members"] = [
        {**{k: v for k, v in m.items() if k != "record"}, "attachment": att_id} for m in coll["members"]
    ]
    coll.setdefault("attachments", []).append(
        {
            "id": att_id,
            "role": MEMBERS_ROLE,
            "path": file.name,
            "media_type": MEMBERS_MEDIA_TYPE,
            "created": _now(),
            "sha256": _sha256_file(file),
            "bytes": file.stat().st_size,
            "rows": len(coll["members"]),
        }
    )
    return coll


def loads_collection(text: str | bytes, *, nonfinite: str = "float") -> dict:
    coll = json.loads(text, parse_constant=_reject_constant)
    if not is_collection(coll):
        raise EstimationError("not an estrec-collection (schema must be 'estrec-collection/<version>')")
    if nonfinite == "float":
        return _decode_members(coll)
    if nonfinite != "string":
        raise ValueError("nonfinite must be 'float' or 'string'")
    return coll


def _decode_members(coll: dict) -> dict:
    out = dict(coll)
    out["members"] = [
        {**m, "record": decode_nonfinite(m["record"])}
        if isinstance(m, dict) and isinstance(m.get("record"), dict)
        else m
        for m in coll.get("members") or []
    ]
    return out


def read_collection(
    path: str | os.PathLike,
    *,
    nonfinite: str = "float",
    embed: bool = False,
    check: bool = False,
) -> dict:
    """Load a collection. With `embed=True`, records in a members file are read into their
    member entries (and the members attachment dropped). Non-finite values are decoded as by
    `read`. With `check=True`, raise if `validate_collection` finds an error."""
    path = Path(path)
    coll = loads_collection(path.read_bytes(), nonfinite="string")
    if check:
        errors = [i for i in validate_collection(coll, base_dir=path.parent) if i.level == "error"]
        if errors:
            raise EstimationError(f"{path}: " + "; ".join(map(str, errors)))
    if embed:
        coll = _embedded(coll, path.parent)
    return _decode_members(coll) if nonfinite == "float" else coll


# ---------------------------------------------------------------- validator


def _parse_time(s: Any) -> _dt.datetime | None:
    if not isinstance(s, str):
        return None
    m = re.match(r"^(\d{4}-\d{2}-\d{2})[Tt ](\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|z|[+-]\d{2}:\d{2})?$", s)
    if not m:
        return None
    frac = (m.group(3) or "0")[:6].ljust(6, "0")
    tz = m.group(4) or "Z"
    tz = "+00:00" if tz in ("Z", "z") else tz
    try:
        return _dt.datetime.fromisoformat(f"{m.group(1)}T{m.group(2)}.{frac}{tz}")
    except ValueError:
        return None


def _loc_key(loc: Any) -> dict | None:
    if not isinstance(loc, dict):
        return None
    return {k: str(v) for k, v in loc.items() if k != "label" and v is not None}


def _locs(obj: Any) -> list[dict]:
    if not isinstance(obj, dict):
        return []
    if isinstance(obj.get("locators"), list):
        return [x for x in obj["locators"] if isinstance(x, dict)]
    return [obj["locator"]] if isinstance(obj.get("locator"), dict) else []


def _doi(pub: Any) -> str | None:
    cit = pub.get("citation") if isinstance(pub, dict) else None
    doi = cit.get("DOI") if isinstance(cit, dict) else None
    return doi.strip().lower() if isinstance(doi, str) and doi.strip() else None


def _structure(coll: dict) -> list[Issue]:
    """The collection's shape by hand, for when no JSON Schema is in use."""
    issues: list[Issue] = []
    err = lambda p, m: issues.append(Issue("error", p, m))
    if coll.get("schema") != COLLECTION_SCHEMA:
        err("schema", f"expected {COLLECTION_SCHEMA!r}, got {coll.get('schema')!r}")
    for k in ("meta", "members"):
        if k not in coll:
            err(k, "required section missing")
    meta = coll.get("meta")
    if "meta" in coll and not isinstance(meta, dict):
        err("meta", "must be an object")
    elif isinstance(meta, dict):
        for k in ("id", "created", "kind"):
            if k not in meta:
                err(f"meta.{k}", "required")
        if "kind" in meta and meta["kind"] not in KINDS:
            err("meta.kind", f"must be one of {', '.join(KINDS)}")
    if "members" in coll and not isinstance(coll["members"], list):
        err("members", "must be a list")
    for i, m in enumerate(coll.get("members") if isinstance(coll.get("members"), list) else []):
        p = f"members[{i}]"
        if not isinstance(m, dict):
            err(p, "must be an object")
            continue
        if not isinstance(m.get("id"), str):
            err(f"{p}.id", "required string")
        if ("record" in m) == ("attachment" in m):
            err(p, "needs exactly one of 'record' and 'attachment'")
        elif "record" in m and not isinstance(m["record"], dict):
            err(f"{p}.record", "must be an object (a record)")
        if "locator" in m and "locators" in m:
            err(p, "has both 'locator' and 'locators'")
    for k in ("publication", "session", "provenance", "extensions"):
        if k in coll and not isinstance(coll[k], dict):
            err(k, "must be an object")
    if isinstance(meta, dict) and meta.get("kind") == "session":
        if not isinstance(coll.get("session"), dict) or "id" not in coll["session"]:
            err("session.id", "required for kind 'session'")
    elif isinstance(coll.get("session"), dict) and "id" not in coll["session"]:
        err("session.id", "required when session is present")
    for k in ("events", "attachments", "history"):
        if k in coll and not isinstance(coll[k], list):
            err(k, "must be a list")
    for i, e in enumerate(coll.get("events") if isinstance(coll.get("events"), list) else []):
        if not isinstance(e, dict) or "when" not in e or not isinstance(e.get("type"), str):
            err(f"events[{i}]", "needs 'when' and a string 'type'")
    for i, a in enumerate(coll.get("attachments") if isinstance(coll.get("attachments"), list) else []):
        if not isinstance(a, dict) or not a.get("id") or not a.get("path"):
            err(f"attachments[{i}]", "needs 'id' and 'path'")
    for k in coll:
        if k not in SECTIONS:
            err(k, "unknown section (tool-specific content belongs in extensions)")
    return issues


def _resolve_schemas(schema: Any) -> tuple[Schemas | None, list[Issue]]:
    if isinstance(schema, str) and schema == "auto":
        schemas = load_schemas()
        if schemas is None:
            return None, [Issue("info", "", "no packaged schemas; used the built-in checks")]
        if not _have_jsonschema():
            return None, [
                Issue("info", "", "the 'jsonschema' package is not installed; used the built-in checks")
            ]
        return schemas, []
    if schema is None or isinstance(schema, Schemas):
        return schema, []
    raise TypeError("schema must be 'auto', a Schemas or None")


def validate_collection(
    collection: dict,
    *,
    schema: Schemas | str | None = "auto",
    base_dir: str | os.PathLike | None = None,
) -> list[Issue]:
    """Check a collection (as read, or as returned by `write_collection`) and each member
    record (core and claimed profiles, via `validate`), and return the issues (spec 11.6).
    A member's issues are reported under `members[<i>].record`. With `base_dir` (the
    collection's folder), records in a members file are read and checked, and the files'
    hashes compared. `schema` is as in `validate` ("auto", a `Schemas`, or None for the
    built-in checks only)."""
    if not isinstance(collection, dict):
        return [Issue("error", "", "an estimation collection is a JSON object")]
    schemas, issues = _resolve_schemas(schema)
    try:
        coll = to_json(collection)
    except (EstimationError, ValueError) as e:
        return [*issues, Issue("error", "", f"not encodable as JSON: {e}")]
    err = lambda p, m: issues.append(Issue("error", p, m))
    warn = lambda p, m: issues.append(Issue("warning", p, m))
    info = lambda p, m: issues.append(Issue("info", p, m))

    if schemas is not None and schemas.collection is not None:
        issues += jsonschema_check(schemas.collection, schemas.documents())(_without_records(coll, True))
        for i, m in enumerate(coll.get("members") or []):
            if isinstance(m, dict) and "record" in m and not isinstance(m["record"], dict):
                err(f"members[{i}].record", "must be an object (a record)")
    else:
        issues += _structure(coll)

    # no size limits on the collection itself (spec 11.7); its records are checked one by one

    meta = coll.get("meta") if isinstance(coll.get("meta"), dict) else {}
    kind = meta.get("kind")
    members = coll.get("members") if isinstance(coll.get("members"), list) else []
    atts = _members_attachments(coll)
    files = _Files(coll, base_dir)
    pub_doi = _doi(coll.get("publication"))

    # members files: found, hash
    for att_id in sorted({m.get("attachment") for m in members if isinstance(m, dict)} - {None}):
        if not isinstance(att_id, str):
            continue
        if att_id not in atts:
            continue  # reported per member below
        p = files.path(att_id)
        if p is None:
            info(
                f"attachments.{att_id}", "members file not read (pass base_dir); its records weren't checked"
            )
        elif not p.is_file():
            info(
                f"attachments.{att_id}",
                f"members file not found: {atts[att_id].get('path')}; its records weren't checked",
            )
        elif atts[att_id].get("sha256") and _sha256_file(p) != atts[att_id]["sha256"]:
            warn(f"attachments.{att_id}", "members file does not match its sha256")

    ids: set[str] = set()
    for i, m, rec in iter_members(coll, base_dir):
        p = f"members[{i}]"
        if not isinstance(m, dict):
            continue
        mid = m.get("id")
        if isinstance(mid, str):
            if mid in ids:
                err(f"{p}.id", f"duplicate id {mid!r}: a record shown twice is one member with locators")
            ids.add(mid)
        att = m.get("attachment")
        if isinstance(att, str) and att not in atts:
            err(f"{p}.attachment", f"no attachment with id {att!r}")
        elif isinstance(att, str) and rec is None and files.records(att) is not None:
            warn(p, f"record {mid!r} not in members file {att!r}")
        if rec is None:
            continue
        rid = (rec.get("meta") or {}).get("id") if isinstance(rec.get("meta"), dict) else None
        if rid != mid:
            err(f"{p}.id", f"is {mid!r} but the record's meta.id is {rid!r}")
        if isinstance(m.get("sha256"), str):
            try:
                ok = member_sha256(rec) == m["sha256"]
            except EstimationError as e:
                ok = False
                warn(f"{p}.sha256", f"can't compute: {e}")
            if not ok:
                warn(f"{p}.sha256", "does not match the record: the collection holds another version")
        rec_locs = [_loc_key(x) for x in _locs(rec.get("publication"))]
        if rec_locs:
            for j, loc in enumerate(_locs(m)):
                if _loc_key(loc) not in rec_locs:
                    where = f"{p}.locators[{j}]" if "locators" in m else f"{p}.locator"
                    warn(where, "matches none of the record's publication locators")
        rec_doi = _doi(rec.get("publication"))
        if pub_doi and rec_doi and rec_doi != pub_doi:
            warn(f"{p}.record.publication.citation.DOI", f"{rec_doi} differs from the collection's {pub_doi}")
        prefix = f"{p}.record"
        for issue in validate(rec, schema=schemas, base_dir=base_dir):
            if issue.level == "info" and not issue.path:  # e.g. "used the built-in checks": once
                if issue not in issues:
                    issues.append(issue)
                continue
            issues.append(
                Issue(issue.level, f"{prefix}.{issue.path}" if issue.path else prefix, issue.message)
            )

    events = coll.get("events") if isinstance(coll.get("events"), list) else []
    last = None
    fit_members = set()
    for j, e in enumerate(events):
        if not isinstance(e, dict):
            continue
        if "member" in e and e["member"] not in ids:
            err(f"events[{j}].member", f"no member with id {e['member']!r}")
        if e.get("type") == "fit" and "member" in e:
            fit_members.add(e["member"])
        t = _parse_time(e.get("when"))
        if t is not None:
            if last is not None and t < last:
                warn(f"events[{j}].when", "earlier than the event before: events are in time order")
            last = t

    issues += _level_issues(coll, members, base_dir, schemas if schemas is not None else load_schemas())

    # what each kind expects (11.6)
    if kind == "paper":
        if not members:
            warn("members", "[paper] expected at least one member")
        cit = (
            (coll.get("publication") or {}).get("citation")
            if isinstance(coll.get("publication"), dict)
            else None
        )
        if not cit:
            warn("publication.citation", "[paper] expected, missing")
        for i, m in enumerate(members):
            if isinstance(m, dict) and "locator" not in m and "locators" not in m:
                warn(f"members[{i}]", "[paper] expected a locator, none present")
    elif kind == "session":
        if "events" not in coll:
            warn("events", "[session] expected, missing")
        sid = (coll.get("session") or {}).get("id") if isinstance(coll.get("session"), dict) else None
        for i, m, rec in iter_members(coll, base_dir):
            if not isinstance(m, dict):
                continue
            if "events" in coll and m.get("id") not in fit_members:
                warn(f"members[{i}]", "[session] expected a fit event for this member, none present")
            if rec is not None and sid is not None:
                ex = (
                    ((rec.get("provenance") or {}).get("execution") or {})
                    if isinstance(rec.get("provenance"), dict)
                    else {}
                )
                got = ex.get("session") if isinstance(ex, dict) else None
                if got != sid:
                    warn(
                        f"members[{i}].record.provenance.execution.session",
                        "[session] missing"
                        if got is None
                        else f"[session] is {got!r}, not the session's {sid!r}",
                    )
    elif kind == "replication":
        for k in ("events", "publication"):
            if k not in coll:
                warn(k, "[replication] expected, missing")
    return issues


# ---------------------------------------------------------------- redactor


def collection_identifying_paths(schemas: Schemas | None) -> list[str]:
    """The collection's own identifying paths (not its members'): those its schema marks
    `x-identifying`, or COLLECTION_IDENTIFYING without schemas."""
    if schemas is None or schemas.collection is None:
        return list(COLLECTION_IDENTIFYING)
    found = identifying_paths(schemas.collection, schemas.documents())
    return [p for p in found if not p.startswith("members")]


def redact_collection(
    collection: dict,
    *,
    salt: bytes | str | None = None,
    schema: Schemas | str | None = "auto",
    base_dir: str | os.PathLike | None = None,
    paths: Iterable[str] = (),
    by: dict | None = None,
) -> dict:
    """A copy of `collection` with its identifying fields and every member record's removed
    or, with `salt`, HMAC-hashed (as `redact`), each under its own schema marks. Records in a
    members file are read from `base_dir` and come back embedded (`write_collection` decides
    again where they go). Member hashes that are present are recomputed. Each member and the
    collection get a `history` entry. `paths` adds collection paths to redact."""
    schemas = load_schemas() if isinstance(schema, str) and schema == "auto" else schema
    if schemas is not None and not isinstance(schemas, Schemas):
        raise TypeError("schema must be 'auto', a Schemas or None")
    coll = _embedded(collection, base_dir)
    members = coll.pop("members")
    out = redact(coll, paths=[*collection_identifying_paths(schemas), *paths], salt=salt, by=by)
    redacted = []
    for m in members:
        rec = redact(m["record"], schema=schemas, salt=salt, by=by)
        m = {**m, "record": rec}
        if "sha256" in m:
            m["sha256"] = member_sha256(rec)
        redacted.append(m)
    out["members"] = redacted  # each member's own history entry lists its fields
    return _ordered(out)
