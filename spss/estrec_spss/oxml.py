"""Reads SPSS OMS output in OXML (the XML OMS writes with FORMAT=OXML) into plain tables.

Each procedure ("command") becomes a `Command` with its pivot tables; each table is a list of
`Cell`s, each with the row and column labels on the path to it (outermost first) and the
cell's full-precision number (OXML's `number` attribute) or text. Labels are SPSS's display
text in the output language, so ESTREC BEGIN sets OLANG=ENGLISH while capturing. A category
for a variable also carries its name (`varName`)."""

from __future__ import annotations

import xml.etree.ElementTree as ET
from dataclasses import dataclass, field


def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


@dataclass
class Label:
    text: str
    var: str | None = None  # varName, when the category is a variable

    def __repr__(self) -> str:
        return f"{self.text}<{self.var}>" if self.var else self.text


@dataclass
class Cell:
    row: tuple[Label, ...]
    col: tuple[Label, ...]
    number: float | None
    text: str | None

    @property
    def value(self):
        return self.number if self.number is not None else self.text


@dataclass
class Table:
    subtype: str
    title: str
    cells: list[Cell] = field(default_factory=list)
    footnotes: list[str] = field(default_factory=list)

    def rows(self) -> list[tuple[Label, ...]]:
        seen: dict = {}
        for c in self.cells:
            seen.setdefault(tuple(l.text for l in c.row), c.row)
        return list(seen.values())

    def get(self, row: tuple[str, ...] | str, col: tuple[str, ...] | str):
        """The cell value whose row and column labels end with `row` and `col` (texts)."""
        row = (row,) if isinstance(row, str) else tuple(row)
        col = (col,) if isinstance(col, str) else tuple(col)
        for c in self.cells:
            rt = tuple(l.text for l in c.row)
            ct = tuple(l.text for l in c.col)
            if rt[len(rt) - len(row):] == row and ct[len(ct) - len(col):] == col:
                return c.value
        return None


@dataclass
class Command:
    name: str  # OMS command identifier, e.g. "Regression"
    text: str
    tables: list[Table] = field(default_factory=list)
    texts: list[str] = field(default_factory=list)  # warnings and log text blocks

    def table(self, subtype: str, title_startswith: str | None = None, nth: int = 0) -> Table | None:
        found = [t for t in self.tables if t.subtype == subtype
                 and (title_startswith is None or t.title.startswith(title_startswith))]
        return found[nth] if len(found) > nth else None


def _num(s: str | None) -> float | None:
    if s is None or s == "":
        return None
    try:
        return float(s)
    except ValueError:
        return None


def _walk(el, row: tuple, col: tuple, out: list[Cell]) -> None:
    """Depth-first through dimension/group/category nesting, collecting cells."""
    for ch in el:
        tag = _local(ch.tag)
        if tag == "dimension":
            axis = ch.get("axis")
            _walk_dim(ch, axis, row, col, out)
        elif tag == "cell":
            out.append(Cell(row, col, _num(ch.get("number")), ch.get("text")))


def _walk_dim(dim, axis: str, row: tuple, col: tuple, out: list[Cell]) -> None:
    for ch in dim:
        tag = _local(ch.tag)
        if tag in ("category", "group"):
            lab = Label(ch.get("text") or ch.get("label") or "", ch.get("varName"))
            r, c = (row + (lab,), col) if axis == "row" else (row, col + (lab,))
            if tag == "group":
                _walk_dim(ch, axis, r, c, out)
            else:
                _walk(ch, r, c, out)


def parse(path_or_text) -> list[Command]:
    """The commands in an OXML file (path) or string."""
    if isinstance(path_or_text, str) and path_or_text.lstrip().startswith("<"):
        root = ET.fromstring(path_or_text)
    else:
        root = ET.parse(path_or_text).getroot()
    commands = []
    for cmd in root.iter():
        if _local(cmd.tag) != "command":
            continue
        c = Command(cmd.get("command") or "", cmd.get("text") or "")
        for el in cmd.iter():
            tag = _local(el.tag)
            if tag == "pivotTable":
                t = Table(el.get("subType") or "", el.get("text") or "")
                for fn in el.iter():
                    if _local(fn.tag) == "note" and fn.get("text"):
                        t.footnotes.append(fn.get("text"))
                _walk(el, (), (), t.cells)
                c.tables.append(t)
            elif tag == "textBlock":
                txt = el.get("text") or "".join(el.itertext())
                if txt.strip():
                    c.texts.append(txt.strip())
        commands.append(c)
    return commands
