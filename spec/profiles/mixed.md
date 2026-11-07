# Profile `mixed/0.1`

Status: draft. Schema: [`schema/profiles/mixed-0.1.json`](../../schema/profiles/mixed-0.1.json).
Kind: standard. Builds on the core only.

Linear and generalized linear mixed (multilevel) models. Surveyed 2026-10-25: from source,
lme4 2.1-1 (lme4/lme4 @ 808a76d), lmerTest 3.2-1 (@ 282b9e9), glmmTMB 1.1.15.9000
(@ 1db3b46), MixedModels.jl (@ 492680d) and statsmodels 0.15.0 `MixedLM`; from their
documentation, Stata `mepoisson`; Stata `mixed`, `melogit` and `meglm` from their help files. nlme, brms and
Bayesian fits were not surveyed.

## Requirements

- `meta.estimator.method`: `reml`, `ml`, `laplace`, `agq`, `pql`, `variational`. Always
  recorded, because the defaults differ (below).
- `specification.random_effects`: the random-effect terms as specified,
  `[{group, terms, covariance, nested_in, text}]`.
- Fixed-effect rows: `estimate` and `std_error`. p-values are optional: lme4 reports none.
- Variance-component rows (`component: "random"`): `estimate` and a `vc` object, below.
- `metrics.nobs`.
- `structures.random_effects`: one `{kind: "object", group, levels}` per grouping factor.
- A default vcov of the fixed effects with `type`.
- `structures.numerics.converged`.

`metrics.log_lik` is **expected**, and `structures.numerics.singular` when the tool reports it
(Stata doesn't; Ted, 2026-11-07). GLMMs add
`meta.estimator.distribution` and `link` as in [`glm/0.1`](glm.md).

## The defaults that make tools disagree

| Tool | Default criterion | Optimizer | Fixed-effect tests |
|---|---|---|---|
| `lme4::lmer` | REML | `nloptwrap` | t values, no p-values |
| `lmerTest::lmer` | REML | as lme4 | Satterthwaite df (`ddf`: `"Kenward-Roger"`, `"lme4"`) |
| `lme4::glmer` | Laplace (`nAGQ = 1`) | `bobyqa`, then `Nelder_Mead` | z |
| glmmTMB | ML (`REML = FALSE`) | `nlminb` | z |
| Stata `mixed` | **ML** (`reml` option); `e(method)` | `technique()` (`nr`), after 20 EM iterations | z; `dfmethod()` for small-sample df (Satterthwaite and Kenward-Roger need REML) |
| Stata `me*` | adaptive quadrature, `intpoints(7)`; `e(intmethod)`, `e(n_quad)` | | z |
| statsmodels `MixedLM` | REML | `fit(method=)` | z |
| MixedModels.jl | **ML** (`REML = false`) | `:LN_NEWUOA` | z |

Stata's `me*` commands store `e(cmd)` as `meglm` (`melogit`) or `gsem` (`meglm`); `e(cmd2)` names
the command typed.

The same model in `lmer` and Stata `mixed` gives different variance components unless one of
them is told to switch, which is why `method` is required. `specification.options` records
`optimizer`, `n_quadrature` and `df_method` (`satterthwaite`, `kenward_roger`, `residual`,
`containment`, `between_within`, `none`); per-row df go in `parameters[*].df`.

## Variance components

Each variance, SD, covariance or correlation is a parameter row with `component: "random"`,
`group` (the grouping factor, `"Residual"` for the residual) and
`vc: {group, terms, type}`. `terms` has one entry for a variance or SD and two for a
covariance or correlation. `type` names the scale the estimate is on, as the tool reports it:

| Tool | Reports | `vc.type` |
|---|---|---|
| lme4, glmmTMB (`VarCorr`) | SDs and correlations | `sd`, `cor` |
| Stata `mixed` `e(b)` | log SDs and atanh correlations (names such as `lns1_1_1`, `atr1_1_1_2`, `lnsig_e`; the help file confirms the metric, not the names) | `log_sd`, `atanh_cor` |
| Stata `mixed` output (default `variance`; `stddeviations`) | variances and covariances, or SDs and correlations | `var`, `cov` or `sd`, `cor` |
| statsmodels summary / `cov_re`, `scale` | variances and covariances | `var`, `cov` |
| MixedModels.jl `VarCorr` | SDs and correlations | `sd`, `cor` |

statsmodels' `params` hold the random-effect covariances divided by the residual variance;
writers use `cov_re` and `scale` (what the summary prints), not `params`. Standard errors of
variance components are optional; lme4 gives none.

Per-level predictions (BLUPs, conditional modes) are not parameters: they go in an
attachment (core 4.4).

## Other names

| Name | lme4 | glmmTMB | Stata | statsmodels | MixedModels.jl |
|---|---|---|---|---|---|
| `metrics.nobs` | `nobs()` | `nobs()` | `e(N)` | `nobs` | `nobs()` |
| `metrics.log_lik` | `logLik()` (REML when `isREML`) | `logLik()` | `e(ll)` | `llf` | `loglikelihood()` |
| `metrics.reml_criterion` | `REMLcrit()` | | | −2 `llf` | |
| `metrics.sigma` | `sigma()` | `sigma()` | `exp(lnsig_e)` | `sqrt(scale)` | `sdest()` |
| `metrics.aic`, `bic` | `AIC()`, `BIC()` | `AIC()`, `BIC()` | `estat ic` | `aic`, `bic` (NaN under REML) | `aic()`, `bic()` |
| test `random_effects` (`likelihood_ratio`, on the boundary) | | | `e(chi2_c)`, `e(p_c)` | | |
| `random_effects[].levels` | `ngrps()` | `ngrps()` | `e(N_g)` (matrix by level) | `n_groups` | levels per term |
| `random_effects[].size` | | | `e(g_min)`, `e(g_avg)`, `e(g_max)` (matrices) | group sizes | |
| `numerics.converged` | `optinfo$conv$opt == 0` and no convergence messages | `convergence == 0` and `sdr$pdHess` | `e(converged)` | `converged` | `optsum.returnvalue` |
| `numerics.singular` | `isSingular()` | (inspect `VarCorr`) | | | `issingular()` |
| `numerics.warnings` | `optinfo$conv$lme4$messages` | | | | |

lme4's `deviance()` of a REML fit is the ML deviance at the REML estimates; record it as
`{value, definition}` or use `reml_criterion`. lme4 reports a singular fit as a message, not a
warning, so `converged` can be true while `singular` is true.

## Example

[`schema/examples/mixed.estrec.json`](../../schema/examples/mixed.estrec.json): a real
statsmodels REML fit of `Reaction ~ Days` with a random intercept and slope by `Subject` on
lme4's `sleepstudy` data. It matches `lmer(Reaction ~ Days + (Days | Subject), sleepstudy)`.
