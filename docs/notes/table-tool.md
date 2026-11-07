# Table tool: state and backlog

Handoff notes from the Record viewer chat (f69fc03f, 2026-11-05/06) for the chat that keeps
improving the table tool. Decisions are Ted's unless marked as a proposal.

## What exists

| Piece | Where | Notes |
|---|---|---|
| Table spec | `spec/table.md`, `schema/estrec-table-0.1.json`, `schema/examples/paper.estrec-table.json` | Own document type, versioned apart from the record format (adopted; `docs/proposals/table-spec.md`). Holds layout only, never numbers |
| Python | `src/estrec/views.py` (`tidy`, `glance`, `parameters_table`), `table.py` (`new_table`, `validate_table`, `build_table`, `render`, `render_table`, `to_great_table`), `show.py` | Renderers: text, markdown, latex, html, csv, word; great_tables optional |
| CLI | `estrec show`, `estrec table`, `estrec validate` (detects table specs) | In `records.py` `main()` |
| R (estrec) | `r/R/read.R` (`read_estimation`, `read_collection`, `tidy`/`glance` methods), `r/R/table.R` (`render_table` through modelsummary) | `S3method(generics::tidy, ...)` registered lazily |
| Viewer | `viewer/index.html`, `viewer/estrec-table.js` (UMD: `window.EstTable` / node), generated `examples.js`, `identifying.js` (`python viewer/make_examples.py`) | Static page; Pages deploys it at `/estimation/viewer/` |
| Tests | `tests/test_table.py`, `test_views.py`, `test_show.py`, `test_viewer.py` (+ `viewer_check.js`, node 24); `r/tests/testthat/test-table.R`, `test-read.R` | JS and Python must build identical tables; R matches cell for cell on the example |

Viewer features: drag-and-drop of files and folders; record detail tab; **New table**,
**+ Table** per record, **Table from these** per file; per-column vcov, component, response;
terms (rename, merge, keep/drop); statistics rows (metric, vcov type, clusters, FE yes/no,
test, literal); lines under each estimate (names or templates such as `[{p_value}]`, p-value
decimals, rounded 0.000 or bounded <0.001); live preview whose column heads summarise on
hover and open the record on click; export LaTeX, Markdown, HTML, CSV, text, **Web page**
(self-contained HTML with the records embedded, identifying fields left out by default) and
the table spec (optionally pinning record versions by sha256), and **Word**: Copy puts the
table on the clipboard as inline-styled HTML (three rules, centred numbers, 10 pt, no font
family) plus the text rendering as plain text, for pasting into Word, Google Docs,
LibreOffice or Excel; Save file gives an .html file Word opens.

Decisions so far:

- Presentation, not estimation: renderers need not agree on digits.
  There's no cross-renderer rounding rule.
- `uncertainty` can be a list (one row per line); `format.p_digits` sets p-value decimals;
  `format.p_style` is `fixed` or `less_than`.
- Star cuts (Ted, 2026-11-06): `* .1, ** .05, *** .01` everywhere a default is needed
  (`new_table`, the viewer, `estrec show`); the spec has no default (absent = no stars).
- Heading rows (Ted, 2026-11-06): `(1)`, `(2)`, ... on top and the dependent variable
  under them, whichever way the columns were added; no stub label. Column labels are an
  optional row that can move above the numbers or replace the dependent variable. Spec
  `head` (ordered `number` / `response` / `label`, default `["number", "response"]`) and
  `response_labels`; `header` is now the label row only. The built table has `head` (rows
  of `{kind, cells}`) and `header` (the numbers). Markdown and modelsummary have one heading
  row: the first; the others open the body. Viewer: "Heading rows" (on/off, up/down) and a
  name box per dependent variable.
- Interval sparklines (Ted, 2026-11-07): a line type `{"sparkline": {"color", "scale"}}`
  under each estimate. The CI is drawn as a coloured line with a dot at each end, the
  estimate as a darker dot (channels x 0.65) and 0 as a dark grey rule. `scale` is
  `column` (default; for event studies, leads and lags down a column read as a coefficient
  plot), `row` or `table`; an axis always holds 0. HTML, the web page and the viewer
  draw inline SVG; Word gets `<img>` of the SVG, and the viewer's Copy turns it into PNG
  (Word drops SVG on paste); text, Markdown, CSV, LaTeX, great_tables and R show
  `[low, high]`. Coordinates are rounded in integer tenths so JS and Python match.
  2026-11-07 (Ted: Word paste works; a column of sparklines alone; prettier marks): spec
  `"estimate": false` drops the estimate row (the first line carries the term's label, no
  stars; the viewer lists the estimate as a removable first item of "Each term");
  sparkline rows have no vertical padding and an 80x16 image whose 0 rule runs its full
  height, so stacked rows join; marks: a faint band swelling toward the estimate, a thin
  round-capped line, dots with a background-coloured halo (`var(--bg,#fff)`).
  Example spec `schema/examples/event-study.estrec-table.json` (csdid record, t-3..t+3,
  sparklines only; in the parity tests and R tests; the viewer's example note switches
  between example tables). Open: perhaps LaTeX (TikZ), R (tinytable images),
  great_tables (`gt.html`); a continuous 0 rule down a column (rows between break it now).
- Web export redacts the union of the schemas' `x-identifying` paths outside the digest
  sections (meta, specification, metrics, parameters, structures).

## How to work on it

- Keep JS and Python in step. Any change to building or rendering goes in both
  `table.py` and `estrec-table.js`. `tests/test_viewer.py` compares them in node.
- After a schema or example change, run `python viewer/make_examples.py`. A test fails if
  the generated files are stale.
- valiant has no browser. The UI was checked with a node DOM stand-in, so Ted reviews it via
  a private artifact preview (latest: https://claude.ai/artifact/En9fanz81wP5ueYEBHkFYB,
  v7 with interval sparklines (same link since v5; v6 heading rows, v5 the Word export); event-study sparkline example https://claude.ai/artifact/7p3VZjgZDwtsrH7pv7MikW, an inlined copy of `viewer/` without `publish.js`; v4 was
  https://claude.ai/artifact/FZJU8TRYRWEFpY64nnyy1Z; web-export example https://claude.ai/artifact/LmYbDiLtDB59NqohaPR3LN). Downloads
  don't work inside artifacts; they do on a normal host.
- R: `R CMD check` must stay clean. Use ASCII only in R code (`²` escapes). Ted
  installs packages.
- The Disclosure levels chat (05fe2fb6) also edits this repo, so commit only your own
  files.

## Table graphics chat (55cd4c58, 2026-11-07): done

- Sparklines drawn in LaTeX (TikZ; `_spark_tikz` / `sparkTikz`, the same x positions as the
  SVG via `_spark_xs`; 1 px = 0.75 pt, 12 pt rows; a first-line comment names
  `\usepackage{tikz}`), `to_great_table` (SVG in HTML, TikZ in LaTeX, through great_tables'
  private `FormatFns`) and estrec's `render_table` (tinytable outputs, per-output
  `format_tt`; strings equal to Python's, a pinned cell in both test suites). Not compiled:
  valiant has no TeX. Open: tinytable pads rows, so R's HTML column doesn't join.
- `show_table` is a wrapper over the table builder (layout as shown to Ted; he set FE rows to `Y`/`N`, and said nothing on the names-on-top question, so names stay on top;
  FE rows `Y`/`N` are the default everywhere: `format.fe_yes` / `fe_no`; estrec's
  `glance()` keeps fixest's `X`).

- Sparkline beside the estimates (Ted, 2026-11-07: option B, a sub-column whose cell spans
  the term's rows so the 0 rule runs alongside the estimates without gaps; viewer and Word
  only for now): spec `sparkline.place` `below` / `beside`; `_beside_plan` / `besidePlan`
  lay it out in HTML and Word (Python = JS byte for byte, 3 parity specs); the HTML cell is
  `position:relative` with an SVG of height 100% (marks in a nested SVG at y=50%); Word rows
  get `mso-height-rule:exactly` heights and the image their sum (untested in real Word).
  LaTeX, R, great_tables, text formats draw it below. Preview v10 (same link). Open: a
  missing term leaves its cell empty, so the 0 rule breaks there; LaTeX/R beside later.

## Earlier hand-off: sparklines everywhere and the `show_table` refactor (Ted, 2026-11-07)

1. **Sparklines in every renderer that can draw.** Today HTML, the web page, the viewer
   and Word draw them; text, Markdown, CSV, LaTeX, great_tables and estrec's
   `render_table` show `[low, high]`. To do:
   - LaTeX: a TikZ picture per cell (or one per column, so the 0 rule is continuous), with
     the preamble line (`\usepackage{tikz}`) in the notes or a comment. Match the SVG's
     marks: band, round-capped line, end dots, darker estimate dot, background halo.
   - great_tables: `gt.html` with the same SVG the HTML renderer writes.
   - R (estrec): modelsummary's tinytable backend can put images in cells (`plot_tt`);
     draw with base graphics or write the SVG; same marks and the same axes (column / row
     / table, always holding 0) as `_spark_domains`.
   - Keep JS and Python byte-identical; R matches cell for cell where it can, and a test
     says where it can't.
2. **`show_table` as a thin wrapper** over `new_table` + `build_table` + `render(...,
   "text")`, so `estrec show` can't drift from the table spec. It changes `show`'s
   layout; show Ted the before/after first.

Web-page export outside the viewer (backlog 2) is on hold: Ted is unsure about it.

## Backlog (proposals; ask Ted before changing behaviour)

1. ~~Star cuts~~: settled (above). Follow-up: make `show_table` a thin wrapper over
   `new_table` + `build_table` + `render(..., "text")` so it can't drift (changes `show`'s
   layout; after the rename).
   **Word export** (Ted asked for Word copy-paste; first version built, d7b97b1): check the
   paste in real Word (Windows and Mac) and Google Docs; then perhaps a real .docx file (no
   library in the browser: a small zip writer) and estrec `render_table(output = "word")`
   via modelsummary's docx output.
2. **Web-page export outside the viewer.** Add `render(..., "webpage")` in Python and
   `render_table(output = "webpage")` in estrec, reusing the viewer's template.
3. **Ted's first review in a real browser** once Pages serves the viewer. Collect his
   rough edges.
4. Possible additions:
   - several panels (Panel A/B) or column groups ("spanners") in the spec;
   - significance from a chosen test rather than the coefficient's p;
   - a viewer option to reorder columns by dragging;
   - an "open spec" round trip test for every exported spec;
   - per-row `digits` for estimate rows.
5. The **Publish** button in the viewer depends on the hosting server. That's the other
   chat's work (`docs/notes/rename-and-site.md`). Leave a hook only.

The rename to estrec (being decided in the other chat) will change type strings, file
names and the Python package name. Check with Ted whether it has landed before starting
large edits, so the two chats don't conflict.
