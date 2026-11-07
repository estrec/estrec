# Table specs (`estrec-table/0.1`)

Status: **0.1 draft.** A companion to the estrec format (`spec/estrec.md`),
versioned on its own. It doesn't change records or collections.

A **table spec** says how to lay out a regression table from records: which records are the
columns, which terms are the rows and what they're called, which statistics go underneath,
and how numbers are shown. It holds **no results**. Every number comes from the records when
the table is rendered, so a spec can't drift from the results, and records from a re-run
give a new table from the same spec.

A spec is a JSON object (UTF-8), conventionally named `<name>.estrec-table.json`. The
key words MUST, SHOULD and MAY are as in `spec/estrec.md` section 1.1. Schema:
`schema/estrec-table-0.1.json`.

```json
{"schema": "estrec-table/0.1",
 "meta": {"id": "8c0e5d1a-...", "created": "2026-11-05T09:00:00Z"},
 "title": "Table 2: Fares and concentration",
 "sources": [{"id": "t2", "path": "table2.estrec-collection.json"}],
 "columns": [
   {"record": "2b7e6e56-...", "source": "t2"},
   {"record": "380a95f5-...", "source": "t2", "vcov": "iid"}],
 "response_labels": {"fare_log": "log(fare)"},
 "rows": [
   {"term": "hhi", "label": "HHI"},
   {"terms": ["price_log", "fit_price_log"], "label": "log(price)"}],
 "drop": ["^year::"],
 "uncertainty": ["std_error", "[{p_value}]"],
 "stars": [0.1, 0.05, 0.01],
 "stats": [
   {"metric": "nobs", "label": "N"},
   {"metric": "r2_within", "label": "Within R²"},
   {"vcov": "type", "label": "Std. errors"},
   {"fixed_effect": "carrier", "label": "Carrier FE"},
   {"test": "pre-trends", "value": "p_value", "label": "Pre-trends p"},
   {"label": "Controls", "values": ["No", "Yes"]}],
 "format": {"digits": 3, "p_style": "less_than"},
 "notes": ["Standard errors clustered by route in parentheses."]}
```

## 1. Top level

| Field | Status | Content |
|---|---|---|
| `schema` | required | `"estrec-table/0.1"` |
| `meta` | required | `id` (a UUID), `created` (UTC timestamp); optional `producer` `{name, version}`, `tags`, `notes` |
| `title` | optional | the table's caption |
| `sources` | optional | where to find the records (2) |
| `columns` | required | one entry per column, left to right (3) |
| `head`, `response_labels` | optional | the heading rows (3.1) |
| `rows` | optional | the terms to show, in order, with labels (4) |
| `keep`, `drop`, `keep_unlisted` | optional | which other terms to show (4) |
| `uncertainty` | optional | the lines under each estimate (5); default `"std_error"` |
| `estimate` | optional | `false` leaves out the estimate row (5); default `true` |
| `stars` | optional | significance thresholds (5); default none |
| `stats` | optional | rows under the estimates (6) |
| `format` | optional | number display (7) |
| `notes` | optional | lines of text under the table |

## 2. Sources

`sources` lists files to look in: `{id, path}`, where `path` is relative to the spec's folder
and names a record file, a folder of records or a collection. A renderer MAY be given records
some other way (loaded in a browser, passed to a function); sources are where to look first.

## 3. Columns

| Field | Status | Content |
|---|---|---|
| `record` | required | the record's `meta.id` |
| `source` | optional | the `id` of the source that holds it |
| `sha256` | optional | the record's RFC 8785 hash, as a collection member's (`spec/estrec.md` 11.3) |
| `header` | optional | the column's label (the `label` heading row, 3.1); default: the member label, else the record's title |
| `vcov` | optional | another vcov in the record: its `type`, its cluster variables (`"firm"`, `"firm & year"`), or its position (0-based). Standard errors, tests and intervals are computed from it (8) |
| `component` | optional | a `parameters[*].component` to show (`"first_stage"`); default the rows with none |
| `response` | optional | for a record with several responses, which one |

Columns name records by id, so a spec survives files being moved or renamed. A record that
can't be found is an error, not a blank column. With `sha256`, a renderer warns when the
record found has a different hash: it has changed since the table was made (a test added,
say).

### 3.1 Heading rows

`head` lists the heading rows above the estimates, top to bottom, each at most once:

- `"number"`: `(1)`, `(2)`, ... by position;
- `"response"`: the dependent variable: the column's `response`, else the one response its
  rows have (a first stage's), else the record's `meta.responses` joined with `", "`.
  `response_labels` MAY give display names, `{"fare_log": "log(fare)"}`;
- `"label"`: the column's `header`, else its collection member's label, else the record's
  title.

The default is `["number", "response"]`. `["label", "number", "response"]` puts labels on
top; `["number", "label"]` shows them instead of the dependent variable; `[]` gives no
heading. A `response` or `label` row that would be blank in every column is left out. The
stub (the row labels' column) is blank in heading rows. Formats with one heading row
(Markdown) show the first as the heading and the others at the top of the body.

## 4. Rows

`rows` lists terms in display order: `{term, label}`, or `{terms: [...], label}` to show
several terms on one row (the first one a column has), for an OLS and an IV column side by
side. `label` defaults to the term.

Terms not in `rows` follow in the order they first appear across the columns, unless
`keep_unlisted` is `false`. `keep` and `drop` are lists of regular expressions (ECMAScript
syntax, searched anywhere in `term`) that filter these unlisted terms: with `keep`, only terms
matching one are shown; then terms matching a `drop` pattern are left out. Listed rows are
always shown. Dropped terms (`parameters[*].dropped`) are never shown.

## 5. Estimates, the lines under them, and stars

Each estimate row shows the estimate, with stars. `uncertainty` says what goes under it, one
row per line:

- a **name**: `"std_error"` (in parentheses), `"statistic"` (in parentheses), `"p_value"`
  (in brackets) or `"conf_int"` (`[low, high]`);
- a **template**: text with placeholders `{estimate}`, `{std_error}`, `{statistic}`,
  `{p_value}`, `{conf_low}` and `{conf_high}`, such as `"[{p_value}]"`, `"p = {p_value}"` or
  `"({conf_low} to {conf_high})"`;
- a **sparkline**: `{"sparkline": {"color": "#2b5f8e", "scale": "column"}}` draws the
  confidence interval as a small horizontal line: a dot at each end in `color` (`#rrggbb`,
  default `#2b5f8e`), the estimate as a darker dot (each channel × 0.65), and 0 as a dark
  grey rule. `scale` sets which sparklines share an axis: `"column"` (the default; down a
  column, so an event study's leads and lags read as a coefficient plot), `"row"` (along a
  row) or `"table"`. An axis spans the intervals it holds and always 0. HTML draws an SVG
  and LaTeX a TikZ picture with the same marks (the document needs `\usepackage{tikz}`);
  formats that can't draw (text, Markdown, CSV, a renderer without graphics) show
  `[conf_low, conf_high]` instead. `place` is `"below"` (the default: a row under the
  estimate) or `"beside"`: each column of estimates gets a column next to it, and each
  term's drawing goes there, its 0 rule the full height of the term's rows, so down a column
  the rules join into one line alongside the estimates. Headings and
  statistics rows span both columns. `align` places the marks: `"estimate"` (the default)
  level with the estimate's row, the term's other rows carrying the 0 rule only; or
  `"middle"`, one cell spanning the term's rows with the marks at its middle. HTML, the
  viewer, its web page and Word lay it out beside; other formats draw it below. One
  sparkline at most is beside;
- a **list** of names, templates and sparklines, one row each, in order: `["std_error", "[{p_value}]"]`;
- `null`: no lines.

The default is `"std_error"`. A line is blank in a column when any value it needs is missing.
With `"estimate": false` the estimate row is left out and a term is shown by its lines
alone, the first carrying the term's label (a column of sparklines, say); there are no
stars then. A spec with no estimate and no lines is an error.
Other placeholders are an error.

p-values, in lines and in test rows (6), take `format.p_digits` decimals (default
`format.digits`) and `format.p_style`: `"fixed"` (the default) shows them as rounded,
`0.000`; `"less_than"` shows a p-value below the smallest the decimals can show as `<0.001`
(for three decimals).

`stars` is a list of p-value thresholds, largest first: `[0.1, 0.05, 0.01]` marks p < 0.1
with `*`, p < 0.05 with `**`, p < 0.01 with `***`. `format.star_symbols` MAY give other
symbols, one per threshold. `null` or absent means no stars; the spec has no default, so a
spec that wants stars lists them. Tools that create specs SHOULD offer `[0.1, 0.05, 0.01]`
as their default (the reference tools, the viewer and `estrec show` use it). Renderers
add a note saying what the stars and the lines under the estimates are.

## 6. Statistics rows

Each entry of `stats` is one row, of one of these kinds:

| Kind | Fields | Shows |
|---|---|---|
| metric | `metric` (the record's name: `nobs`, `r2`, `r2_within`, `aic`, ...; `rmse` is `sqrt(rss / nobs)` when the record has no `rmse`) | the value; blank when the record hasn't got it |
| vcov | `vcov`: `"type"` or `"n_clusters"` | the column's vcov as `by: firm` or its type; or its cluster counts |
| fixed effect | `fixed_effect` (a name in `specification.fixed_effects`) | `format.fe_yes` (default `"Y"`) when the record has it, else `format.fe_no` (default `"N"`) |
| test | `test` (a `tests[*].label`, else `name`), `value`: `"statistic"` (default) or `"p_value"` | the test's value |
| literal | `values` (one string per column) | the text, for what records don't hold |

Every kind takes an optional `label` (default: the metric, fixed effect or test name) and
`digits`.

## 7. Format

`format` holds `digits` (decimals for estimates, the lines under them and statistics; default
3), `p_digits` and `p_style` (p-values, section 5), `thousands` (separator for whole numbers in
statistics rows; default `","`), `missing` (a blank cell; default `""`), `fe_yes`, `fe_no` and
`star_symbols`.

Rounding is the renderer's own: a browser, R and Python may differ in the last digit on exact
ties (0.125 to two decimals). That is presentation, not estimation.

## 8. Another vcov

When a column names a `vcov` other than the record's default, a renderer computes standard
errors from the square root of that matrix's diagonal, the statistic as estimate / SE, the
p-value from Student's t on the vcov's `df_t` (normal when it has none), and the interval at
the record's `metrics.conf_level` (0.95 when absent). These are the same rules as the
reference readers' `tidy`.

## 9. Validation

A validator reports, as **errors**: a spec that fails the schema, a column whose record can't
be found, a `source` naming no source, duplicate source ids, a `keep`/`drop` pattern that
doesn't compile, a literal row whose `values` don't match the columns, and an `uncertainty`
line that is neither a name nor a template, or uses an unknown placeholder, and a `head`
entry that isn't `number`, `response` or `label` or appears twice. As **warnings**: a
column whose record's hash isn't its `sha256`, a vcov a record doesn't have, a row term that
no column has, and a metric, fixed effect or test that no column's record has.
