# estrec (R)

Writes fitted models as estrec records: one JSON file per model, holding what was
estimated, what came out, and how and where it ran. Version 0.1 writes **fixest** fits:
`feols` (OLS and IV) and `feglm`/`fepois` (GLMs), with or without fixed effects, including
multiple estimations (`c(y1, y2)`, `csw()`, `split`, `fsplit`, `subset`). MIT.

```r
# install.packages("remotes")
remotes::install_github("estrec/estrec", subdir = "r")
```

```r
library(fixest)
library(estrec)

fit <- feols(y ~ x1 + x2 | firm + year, data, cluster = ~firm)
write_estimation(fit, "fit.estrec.json")

# Several vcovs in one record: the first is the default and gives the standard errors
write_estimation(fit, "fit.estrec.json", vcov = list(~firm, "hetero", ~firm + year))

# A multiple estimation writes one numbered file per model: fits-1.estrec.json, ...
fits <- feols(c(y1, y2) ~ csw(x1, x2) | firm, data, split = ~region)
write_estimation(fits, "fits.estrec.json")

rec <- to_estimation(fit)   # the record as a list
recs <- to_estimation(list(base = fit, full = fit2))   # a list of fits: a list of records

# Test results: run the test with the function you use, and record its result
rec <- add_test(rec, wald(fit, keep = "^counter::-([2-9]|1[0-9]|20):"), label = "pre-trends")
rec <- add_test(rec, marginaleffects::hypotheses(fit, "b1 + b2 * 0.25 = 0"))
rec <- add_test(rec, car::linearHypothesis(fit, "x1 = x2"))
rec <- to_estimation(fit, tests = list(wald(fit, keep = "^x")))   # or when writing the record
write_estimation(rec, "fit.estrec.json")
```

Tests go in the record's `tests` list: fixest's joint Wald test of the coefficients and, for
IV, the first-stage and identification tests (`origin: "estimation"`), plus each test result you
add (`origin: "postestimation"`). estrec doesn't run tests; it records the statistic, df,
p-value, vcov and hypothesis that the result carries, and the call that made it.
`fixest::wald()` doesn't return which terms it tested, so estrec reads them from the call's
`keep`/`drop`. Adding a test doesn't change the results, so it keeps the core digest valid.

`as_estimation_test()` reads a result into test objects. It has methods for `wald()`,
`marginaleffects::hypotheses()` and other broom-style data frames, `anova` comparisons
(`anova(m1, m2)`, `car::linearHypothesis()`, `lmtest::waldtest()`/`lrtest()`) and `htest`
(`t.test()` and friends). To record results of another kind, write a method for their class:

```r
as_estimation_test.my_test <- function(x, ...)
  list(list(name = "wald", statistic = x$W, distribution = "chi2", df = x$k, p_value = x$p))
```

## PROCESS

`record_process()` records a run of PROCESS (Andrew F. Hayes's macro for mediation,
moderation and conditional process models). estrec doesn't include PROCESS: get it from
https://www.afhayes.com/download.html and `source()` it.

```r
source("process.R")
rec <- record_process(process(data = d, y = "y", x = "x1", m = "x2", w = "z", model = 7,
                              seed = 20261114))
write_estimation(rec, "model7.estrec.json")
```

PROCESS prints as usual. The call runs with `save = 2`, so the record's numbers come from
PROCESS's matrix at full precision and its labels from the printed output; `save = 2` also
probes every interaction (as `intprobe = 1`). The record is the one estrec for SPSS writes for
the same model: each equation's coefficients (`response`), the direct, indirect, total and
conditional effects (`indirect: x1 -> x2 -> y, at z = 0.028`; the exact value in
`mediation.moderator_value`) and indices of moderated mediation as `mediation` rows, the model
tests, each equation's R² and MSE in `structures.equations`, and the bootstrap settings.
Checked with PROCESS 5.1.1; another version gets a `process_version_unchecked` warning.

## Collections

`write_collection()` writes several records as one `estrec-collection` file (spec section
11): a paper's results with where each appears, a session or replication with its timeline,
or a batch of runs. The records are embedded whole and never changed; the locators stay in the
collection.

```r
write_collection(list(baseline = f1, full = f2), "table2.estrec-collection.json",
                 kind = "paper",
                 locators = list("Table 2, col. (1)", list(table = "2", column = "2")),
                 publication = list(citation = list(type = "article-journal", title = "...",
                                                    DOI = "10.1257/...")))
write_collection(fits, "batch.estrec-collection.json", kind = "batch",
                 members = "jsonl")   # records in batch.members.jsonl, one per line
```

Labels default to the list's names. With the `openssl` package installed, each member carries
the SHA-256 of its record's RFC 8785 canonical JSON, which shows which version of the record the
collection holds; without it the hashes are left out (they are optional).

## Reading records and making tables

`read_estimation()` reads a record, or every record in a folder; `read_collection()` reads a
collection's members (embedded or in a members file). Records print a quick view, and have
`tidy()` and `glance()` methods, so modelsummary and other broom-based table packages take them
as they take fitted models, whatever wrote the record (estrec, pyfixest, Stata, dfeols).

```r
r <- read_estimation("fit.estrec.json")
r                                        # estimates, metrics, FEs, vcov, messages
tab <- read_collection("table2.estrec-collection.json")
modelsummary::modelsummary(tab, stars = TRUE, coef_rename = c(price_log = "log(price)"))
generics::tidy(r, vcov = "iid")          # another vcov in the record: SEs, t, p, CIs recomputed
generics::tidy(r, component = "first_stage")
```

`glance()` gives the metrics a table shows (broom names: `r.squared`, `r2.within`, `AIC`,
`rmse`, ...; `metrics = "all"` for every one), `vcov.type` (`"by: firm"`) and an
`FE: <name>` column per fixed effect. modelsummary needs **broom** installed to use these
methods. A modelsummary table from records matches the one from the fixest fits they were
written from, coefficients, stars and fit rows alike, except that a Poisson or logit fit's
McFadden pseudo R2 shows as "R2 Pseudo" (fixest puts it in the R2 rows). Records read back in can be written again (`write_estimation`,
`write_collection`) unchanged.

### Table specs

`render_table()` renders a table spec (`spec/table.md`), such as the
[record viewer](https://estrec.org/viewer/) saves: columns by
record, each with its own vcov if wanted, rows relabelled, and statistics rows. It finds the
records in the spec's sources or in `records`, and passes the table to modelsummary, so any of
modelsummary's outputs work:

```r
render_table("table2.estrec-table.json", output = "latex")
render_table(spec, records = read_collection("table2.estrec-collection.json"))
```

`new_table()` makes a spec with one column per record (as Python's `estrec.table.new_table()`),
and `write_table()` writes a spec, filling in `schema` and `meta` when they're missing and
keeping one-entry fields such as `head` or a row's `terms` as JSON arrays:

```r
recs <- list(Base = to_estimation(fit1), Full = to_estimation(fit2))
spec <- new_table(recs, sources = list(list(id = "r", path = "records")),
                  head = c("label", "number"))   # show the headers (the list's names)
write_table(spec, "table2.estrec-table.json")
```

## What a record holds

| Section | From fixest |
|---|---|
| `parameters` | estimates, SEs, t, p, CIs (`conf_level`), canonical term names; collinear terms marked `dropped` |
| `metrics` | `nobs`, `n_singletons`, `df_residual`, R², within R², sigma, RSS/TSS, log-likelihoods; for GLMs deviance, McFadden pseudo R², AIC/BIC, dispersion, `n_separated` |
| `specification` | call, formula, terms, fixed effects, clusters, weights, offset, endogenous/instruments; `sample`: rows in, the `subset`/`split` restriction, and rows dropped by reason (missing, non-finite, zero weights, singletons, separated); options (`fixef.rm`, separation, tolerances) |
| `structures` | each vcov with its type, clusters and cluster counts, df for t tests and the small-sample correction (`ssc`); fixed-effect level counts; convergence |
| `tests` | fixest's joint Wald test; IV first-stage F and Wald F, Cragg-Donald, Kleibergen-Paap, Wu-Hausman and Sargan; tests you add |
| `provenance` | fixest, R and loaded package versions; OS, BLAS/LAPACK, threads; user, host and command line (`identifying = FALSE` leaves these out) |

Records claim `inference/0.1`, plus `linear-fe/0.1` with fixed effects and `iv/0.1` for IV.
`feglm` and `fepois` records claim `inference/0.1` and `glm/0.1` (with any fixed effects in
`structures.fixed_effects`). Poisson and binomial fits use z tests, so their vcovs have no
`df_t`; a quasi family is recorded as its base distribution with `quasi: true`.

**GLM drops.** With `fixef.rm = "perfect_fit"` (the default) fixest removes singletons and
fixed-effect levels whose outcomes are all 0 (or all 0 or 1 for binomial) in one count. estrec
repeats that removal on the data to split it into `singletons` and `separated` (a one-row
level at a bound counts as separated), and keeps the split only if the rows left match the
fit's; otherwise they are recorded as `other`.

**Sample drops need the data.** fixest stores only which rows it removed, not why. To split
the drops by reason, estrec looks at the data the model was fitted on: it takes `data =`, or
else finds the data the way fixest's own methods do (in the fit's call environment). When the
data can't be found, for example after the fit was saved with `saveRDS` and reloaded, the drops
are recorded as `other` and the record carries a warning. Pass `data =` to fix that.

## Checking and sharing records

The Python reference tools validate, digest and redact records:

```bash
pip install "estrec[jsonschema] @ git+https://github.com/estrec/estrec"
estrec validate fit.estrec.json
estrec redact fit.estrec.json -o shareable.estrec.json   # drops user, host, argv
estrec digest fit.estrec.json                                  # checks the core digest
```

**Core digest.** With the `openssl` package installed, every record carries
`meta.core_digest` (spec 7.2): the SHA-256 of the RFC 8785 form of `meta`, `specification`,
`metrics`, `parameters` and `structures`. Editing a result breaks it; adding a test, a
publication or a note in `history` doesn't. `digest = FALSE` leaves it out.

**Software.** Each package's purl follows where it was installed from: `pkg:cran/...` for
CRAN, `pkg:github/<owner>/<repo>@<commit>` (with `#<subdir>`) for packages installed by
`remotes`/`pak` from GitHub, `pkg:generic/...` otherwise. A local install of estrec is
`pkg:github/estrec/estrec#r` with `source: "local"`.

## Not yet

- `fenegbin`/`femlm`, `lm`/`glm` and other classes through `insight`.
- The `car`, `lmtest` and `marginaleffects` methods are written to those packages' documented
  output but not yet checked against them (they aren't installed where estrec was built).
- Tests: `tests/test-fixest.R`, `tests/test-collection.R`, `tests/test-read.R` and `tests/test-table.R` (base R). They validate every
  record and collection when the `estrec` CLI is on `PATH` or `ESTREC_VALIDATOR` names it;
  with `ESTREC_PYTHON` (a Python with `estrec`), the collection test also checks that
  estrec's canonical JSON equals the reference implementation's.
