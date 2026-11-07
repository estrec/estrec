# Changelog

## Unreleased

- Viewer: **Print / PDF** (Ted 2026-11-07) prints the table preview alone, in light colours
  with 1 in margins, shrunk to the Table width (6.5 in by default) if wider; Save as PDF in
  the browser's print dialog gives a PDF (vector, sparklines included).
- Word export of a set width (Ted 2026-11-07): `render(t, "word", width=6.5)` (inches; the
  viewer's Word export has a Table width box, 6.5 by default) fixes the table's and every
  column's width (label column by its longest label, 36 pt to 40%; the rest shared; beside
  the estimates, numbers then drawing) and draws each sparkline to its column's width; the
  marks keep their size and only the axis narrows, so nothing needs scaling in Word.
- Published tables keep the viewer's column labels: estrec.org rebuilds a table from the spec
  and the bare records, so a column labelled by its collection member fell back to the
  record's `meta.title` (for R records, the estimation call). Publish now writes each such
  label into the column's `header` (`publishSpec` in the viewer's script).
- Table sparklines can sit beside the estimates (Ted 2026-11-07): `"place": "beside"` on a
  sparkline line gives each column of estimates a column next to it, with one drawing per
  term spanning the term's rows (its 0 rule their full height, so down a column the rules
  join into one line). Headings and statistics rows span both columns. HTML, the viewer and
  its web page lay it out (an SVG filling its cell), and Word (rows exactly 12 pt, 15 pt with
  the space above a term, and an image of their height); other formats draw it below. One
  sparkline at most is beside. The viewer's sparkline line has a "Where" choice.
  `"align"` (Ted 2026-11-07): `"estimate"` (default) puts the marks level with the
  estimate's row and gives the term's other rows the 0 rule alone, so with a standard
  error and a p-value the drawing reads with its estimate; `"middle"` keeps one cell
  spanning the term's rows.
- Stata: fixed-effect names after reghdfe, ivreghdfe and ppmlhdfe come from
  `e(extended_absvars)` (`rep78`, `foreign#c.mpg`), not `e(dof_table)`'s row names (`1.rep78`);
  the same fix in `converters/reghdfe/`. ppmlhdfe's 8 test cases now run (records
  `e(df)` as `df_residual`, as glm, with z tests).
- Fixed-effect rows in tables default to `Y` / `N` (Ted 2026-11-07; were `Yes` / blank):
  `format.fe_yes` and `format.fe_no`, in Python, the viewer and estrec's `render_table`.
  estrec's `glance()` keeps `X`, as fixest's does, so modelsummary gives the same table from
  records as from fits.
- `estrec show`'s side-by-side table is now `new_table` + `build_table` + `render(..., "text")`
  (Ted 2026-11-07), so it can't drift from `estrec table`: names, then the dependent
  variable, as heading rows; the table's statistic labels (`R²`, `Adj. R²`, ...); `Y`/`N`
  fixed-effect rows; the stars and standard-error notes. With `--component`, a component
  with several responses (first stages) gets a column per response, headed by it.
- Table sparklines are drawn in LaTeX too, as a TikZ picture per cell with the SVG's marks
  (1 px = 0.75 pt; rows 12 pt high so a column joins; the output's first line says it needs
  `\usepackage{tikz}`), by the Python `render`, the viewer's script (byte for byte) and
  `to_great_table` (the SVG in `as_raw_html`, TikZ in `as_latex`, sparkline rows unpadded
  and the body without hairlines). estrec's `render_table` draws them in modelsummary's
  tinytable outputs (SVG in HTML, TikZ in LaTeX, the same strings as Python's); other
  formats still show `[low, high]`.
- **Renamed to estrec** ("estimation record"; Ted 2026-11-06), a clean break with no aliases
  while 0.1 is a draft: type strings `estrec/0.1`, `estrec-collection/0.1`,
  `estrec-table/0.1` (schema files `schema/estrec-0.1.json` etc.); file suffixes
  `.estrec.json`, `.estrec-collection.json`, `.estrec-table.json`; `$id`s under
  `https://estrec.org/schema/`; the spec is `spec/estrec.md`; the Python package, import and
  command are all `estrec` (was `estimation-format`, `estimation_format`, `estimation`);
  environment variables `ESTREC_SCHEMA_PATH`, `ESTREC_REDACT_SALT`; the viewer's script is
  `viewer/estrec-table.js`; the repository moves to github.com/estrec/estrec. Profile names
  and function names (`to_estimation()`, `write_estimation()`, `read_estimation()`,
  `as_estimation_test()`, the converters) are unchanged. Entries below use the old names.
- estrec.org (`server/`): one Cloudflare Worker serves the home page, the schemas at their
  `$id`s and the viewer, and a Publish service. `POST /api/publish` stores a table spec and
  its records, with identifying fields removed, in R2 and returns an unlisted `/t/<id>` link
  and a delete token. The page is the viewer's web export, rendered by the Worker under a CSP
  that allows only its own script. Tables expire a year after their last view; the licence is
  CC0 1.0 (default), CC BY 4.0 or CC BY-SA 4.0; Turnstile and per-IP limits guard publishing;
  there is a report page. The viewer shows **Publish…** when it is served from the site
  (`viewer/publish.js`). The GitHub Pages workflow is removed.
- Writers report; they don't reinterpret (spec section 4, Ted 2026-11-07): values as the tool
  reported them, renamed only when the math or the tool's documentation shows it's the same
  quantity under a canonical name. `metrics.nobs` is now the number of observations as the
  tool reports it (was "rows used"), so Stata's `e(N)` under frequency weights (the sum of the
  weights) is kept, with a `definition`. `glm/0.1`: `deviance` is expected only when the tool
  reports one and is no longer flagged when missing. `estrec` for Stata records `nobs` as
  `e(N)`, and runs `estat gof` after `poisson` (its deviance goodness-of-fit, equal to `glm`'s
  `e(deviance)`, as `metrics.deviance`; deviance and Pearson tests) and after `logit`,
  `logistic`, `probit` (Pearson over covariate patterns, a test); `noestat` skips them.
- `inference/0.1`: `metrics.df_residual` is no longer required when the default vcov has no
  `df_t` (absent or null), i.e. its tests and intervals are z (Ted, 2026-11-07). Tools that
  use z tests and report no residual df (Stata's ML commands, `ivregress`/`ivreg2` without
  `small`, `xtreg, re`, ppmlhdfe) leave it out instead of writing a value they don't report.
- `estrec` for Stata (`stata/`, installable with `net install estrec`): `estrec write using
  FILE` writes a record from `e()` after `regress`, `areg`, `xtreg` (fe, re), `reghdfe`,
  `ivregress`, `ivreg2`, `ivreghdfe`, `logit`, `logistic`, `probit`, `poisson`, `nbreg` and
  `glm`, claiming `inference/0.1`, `linear-fe/0.1`, `iv/0.1` and `glm/0.1` as each fits; any
  other e-class command gets a core record with no profile claims, and prefix results are
  refused. Small-sample corrections are written out per command, checked against each other in
  Stata 18 (`areg` counts absorbed levels nested in the clusters, `xtreg, fe` and reghdfe
  don't; `ivregress` and `ivreg2` without `small` apply no factor). IV records carry the
  first-stage, identification, overidentification and endogeneity tests (`ivreg2` from `e()`,
  `ivregress` from `estat`); GLM records convergence, offset or exposure, and the deviance
  when the command posts one (`glm`; estrec computes no statistics of its own, Ted
  2026-11-07). z-test fits record no `df_residual`.
  Disclosure levels 1-5 as in the converters. `reghdfe` records equal
  `converters/reghdfe`'s apart from the writer and the formula text. `tests/test_stata.py`:
  22 commands at every level validate with no warnings and match Stata's results table.
- `estrec` for Stata, Tier 2: `ppmlhdfe` (inference, glm, ppmlhdfe; from the profile, not yet
  run), `clogit` (conditional-logit), `stcox` and `streg` (survival; `estat phtest, detail`
  after `stcox`), `mixed` and `me*` (mixed), and the `svy:` (survey), `bootstrap:` and
  `vce(bootstrap)` (resampling) and `mi estimate:` (mi, with the new `imputation()` option)
  prefixes. Variance components are recorded in `e(b)`'s metric with only the tests and
  intervals Stata's table shows; `mixed, dfmethod(kroger)` records `e(V_df)` as the default
  vcov with per-row `df`; `mi estimate` rows carry Rubin's components and their own df;
  bootstrap rows keep the bootstrap SE and intervals beside `e(V_modelbased)`. ML records also
  record `specification.options.optimizer` (`e(technique)`). The Stata test now compares every
  value of `r(table)`, including those between 0 and 1 that it used to read as missing, and
  checks that a record has no test where Stata shows none.
- Profiles, from the Stata Tier 2 work (Ted, 2026-11-07): `inference/0.1` and `glm/0.1` need no
  `p_value` on variance-component and ancillary rows (`component` `random` or `auxiliary`), so
  Stata `mixed`/`me*` records claim inference and nbreg's `/lnalpha` carries no test Stata
  doesn't show; `inference/0.1` registers `parameters[*].df`, a row's own t-test df (with the
  vcov's `df_t` null: mixed `dfmethod()`, mi estimate). `conditional-logit/0.1` `n_groups` and
  `mixed/0.1` `numerics.singular` are expected only when the tool reports them.
  `resampling/0.1`: the core columns follow the default vcov, which is the resampling one when
  the estimator's own variance is resampled (Stata's bootstrap prefix), the analytic vcov kept
  beside it; rows add `mean`, `bias`, `reps`, `intervals`, the design `mse`. `mi/0.1`:
  `imputation.method` is expected, not required, since Stata's `mi estimate` doesn't keep it.

- Table specs, `estimation-table/0.1` (`spec/table.md`, `schema/estimation-table-0.1.json`,
  catalog entry `table`; proposal `docs/proposals/table-spec.md`, Ted 2026-11-05): a saved
  layout for a regression table from records, with no results in it. Columns name records by
  `meta.id` (with source paths as hints and an optional `sha256` pin) and may pick another
  vcov, a component or a response; rows are ordered and relabelled, with `keep`/`drop`
  patterns and shared rows; statistics rows are metrics, the vcov type or cluster counts,
  fixed effects, tests or literal text. A companion to the format: records and collections
  don't change. Python: `estimation_format.table` (`new_table`, `read_table`, `write_table`,
  `validate_table`, `build_table`, `render`/`render_table` to text, Markdown, LaTeX, HTML
  and CSV, `to_great_table`; `python -m estimation_format.table spec.json -f latex`).
- The record viewer (`viewer/`, published at
  https://estimation-format.github.io/estimation/viewer/): a static page that reads records,
  folders and collections in the browser (nothing is uploaded), shows one record in full, and
  builds a table: columns from records (each with its own vcov), terms shown, ordered and
  relabelled, statistics rows, stars and decimals, with a live journal-style preview and
  LaTeX, Markdown, HTML, CSV, text or table-spec export (optionally pinning record versions).
  Its logic, `viewer/estimation-table.js`, runs in node too; tests check that it builds and
  renders the same tables as the Python reference and agrees with its t distribution.
- estrec `render_table(spec, output, records)`: renders a table spec through modelsummary (each
  column a model from the record's `tidy()` with its vcov; statistics rows by the spec's rules
  as `add_rows`). The example spec gives the same cells as the Python and browser renderers.
- Viewer: tables that link to their records. In the preview, a column heading shows a summary
  of its record on hover and opens it on click. A new **Web page** export writes one
  self-contained HTML file with the table and the records behind it: hover a heading for a
  summary (estimator, N, standard errors, fixed effects, software), click it for the full
  record (estimates, metrics, variance estimates, fixed effects, tests, the JSON and a
  download). Identifying fields are left out by default (`viewer/identifying.js`, generated
  from the schemas' `x-identifying` marks; the same result as the Python `redact`). Built
  tables carry `column_records`, the record behind each column (Python and JS).
- Table specs: several lines under each estimate (Ted, 2026-11-05). `uncertainty` may be a
  list of names and templates, one row each (`["std_error", "[{p_value}]"]`, `"p = {p_value}"`,
  `"[{conf_low}, {conf_high}]"`; placeholders `{estimate}`, `{std_error}`, `{statistic}`,
  `{p_value}`, `{conf_low}`, `{conf_high}`). `format.p_digits` sets p-value decimals and
  `format.p_style` shows small ones as `0.000` (`"fixed"`) or `<0.001` (`"less_than"`), in
  these lines and in test p-value rows. Python, the viewer (a line editor) and estrec
  `render_table()` agree cell for cell; existing specs render as before.
- CLI: `estimation show` (the quick look) and `estimation table` (render or `--check` a table
  spec); `estimation validate` also takes table specs. `ef.show` and `ef.table` are available
  from `import estimation_format as ef`.
- estrec reads records: `read_estimation()` (a record, or a folder of them) and
  `read_collection()` (embedded members or a members file) return records of class
  `estimation_record`, kept as written. `print` gives a quick view; `tidy` and `glance`
  methods, registered on generics, let modelsummary and other broom-based table packages take
  records as they take fitted models. `tidy(vcov = "iid")` and other vcovs in the record
  recompute SEs, tests and intervals; `component =` selects first-stage and other components.
  The writers accept records read back in.
- estrec and Python `glance` give the metrics a regression table shows by default (N, R2s,
  AIC, BIC, log-likelihood, F, RMSE as sqrt(rss / nobs)); `metrics = "all"` gives every one.
  estrec's feols records now carry `aic` and `bic`, as its GLM records did. A modelsummary
  table from records matches the one from the fits (tested when broom is installed).
- A quick look in the terminal (`estimation_format.show`, `python -m estimation_format.show`):
  a detail view of one record (estimates, metrics, FE level counts, vcov and its ssc, tests,
  messages), or a side-by-side table of several records, a folder or a collection.
  `--vcov`, `--digits`, `--table`/`--detail`, `--component`.
- Python views for tables (`estimation_format.views`): `tidy(record, vcov=, conf_level=,
  component=, dropped=)`, `glance(record)`, and `parameters_table`/`glance_table` across a
  collection's members (the flat table of spec 11), as plain dicts for polars, pandas or
  great_tables. The same semantics as estrec's views; t tests use a stdlib Student t (within
  2e-12 of scipy at any df).
- Disclosure levels (spec 4.9; proposal `docs/proposals/disclosure.md`, Ted 2026-11-05):
  how much a record discloses is the sharer's choice, from 1 (estimates, SEs, p-values,
  intervals, N, df) to 5 (environment, execution, agent, every software component). The core
  schema marks each field with `x-level` (`x-level-if` for software components by role);
  `meta.disclosure.level` declares it. Writers default to 4: language, estimator and writer
  only (the writer also in `history[*].by` and `meta.producer`, so its version can be traced),
  no environment, execution, agent or data locations. At
  level 1 `created` may be a date. Validators: fields above the declared level are errors, and
  withheld expected members are information, not warnings. New history action `reduced`.
- Collections: disclosure levels (spec 11.7). `meta.disclosure` and `meta.parent`; the
  collection schema marks its own fields (session times and clients, and events about workers
  and clients, at 5; `session`, `events`, `provenance` and `extensions` at 4); every member
  must be at the collection's level or below; a session or replication collection needs 4 or
  more. `new_collection(level=)` lowers members above it (new records; event references
  follow) and cuts the collection's own fields; it declares nothing by default, so building a
  collection from existing records leaves them as they are. `reduce_collection()`; `estimation
  reduce` takes collections; the validator checks the collection's level. estrec:
  `write_collection(level =)`, default 4 for fits.
- Any field marked `x-identifying` is level 5, so profiles' identifying fields need no mark of
  their own. `dfeols/0.1`: the `dask` block, the time estimate and per-round timings are
  level 5.
- estrec: `to_estimation(level =, purpose =, program =, data_info =)`. Level 4 by default
  (R, fixest and estrec only; no other packages, environment, user, host or command line);
  the marks come from `inst/levels.json`, written by `estimation levels` and kept equal to the
  schema by the Python tests. Profile claims the level breaks are dropped with a
  `profile_not_claimed` message; `add_test()` respects the declared level; the data input is
  named after the call's `data` argument.
- Converters: `level` in the fixest (R) and reghdfe (Stata) converters, default 4; each
  converter names itself as the writer; pyfixest takes `program=` and `data_info=`. The fixest
  converter wrote non-finite numbers as `"Infinity"`; now `"Inf"`, as the format says.
- CLI: `estimation levels` (the marks as JSON, for writers in other languages), `estimation
  reduce FILE --level N -o OUT`, `estimation digest --write FILE`.
- Core: `provenance.execution.session` is level 4 (the rest of `execution` stays 5), so
  session collections work at the default level; a test's `vcov.cluster` is level 3; objects
  and lists that removing fields leaves empty are removed too.
- Purpose profiles: a third catalog `kind`, `purpose`, for what a destination needs, with
  `x-min-level`; a floor where the level is a ceiling.
- Profiles: `dcas/0.1`, the first purpose profile (`spec/profiles/dcas.md`; proposal
  `docs/proposals/aea-profile.md`): results in a replication package for a journal that
  follows the Data and Code Availability Standard (DCAS 1.0: the AEA journals, Econometrica,
  the Economic Journal, the JPE, the JEEA, the Review of Economic Studies and others), from the
  standard and the SSDE README template, at level 4. Example `dcas.estimation.json`. Drafted
  as `aea/0.1` and renamed before release.
- Core: `specification.program` (`{path, line, sha256}`), the program in the replication
  package that ran the command, not identifying. A software `lock` is level 4 without its
  `path` (5). A field's level is never below its parent's.
- Validator and tools: `prepare` and `write` take `level` and `purpose`, drop the claims of
  model profiles the level breaks (`profile_not_claimed` in `meta.messages`) and fail when a
  purpose can't be met; `reduce(record, level)` writes a lowered copy as a new record with
  `meta.parent`; `fields_above`, `record_level`, `level_marks`, `path_level`,
  `DEFAULT_LEVEL_MARKS`. `add_test` and `redact` respect the declared level.
- Collections: `estimation-collection/0.1` (spec section 11, `schema/estimation-collection-0.1.json`,
  catalog entry `collection`), a set of records plus what is true of the set. `meta.kind` is
  `paper`, `session`, `replication`, `batch` or `other` and sets what a validator expects: a
  paper's members with locators and the citation; a session's `session` block (its id on every
  member's `provenance.execution.session`) and `events`; a replication's `events` and
  `publication`. Members are the records themselves, embedded or (above 16 MB) in a JSON Lines
  members file beside the collection; each has the record's `meta.id`, an optional `sha256` of
  its RFC 8785 canonical JSON, a `label` and the collection's own `locator`/`locators`, which
  must match the record's publication locators where it has them. Events are
  `{when, type, member, detail, message}` with an open `type` vocabulary. Size limits apply to
  the file and to the collection without its records; each member is checked as a record.
  Redaction covers the collection and its members. Examples: a paper, a session and a
  replication with a members file.
- Validator and tools: `new_collection`, `write_collection`, `read_collection`,
  `validate_collection` (each member validated as a record, under `members[<i>].record`),
  `redact_collection`, `member_sha256`, `add_event`, `iter_members`; `estimation validate`,
  `redact` and `digest` take collections.
- estrec: `write_collection()` (embedded or JSON Lines members; member hashes with the optional
  `openssl` package) and `to_estimation()` for a plain list of fits, which flattens
  `fixest_multi` elements. RFC 8785 canonical JSON in R, checked against the Python reference.
- estrec: fixest `feglm` and `fepois` fits, as `glm/0.1` and `inference/0.1` records: family
  and link, offset, deviance, McFadden pseudo R², AIC/BIC, dispersion, convergence, z tests
  without `df_t`, and fixest's perfect-fit removals split into `singletons` and `separated`
  (checked against the rows fixest kept). `fenegbin` and `femlm` still fail with a clear error.
- Profiles: `ppmlhdfe/0.1` uses `glm/0.1`'s names for the fixed-effect solver inside each IRLS
  step, as fixest `fepois` records do: `itolerance()` is `options.fixef_tolerance` (was
  `inner_tolerance`) and `e(ic2)` is `structures.numerics.fixef_iterations` (was
  `inner_iterations`).
- estrec: `meta.core_digest` on every record when `openssl` is installed (`digest = FALSE` to
  leave it out), equal to the Python reference's. Software purls follow each package's origin
  (`pkg:cran`, `pkg:github/...@<commit>#<subdir>` from remotes/pak metadata, else
  `pkg:generic`); estrec no longer claims to come from CRAN.

- Core: an optional top-level `tests` list (spec 4.8, `$defs/test`) for every hypothesis test
  about the model: the estimator's own, those asked for after the fit, and linear
  combinations. Each test has a `name`, a `statistic` or `p_value`, and optionally a
  `category`, `origin` (`estimation` or `postestimation`), the hypothesis (`text`, `terms`, and
  `R`, `q` for a linear test), the reference distribution and df, the vcov it used, and its
  `source`. `tests` is append-only: any tool may add tests to a record without writing a new
  one. It is outside the core digest. Profiles name tests by `category` and can expect one
  (`x-expected-tests`).
- Profiles: tests move from their own locations to `tests`: iv (`structures.first_stage` keeps
  only the R²s), linear-fe (`metrics.f_stat`, `f_stat_robust`, `f_fe`), glm and
  conditional-logit (`metrics.chi2`, `chi2_type`), did and csdid (`pretrend`), survival
  (`metrics.lr_test`, `structures.ph_test`), meta-analysis (Egger, Begg), sem (`chisq`,
  `chisq_baseline` and their df and p), mixed (`lr_vs_fixed`), causal-ml (grf calibration).
  `multiple-testing/0.1` accepts `p_value_adjusted` on tests. fixest's `kpr` is mapped to
  the Kleibergen-Paap rk Wald F (weak identification), valid only with a non-iid vcov and exact
  identification (checked against ivreg2).
- Validator: checks test ids, restriction shapes, and term and vcov references; warns on a
  missing expected test category. `estimation_format.add_test()` appends a test and logs it in
  `history`.

- Core: optional `parameters[*].scale` (`estimation`, `exponentiated`) and `measure`
  (`odds_ratio`, `hazard_ratio`, ...), so exponentiated estimates are labeled.
- Draft profiles for difference-in-differences: `did/0.1` (standard; csdid, R did, did2s,
  pyfixest did2s), and the tool profiles `did2s/0.1` and `csdid/0.1`, with example records
  and pages in `spec/profiles/`.
- Draft profiles for generalized linear models: `glm/0.1` (standard; Stata logit/probit/
  poisson/glm, ppmlhdfe, R glm, fixest feglm/fepois, statsmodels, pyfixest) and the tool
  profile `ppmlhdfe/0.1`, with example records and pages in `spec/profiles/`.
- Draft standard profile `conditional-logit/0.1` (Stata clogit and xtlogit fe,
  survival::clogit, statsmodels ConditionalLogit), with an example record and a page.
- Draft standard profile `mixed/0.1` (lme4, lmerTest, glmmTMB, Stata mixed and me*,
  statsmodels MixedLM, MixedModels.jl), with an example record and a page.
- Draft standard profile `choice/0.1` (mlogit, logitr, apollo, xlogit, Biogeme, Stata cm*
  and mixlogit), with MNL and mixed-logit example records and a page.
- Draft standard profiles `sem/0.1` (lavaan, semopy, Stata sem) and `mediation/0.1` (R
  mediation, lavaan :=, PROCESS, Stata estat teffects, pingouin, statsmodels Mediation),
  with example records and pages.
- Draft cross-cutting standard profiles `mi/0.1`, `survey/0.1`, `multiple-testing/0.1` and
  `resampling/0.1`, which combine with a model's own profile, with example records and pages.
- `mediation/0.1`: two-stage (IV) mediation (`instruments`, `instrumented`), the Aroian
  method and controlled direct effects; mappings for `mediate_tsls`, `ivmediate` and StataNow
  `mediate`.
- Draft standard profile `survival/0.1` (R survival and cmprsk, lifelines, scikit-survival,
  statsmodels PHReg, Stata stcox/streg/stcrreg), with Efron and Breslow Cox examples and a page.
- `mediation/0.1`: several predictors, `total_indirect`, and a mapping for `indirect_boot`.
- Draft tool profile `med2s/0.1` (two-stage DiD mediation), with an `extensions.med2s` block,
  a shape example and a page.
- Draft standard profile `meta-analysis/0.1` (metafor, meta, statsmodels, Stata meta), with an
  example record and a page.
- Draft standard profiles `predictive/0.1` (scikit-learn, XGBoost, ranger, tidymodels, mlr3)
  and `causal-ml/0.1` (DoubleML, EconML, grf), with example records and pages.
- Draft standard profiles `gam/0.1` (mgcv, pyGAM, statsmodels GLMGam) and `bayesian/0.1` (brms,
  rstanarm, Stan, PyMC/ArviZ, Stata bayes), with example records and pages.
- `mediation/0.1`: StataNow `mediate` and `ivmediate` mapped from their help files (pure
  indirect, total direct and potential-outcome-mean effects; interaction and treatment type;
  `ivmediate`'s two first-stage F statistics).
- Stata mappings checked against the help files for `glm`, `clogit`, `cmclogit`,
  `cmmixlogit`, `cmmprobit`, `mixed`, `stcox`, `streg` and `bayes`. `choice/0.1`: Stata stores
  the base alternative as `e(i_base)` (`cmmixlogit`: `e(base)`), not `e(basealt)`, and the
  integration defaults (Hammersley points, a sample-size-dependent count) are now mapped.
  `mixed/0.1`: `e(N_g)` and `e(g_*)` are matrices by level. `survival/0.1`: `streg`'s
  ancillary parameters and `e(frm2)`, and `stcox`/`streg` `e(cmd)` vs `e(cmd2)`.
- Second help-file pass (`logit`, `melogit`, `meglm`, `mi estimate`, `svy`, `svyset`, `sem`,
  `estat gof`, `bootstrap`, `meta summarize`, `stcrreg`, `stcox` postestimation, `bayesmh`,
  `bayesstats grubin`): `mi/0.1` maps RVI to `e(rvi_mi)`, not `e(riv_mi)`; Stata `bootstrap`
  seeds with `rseed()`; `estat phtest` per-term results are the `r(phtest)` matrix; `stcrreg` has no `ties()` option and always reports robust SEs; added
  `bayesmh` and `meta summarize` stored results. Documentation-only R mappings checked against
  source on GitHub (base R `glm` and `p.adjust`, rstanarm/rstan, cmprsk, ri2, caret, tidymodels,
  mlr3): rstanarm has no pathfinder, its `adapt_delta` default is 0.95, and caret's
  `trainControl()` defaults to 25 bootstrap resamples.
- Format `estimation/0.1` (draft) and the `inference/0.1`, `linear-fe/0.1`, `iv/0.1` and
  `dfeols/0.1` profiles, moved from the dfeols repository
  (https://github.com/jemather/dfeols, `src/dfeols/schema/` at a33a767) into their own
  repository. Schema `$id`s now point to `https://estimation-format.github.io/estimation/schema/`.
- `estimation-format` 0.1.0.dev0: the reference validator, writer and redactor, from
  `dfeols.estimation`. The built-in fallback checks cover the standard profiles only; tool
  profiles are checked through their schemas.
- `converters/`: worked converters from pyfixest, fixest (R) and reghdfe (Stata) to
  `linear-fe/0.1` records, with `tests/test_converters.py` comparing the tools on one panel.
- `linear-fe/0.1` (draft): `sigma` defined as sqrt(RSS / (N - K)), with pyfixest `_rmse`
  (sqrt(RSS / N)) recorded as `{value, definition}`; pyfixest has no residual df (`_dfd` is
  the Wald denominator df); reghdfe per-cluster counts are `e(N_clust#)`.
- `linear-fe/0.1` (draft): `metrics.n_singletons` is expected, not required (pyfixest and
  fixest don't store it). The validator now warns for a missing `x-expected` field of a
  claimed profile (also `iv/0.1` `structures.first_stage`); `expected_paths()` lists them.
- `write`/`prepare`: `redact_identifying` also takes a list of paths, so a tool can redact its
  own extension's fields whatever profiles the record claims.
