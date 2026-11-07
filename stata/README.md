# estrec for Stata

`estrec write` saves the results of a Stata estimation command as an estrec record (an estimation record).
Run it right after the command:

```stata
net install estrec, from("https://raw.githubusercontent.com/estrec/estrec/main/stata") replace
sysuse auto, clear
regress price mpg weight, vce(cluster rep78)
estrec write using "price.estrec.json", replace
```

Or, from a clone: `net install estrec, from("path/to/estrec/stata") replace`.

| Command | Profiles claimed (level 4) | Notes |
|---|---|---|
| `regress` | inference | the model-based vcov is kept beside a robust or cluster one |
| `areg` | inference, linear-fe | K counts the absorbed levels even when nested in the clusters |
| `xtreg, fe` | inference, linear-fe | the panel variable is the fixed effect; `xtset` in `specification.state` |
| `xtreg, re` | inference | z tests, so no `df_residual` and `df_t` null |
| `reghdfe` | inference, linear-fe | same record as `converters/reghdfe` |
| `ivregress` | inference, iv | without `small`, z tests (no `df_residual`); runs `estat firststage`, `overid` and `endogenous` (`noestat` skips them) |
| `ivreg2` | inference, iv | as `ivregress` without `small`; first-stage tests with `first`/`ffirst`, C test with `endog()` |
| `ivreghdfe` | inference, iv, linear-fe | |
| `logit`, `logistic`, `probit`, `poisson`, `nbreg` | inference, glm | z tests (no `df_residual`). After `poisson`, `estat gof`'s deviance and Pearson goodness-of-fit (the deviance equals `glm`'s); after `logit`, `logistic`, `probit`, its Pearson test over covariate patterns; `nbreg` reports no deviance |
| `glm` | inference, glm | `glm, irls` stores no convergence flag, so only inference |
| `ppmlhdfe` | inference, glm, ppmlhdfe | written from the profile's survey of the source; not yet run (ppmlhdfe isn't installed here) |
| `clogit` | inference, conditional-logit | `vce(robust)` is clogit's cluster-robust vcov on the groups (it equals `vce(cluster` *group*`)`), recorded as CRV1 with no cluster count, since Stata posts none; clogit doesn't post the number of groups |
| `stcox` | inference, survival | ties from `e(ties)`; runs `estat phtest, detail` (global and per term, against analysis time) |
| `streg` | inference, survival | distribution from `e(cmd)`, metric from `e(frm2)`; shape or scale as posted (`e(aux_p)`, `e(gamma)`, `e(sigma)`, `e(kappa)`) |
| `mixed` | mixed | variance components as in `e(b)` (log SDs, atanh correlations, `mixed, estmetric`), with the tests and intervals Stata's table shows: none for a log SD; with `dfmethod()`, per-row `df` from `e(df)`, and under Kenward-Roger the default vcov is `e(V_df)` (`e(V)` kept beside it) |
| `melogit`, `mepoisson`, ... (`meglm`) | mixed | variances and covariances as in `e(b)`, with Stata's interval and no test; `integration`, `n_quadrature` |
| `svy:` | inference, survey | design from `e(strata#)`, `e(su#)`, `e(fpc#)`, `e(singleunit)`, `e(subpop)`; t tests on the design df; the model F is Stata's adjusted F(df_m, df_r − df_m + 1); no model profile |
| `bootstrap:`, `vce(bootstrap)` | the command's, plus resampling | the default vcov is the bootstrap one (as Stata's table), `e(V_modelbased)` beside it; each row's `resampling` has the bootstrap SE, mean, bias, replications and the normal, percentile and bias-corrected intervals |
| `mi estimate:` | inference (mi with `imputation()`) | `e(b_mi)`, `e(V_mi)`; each row's t test on its own df (`e(df_mi)`) and `mi` (W, B, RVI, FMI, df, relative efficiency); `df_t` null; no model profile |
| anything else with `e(b)`, `e(V)` | none | core fields only |

Tested with Stata 18 MP, reghdfe 6.13.1, ivreg2 4.1.12 and ivreghdfe 1.1.4
(`tests/test_stata.py`: each command at every disclosure level validates with no warnings
and reproduces Stata's results table, including where it shows no test; two warnings remain, for
fields a profile expects that Stata doesn't report: clogit's number of groups and mixed's
singular-fit flag). estrec records what Stata reports, under the
record's name for it, and does not compute statistics of its own: `nobs` is `e(N)`, which
with frequency weights is the sum of the weights, as Stata counts it.

## Small-sample corrections

Recorded in `structures.vcov[*].ssc`, checked against each other in Stata 18:

| Command | iid | robust | cluster |
|---|---|---|---|
| `regress`, `ivregress, small`, `ivreg2, small` | s² = RSS/(N−K) | HC1, N/(N−K) | (N−1)/(N−K) · G/(G−1) |
| `areg` | K = rank + df_a | same | same, absorbed levels counted even when nested |
| `xtreg, fe` | K = rank + df_a | (cluster on the panel) | K = rank |
| `reghdfe`, `ivreghdfe` | K = df_m + df_a | same | same (nested levels not counted) |
| `ivregress`, `ivreg2` (no `small`) | s² = RSS/N | HC0, none | no factor |
| ML (`logit`, `poisson`, `glm`, ...) | none (OIM) | N/(N−1) | G/(G−1) |
| `stcox` | none (OIM) | N/(N−1): R's `coxph(robust = TRUE)` times N/(N−1), checked on the cancer data | G/(G−1) |
| `clogit`, `streg` | none (OIM) | N/(N−1) (`clogit`: clustered on the groups) | G/(G−1) |
| `ppmlhdfe` | | N/(N−1) | G/(G−1) |

The `clogit`, `streg` and `ppmlhdfe` factors are Stata's ML convention (and ppmlhdfe's, per its
profile), not checked here against another tool. `mixed` and `me*` record a formula only for
OIM.
