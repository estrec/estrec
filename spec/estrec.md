# estrec, the estimation record format, version 0.1

**Status: draft for comment.** Version 0.1 may still change in incompatible ways. Comments
are welcome as issues at https://github.com/estrec/estrec. The first stable
version will be `estrec/1`.

This document, the JSON Schemas in [`schema/`](../schema/) and the
[profiles](profiles/) together define the format. Where this document and a schema
disagree, that is a bug: please report it.

## 1. Introduction

An estrec ("estimation record") is a JSON file that describes **one estimation run**: what was
estimated, what came out, and how and where it ran. It works for any software and any kind
of model: base R `lm`, fixest, reghdfe, statsmodels, pyfixest, a random forest.

A record serves three uses:

1. **Reading and reporting** results: tables, plots, regression summaries.
2. **Explaining a discrepancy** between two runs or two tools *without rerunning them*.
   Comparing two records should show whether the rows, options, small-sample correction,
   convergence, software, environment or data differ.
3. **Reproducing** a run with confidence.

A record stays **small**: results and metadata, never per-row data. Large outputs are linked
as attachments, not embedded.

The format has a small **core** that every producer can fill, and **profiles** that add
the rules for a kind of model (for example linear models with fixed effects) or for one
tool's records. Tools that handle a record later can add their own **extension** blocks.

### 1.1 Conventions

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT",
"RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be
interpreted as described in BCP 14 ([RFC 2119], [RFC 8174]) when, and only when, they
appear in all capitals, as shown here.

Paths to fields are written with dots (`provenance.execution.scheduler`); `[*]` means every
item of a list and `*` every key of an object.

### 1.2 Terms

| Term | Meaning |
|---|---|
| record | one estrec JSON document, describing one run |
| run | one estimation call at one time |
| producer | the software that estimated the model |
| writer | the code that writes the record: the producer itself, or a converter (e.g. one that reads Stata's `e()`) |
| reader | any code that reads records |
| validator | a reader that checks a record against this specification, the core schema and the profiles the record claims |
| profile | a named, versioned set of extra rules for a kind of record (section 9) |
| extension | a block under `extensions`, owned by the tool that wrote it (section 7) |
| catalog | the registered list of the core schema and the profiles (section 9.3) |
| collection | an `estrec-collection` document: a set of records with what is true of the set, such as a paper's results or a session's timeline (section 11) |
| member | one record in a collection, with the collection's label and locator for it |

## 2. Encoding

- A record MUST be a single JSON object ([RFC 8259]) encoded in UTF-8.
- A record file SHOULD be named `<name>.estrec.json`.
- Numbers SHOULD be written with enough precision to round-trip a 64-bit float (17
  significant digits).
- JSON has no non-finite numbers. Where the format expects a number, the strings `"NaN"`,
  `"Inf"` and `"-Inf"` MUST be used for them, and bare `NaN` or `Infinity` tokens MUST NOT
  appear.
- An **absent** key means the producer does not record that quantity. **`null`** means the
  quantity applies but was not computed. Writers MUST NOT use one for the other.
- Times MUST be in UTC, as ISO 8601 / [RFC 3339] timestamps (`2026-10-24T15:02:11Z`). A
  local time zone, when relevant, is recorded separately (`provenance.execution.timezone`).
- Values are **resolved, not as typed**: an option is recorded with the value in effect,
  defaults included. A later change of a tool's default then cannot change what an existing
  record means.

## 3. Structure

A record has the following top-level members. Each is **required**, **expected** or
**optional**:

- A record without a **required** member is invalid.
- A record without an **expected** member is valid, but validators MUST warn, and writers
  SHOULD include the member whenever they can fill it.
- **Optional** members are used when they apply.
- A record that declares a disclosure level (4.9) may withhold any member above it, required
  members excepted; validators report a withheld expected member as information.

| Member | Status | Content |
|---|---|---|
| `schema` | required | the format version, `"estrec/0.1"` |
| `meta` | required | identity and type of the run (4.1) |
| `parameters` | required | one row per reported parameter (4.4) |
| `metrics` | expected | named scalar results (4.3) |
| `specification` | expected | what was asked for (4.2) |
| `provenance` | expected | software, environment, execution, data (4.6) |
| `structures` | optional | named complex results: vcov, fixed effects, ... (4.5) |
| `tests` | optional | hypothesis tests: the estimator's own and those added after the fit (4.8) |
| `publication` | optional | where the result appears in a paper (5) |
| `validation` | optional | the same model in other software, and comparisons (6) |
| `attachments` | optional | links to large side files (8) |
| `extensions` | optional | blocks added by tools, one per namespace (7) |
| `history` | optional | every tool that created, extended or redacted the record (7) |

Writers MUST NOT add other top-level members; tool-specific content belongs in
`extensions`. Validators SHOULD warn about unknown top-level members.

A record from base R `lm` and one from a distributed fixed-effects estimator have the same
shape; the second is just fuller. Section 12 shows a minimal record.

## 4. Result sections

Writers report; they don't reinterpret. A value is recorded as the tool reported it, under
the record's name for the tool's quantity, so that a record can always say "this is what the
tool reported", not something the writer worked out. A writer records a value under another
name only when it can show the two are the same quantity, by the math or by the tool's own
documentation, and the other name is the canonical one (for
example Stata `estat gof`'s deviance goodness-of-fit, which equals `glm`'s `e(deviance)`).
It computes nothing the tool didn't report beyond conveniences the tool itself would give
from its own results (a p-value or interval from a reported statistic, df and vcov). When a
writer knows a tool's value to be wrong, it records the value as reported and says so (a
`definition`, or a `messages` entry) rather than replacing it.

### 4.1 `meta` (required)

| Field | Status | Content |
|---|---|---|
| `id` | required | a UUID ([RFC 9562]) identifying this record |
| `created` | required | when the record was written |
| `status` | required | `"ok"`, `"warning"` or `"failed"`. A failed run SHOULD still produce a record with what it knows |
| `parent` | optional | the `id` of the record this one derives from (the same model with a new vcov, for example) |
| `messages` | optional | list of `{level, code, message, source}`: collinear terms dropped, slow convergence, few clusters, singletons removed |
| `estimator` | optional | `{family, method, ...}`, e.g. `{family: "linear", method: "ols"}`, `{family: "glm", method: "mle", distribution: "binomial", link: "logit"}`, `{family: "ensemble", method: "random_forest"}` |
| `responses` | optional | the dependent variable(s) |
| `profiles` | optional | the profiles the record claims to follow, e.g. `["linear-fe/0.1"]` (section 9) |
| `title`, `tags`, `notes` | optional | user labels and free text |
| `producer` | optional | `{name, version}` of the writer, when it is not the estimating software (a converter) |
| `core_digest` | optional | integrity check over the result sections (7.2) |
| `disclosure` | optional | `{level}`: how much the writer chose to disclose, 1 to 5 (4.9) |

`estimator.family` and `estimator.method` have a recommended vocabulary (in the schema), but
any string is valid, so a new kind of model needs no change to the format.

### 4.2 `specification` (expected)

What was asked for, in the estimating software's own terms, fully resolved:

- `call`: the command as written (`feols(y ~ x | fe, data)`, `reghdfe y x, absorb(fe)`).
- `program`: `{path, line, sha256}`, the program in the replication package that ran the
  command, with `path` relative to the package root. Unlike
  `provenance.execution.invocation.script_path` it isn't identifying, so a record can map a
  result to its program without disclosing where it ran.
- `formula`: `{text, syntax}`, where `syntax` names the formula language (`R`, `fixest`,
  `patsy`, `stata`, ...).
- `terms`: the expanded regressors in model order; `factor_terms` with their levels and
  reference level.
- `weights`: `{variable, type}` (`analytic`, `frequency`, `probability`), or `null`.
- `fixed_effects`, `endogenous`, `instruments`, `clusters`: as specified.
- `sample`: the restriction as written, plus `rows_input` and drop counts by reason (missing
  per variable, singletons, zero weights, other). `metrics.nobs` is normally the rows left;
  when the tool counts observations otherwise (frequency weights), it differs, and its
  `definition` says so.
- `state`: settings in force from *outside* the call that change results without
  appearing in it: an active filter, weight or split (SPSS); `xtset`/`tsset`, `if`/`in`, the
  random-number seed (Stata); R `options()` that change estimates; user-defined missing-value
  codes and how they were treated.
- `options`: every option with its effective value: tolerances, algorithms, seeds,
  hyperparameters.

### 4.3 `metrics` (expected)

An object of named scalars. `nobs` (observations, as the tool reports them) applies to nearly
every estimator; the rest depend on it (`r2`, `aic`, `log_lik`, `auc`, `mse`, ...).

- Names SHOULD follow broom's `glance` where one exists. The core schema registers
  recommended names and their definitions, and profiles add more, so that a name means the
  same thing in any two records. Unregistered names are allowed.
- A metric is a number (or a non-finite string, section 2), a string, a boolean, `null`, or
  an object `{value, definition, ...}` when the writer needs to say exactly what it
  computed (for example a residual df that is not the textbook one).
- `conf_level` records the confidence level of `parameters[*].conf_low`/`conf_high`.

### 4.4 `parameters` (required)

A list of rows, one per parameter the model reports. Each row MUST have `term`; the other
columns depend on the estimator:

- **Inference**: broom `tidy` names: `estimate`, `std_error`, `statistic`, `p_value`,
  `conf_low`, `conf_high`, computed from the default vcov (4.5).
- **Machine learning**: `importance`, `rank`, and so on.
- **Models with several parts**: `response` (which outcome), `component` (e.g.
  `first_stage`, `zero_inflation`, `random`), `group` (for random-effect terms).
- `dropped`: `null`, `"collinear"` or `"reference"`. Dropped terms stay in the list as rows,
  so the term list is complete.
- `scale`: the scale of `estimate`, `std_error` and the interval. Absent (or `"estimation"`)
  means the scale the model was estimated on: log-odds, log hazard, log rate. Writers SHOULD
  record that scale. A writer whose only source is exponentiated (a table from Stata's `or`,
  `irr`, `hr` or `eform` display options, broom's `exponentiate = TRUE`, a published table)
  writes `scale: "exponentiated"`: `estimate` is exp(b), `std_error` is exp(b)·se (the delta
  method, as Stata displays it), `conf_low`/`conf_high` are the exponentiated endpoints, and
  `statistic`/`p_value` remain those of the estimation-scale test. `measure` names what an
  exponentiated estimate is (`odds_ratio`, `hazard_ratio`, `incidence_rate_ratio`,
  `risk_ratio`, `relative_risk_ratio`, `subhazard_ratio`). Stata's `e(b)` is always on the
  estimation scale; the display options change only `r(table)`.

Rows are the model's reported parameters. Per-level estimates (fixed-effect coefficients,
BLUPs) are not parameters in this sense: they MUST go in an attachment (section 8).

#### 4.4.1 Term names

`term` is **verbatim**: the name exactly as the producing software reports it,
transformations included (`log(price)`, `i(year, ref = 2000)::2005`, `2005.year`). Writers
MUST NOT reinterpret it.

`canonical` is OPTIONAL and RECOMMENDED: a standard form that lets records from different
tools be matched and tabulated together. It is `{name, factors}`:

```json
{"term": "i(year, ref = 2000)::2005",
 "canonical": {"name": "year2005",
               "factors": [{"variable": "year", "level": "2005", "reference": "2000"}]}}
{"term": "c.price#c.weight",
 "canonical": {"name": "price:weight", "factors": [{"variable": "price"}, {"variable": "weight"}]}}
{"term": "2005.year#c.x",
 "canonical": {"name": "2005.year#c.x",
               "factors": [{"variable": "year", "level": "2005"}, {"variable": "x"}]}}
```

- `factors` is the definition, and matching across tools MUST use it. `name` is a readable
  rendering. The constant has `name: "(Intercept)"` and no factors; every other term has at
  least one factor.
- `name` follows R's `model.matrix` naming: `(Intercept)`, a variable followed by its level
  (`year2005`), `:` between interacted terms. That concatenation can be ambiguous (`year2005`
  could be variable `year2`, level `005`); `factors` resolves it.
- One exception: **factor × continuous interactions use Stata's form** (`2005.year#c.x`),
  which is clearer than R's (`factor(year)2005:x`).
- Levels and transformations stay as the tool reports them (codes or labels, `log(x)` as
  written). A factor MAY add `level_label` or `transform` when the writer knows them.
- Interaction order is kept as specified, in both `term` and `name`. Matching on `factors`
  ignores order.
- Models with absorbed fixed effects need no constant row. A tool that reports one (reghdfe's
  `_cons`) includes it, and `structures.fixed_effects[*].constant_reported` says so.

How tools spell the same term:

| Term | R `lm` | fixest | Stata | patsy (statsmodels, pyfixest) | canonical `name` |
|---|---|---|---|---|---|
| constant | `(Intercept)` | `(Intercept)` | `_cons` | `Intercept` (statsmodels `const`) | `(Intercept)` |
| factor level | `factor(year)2005` | `year::2005` | `2005.year` | `C(year)[T.2005]` | `year2005` |
| base level | (not shown) | (not shown) | `2000b.year` | (not shown) | row with `dropped: "reference"` |
| interaction | `price:weight` | `price:weight` | `c.price#c.weight` | `price:weight` | `price:weight` |
| factor × continuous | `factor(year)2005:x` | `year::2005:x` | `2005.year#c.x` | `C(year)[T.2005]:x` | `2005.year#c.x` |
| omitted (collinear) | `NA` estimate | dropped, in `collin.var` | `o.x` | dropped | row with `dropped: "collinear"` |

### 4.5 `structures` (optional)

Named complex results. Each structure is an object with a `kind`, so a reader can decode it
without knowing the estimator. A name holds one structure or a list of them.

| `kind` | Content |
|---|---|
| `matrix` | `data` (list of rows) with `labels`, or `row_labels` and `col_labels` |
| `table` | `columns` and `rows` |
| `series` | `index` and `values` |
| `tree` | a nested tree (a fitted decision tree, for example) |
| `object` | any nested object |
| `link` | the structure's data is in an attachment (section 8) |

Registered names (profiles define their required shape):

- `vcov`: a list, one per variance-covariance matrix computed (iid, HC1, CRV1, ...). Each
  carries `type`, `cluster`, `n_clusters`, `df_t` (the df used for t tests and confidence
  intervals) and `ssc`, the small-sample correction written out in full: `convention` (the
  tool whose convention it reproduces, e.g. `"fixest"`, `"reghdfe"`), `formula`, `factors`
  and what K counted. The one marked `default: true` is the one `parameters` was computed
  from.

  ```json
  "vcov": [{"kind": "matrix", "labels": ["x1", "x2"], "data": [[...], [...]],
            "type": "CRV1", "cluster": ["pitcher"], "n_clusters": {"pitcher": 1172},
            "ssc": {"formula": "G/(G-1) * (N-1)/(N-K)", "factors": {...}, "K_counts": "...",
                    "convention": "fixest"},
            "df_t": 1171, "default": true}]
  ```

- `fixed_effects`: a list, one `{kind: "object", name, levels, ...}` per fixed effect: levels
  in the sample and in the data, redundant levels and how they were found, nesting (in
  clusters, in other fixed effects). Counts only, never the level values.
- `random_effects`: variance components.
- `numerics`: whether the algorithm is `iterative`, `algorithm`, `tolerance`, `iterations`,
  `converged`, solver, rank, condition number, collinearity settings.
- `hyperparameters`: for machine-learning estimators, with tuning results if any.
- `first_stage`: instrumental-variables first-stage summaries that aren't tests (R²s; see the `iv`
  profile). The first-stage F and the identification tests are in `tests` (4.8).

A structure that is spilled to an attachment keeps its non-data fields (a vcov keeps `type`,
`ssc`, `cluster`, `default`) and becomes `{kind: "link", attachment, spilled_kind, ...}`.

### 4.6 `provenance` (expected)

Everything about how and where the run happened. This is where a discrepancy is traced, so
the section is deliberately open-ended: writers fill each part as far as they can, and any
member not defined here is allowed.

- `software`: a list of components, each `{name, version, purl, role, source, hash,
  attributes, lock, container}`.
  - `purl` is a [Package URL], which identifies a component the same way across ecosystems:
    `pkg:cran/fixest@0.14.2`, `pkg:pypi/numpy@2.1.0`, `pkg:github/<owner>/<repo>@<commit>`.
    Software with no purl type (Stata, SPSS) uses `pkg:generic/stata@19.5` plus
    `attributes`.
  - `role`: `estimator`, `language`, `dependency`, `system` (BLAS, OpenMP, MPI) or
    `container`.
  - `source`: CRAN, PyPI, conda, SSC, or a git commit with a dirty flag.
  - `lock`: a pointer to a full lock file or SBOM (`renv.lock`, `pylock.toml`,
    `conda-lock.yml`, CycloneDX), by path and sha256. The record lists only the components
    that matter; the lock file has the rest.
  - `container`: image reference and digest (OCI, Apptainer `.sif` sha256).
- `environment`: operating system, kernel, locale, time zone, and:
  - hardware: CPU model, sockets, cores, threads, instruction-set flags that change
    floating-point results (AVX2, AVX-512, FMA), memory, GPU and driver;
  - numerical libraries: the BLAS/LAPACK in use, its version, threading layer and thread
    count (`threadpools`);
  - random numbers: generator, seed, state (`random`);
  - environment `variables`: an allowlist only (`OMP_NUM_THREADS`, `MKL_NUM_THREADS`, ...).
    Writers MUST NOT dump the full environment, which can carry credentials.
- `execution`: `started`, `finished`, `elapsed_seconds` and `processor_seconds` (a large gap
  between them means waiting or contention), timing by `stages`, `peak_memory_bytes`;
  `invocation` (command line, script path and sha256, working directory, interactive or
  batch); `scheduler`; `workers`; `launch` (launch parameters, resolved); `session` (the
  session id, when the run was part of one).
  - `scheduler` is `{type, ...}` in the scheduler's own field names. For SLURM: `JobID`,
    `JobName`, `Partition`, `Account`, `QOS`, `NodeList`, `AllocCPUS`, `AllocTRES`,
    `ReqMem`, `Submit`, `Start`, `End`, `Elapsed`, `MaxRSS`, `State`, `ExitCode`,
    `SubmitLine`, `WorkDir` (as `sacct --format` spells them). PBS, LSF and SGE use their own
    names under their own `type`.
- `agent`: the user and host.
- `data`: a list of inputs, each `{role, name, version, location, checksum, rows, columns,
  source, license, publication}`.
  - `checksum` is `{algorithm, value, of, method}`. `of` says what was hashed: a `file`, a
    manifest (such as a `MANIFEST.sha256`), or `in-memory` content. For in-memory content the
    format defines no single procedure, so `method` is REQUIRED and names it
    (`stata-datasignature`, `R digest::digest(df, "xxhash64")`,
    `pandas.util.hash_pandas_object`). Two checksums are comparable only when their
    `method`s match.
  - `publication`: where the data is published (the block of section 5).

What each kind of producer can usually fill (a guide for writers, not a requirement):

| Producer | Software | Environment | Execution |
|---|---|---|---|
| base R | `R.version`, attached and loaded packages (`sessionInfo()`), optionally `renv.lock` | `platform`, `running`, BLAS/LAPACK, `La_version()`, locale, `tzone`, `RNGkind()` | `Sys.time()` around the call, `proc.time()`, `commandArgs()` |
| Stata | `c(stata_version)`, `c(version)`, `c(born_date)`, edition, ado versions (`which`), SSC packages | `c(os)`, `c(osdtl)`, `c(machine_type)`, `c(byteorder)`, `c(processors)`, `c(rngtype)`, `c(rngstate)` | `c(current_date)`, `c(current_time)`, `timer`, `c(mode)`, `c(pwd)`, `e(cmdline)` |
| SPSS | version, edition, fix pack, extension bundles | OS, `SHOW` settings (`RNG`, `SEED`, ...) | the Notes table: output created, syntax, input data, filter/weight/split, processor and elapsed time |
| Python | interpreter, packages (`importlib.metadata`), optionally `pylock.toml` or a conda lock | `platform`, `threadpoolctl`, `os.cpu_count()`, allowlisted variables | `time`, `resource.getrusage`, `sys.argv` |

### 4.7 Identifying details

Some provenance fields identify people or places: the user, hosts, paths, job ids, accounts,
command lines, working directories, data locations. They help trace a discrepancy, but the
format never requires them. Nearly all are at disclosure level 5 (4.9), so a record written at
the default level 4 leaves them out; at level 5 writers include them unless asked to redact.
Either way they MUST be easy to remove:

- **The schemas mark them**: each identifying field carries `"x-identifying": true`. An
  extension's or profile's schema marks its own the same way. A redactor needs only the
  schemas, not knowledge of each tool.
- **Redaction** removes each marked value or replaces it with `hmac-sha256:<hex>`, an
  HMAC-SHA256 of the value's canonical JSON (RFC 8785) under a secret salt, so that records
  redacted with the same salt still compare equal.
- Content hashes (data checksums, a script's sha256) identify content, not people, and are
  kept.
- Redaction MUST NOT change the sections covered by the core digest (7.2).
- The redactor appends a `history` entry with `action: "redacted"`, the `method` (`removed`
  or `hmac-sha256`), the `fields` changed and, when hashing, a `salt_id` (a short hash that
  names the salt without revealing it), so a reader knows what is missing and which records
  are comparable.

### 4.8 `tests` (optional)

A list of hypothesis tests about the model, one object per test (`$defs/test` in the core
schema). It holds the tests the estimator reports (the model F, first-stage and
overidentification tests, a pre-trend test), the tests a user asks for after the fit (a Wald
test of `x = x2`, Stata `test`, `fixest::wald()`), and single linear combinations (`lincom`).
Profiles say which tests a kind of model has, by `category`, and don't store tests in their own
sections.

```json
"tests": [
  {"id": "t1", "category": "model", "name": "f", "origin": "estimation",
   "statistic": 48.9, "distribution": "F", "df1": 2, "df2": 358, "p_value": 1.2e-19},
  {"id": "t2", "category": "restriction", "name": "wald", "origin": "postestimation",
   "hypothesis": {"text": "x = x2", "terms": ["x", "x2"],
                  "restrictions": {"R": [[1, -1]], "q": [0], "labels": ["x", "x2"]}},
   "statistic": 4.21, "distribution": "F", "df1": 1, "df2": 39, "p_value": 0.047,
   "vcov": {"type": "CRV1", "cluster": ["id"]},
   "source": {"name": "car", "version": "3.1-3", "call": "linearHypothesis(fit, \"x = x2\")"},
   "added": "2026-10-31T14:20:00Z"},
  {"id": "t3", "category": "linear_combination", "name": "t", "origin": "postestimation",
   "hypothesis": {"text": "x + x2 = 0", "restrictions": {"R": [[1, 1]], "q": [0], "labels": ["x", "x2"]}},
   "estimate": 1.98, "std_error": 0.06, "conf_low": 1.86, "conf_high": 2.10,
   "statistic": 33.0, "distribution": "t", "df": 39, "p_value": 3.1e-30}
]
```

| Field | Status | Content |
|---|---|---|
| `name` | required | which test: `f`, `wald`, `t`, `likelihood_ratio`, `score`, `sargan`, `hansen_j`, `wu_hausman`, ... (vocabulary in the schema) |
| `statistic` or `p_value` | required (one of) | the test statistic; a resampling test may have only a p-value |
| `id` | recommended | unique within the record, so tools and other tests can refer to it |
| `category` | recommended | what it tests: `model`, `restriction`, `linear_combination`, `fixed_effects`, `first_stage`, `overidentification`, `pretrend`, `proportional_hazards`, ... Profiles refer to tests by category |
| `origin` | recommended | `estimation` (computed by the estimating software as part of the fit or its standard output) or `postestimation` (asked for afterwards) |
| `distribution`, `df`, `df1`, `df2` | expected with `statistic` | the reference distribution (`F`, `chi2`, `t`, `normal`, `empirical`) and its df |
| `hypothesis` | optional | `text` as written; `terms` (the `parameters[*].term` it involves); `restrictions` `{R, q, labels}` for a linear test H0: R b = q; `alternative` (`two_sided`, `greater`, `less`) |
| `vcov` | optional | the `structures.vcov` entry used, by `type` (and `cluster`); absent means the default |
| `estimate`, `std_error`, `conf_low`, `conf_high` | optional | for a single restriction (a linear combination) |
| `response`, `component`, `terms` | optional | as in `parameters`: which equation (a first stage's endogenous variable), or which terms a per-term test is about |
| `method` | optional | `wald`, `likelihood_ratio`, `score`, `bootstrap`, `permutation`, `exact`; `resampling` holds a resampling test's settings as in `resampling/0.1` |
| `p_value_adjusted`, `family` | optional | a p-value adjusted for multiple testing, and its family (`multiple-testing/0.1`) |
| `options` | optional | test-specific settings (the proportional-hazards time transform) |
| `records` | optional | the `meta.id` of each record a cross-model test compares (Hausman, `lrtest m1 m2`) |
| `source`, `added` | optional | `{name, version, call}` of what computed it when that isn't the estimator; when it was added to an existing record |
| `label`, `tags` | optional | the user's label and tags |

Rules:

- `tests` is **append-only**. Any tool MAY add tests to a record, at any time, without
  writing a new record: a test doesn't change the results. A tool MUST NOT change or remove a
  test that another tool wrote, and appends a `history` entry (`action: "extended"`,
  `sections: ["tests"]`) when it adds one.
- `tests` is **outside the core digest** (7.2), so adding a test keeps the digest valid.
- A linear test SHOULD give `hypothesis.restrictions`, so that a reader can recompute it from the
  record's own `parameters` and `structures.vcov`.
- Validators check that `id`s are unique and that `restrictions` has one row of `R` per `q`
  and one column per label, and warn when a named term isn't in `parameters` or a named vcov
  isn't in `structures.vcov`.

### 4.9 Disclosure levels

How much a record discloses is the choice of the person who shares it. Someone may want to
send only an estimate, its standard error and N, because the rest isn't material or because
they don't want to reveal more about their work; a replication harness wants everything. A
record's **disclosure level** is a ceiling: the most it holds. A small record is a complete
record, not a degraded one. Each level includes everything in the levels below it.

| Level | Adds |
|---|---|
| 1 | `parameters` (estimates, standard errors, test statistics, p-values, intervals), `metrics.nobs`, `df_residual` and `conf_level`; `meta.id`, `created`, `status`, `parent`, `profiles`, `title`, `tags`, `notes`, `disclosure`, `core_digest`; `publication`; `history` without `by` |
| 2 | the model's diagnostic and summary measures: the other `metrics`, `meta.estimator`, `responses` and `messages`, `structures.vcov` (without cluster names and counts), `random_effects`, `first_stage`, and `tests` (without `source`); `attachments` |
| 3 | `specification`; the other structures (`fixed_effects`, `hyperparameters`, ...) and the vcov's `cluster` and `n_clusters` (and a test's `vcov.cluster`) |
| 4 | `provenance.software`: the components with `role` `language`, `estimator` or `writer` only, with a `lock` pointer's `format` and `sha256` (which commit to the full environment without listing it); the writer in `meta.producer` and `history[*].by`, so a writer's version can be traced; `provenance.data` without `location`; `structures.numerics`; `validation`; `extensions`; a test's `source` |
| 5 | every other software component (dependencies), a `lock`'s `path`, `container`; `provenance.environment`, `execution` (except `execution.session`, the session id, at 4) and `agent`; data `location`; any other `provenance` member |

- **Writers** SHOULD let the user choose the level and SHOULD default to **4**. A record
  written at a level declares it in `meta.disclosure.level`, inside the core digest. A reader
  then knows that a missing member was withheld, not unknown.
- **The schemas mark the levels.** Each field carries `"x-level": n`; a field without a mark
  has its parent's level, except that a mark on `*` (`additionalProperties`) applies to every
  key without a mark of its own. `"x-level-if": [{field, in, level}]` gives list items whose
  `field` is one of `in` another level (software components by `role`). A field's level is
  never below that of what contains it: a mark lower than its parent's has the parent's
  level (a `lock` is level 4 on a level-4 component, 5 on a level-5 one). A field marked
  `x-identifying` (4.7) is level 5, so a profile's identifying fields need no mark of their
  own. Profiles mark their own fields the same way; where two schemas mark a
  path differently, the higher level applies. Writers, validators and tools that lower a
  record need only the schemas.
- **At level 1**, `meta.created` and a history entry's `when` MAY be dates instead of
  times. Below level 4, history entries omit `by`.
- **Profile claims.** A writer MUST NOT claim a model profile that the level makes the record
  fail (`linear-fe/0.1` needs `structures.fixed_effects`, level 3). It leaves the claim out of
  `meta.profiles` and, at level 2 or more, says so in `meta.messages`
  (`code: "profile_not_claimed"`). A purpose profile (9.1) is never dropped: a writer asked for
  one at too low a level, or for a record that falls short of it, MUST fail and name the field.
- **Validators**, for a record that declares a level: report each field above it as an
  **error**; report each missing expected member or field that the level withholds as
  **information**, not a warning; report a claimed purpose profile whose `x-min-level` is above
  the declared level as an error. A record without `meta.disclosure` gets no level checks.
- **Lowering.** A tool MAY write a record at a lower level from an existing one by removing
  the fields above it, the attachments only removed structures linked to, and the claims of
  model profiles it no longer meets. Lowering changes sections inside the core digest, so the
  result is a **new record**: a new `meta.id`, `meta.parent` set to the original's, a new
  digest, and a `history` entry `{action: "reduced", level, fields}`.
- Identifying details (4.7) keep their own switch: level 5 makes them allowed, and redaction
  still removes or hashes them. Attachments stay opt-in at every level (8.1).

## 5. `publication` (optional)

Where the result appears, so that a number in a paper can be traced to the record that
produced it, and the record back to the paper and its materials. The same block describes
published reference values (6) and published data (`provenance.data[*].publication`).

```json
"publication": {
  "citation": {"id": "parsons2011", "type": "article-journal",
               "title": "Strike Three: Discrimination, Incentives, and Evaluation",
               "author": [{"family": "Parsons", "given": "Christopher A."},
                          {"family": "Sulaeman", "given": "Johan"},
                          {"family": "Yates", "given": "Michael C."},
                          {"family": "Hamermesh", "given": "Daniel S."}],
               "issued": {"date-parts": [[2011]]}, "container-title": "American Economic Review",
               "volume": "101", "issue": "4", "page": "1410-1435",
               "DOI": "10.1257/aer.101.4.1410"},
  "locator": {"study": "1", "table": "3", "panel": "A", "column": "9", "row": null,
              "label": "Table 3, column 9"},
  "status": "published",
  "ascollected_url": "https://ascollected.org/ZJ6_Z47",
  "researchbox_url": "https://researchbox.org/15",
  "researchbox_files": [7, 12],
  "aspredicted_url": null,
  "replication_package": {"doi": "10.3886/E112434V1", "url": "https://www.openicpsr.org/openicpsr/project/112434"},
  "links": [{"rel": "preregistration", "url": "..."}, {"rel": "osf", "url": "..."}]
}
```

(The AsCollected and ResearchBox URLs are public examples that belong to other papers; they
only illustrate the fields.)

- `citation` is [CSL-JSON], the citation format of Zotero, pandoc, Mendeley and CrossRef, so
  it can be pasted from a reference manager or fetched from a DOI. `type` is required; CSL's
  own `id` is not. Name objects use only CSL's keys (`family`, `given`, `literal`, ...).
  Working papers and preprints use `type: "report"` or `"article"` with `number` and
  `publisher`.
- `locator` says where in the work: `study`, `table`, `panel`, `column`, `row`, `figure`,
  `equation`, `page`, `appendix`, `section`, any of which can be absent, **plus** `label`,
  the location as printed (`"Table A4, col. (3)"`). A result that appears more than once
  uses `locators` (a list) instead; a record MUST NOT have both.
- `status`: `published`, `accepted`, `submitted`, `working-paper`, `preprint` or
  `unpublished`. `citation.version` says which version of the paper the locator refers to,
  since table numbers move between drafts.
- Named links for services the format wants to encourage: `ascollected_url`,
  `researchbox_url` (with `researchbox_files`, file ids in the box), `aspredicted_url`, and
  `replication_package` (`{doi, url}`: openICPSR, Dataverse, Zenodo). Each SHOULD point to the
  specific version cited.
- `links`: anything else, as `{rel, url}`.

## 6. `validation` (optional)

Most records have no `validation`. It is for when the estimator itself is in question: a
custom or untested estimator, a new release, a replication. It has two parts.

**`equivalents`**: the same model elsewhere, each in a `style`:

| `style` | Content |
|---|---|
| `code` | `{software, language, code}`, e.g. `reghdfe y x, absorb(fe) vce(cluster c)` |
| `description` | prose: how the reference was produced |
| `record` | another estrec record, by path, sha256 and id, or embedded whole |
| `published` | `{publication, values}`: numbers from a paper, with a `publication` block (5) |

The list of styles is open: a writer MAY use a new style (`notebook`, `container`, ...), and
readers MUST skip styles they don't know. An equivalent can be listed without a comparison
(the code to run, not yet run).

**`comparisons`**: what was compared against which equivalent, and how close it came:

```json
"comparisons": [
  {"reference": "pyfixest", "quantities": ["estimate", "std_error", "nobs"],
   "term_map": {"x::2": "x[T.2]"}, "tolerance": {"rel": 1e-6},
   "max_abs_diff": {...}, "max_rel_diff": {...}, "pass": true,
   "details": [{"term": "x1", "quantity": "estimate", "value": ..., "reference": ...,
                "diff": ...}]}],
"verdict": "pass"
```

## 7. Extensions, history and integrity

### 7.1 `extensions` and `history`

Any tool that handles a record MAY add a block under `extensions`, in its own namespace: the
estimator (with its own diagnostic detail), or a tool later in a chain (a table exporter, a
replication harness, a cluster accounting tool).

```json
"extensions": {
  "dfeols":   {"schema": "dfeols/0.1", "by": {"name": "dfeols", "version": "0.8.0"},
               "added": "2026-10-24T15:02:11Z", ...},
  "harness":  {"schema": "dfeols-harness/0.1", "by": {...}, "added": "...",
               "reference_file": "reference.json", ...}
}
```

- A block SHOULD carry `schema` (the schema that validates it), `by` (`{name, version}`)
  and `added`.
- A namespace belongs to the tool that writes it. A tool MUST add or replace only its own
  block, never another tool's block or a core section. The exception is `tests` (4.8), which
  any tool may append to.
- A tool that changes results (a new vcov, a new sample) MUST write a **new record** with
  `meta.parent` set, not a block.
- Each tool that creates, extends, redacts, reduces or validates a record SHOULD append to
  `history` an entry `{when, by: {name, version}, action, sections}`, where `action` is
  `created`, `extended`, `redacted`, `reduced` (4.9) or `validated`. `created` and `reduced`
  entries carry the `level` written; below level 4 entries omit `by`. The chain of tools that touched a record is then
  explicit and in order.
- The core validator ignores the content of blocks. Readers MUST skip blocks they don't
  know.

### 7.2 Core digest

`meta.core_digest` lets anyone check whether the results were edited after the run, as
opposed to only annotated:

```text
"core_digest": {"algorithm": "sha256", "canonicalization": "RFC8785", "value": "<hex>"}
```

- `value` is the SHA-256 of the [RFC 8785] (JSON Canonicalization Scheme) serialization of an
  object holding the record's `meta` (without `core_digest`), `specification`, `metrics`,
  `parameters` and `structures`, each only if present, as written (non-finite numbers as
  strings, spilled structures as links). `tests`, `publication`, `validation`, `extensions`
  and `history` are outside it, so annotating a record, or adding a test to it, keeps it valid.
- The digest is OPTIONAL. Writers SHOULD compute it by default and MAY let users turn it off.
- Validators report a missing digest as information and a digest that doesn't match as a
  warning.

## 8. Attachments and size

### 8.1 `attachments` (optional)

Large outputs (fixed-effect coefficients, residuals, fitted values, a vcov with thousands of
terms, predictions) live in side files. The record holds only a link:

```json
{"id": "fe_coefs", "role": "fe_coefficients", "path": "fe_coefs.parquet",
 "media_type": "application/vnd.apache.parquet", "created": "2026-10-24T15:02:11Z",
 "sha256": "...", "bytes": 81234567, "rows": 1838676, "columns": ["fe", "level", "estimate"]}
```

- `id` and `path` are required; `id`s are unique within a record. `sha256` is expected.
- `path` is relative to the record's folder, or a URI. A record stays valid when the file is
  missing; the hash says whether a file found later is the right one.
- A structure points to an attachment with `{kind: "link", attachment: "<id>"}`.
- Parquet is RECOMMENDED for tables. Per-observation and per-level output MUST be an
  attachment, and writers SHOULD write such attachments only when asked.

### 8.2 Size limits

| Limit | Validator |
|---|---|
| record above 1 MB (10^6 bytes) | warning, naming the largest section |
| one array above 10,000 elements | warning, naming the array |
| record above 16 MB | error |

An array's elements are its items, with nested arrays counted by their leaves (a 100 × 100
matrix has 10,000). Writers SHOULD move a structure above these limits into an attachment
automatically, leaving a `link`, so the easy path is the small one.

## 9. Profiles

### 9.1 What a profile is

A profile is a named, versioned set of rules on top of the core: which `metrics`,
`parameters` columns and `structures` a record of that kind must have, and their shapes. A
record lists the profiles it follows in `meta.profiles`, and a validator checks the core plus
each claimed profile. Profiles give model-specific requirements without a new format per
model.

A profile is a JSON Schema (draft 2020-12) whose `title` is its name (`linear-fe/0.1`) and
whose `$defs/rules` holds its own rules. The file as a whole is `allOf` the core and its
rules, so it validates a complete record.

**Standard profiles** describe a kind of model shared across tools. Each is built from the
most popular tools for that task in Stata, R and Python:

- **Vocabulary = the union**: every quantity any surveyed tool saves gets one name, a
  definition and a mapping to each tool's own name (`x-tools` in the schema).
- **Requirements = what (nearly) all of them save by default.** A quantity most tools
  compute only on request is not required; it MAY be *expected* (validators warn when it is
  missing).
- **Options = the union**, with each tool's default, so a reader can see which option in
  another tool corresponds, which explains most discrepancies between tools.

**Tool profiles** describe one program's records (`dfeols/0.1`). A tool profile builds on
standard ones and MAY depart from them where the tool must, but MUST declare it:

- `x-extends` lists the profiles it builds on (`["linear-fe/0.1"]`).
- `x-deviations` lists each departure as `{path, reason}`, where `path` uses the syntax of
  section 1.1 and covers its sub-paths.
- A profile whose `$defs/rules` includes its base's rules has no departures. Standard profiles
  don't deviate from each other.

**Purpose profiles** describe what a destination needs: a journal, a data editor, a registry,
a replication harness. Model profiles say what a kind of model must report; a purpose profile
says what a use of the record must see. It is a floor, where the disclosure level (4.9) is a
ceiling.

- `x-min-level` is the lowest disclosure level that can meet it. A writer asked for a purpose
  uses that level unless the user sets one, and fails, naming the level, if the user's is
  lower.
- It only adds requirements, so it composes with any model profile: a record claims
  `["linear-fe/0.1", "<purpose>/0.1"]` and is checked against both.
- It can't forbid content; only the sharer's level does that.
- It SHOULD require only what the destination states it needs, and its page in
  `spec/profiles/` cites where the destination says so, rule by rule.

### 9.2 What a validator reports

- Errors against the core or a claimed profile make the record invalid.
- For a claimed profile that extends a base the record doesn't also claim, the validator
  checks the record against the base and reports: information when the record meets it ("also
  meets linear-fe/0.1"); information for each failure the profile declares in
  `x-deviations`; a **warning** for each failure it doesn't declare. The record stays valid
  either way: it is judged by the profiles it claims.
- A claimed profile the validator doesn't know is reported as information.
- A claimed purpose profile whose `x-min-level` is above the record's declared disclosure
  level is an error (4.9).

### 9.3 The catalog

[`schema/catalog.json`](../schema/catalog.json) lists the core schema and every registered
profile: `name`, `file`, `kind` (`standard`, `tool` or `purpose`), `status` (`draft` or `published`),
`maintainer`, `description` and `examples`. Profiles are added by pull request
([CONTRIBUTING.md](../CONTRIBUTING.md)); CI checks each one.

- **Published versions never change.** A published entry carries the sha256 of its file, and
  a fix is a new version (`/0.2`).
- **Local drafts**: validators SHOULD accept extra profile folders (the reference validator
  reads `$ESTREC_SCHEMA_PATH`), so a profile can be tried before its pull request. A
  local profile MUST NOT replace a catalog name.
- **License**: everything in the catalog is dedicated to the public domain under [CC0 1.0],
  so any tool can copy, embed or adapt a profile under its own license. Contributed profiles
  MUST be CC0 too, and carry `"x-license": "CC0-1.0"`.

### 9.4 Registered profiles (0.1)

| Profile | Kind | Requires |
|---|---|---|
| [`inference/0.1`](profiles/inference.md) | standard | `parameters` with `estimate`, `std_error`, `p_value` (no `p_value` needed on variance-component and ancillary rows), a row's own `df` when it has one; a default `vcov` with `type` and `ssc.convention`; `metrics.nobs`; `df_residual` unless the default vcov has no `df_t` (z tests) |
| [`linear-fe/0.1`](profiles/linear-fe.md) | standard | `inference` plus `n_singletons`, `specification.options.drop_singletons`, and `structures.fixed_effects` with `levels` |
| [`iv/0.1`](profiles/iv.md) | standard | `inference` plus `specification.endogenous` and `instruments`; a `first_stage` test expected |
| [`dfeols/0.1`](profiles/dfeols.md) | tool | `linear-fe` plus `extensions.dfeols`: the first worked tool profile |
| [`did/0.1`](profiles/did.md) | standard | `meta.estimator.method`; `specification.did` (time, comparison, cohort or treatment); `metrics.nobs`; `estimate` and `std_error`; a `did` object saying which effect a row is; a default `vcov` with `type`; `structures.did` expected |
| [`did2s/0.1`](profiles/did2s.md) | tool | `did` plus first- and second-stage specifications, the cluster, and a two-stage GMM or bootstrap vcov |
| [`csdid/0.1`](profiles/csdid.md) | tool | `did` plus `method`, `agg`, `typebase`, an influence-function or wild-bootstrap vcov, and the `e(gtt)` cells |
| [`glm/0.1`](profiles/glm.md) | standard | `meta.estimator.distribution` and `link`; `estimate`, `std_error`, `p_value` (not on ancillary rows); `metrics.nobs`; a default `vcov` with `type` and `ssc.convention`; `structures.numerics.converged`; `log_lik` expected, and `deviance` when the tool reports one |
| [`ppmlhdfe/0.1`](profiles/ppmlhdfe.md) | tool | `glm` (Poisson, log) plus separation and singleton counts and options, and `structures.fixed_effects` |
| [`conditional-logit/0.1`](profiles/conditional-logit.md) | standard | `specification.groups`; `options.likelihood` and `drop_uninformative`; `estimate`, `std_error`, `p_value`; `metrics.nobs`; a default `vcov` with `type` and `ssc.convention`; `log_lik`, `structures.groups` expected, `n_groups` when the tool reports one |
| [`mixed/0.1`](profiles/mixed.md) | standard | `meta.estimator.method` (REML/ML/quadrature); `specification.random_effects`; fixed-effect `estimate` and `std_error`; a `vc` object on variance-component rows; `metrics.nobs`; `structures.random_effects` with `levels`; a default `vcov` with `type`; `numerics.converged`; `log_lik` expected, `singular` when the tool reports it |
| [`choice/0.1`](profiles/choice.md) | standard | `meta.estimator.method`; `specification.choice` (case, alternative); `estimate`, `std_error`; `n_cases`, `log_lik`; a default `vcov` with `type`; `numerics.converged`; mixed logit adds random parameters, draws and a spread row |
| [`sem/0.1`](profiles/sem.md) | standard | `meta.estimator.method`; `specification.formula` (model syntax); a `sem` row object (op, lhs, rhs, free); `std_error` on free parameters; `nobs`, `chisq`, `chisq_df`; a default `vcov` with `type`; `numerics.converged`; `cfi`, `tli`, `rmsea`, `srmr` expected |
| [`mediation/0.1`](profiles/mediation.md) | standard | `specification.mediation` (treatment, mediators, outcome, inference method); `nobs`; an indirect-effect row; `estimate` with `std_error` or an interval on effect rows |
| [`mi/0.1`](profiles/mi.md) | standard | `specification.imputation` (`m`; `method` expected); `estimate`, `std_error` (pooled); `nobs`; a default `vcov` with `type`; per-row Rubin components as vocabulary |
| [`survey/0.1`](profiles/survey.md) | standard | `specification.survey_design` (weights, strata, PSUs, fpc with its convention, variance method, single-PSU handling); `estimate`, `std_error`; `nobs`; a default `vcov` with `type` |
| [`multiple-testing/0.1`](profiles/multiple-testing.md) | standard | `specification.multiple_testing` (method, error rate, `n_tests`); `p_value_adjusted` on the tested rows or tests |
| [`resampling/0.1`](profiles/resampling.md) | standard | `specification.resampling` (method, `reps`); a row with a `resampling` p-value or interval |
| [`survival/0.1`](profiles/survival.md) | standard | `meta.estimator.method`; `specification.survival` (time, event); `estimate`, `std_error`; `nobs`, `n_events`; a default `vcov` with `type`; `ties` for Cox/Fine-Gray; distribution and AFT/PH metric for parametric; competing events for Fine-Gray |
| [`med2s/0.1`](profiles/med2s.md) | tool | `mediation` plus the DiD design, cluster, placebo-adjustment options, bootstrap percentile inference, and `extensions.med2s` (signal test, moments, placebo composition, diagnostics, sensitivity) |
| [`meta-analysis/0.1`](profiles/meta-analysis.md) | standard | `meta.estimator.method`; `effect_measure`; pooled rows with `estimate`, `std_error`; `k`, `q`, `q_df`; random effects add `tau2_method`, `ci_method`, `tau2` |
| [`predictive/0.1`](profiles/predictive.md) | standard | `meta.estimator.method`; `specification.task` and `validation`; `structures.hyperparameters` (resolved) and `evaluation` (metric, split, value) |
| [`causal-ml/0.1`](profiles/causal-ml.md) | standard | `meta.estimator.method`; `specification.causal` (treatment, outcome, estimand), `learners`, `cross_fitting` (folds, repeats, seed); a row with a `causal` estimand, `estimate`, `std_error`; `nobs` |
| [`gam/0.1`](profiles/gam.md) | standard | `specification.smooths` (basis, k); `options.smoothing_method`; `edf` on smooth rows; `estimate`, `std_error` on parametric rows; `nobs` |
| [`bayesian/0.1`](profiles/bayesian.md) | standard | `meta.estimator.method`; every prior; chains, draws, warmup and seed for MCMC; a `posterior` object (point, sd, interval with probability and kind) on each row; `nobs` |
| [`dcas/0.1`](profiles/dcas.md) | purpose | disclosure level 4; `publication.locator` with `label` and a table, figure, page or section; `estimate` with `std_error` or an interval; `meta.core_digest`; language and estimator with `version`; each data input by `name`; a set seed for resampling, Bayesian and causal-ML records; `specification.program`, data citations and checksums expected |

Planned as needed: `glm` (deviance, log-likelihood, family and link), `mixed` (variance
components), `ml` (scikit-learn, tidymodels, xgboost).

## 10. Schema locations and versions

- The format version is `schema` in each record: `"estrec/0.1"` during the draft, then
  `"estrec/1"`. Collections carry `"estrec-collection/0.1"` (section 11), versioned
  with the format.
- Schemas are published at
  `https://estrec.org/schema/<file>`, which is also each file's
  `$id` (for example `.../schema/estrec-0.1.json`, `.../schema/profiles/linear-fe-0.1.json`,
  `.../schema/estrec-collection-0.1.json`).
  Profiles refer to the core by relative `$ref`, so a local copy validates offline. These
  locations may change before the first published version; a published `$id` never changes.
- Validators SHOULD NOT fetch schemas over the network; the reference validator ships them.

## 11. Collections (`estrec-collection/0.1`)

A **collection** is a set of records plus what is true of the set as a whole. It has two main
uses, and each leans on a different part:

- **A paper's results** (`kind: "paper"`) is organised by `members`: the records behind the
  paper's numbers, each with where it appears (Table 1 col. 1, col. 2, ...), and the paper's
  citation in `publication`. It answers "which record is behind each number?".
- **Replicating results** (`kind: "session"` or `"replication"`) is organised by `events`:
  the timeline of what was done, in order, including the fits (each fit event names its
  member). It answers "what exactly happened, so that I can do it again?".

Both parts are always allowed, and a collection can have both; `kind` sets which one a
validator expects (11.6).

A collection is an **export**: it is built from records and never edited on its own. Each
member stays a self-contained record that can be pulled out and read alone, and the
collection never changes a member. Members are carried *in* the collection, embedded or in a
JSON Lines file beside it (11.3); a collection does not point to record files elsewhere.

### 11.1 Encoding and structure

A collection is a single JSON object in UTF-8, encoded as a record is (section 2: non-finite
numbers as strings, absent vs `null`, UTC times, resolved values). A collection file SHOULD
be named `<name>.estrec-collection.json`.

| Member | Status | Content |
|---|---|---|
| `schema` | required | `"estrec-collection/0.1"` |
| `meta` | required | identity and kind of the collection (11.2) |
| `publication` | optional | the paper a `paper` collection belongs to: the block of section 5, with `citation` and no locator (members carry those) |
| `session` | optional | what the session was and how it ran (11.4) |
| `provenance` | optional | the session's or replication's own software, environment, execution, agent and data (11.4) |
| `members` | required | the records, in order (11.3); may be empty |
| `events` | optional | what happened, in order (11.5) |
| `attachments` | optional | side files, as for records (8.1); holds the members file (11.3) |
| `extensions` | optional | blocks added by tools, as for records (7.1) |
| `history` | optional | every tool that created, extended or redacted the collection (7.1) |

Writers SHOULD write the members in this order, so a reader sees what the collection is
before its records, and MUST NOT add others. `extensions` and `history` follow section 7.1;
a collection's `history` describes the collection, and each member keeps its own.

### 11.2 `meta` (required)

| Field | Status | Content |
|---|---|---|
| `id` | required | a UUID identifying this collection |
| `created` | required | when the collection was written |
| `kind` | required | `"paper"`, `"session"`, `"replication"`, `"batch"` or `"other"` |
| `title`, `tags`, `notes` | optional | user labels and free text |
| `producer` | optional | `{name, version}` of the software that wrote the collection |
| `disclosure` | optional | `{level}`: the most the collection and its members disclose (11.7) |
| `parent` | optional | the `id` of the collection this one was lowered from (11.7) |

`batch` is a set of runs with no paper or session behind it (a grid of specifications, a
benchmark); `other` is anything else.

### 11.3 `members` (required)

Each member is an object:

| Field | Status | Content |
|---|---|---|
| `id` | required | the member record's `meta.id`; unique within the collection |
| `record` | one of these | the record, embedded whole |
| `attachment` | one of these | the `id` of the members file in `attachments` that holds the record |
| `sha256` | optional | SHA-256 (hex) of the record's [RFC 8785] canonical JSON |
| `created` | optional | the record's `meta.created`, so the order of runs is visible without opening the records |
| `label` | optional | the collection's own short name for the member (`"baseline"`, `"col3"`) |
| `locator` or `locators` | optional | where the result appears in the collection's `publication` (5); expected for `kind: "paper"` |
| `notes` | optional | free text |

- **Order.** The array order is the collection's order. A `paper` collection SHOULD list its
  members in locator order (Table 1 before Table 2, columns left to right); a `session`
  SHOULD list them in the order run. A record that appears in several places is **one**
  member with `locators`, not several members.
- **Storage.** Each member has exactly one of `record` and `attachment`. Writers SHOULD embed
  the records. A collection that would pass the 16 MB limit (11.7) keeps its records in a
  **members file** instead: a [JSON Lines] file of one record per line, named
  `<name>.members.jsonl`, next to the collection and listed in `attachments` with
  `role: "members"` and `media_type: "application/jsonl"`. Writers SHOULD switch to a members
  file automatically above the limit, and MAY do so on request. The member entries stay in
  `members` either way, so the collection can be read as an index without opening the file. A
  reader finds a record in the members file by its `meta.id`.
- **Hash.** `sha256` proves which version of a record the collection holds. It is computed
  over the record's RFC 8785 serialization (non-finite numbers as strings, as written), the
  same way wherever the record is stored, so moving a member between the collection and a
  members file doesn't change it. It covers the whole record, so appending a test to a member
  (4.8) changes its hash: the collection then no longer holds that version. The hash is
  OPTIONAL; a validator reports one that doesn't match as a warning.
- **Locators.** A member's `locator` (or `locators`) is the collection's statement of where
  the result appears, with the same fields as in section 5. It is separate from the record's
  own `publication`: a writer MUST NOT copy it into the record (records are often written
  before tables are numbered, and the collection never changes a member). When the record
  does carry `publication.locator` or `locators`, the member's locator SHOULD equal one of
  them on the structured fields present (`label` aside), and a validator warns when it
  doesn't. A validator also warns when a member record's `publication.citation.DOI` differs
  from the collection's.

### 11.4 `session` and `provenance` (optional)

`session` describes a session: one process (an interactive session, a manager job) that ran
several fits.

| Field | Content |
|---|---|
| `id` | the session id that member records carry in `provenance.execution.session`; required when `session` is present |
| `started`, `ended`, `elapsed_seconds` | when it ran |
| `status` | `"open"`, `"closed"`, `"crashed"` or `"timed_out"` |
| `clients` | the clients that connected, each `{language, version, host, connected, disconnected}` (a Python and an R client, for example) |
| `fixed` | what was fixed for the session, in the producer's terms: fixed-effect structure, weights, sample definition, declared variables |

`provenance` has the structure of a record's (4.6) and describes the **session or
replication process**, not one fit: the software, environment and hardware of the manager
and workers; the scheduler job that held the session, launch parameters, total wall time,
worker-seconds, peak memory and idle time (`execution`); the dataset and its checksum, and
derived data the session persisted (`data`). Members repeat what applies to them, so a member
read alone loses nothing; the collection-level block shows what changed *during* the session
(workers replaced after a failure, for example).

The identifying fields of section 4.7 are identifying here too, as is `session.clients[*].host`.

### 11.5 `events` (optional)

`events` is the timeline, in order. Each event is an object:

| Field | Status | Content |
|---|---|---|
| `when` | required | when it happened |
| `type` | required | what happened (below) |
| `member` | optional | the `id` of the member it produced or concerns; set on every `fit` event |
| `detail` | optional | an object in the producer's terms: the variables created, the setting changed and its old and new values, the worker lost |
| `message` | optional | text, e.g. an error message |

`type` has a recommended vocabulary (in the schema), but any string is valid: `fit`,
`data_loaded`, `variable_created`, `setting_changed`, `demeaned_persisted`,
`demeaned_loaded`, `worker_lost`, `worker_added`, `client_connected`,
`client_disconnected`, `command` (code run, in a replication), `error`, `note`.

Replaying the events in order should reproduce the members. Events SHOULD be in time order;
a validator warns when `when` goes backwards.

### 11.6 What a validator checks

A validator checks the collection against `estrec-collection/0.1` and **each member as a
record**, against the core and the profiles that member claims (section 9), reporting a
member's issues under `members[<i>]`. In addition:

| Check | Level |
|---|---|
| a member without `id`, with both or neither of `record` and `attachment`, or with an `id` used twice | error |
| an `attachment` that names no entry in `attachments` | error |
| a member record whose `meta.id` is not the member's `id` | error |
| an event whose `member` names no member | error |
| `kind: "session"` without `session.id` | error |
| a `sha256` that doesn't match the record | warning |
| a member locator that matches none of its record's locators; a citation DOI that differs from the collection's | warning |
| a members file whose `sha256` doesn't match it, or that lacks a member's record | warning |
| events out of time order | warning |
| expected for the kind but missing (below) | warning |
| a members file that can't be found, so its members weren't checked | information |

| `kind` | Expected |
|---|---|
| `paper` | at least one member; `publication.citation`; a `locator` or `locators` on each member |
| `session` | `events`; a `fit` event for each member; each member's `provenance.execution.session` equal to `session.id` |
| `replication` | `events`; `publication` |
| `batch`, `other` | nothing beyond the structure |

### 11.7 Size, redaction and disclosure levels

- **Size.** A collection file above 16 MB is an error, as for a record. The 1 MB and
  10,000-element warnings (8.2) apply to the collection *without* its embedded records, and
  each member record is checked against the record limits as if it stood alone. A members
  file has no overall limit.
- **Attachments.** A member record's attachment paths are relative to the folder of the
  collection (or of its members file, which sits beside it), so a collection and its
  members' side files move together.
- **Redaction.** Redacting a collection redacts its own identifying fields (those the
  collection schema marks `x-identifying`, which include a record's provenance fields) and
  every member record (under the member's own profiles, 4.7) with the same method and salt,
  updates each member's `sha256` that is present, and appends a `history` entry to each
  member and to the collection.
- **Disclosure levels.** A collection MAY declare a level in `meta.disclosure.level`
  (4.9). Its own fields carry level marks in the collection schema: `meta` (except
  `producer`, 4), `members`, `publication`, `attachments` and `history` are level 1;
  `session` and `provenance` are level 4, with `session.started`, `ended`,
  `elapsed_seconds` and `clients` at 5 and `provenance` as in a record; `events` are level 4,
  except events about workers and clients (`worker_lost`, `worker_added`,
  `client_connected`, `client_disconnected`) at 5; `extensions` are level 4. Every member
  record MUST be at the collection's level or below: declared at it or lower, or, if it
  declares none, holding no field above it. A `session` or `replication` collection needs
  level 4 or more, since its required parts are level 4. Validators report a field above the
  declared level, a member above it and a kind below its minimum as errors.
- **Lowering a collection** lowers each member record above the level (4.9: each becomes a
  new record, so its member `id`, `sha256` and the events that name it change too) and
  removes the collection's own fields above it. The result is a new collection: a new
  `meta.id`, `meta.parent` set to the original's, and a `history` entry
  `{action: "reduced", level, fields}`. A tool that writes records and their collection
  together writes both at the level the user chose; building a collection from existing
  records declares no level unless asked.
- **Integrity.** A collection has no digest of its own in 0.1. Each member keeps its core
  digest (7.2), and member hashes pin which versions the collection holds.

### 11.8 Example: a paper's results, minimal

```json
{"schema": "estrec-collection/0.1",
 "meta": {"id": "c0110000-...", "created": "2026-11-01T12:00:00Z", "kind": "paper",
          "title": "Table 2"},
 "publication": {"citation": {"type": "report", "title": "An illustrative working paper",
                              "DOI": "10.0000/example.wp1"}},
 "members": [
   {"id": "2b7e6e56-...", "label": "baseline", "locator": {"table": "2", "column": "1"},
    "sha256": "...", "record": {"schema": "estrec/0.1", "meta": {"id": "2b7e6e56-...", ...}, ...}},
   {"id": "380a95f5-...", "label": "full",
    "locators": [{"table": "2", "column": "3"}, {"table": "A1", "column": "1"}],
    "sha256": "...", "record": {...}}]}
```

[`schema/examples/`](../schema/examples/) has complete collections: a paper, a session with
its events, and a replication whose members are in a members file.

A flat table of `parameters` across members (Parquet or CSV, with the member id, label,
locator, response and term) is a convenient export for tables and plots. It is not part of
the format.

## 12. Example: base R `lm`, minimal

```json
{"schema": "estrec/0.1",
 "meta": {"id": "6f1c...", "created": "2026-10-24T15:02:11Z", "status": "ok",
          "estimator": {"family": "linear", "method": "ols"}, "responses": ["mpg"],
          "profiles": ["inference/0.1"]},
 "specification": {"call": "lm(mpg ~ wt, data = mtcars)",
                   "formula": {"text": "mpg ~ wt", "syntax": "R"}},
 "metrics": {"nobs": 32, "df_residual": 30, "r2": 0.7528, "sigma": 3.046, "conf_level": 0.95},
 "parameters": [
   {"term": "(Intercept)", "estimate": 37.285, "std_error": 1.8776, "statistic": 19.858,
    "p_value": 8.24e-19},
   {"term": "wt", "estimate": -5.3445, "std_error": 0.5591, "statistic": -9.559,
    "p_value": 1.29e-10}],
 "structures": {"vcov": [{"kind": "matrix", "labels": ["(Intercept)", "wt"],
                          "data": [[3.525, -1.0], [-1.0, 0.3126]], "type": "iid",
                          "ssc": {"convention": "R lm", "formula": "sigma^2 with N - K"},
                          "df_t": 30, "default": true}]},
 "provenance": {"software": [{"name": "R", "version": "4.5.1", "role": "language"},
                             {"name": "stats", "version": "4.5.1", "role": "estimator"}],
                "environment": {"os": "Ubuntu 24.04", "blas": "OpenBLAS 0.3.26"}}}
```

(Numbers illustrative.) [`schema/examples/`](../schema/examples/) has complete records,
including a linear fixed-effects record with every expected section filled.

## Appendix A. Related formats

No existing format covers one estimation run across software. The nearest pieces, and what
this format borrows from them:

| Existing | Covers | Missing | Borrowed |
|---|---|---|---|
| broom `tidy`/`glance` (R) | parameter and fit-statistic names; read by modelsummary | a file format; vcov, provenance | parameter and metric names |
| PMML | scoring a fitted model in another system | inference, provenance | |
| Stata `e()`, `estimates save`, `collect` | full detail of one run in Stata | readable outside Stata | `c()` as a checklist of environment |
| SPSS OMS and the Notes table | output tables as XML; the run's filter, weight, split, syntax, timing | describes display tables, not a model | `specification.state`, processor vs elapsed time |
| fixest, pyfixest, linearmodels result objects | full detail, one tool | in memory, tool-specific | the profile vocabularies |
| MLflow runs | parameters, metrics, artifacts by link, source commit | inference, data identity | links, tags |
| renv.lock, pylock.toml, conda lock, SBOMs | exact package sets with hashes | the model | `provenance.software[*].lock` |
| Package URL (purl) | one identifier for software across ecosystems | | `provenance.software[*].purl` |
| W3C PROV, RO-Crate Process Run Crate | a run as an activity with inputs, outputs, agent | anything statistical | the shape of `provenance` |
| SLURM `sacct` | job, allocation, timing, memory | | `provenance.execution.scheduler` field names |
| CSL-JSON | citations | | `publication.citation` |
| AsCollected, ResearchBox, AsPredicted | provenance of a paper's data, code and pre-registration | the results | named links in `publication` |

## References

- [RFC 2119]: Key words for use in RFCs to Indicate Requirement Levels.
- [RFC 8174]: Ambiguity of Uppercase vs Lowercase in RFC 2119 Key Words.
- [RFC 8259]: The JavaScript Object Notation (JSON) Data Interchange Format.
- [RFC 3339]: Date and Time on the Internet: Timestamps.
- [RFC 8785]: JSON Canonicalization Scheme (JCS).
- [RFC 9562]: Universally Unique IDentifiers (UUIDs).
- [JSON Schema 2020-12](https://json-schema.org/draft/2020-12).
- [Package URL]: purl specification.
- [CSL-JSON]: Citation Style Language data schema.
- [CC0 1.0]: Creative Commons CC0 1.0 Universal.
- [JSON Lines]: one JSON value per line.

[RFC 2119]: https://www.rfc-editor.org/rfc/rfc2119
[RFC 8174]: https://www.rfc-editor.org/rfc/rfc8174
[RFC 8259]: https://www.rfc-editor.org/rfc/rfc8259
[RFC 3339]: https://www.rfc-editor.org/rfc/rfc3339
[RFC 8785]: https://www.rfc-editor.org/rfc/rfc8785
[RFC 9562]: https://www.rfc-editor.org/rfc/rfc9562
[Package URL]: https://github.com/package-url/purl-spec
[CSL-JSON]: https://github.com/citation-style-language/schema
[CC0 1.0]: https://creativecommons.org/publicdomain/zero/1.0/
[JSON Lines]: https://jsonlines.org/
