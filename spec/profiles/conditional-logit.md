# Profile `conditional-logit/0.1`

Status: draft. Schema: [`schema/profiles/conditional-logit-0.1.json`](../../schema/profiles/conditional-logit-0.1.json).
Kind: standard. Builds on the core only.

Conditional (fixed-effects) logit: the likelihood conditional on the number of positive
outcomes in each group, so the group effects drop out and are never estimated. Surveyed
2026-10-25: from source, R `survival::clogit` 3.8-13 (therneau/survival @ b76de62; it is a
`coxph` fit) and statsmodels 0.15.0 `ConditionalLogit`; Stata `clogit` from its help file and
`xtlogit, fe` from its documentation.

Not for unconditional fixed-effects logit (fixest `feglm`, pyfixest `feglm`, `bife`), which
estimates the group effects and has the incidental-parameters bias: those records claim
[`glm/0.1`](glm.md). Choice-model front ends with the same likelihood (Stata `cmclogit`,
`asclogit`; R `mlogit`) were not surveyed.

## Requirements

- `specification.groups`: the grouping the likelihood conditions on.
- `specification.options.likelihood`: `exact`, or R's tied-event approximations `breslow`
  and `efron`.
- `specification.options.drop_uninformative`: whether all-0 and all-1 groups were dropped.
- `estimate`, `std_error` and `p_value` on every row that isn't dropped.
- `metrics.nobs`.
- A default vcov with `type` and `ssc.convention`.

`metrics.log_lik` and `structures.groups` are **expected**, and `metrics.n_groups` when the
tool reports one (Stata's `clogit` doesn't; Ted, 2026-11-07). Convergence
is vocabulary only (below).

### Two settings that change results without changing the model

- **Uninformative groups.** A group whose outcomes are all 0 or all 1 adds nothing to the
  conditional likelihood. Stata and statsmodels drop it (and its rows leave `nobs`); R keeps it
  in `n`. Same estimates, different `nobs`: `drop_uninformative` records which, and
  `n_dropped_uninformative` / `n_groups_dropped` how many.
- **Likelihood.** `survival::clogit` defaults to the exact likelihood, like Stata and
  statsmodels, but `method = "approximate"` (Breslow) or `"efron"` give different estimates
  when groups have several positive outcomes. Robust variances (`cluster()`) and weights
  aren't available with `"exact"` in R.

## Names

| Name | Stata `clogit` | Stata `xtlogit, fe` | `survival::clogit` | statsmodels |
|---|---|---|---|---|
| `specification.groups` | `group()`, `e(group)` | panel variable, `e(ivar)` | `strata()` term | `groups` |
| `options.likelihood` | exact | exact | `method` (`"exact"`) | exact |
| `options.drop_uninformative` | true | true | false | true (warning) |
| `options.optimizer` | `technique()` (`nr`) | `technique()` | Newton-Raphson | `fit(method=)` (`"BFGS"`) |
| `metrics.nobs` | `e(N)` | `e(N)` | `n` | `nobs` |
| `metrics.n_groups` | — | `e(N_g)` | strata (not stored) | `n_groups` |
| `metrics.n_events` | | | `nevent` | |
| `metrics.n_dropped_uninformative`, `n_groups_dropped` | `e(N_drop)`, `e(N_group_drop)` | `e(N_drop)`, `e(N_group_drop)` | 0 (kept) | warning text only |
| `metrics.log_lik` | `e(ll)` | `e(ll)` | `loglik[2]` | `llf` |
| `metrics.log_lik_null` (all coefficients 0) | `e(ll_0)` | `e(ll_0)` | `loglik[1]` | `loglike(zeros)` (not stored) |
| `metrics.pseudo_r2` | `e(r2_p)` | | | |
| `tests`: category `model`, `name` `likelihood_ratio`, `wald` or `score` | `e(chi2)`, `e(chi2type)` | `e(chi2)` | `summary()`: `logtest`, `waldtest`, `sctest` | |
| `structures.groups.size` | | `e(g_min)`, `e(g_avg)`, `e(g_max)` | | summary group sizes |
| `structures.groups.multiple_positive` | `e(multiple)` | | | |
| `structures.numerics.converged` | `e(converged)` | `e(converged)` | warning only | not kept |
| `structures.numerics.iterations` | `e(ic)` | `e(ic)` | `iter` (max `iter.max` 20) | |

statsmodels' `ConditionalLogit.fit` documents `mle_retvals`, but its `ConditionalResults` don't
keep it, so the convergence flag is lost; R's `coxph` only warns ("Ran out of iterations and did
not converge"). That's why convergence isn't required here, unlike [`glm/0.1`](glm.md).

## Example

[`schema/examples/conditional-logit.estrec.json`](../../schema/examples/conditional-logit.estrec.json):
a real statsmodels run on R's `infert` matched case-control data (83 strata, each with one case and one or two
controls). The estimates (spontaneous 1.986, induced 1.409) match `survival::clogit` on
the same data.
