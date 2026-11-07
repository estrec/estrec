# Profile `resampling/0.1`

Status: draft. Schema: [`schema/profiles/resampling-0.1.json`](../../schema/profiles/resampling-0.1.json).
Kind: standard. Builds on the core only.

Inference by resampling: wild (cluster) bootstrap, pairs and cluster bootstrap, jackknife,
permutation and randomization inference. Surveyed 2026-10-25: from source, Stata `boottest`
(droodman/boottest @ ab5e99a), R fwildclusterboot 0.14.3 and Python wildboottest 0.3.2 (as
called by pyfixest); R ri2 0.5.0 (cran/ri2; `conduct_ri()` defaults to 1,000 simulations, two-tailed);
Stata's `bootstrap` prefix from its help file; `jackknife` and `ritest` from documentation.

The record also claims the model's own profile. The core columns (`std_error`, `p_value`,
`conf_low`, `conf_high`) are computed from the default vcov, as everywhere (core 4.4). When the
resampling is added after the fit (boottest, fwildclusterboot), that is the analytic vcov and
the resampled results go in each row's `resampling` object, so both can be compared. When the
estimator's own variance is resampled (Stata's `bootstrap` prefix and `vce(bootstrap)`), the
tool reports the resampled results, so the default vcov is the resampling one, the analytic
vcov (Stata's `e(V_modelbased)`) is kept as a non-default vcov, and `resampling` holds the
resampling details: `mean`, `bias`, `reps` and every interval the tool reports in
`intervals` (`normal`, `percentile`, `bias_corrected`, `bca`) (Ted, 2026-11-07).

## Requirements

- `specification.resampling` with `method` and `reps`.
- At least one row with `resampling`, holding a `p_value` or `conf_low`/`conf_high`.

## Settings and defaults

| Name | boottest | fwildclusterboot | wildboottest / pyfixest | Stata `bootstrap` |
|---|---|---|---|---|
| `reps` | `reps()` (999) | `B` (required) | `reps` (required) | `reps()` (50) |
| `seed` | `seed()` | `seed` | `seed` | `rseed()`; `e(rngstate)` |
| `cluster` | `bootcluster()` (the model's clusters) | `bootcluster` (`"max"`) | `cluster` | `cluster()` |
| `weights` | `weighttype()` (rademacher) | `type` (`"rademacher"`) | `weights_type` (`"rademacher"`) | — |
| `impose_null` | yes unless `nonull` | `impose_param_null` (TRUE) | `impose_null` (True) | — |
| `variant` | | `bootstrap_type` (`"fnw11"`) | `bootstrap_type` (`"11"`) | — |
| `p_value_type` | `ptype()` (symmetric) | `p_val_type` (two-tailed) | two-sided | — |
| `ci_method` | test inversion | test inversion | | normal (`estat bootstrap`: percentile, bc, bca) |
| `small_sample` | `small` / `nosmall` | `ssc` | `k_adj`, `G_adj` | |
| `mse` | | | | `mse` (around the full-sample estimate) |

Per row: `statistic`, `p_value`, `conf_low`, `conf_high`, `std_error` (when the method gives
one) and `null_value`. A resampled p-value of 0 means no replication was as extreme; its
resolution is about 1/reps. `metrics.n_reps_failed` records Stata's `e(N_misreps)` (`e(N_reps)` counts the complete ones).

## Example

[`schema/examples/resampling.estrec.json`](../../schema/examples/resampling.estrec.json):
a real pyfixest regression with CRV1 standard errors (claims `inference/0.1` too) and a
restricted wild cluster bootstrap of one coefficient, 9999 Rademacher replications.
