# Profile `glm/0.1`

Status: draft. Schema: [`schema/profiles/glm-0.1.json`](../../schema/profiles/glm-0.1.json).
Kind: standard. Builds on the core only (see "Why not `inference/0.1`" below).

Generalized linear models (logit, probit, Poisson, gamma, ...), with or without absorbed fixed
effects. Surveyed 2026-10-25: from source, ppmlhdfe 2.3.4 (sergiocorreia/ppmlhdfe @ b85665d),
fixest 0.14.2 `feglm`/`fepois` (lrberge/fixest @ 789f888) and pyfixest 0.60.0
`feglm`/`fepois`; R `glm` from source (wch/r-source, `stats/R/glm.R`); Stata `glm` and `logit` from their help files;
from their documentation, Stata `probit` and `poisson` and statsmodels 0.15 `GLM`/`Logit`/`Poisson`.

Tool profile: [`ppmlhdfe/0.1`](ppmlhdfe.md). Conditional (fixed-effects) logit — `clogit`,
`xtlogit, fe`, `fixest::feglm` is not this — and negative binomial dispersion models were not
surveyed.

## Requirements

- `meta.estimator.distribution` and `link` (and `family: "glm"`, recommended).
- `estimate`, `std_error` and `p_value` on every row that isn't dropped, except that ancillary
  rows (`component: "auxiliary"`, such as nbreg's `/lnalpha`) need no `p_value`: a writer
  records no test there that the tool doesn't report (Ted, 2026-11-07).
- `metrics.nobs`.
- A default vcov with `type` and `ssc.convention`.
- `structures.numerics.converged`: every surveyed tool stores it, and an unconverged GLM is a
  common source of discrepancies.

`metrics.log_lik` is **expected**. `metrics.deviance` is expected **when the tool reports
one**: GLM routines do (Stata `glm`, R `glm`, fixest, statsmodels `GLM`, ppmlhdfe, SAS
`GENMOD`); dedicated likelihood commands mostly don't (Stata `logit`, `probit`, `nbreg`,
statsmodels' discrete `Logit`/`Probit`/`Poisson`). Writers don't compute one, and a validator
can't tell whether the tool had one, so a missing deviance isn't flagged.

### Why not `inference/0.1`

This profile was written when `inference/0.1` required `metrics.df_residual`, which Stata's ML
commands (`logit`, `poisson`, ...) and ppmlhdfe don't post (they use z tests). Since 2026-11-07
`inference/0.1` lets a record leave out `df_residual` when its default vcov has no `df_t`, so
those records can claim `inference/0.1` as well, like R `glm`, fixest and statsmodels records.
`glm/0.1` still doesn't require it.

## Model

| Name | Stata | ppmlhdfe | R `glm` | fixest | statsmodels | pyfixest |
|---|---|---|---|---|---|---|
| `meta.estimator.distribution` | `glm` `e(varfunct)`; `logit`/`probit` binomial; `poisson` | poisson | `family$family` | `family` (fepois: poisson) | `model.family` | `_method` (`fepois`, `feglm-logit`, `feglm-probit`, `feglm-gaussian`) |
| `meta.estimator.link` | `glm` `e(linkt)` | log | `family$link` | `family$link` | `model.family.link` | from `_method` |
| `specification.offset` | `e(offset)` (`ln(x)` with `exposure()`) | `e(offset)` | `offset` | `offset` | `offset`, `exposure` | `offset` |
| `options.separation` | — | `e(separation)` | — | `fixef.rm` | — | `separation_check` |
| `options.tolerance` | `tolerance()` etc. | `tolerance()` 1e-8 | `control$epsilon` 1e-8 | `glm.tol` 1e-8 | `tol` 1e-8 | `iwls_tol` 1e-8 |
| `options.max_iterations` | `iterate()` | `maxiterations()` 10000 | `control$maxit` 25 | `glm.iter` 25 | `maxiter` 100 | `iwls_maxiter` 25 |
| `options.fixef_tolerance` | | `itolerance()` | | `fixef.tol` 1e-6 | | `fixef_tol` |
| `options.fixef_max_iterations` | | | | `fixef.iter` 10000 | | `fixef_maxiter` |

`specification.offset` is `{variable, exposure}` or `null`; `exposure: true` means the tool
took the log of the variable.

`options.tolerance` and `max_iterations` are the IRLS (or ML) iterations'. With absorbed fixed
effects, the solver that partials them out inside each iteration has its own settings,
`fixef_tolerance` and `fixef_max_iterations`, and `structures.numerics.fixef_iterations` counts
its iterations (ppmlhdfe `e(ic2)`, summed over the IRLS steps).

A quasi-likelihood family (R and fixest `quasipoisson`, `quasibinomial`) is recorded as its
base `distribution` with `meta.estimator.quasi: true`: the estimates are the base family's,
the dispersion is estimated (`metrics.dispersion`), the tests are t tests, and there is no
log-likelihood, so `log_lik` is absent.

## Metrics

| Name | Stata | ppmlhdfe | R `glm` | fixest | statsmodels | pyfixest |
|---|---|---|---|---|---|---|
| `log_lik` | `e(ll)` (`glm`: not stored with `irls`) | `e(ll)` | `logLik()` | `loglik` | `llf` | `_loglik` (fepois) |
| `log_lik_null` (constant only) | `e(ll_0)` | — | | `ll_null` | `llnull` | `_loglik_null` |
| `log_lik_fe_only` | | `e(ll_0)` | | `ll_fe_only` | | |
| `deviance` | `glm` `e(deviance)`; `poisson` `estat gof` `r(chi2_d)` (equal to `glm, family(poisson)`'s) | `e(deviance)` | `deviance` | `deviance` | `deviance` | `deviance` |
| `null_deviance`, `df_null` | | | `null.deviance`, `df.null` | | `null_deviance` | |
| `df_residual` | `glm` `e(df)` | `e(df)` | `df.residual` | `df.residual()` | `df_resid` | |
| `pseudo_r2` | `e(r2_p)` | `e(r2_p)` (vs FE-only) | | `fitstat(, "pr2")` | `pseudo_rsquared("mcf")` | `_pseudo_r2` |
| `aic`, `bic` | `glm` `e(aic)` (per obs.), `e(bic)` | | `aic` | `AIC()`, `BIC()` | `aic`, `bic` | |
| `dispersion` | `glm` `e(phi)` | | `summary()$dispersion` | `dispersion` | `scale` | |
| `pearson_chi2` | `glm` `e(deviance_p)`; `poisson` `estat gof` `r(chi2_p)` | | | | `pearson_chi2` | |
| `n_separated` | | `e(num_separated)` | | `obs_selection` / `fixef_removed` | | `n_separation_na` |
| `n_completely_determined` | `logit`/`probit` `e(N_cds)` + `e(N_cdf)` | | | | | |
| `n_singletons`, `nobs_full` | | `e(num_singletons)`, `e(N_full)` | | | | |

Two names differ in meaning across tools:

- **Null log-likelihood.** `log_lik_null` is the constant-only model. ppmlhdfe's `e(ll_0)` is
  the model with only the fixed effects, so it goes in `log_lik_fe_only`.
- **Pseudo R².** `pseudo_r2` is McFadden's 1 − ll / ll_null. ppmlhdfe's `e(r2_p)` uses the
  FE-only log-likelihood, and fixest's stored `pseudo_r2` element is the adjusted
  1 − (ll − k) / (ll_null − 1) (`fitstat(, "pr2")` is the unadjusted one). Record either as
  `{value, definition}`.

## `structures`

- `vcov`: `type` and `ssc.convention` required. Stata's ML robust and cluster vcovs use
  N/(N−1) and G/(G−1); ppmlhdfe uses reghdfe's asymptotic adjustment (N/(N−1) robust,
  G/(G−1) cluster) and turns `vce(unadjusted)` into robust; fixest and pyfixest follow their
  `ssc()` settings. `oim`, `opg`, `eim` join the core's vocabulary for `type`.
- `numerics`: `converged` (Stata `e(converged)`, R `converged`, fixest `convStatus`,
  statsmodels `converged`, pyfixest `_convergence`) and, when stored, `iterations` (Stata
  `e(ic)`, R `iter`, fixest `iterations`, statsmodels `fit_history["iteration"]`).
- `fixed_effects`: for GLMs with absorbed fixed effects, as in
  [`linear-fe/0.1`](linear-fe.md). Those records don't claim `linear-fe/0.1`, which is for
  linear models.

## Sample drops

Rows removed because the fixed effects fit them perfectly are `specification.sample.dropped`
`separated` (a level whose outcomes are all 0, or all 0 or 1 for binomial) and `singletons`
(other one-row levels), with `metrics.n_separated` and `n_singletons`. fixest's default
`fixef.rm = "perfect_fit"` removes both and reports one count; a writer that splits it counts a
one-row level at a bound as separated (estrec repeats the removal on the data and keeps the
split only when the rows left match the fit's).

## Examples

- [`schema/examples/glm-logit.estrec.json`](../../schema/examples/glm-logit.estrec.json):
  a real statsmodels logit on the Spector-Mazzeo data (claims `inference/0.1` and `glm/0.1`).
- [`schema/examples/ppmlhdfe.estrec.json`](../../schema/examples/ppmlhdfe.estrec.json):
  ppmlhdfe with two absorbed fixed effects (a shape example; see its `meta.notes`).
