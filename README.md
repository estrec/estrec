# <img src="https://estrec.org/favicon.svg" alt="" width="36" height="36"> estrec

**estrec** ("estimation record") is **a file format for one statistical estimation run**:
what was estimated, what came out, and how and where it ran, as a small JSON record that any
software can write and read.

> **Status: 0.1 draft for comment.** The format may still change. Please open an issue with
> anything that would stop your tool from writing or reading these records.

Why: results from two tools, or two runs, often differ, and finding out why usually means
rerunning both. An estrec record keeps what you need to explain the difference: the
resolved options, the sample and singleton counts, the small-sample correction behind the
standard errors, convergence, the software and environment, and the data's checksum.

- **Any software, any model**: a small core every tool can fill (`meta`, `parameters`,
  `metrics`, `specification`, `provenance`), with **profiles** for the rules of a kind of
  model (`inference`, `linear-fe`, `iv`, `did`, `glm`, `conditional-logit`, `mixed`, `choice`, `sem`, `mediation`, `survival`, `meta-analysis`, `predictive`, `causal-ml`, `gam`, `bayesian`; cross-cutting `mi`, `survey`, `multiple-testing`, `resampling`) or one tool.
- **Small**: results and metadata only; residuals, fitted values and fixed-effect
  coefficients go in linked attachments.
- **Traceable**: records can cite the paper and table they appear in, carry an integrity
  digest, and be redacted of user and host details before sharing.

## Contents

| Path | What | License |
|---|---|---|
| [`spec/estrec.md`](spec/estrec.md) | the specification | CC0 1.0 |
| [`spec/profiles/`](spec/profiles/) | the profiles, with field mappings across Stata, R, Python and Julia tools | CC0 1.0 |
| [`schema/`](schema/) | JSON Schemas (2020-12) for the core, the profiles and collections; the catalog; example records and collections | CC0 1.0 |
| [`src/estrec/`](src/estrec/) | `estrec`, the reference validator, writer and redactor (Python) | MIT |
| [`r/`](r/) | `estrec`, an R package that writes records from fitted models (fixest `feols` so far) | MIT |
| [`viewer/`](viewer/), [`server/`](server/) | the record viewer, and estrec.org: the site and the Publish service (one Cloudflare Worker) | MIT |

Schemas are served at `https://estrec.org/schema/`.

## A minimal record

```json
{"schema": "estrec/0.1",
 "meta": {"id": "6f1c0000-0000-4000-8000-000000000001", "created": "2026-10-24T15:02:11Z",
          "status": "ok", "estimator": {"family": "linear", "method": "ols"},
          "responses": ["mpg"], "profiles": ["inference/0.1"]},
 "metrics": {"nobs": 32, "df_residual": 30, "r2": 0.7528},
 "parameters": [
   {"term": "(Intercept)", "estimate": 37.285, "std_error": 1.8776, "p_value": 8.24e-19},
   {"term": "wt", "estimate": -5.3445, "std_error": 0.5591, "p_value": 1.29e-10}],
 "structures": {"vcov": [{"kind": "matrix", "labels": ["(Intercept)", "wt"],
                          "data": [[3.525, -1.0], [-1.0, 0.3126]], "type": "iid",
                          "ssc": {"convention": "R lm"}, "default": true}]}}
```

## The validator

```bash
pip install 'estrec[jsonschema]'      # not yet on PyPI; for now: pip install .
estrec validate model.estrec.json
estrec redact model.estrec.json -o shareable.estrec.json
estrec digest model.estrec.json
```

```python
import estrec as ef

rec = ef.new_record(
    rows,
    estimator={"family": "linear", "method": "ols"},
    profiles=["inference/0.1"],
    metrics={"nobs": 32, "df_residual": 30},
)
ef.write(rec, "model.estrec.json")  # spills large structures, adds the digest
for issue in ef.validate(ef.read("model.estrec.json")):
    print(issue)
```

It needs only the standard library; `jsonschema` adds full schema validation and `pyarrow`
writes large structures as Parquet attachments.

A **collection** (`estrec-collection/0.1`, spec section 11) holds a set of records: a
paper's results with where each appears, or a session's or replication's timeline. The same
commands validate, redact and digest collections.

```python
coll = ef.new_collection({"baseline": rec1, "full": rec2}, kind="paper",
                         locators=["Table 2, col. (1)", {"table": "2", "column": "2"}],
                         publication={"citation": {"type": "report", "title": "..."}})
ef.write_collection(coll, "table2.estrec-collection.json")   # records embedded
issues = ef.validate_collection(ef.read_collection("table2.estrec-collection.json"), base_dir=".")
```

## Tables

The readers give the parameters as rows for any table tool: `estrec::read_collection()` with
modelsummary in R, and in Python

```python
rows = ef.parameters_table(ef.read_collection("table2.estrec-collection.json"),
                           base_dir=".")        # member, locator, term, estimate, std_error, ...
ef.tidy(rec, vcov="iid")                        # another vcov in the record, recomputed
ef.glance(rec)                                  # metrics, vcov_type, fixed_effects
polars.DataFrame(rows)                          # then great_tables, to_latex, ...
```

A quick look in the terminal: one record gives a detail view, several records, a folder or
a collection a side-by-side table (estimates over SEs, N, R2s, SE type, FE rows):

```bash
estrec show table2.estrec-collection.json
estrec show fit.estrec.json --vcov iid
```

**In the browser:** the [record viewer](https://estrec.org/viewer/)
opens records, folders and collections without uploading them, and builds tables you can copy
as LaTeX, Markdown, HTML or CSV, or save as a table spec (`spec/table.md`) to render again with
`estrec table table2.estrec-table.json -f latex`.

## Contributing

Profiles for new model types or tools come by pull request; see
[CONTRIBUTING.md](CONTRIBUTING.md). Writers for your own tool don't need anyone's permission:
the schemas are public domain.
