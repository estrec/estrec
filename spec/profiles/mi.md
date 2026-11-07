# Profile `mi/0.1`

Status: draft. Schema: [`schema/profiles/mi-0.1.json`](../../schema/profiles/mi-0.1.json).
Kind: standard. Builds on the core only.

Results pooled over multiply imputed data sets with Rubin's rules. Surveyed 2026-10-25: from
source, R mice 3.19.10 (amices/mice @ 61083e6) and statsmodels 0.15 `MICE`; Stata `mi estimate` from its help file and `mi impute` from documentation. Amelia, jomo and Blimp were not surveyed.

A pooled record also claims the analysis model's profile (`glm/0.1`, `linear-fe/0.1`, ...)
where that profile's requirements make sense for pooled results; metrics such as R² or
log-likelihood are not pooled by Rubin's rules and are usually absent.

## Requirements

- `specification.imputation`: `m` (≥ 2). `method` (`chained`, `mvn`, `monotone`, ...) is
  **expected**: Stata's `mi estimate` doesn't know how the data were imputed (Ted, 2026-11-07).
- `estimate` and `std_error` (the pooled total-variance SE) on every row that isn't dropped.
- `metrics.nobs`: rows in each completed data set.
- A default vcov with `type`: the pooled T = Ū + (1 + 1/m) B, typed by the
  within-imputation variance (`iid`, `HC1`, `CRV1`, ...).

## `specification.imputation` and options

| Name | mice | Stata | statsmodels |
|---|---|---|---|
| `m` | `m` (5) | `add()`, `e(M_mi)` | `fit(n_imputations=)` (10) |
| `method` | chained | `mi impute chained` / `mvn` / `monotone` | chained (`MICEData`) |
| `variable_methods` | `method` (pmm for numeric; logreg, polyreg, polr for factors) | `regress`, `pmm`, `logit`, ... | predictive mean matching with a perturbed model (`k_pmm` 20) |
| `iterations` | `maxit` (5) | `burnin()` (10) | `fit(n_burnin=)` (10) |
| `seed` | `seed` | `rseed()` | numpy's global RNG |
| `options.df_method` | Barnard-Rubin (with `dfcom`) | Barnard-Rubin for models with residual df (`nosmall`: Rubin 1987) | none (normal tests) |

## Per-row components: `parameters[*].mi`

| Name | Meaning | mice `pool()` | Stata | statsmodels |
|---|---|---|---|---|
| `ubar` | mean within-imputation variance | `ubar` | `e(W_mi)` | (per-imputation fits) |
| `b` | between-imputation variance | `b` | `e(B_mi)` | (per-imputation fits) |
| `t` | total variance | `t` | | `bse²` |
| `riv` | (1 + 1/m) B / Ū | `riv` | `e(rvi_mi)` (Stata calls it RVI) | |
| `lambda` | (1 + 1/m) B / T | `lambda` | | `frac_miss_info` |
| `fmi` | (riv + 2/(df + 3)) / (1 + riv) | `fmi` | `e(fmi_mi)` | |
| `df` | pooled-test df | `df` | `e(df_mi)` | |

**statsmodels' "FMI" is mice's `lambda`**, not mice's `fmi`, which also adjusts for the df.
Writers record it as `lambda`.

## Example

[`schema/examples/mi.estrec.json`](../../schema/examples/mi.estrec.json): a real
statsmodels MICE run on mice's `nhanes` data, `chl ~ age + bmi`, 20 imputations.
