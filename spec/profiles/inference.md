# Profile `inference/0.1`

Status: draft. Schema: [`schema/profiles/inference-0.1.json`](../../schema/profiles/inference-0.1.json).
Kind: standard. Surveyed: R `lm` and estimatr, statsmodels, Stata `regress`.

Records of models that report estimates with standard errors. The other inference profiles
(`linear-fe`, `iv`) build on it.

## Requirements

A record claiming `inference/0.1` MUST have:

- in `parameters`, on every row that is not `dropped`: `estimate` and `std_error`, and `p_value`
  too except on variance-component and ancillary rows (`component` `random` or `auxiliary`),
  which tools often report without a test (Stata's log SDs and `me*` variances, nbreg's
  `/lnalpha`, lme4). A writer records no test there that the tool doesn't report (Ted,
  2026-11-07);
- `metrics.nobs`;
- `metrics.df_residual`, unless the default vcov has no `df_t` (absent or null), which means
  its tests and intervals use the normal distribution (z tests). Tools that use z tests and
  report no residual df (Stata's ML commands, `ivregress` and `ivreg2` without `small`,
  `xtreg, re`) leave it out rather than writing a value the tool doesn't report;
- a default vcov in `structures.vcov`: the one marked `default: true`, or the only one. It
  MUST have `type` and `ssc` with at least `convention`. Two vcovs both marked default are an
  error.

## Vocabulary

- `structures.vcov[*].type`: `iid`, `HC0` to `HC3`, `CRV1`, `CRV3`, `twoway`/`multiway`,
  `HAC`, `DK` (recommended values; any string is allowed).
- `structures.vcov[*].ssc` (small-sample correction): `convention` names the tool whose
  convention the correction reproduces (`"fixest"`, `"reghdfe"`, `"stata"`, `"R lm"`,
  `"linearmodels debiased=True"`); `formula`, `factors` and `K_counts` write it out when the
  writer has them. These factors are the most common source of standard-error differences
  between tools, which is why `convention` is required.
- `structures.vcov[*].df_t`: the df used for t tests and confidence intervals (many tools use
  G − 1 under clustering), which can differ from `metrics.df_residual`.
- `parameters[*].df`: a row's own df. When present, the row's test and interval are t on this
  df rather than on the vcov's `df_t`, which is then null: Satterthwaite or Kenward-Roger df in
  mixed models, Rubin's df under multiple imputation (Ted, 2026-11-07).
- `metrics.df_residual` is the residual df as the tool reports it. When that is not the
  textbook N − K (minus absorbed levels), writers SHOULD say what it is with
  `{value, definition}`.
