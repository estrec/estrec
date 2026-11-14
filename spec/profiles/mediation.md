# Profile `mediation/0.1`

Status: draft. Schema: [`schema/profiles/mediation-0.1.json`](../../schema/profiles/mediation-0.1.json).
Kind: standard. Builds on the core only.

Mediation analyses, whether computed from two regressions, from two-stage (instrumental-
variables) regressions, or inside an SEM. Surveyed 2026-10-25: from source, R mediation 4.5.1
(kosukeimai/mediation @ 44e1146; `mediate` and `mediate_tsls`), lavaan (defined parameters,
`:=`), pingouin 0.7.0 `mediation_analysis` and statsmodels 0.15 `Mediation`; PROCESS, Stata
`sem` / `estat teffects` from documentation; StataNow `mediate` (1.1.1) and Stata `ivmediate`
(1.0.1; Dippel, Ferrara and Heblich) from their help files. The same layout
fits other bootstrap mediation tools (`medsem`, `indirect_boot`): a writer fills
`specification.mediation` and tags each effect row.

An SEM-based record (lavaan `:=`, Stata `sem`) claims [`sem/0.1`](sem.md) too.

## Requirements

- `specification.mediation`: `treatment`, `mediators`, `outcome`, and `inference` with its
  `method`.
- `metrics.nobs`.
- At least one row whose `mediation.effect` is an indirect effect (`indirect` or an `acme_*`).
- Every row with a `mediation` object has `estimate` and either `std_error` or
  `conf_low`/`conf_high`. R mediation reports intervals and p-values but no standard errors.

No vcov is required: bootstrap tools often report none.

## `specification.mediation`

| Name | R mediation | pingouin | statsmodels | PROCESS | lavaan / Stata sem |
|---|---|---|---|---|---|
| `treatment` | `treat` | `x` | `exposure` | `x=` | in the model |
| `mediators` | `mediator` | `m` (one or several) | `mediator` | `m=` | in the model |
| `outcome` | from `model.y` | `y` | `outcome_model` | `y=` | in the model |
| `covariates` | terms in both models | `covar` | in the models | `cov=` | in the model |
| `moderators` | | | | `w=`, `z=` | |
| `process_model` | | | | `model=` (4 = simple) | |
| `treat_value`, `control_value` | `treat.value` (1), `control.value` (0) | | | | |

`structure` is `simple`, `parallel`, `serial` or `moderated`; `models` lists how the mediator
and outcome models were fit, or is `"sem"`.

### `inference`: where the defaults differ most

| | R mediation | statsmodels | pingouin | lavaan | PROCESS | Stata `estat teffects` |
|---|---|---|---|---|---|---|
| `method` | quasi-Bayesian (`boot = FALSE`) | `"parametric"` (quasi-Bayesian) | bootstrap | delta (`se = "standard"`), or bootstrap | bootstrap | delta |
| `reps` | `sims = 1000` | `n_rep = 1000` | `n_boot = 500` | `bootstrap = 1000` | 5000 | |
| `ci_type` | `"perc"` (`"bca"`) | percentile | `bc` (bias-corrected, not accelerated) | `"perc"` in `parameterEstimates()` | percentile (v3+) | normal |
| `seed` | | `rng` | `seed = None` | | `seed=` | |

The same indirect effect gets different intervals (and different "significance") from a
Sobel/delta test, a percentile bootstrap, a bias-corrected bootstrap and a quasi-Bayesian
simulation, so `method`, `reps`, `ci_type` and `seed` are what a reader needs to compare two
results. `conf_low`/`conf_high` on effect rows are the intervals the method produced, not
estimate ± z·SE.

## Two-stage (IV) mediation

Two tools instrument part of the mediation chain; they record `instruments` and
`instrumented`:

| | `mediate_tsls` (R mediation) | `ivmediate` (Stata) |
|---|---|---|
| `instrumented` | `mediator`: the outcome model uses the mediator's first-stage fitted values | `treatment` |
| `instruments` | regressors of `model.m` that are not in `model.y` | `instrument()` |
| `models[].estimator` | `ols` (mediator), `tsls` (outcome) | three IV regressions: Y on T, M on T, Y on M given T, each instrumented with Z |
| `inference.method` | `aroian` (Aroian 1947 product SE; default) or `bootstrap` (`boot = TRUE`, `sims`) | `analytic`; vcov `type` from `vce()`: unadjusted (default), robust, cluster |
| Effects | `d0` = `d1` (indirect), `z0` = `z1` (direct), `tau.coef`, `n0`, each with an SE | total, direct and indirect in `e(b)`/`e(V)`; `e(mepct)` = indirect / total × 100, recorded as a `prop_mediated` row (divided by 100) |
| First stage | — | `e(fstat1)` (T on Z) and `e(fstat2)` (M on Z given T): Kleibergen-Paap F under `robust` or `cluster`. Recorded in `structures.first_stage.per_endogenous` with `endogenous` T and M |
| Other | | one instrument only; `absorb()` absorbs one fixed effect; controls are partialled out and not reported |

`mediate_tsls` always computes its analytic SEs with `sandwich::vcovCL`; with `cluster = NULL`
each row is its own cluster (an HC1-type variance), so `robustSE` has no effect. When a tool
reports first-stage diagnostics, they go in `structures.first_stage` as in [`iv/0.1`](iv.md).

### StataNow `mediate`

`mediate (ovar …, omodel) (mvar …, mmodel) (tvar)` estimates potential-outcome effects with one
mediator (two with `mediate multiple`, not mapped here):

| Record | `mediate` |
|---|---|
| `treatment`, `mediators`, `outcome` | `e(tvar)`, `e(mvar)`, `e(depvar)` |
| `models[].estimator` | `e(omodel)`, `e(mmodel)`: `linear` (default), `expmean`, `logit`, `probit`, `poisson` |
| `treatment_type`, `control_value` | `e(tvartype)` (`binary`, `multivalued`, `continuous`; `continuous()` gives the evaluation points, the first the control), `e(control)` |
| `interaction` | `e(interact)`: the treatment-mediator interaction is included unless `nointeraction` |
| Effect rows | `nie` → `indirect`, `nde` → `direct`, `te` → `total` (the default set); `pnie` → `pure_indirect`, `tnde` → `total_direct`, `pomeans` → `potential_outcome_mean`. `aite`, `adte`, `ate`, `aitec`, `adtet` are ATE-terminology synonyms (`ateterms`) |
| `inference` | analytic by default; `vce(robust)`, `vce(cluster)`, `vce(bootstrap)`, `vce(jackknife)`; `nose` suppresses SEs |
| Convergence | `e(converged)` (optimizer: `conv_maxiter()` 300, `conv_ptol()` 1e-6, `conv_vtol()` 1e-7) |

## Effect rows: `parameters[*].mediation`

`{effect, mediator, path, moderator_value}`:

| `effect` | Meaning | R mediation | statsmodels | pingouin |
|---|---|---|---|---|
| `a`, `b` | X → M, M → Y paths | (in the models) | | `M ~ X`, `Y ~ M` |
| `indirect` | a·b | | | `Indirect` |
| `total_indirect` | sum of a predictor's indirect effects over mediators | | | |
| `acme_control`, `acme_treated`, `acme_average` | average causal mediation effects | `d0`, `d1`, `d.avg` | `ACME (control)`, ... | |
| `controlled_direct` | direct effect with the mediator fixed | | | |
| `pure_indirect`, `total_direct` | Pearl's pure natural indirect and total natural direct effects | | | |
| `potential_outcome_mean` | E[Y(t, M(t'))] | | | |
| `direct`, `ade_*` | direct effect | `z0`, `z1`, `z.avg` | `ADE (...)` | `Direct` |
| `total` | total effect | `tau.coef` | `Total effect` | `Total` |
| `prop_mediated`, `prop_mediated_*` | share mediated | `n0`, `n1`, `n.avg` | `Prop. mediated (...)` | |
| `index_moderated_mediation`, `contrast` | PROCESS indices and pairwise contrasts | | | |

`mediator` names which mediator a specific indirect effect goes through; `path` lists a serial
path in order; `moderator_value` marks a conditional indirect effect.

## Equations

When the effects come from regressions the writer can see (PROCESS, path models), each
equation's coefficients are `parameters` rows with `response` (the mediator or outcome it
predicts; PROCESS's total-effect model with `component: "total_effect_model"`), its F or
likelihood-ratio test is a `model` test with the same `response`, and its fit statistics
(PROCESS's Model Summary: `r2`, `mse`, `df_residual`; for a dichotomous outcome `deviance`
(-2LL), `pseudo_r2` (McFadden), `cox_snell_r2`, `nagelkerke_r2`) are in
`structures.equations` (spec/estrec.md 4.5). A table then shows a column per equation and one
of the effects (spec/table.md 3).

## `indirect_boot` (Stata)

`indirect_boot` 1.0.1 (Matherly) bootstraps the effects of a parallel-mediation path model fit
with `sem`, in the layout of PROCESS's parallel models. It reads the model from `e(b)`: a
variable that is only a dependent variable is the outcome, one that is only a predictor is an
exogenous predictor (minus `controls()`), and one that is both is a mediator. Serial models are
refused. A record of an `indirect_boot` run:

| Record | `indirect_boot` |
|---|---|
| `specification.mediation.treatment` | the inferred predictors (a list when there are several) |
| `mediators`, `outcome`, `covariates` | the inferred mediators and outcome; `controls()` |
| `structure` | `parallel` |
| `models` | `"sem"`, with the `sem` command line (`e(cmdline)`) in `specification.call` |
| `inference` | `method: "bootstrap"`, `reps` (`reps()`, 1000), `seed` (`seed()`, **12345**), `ci_type` (`cis()`, **bca**; `normal`, `percentile`, `bc`) |
| Rows | `r(ind_X_M)` → `{effect: "indirect", treatment: X, mediator: M}`; `r(tot_ind_X)` → `{effect: "total_indirect", treatment: X}`; `r(direct_X)` → `{effect: "direct", treatment: X}` |
| `estimate`, `std_error` | `_b` and the bootstrap SE of each statistic |
| `conf_low`, `conf_high` | from `estat bootstrap`, of the type `ci_type` names |
| `metrics.nobs` | the `sem` sample |

Two defaults are worth recording explicitly: the seed is fixed at 12345 unless set, so two
default runs give identical draws, and the default interval is BCa, where PROCESS defaults to
percentile. The underlying `sem` fit can be written as its own `sem/0.1` record and linked with
`meta.parent`.

Two-stage DiD mediation with `med2s` has its own tool profile, [`med2s/0.1`](med2s.md).

## Example

[`schema/examples/mediation.estrec.json`](../../schema/examples/mediation.estrec.json):
a real pingouin run on the JOBS II data from R's mediation package (treatment → job-search
self-efficacy → depression), no covariates, 5000 bias-corrected bootstrap replications.
