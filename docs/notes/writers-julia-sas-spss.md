# Writers for Julia, SAS and SPSS

Plan agreed with Ted, 2026-11-13. Each writer runs inside its own tool, so a user needs
nothing else installed, and claims the same profiles as the Stata and R writers for the same
kind of model.

## Scope (Ted: linear and logit core, then panel and mixed)

| Tool | Package / command | First | Then |
|---|---|---|---|
| Julia | `julia/` (EstRec.jl): `write_estimation(model, path)` | FixedEffectModels `reg` (OLS, IV, FE, clusters); GLM.jl `lm`, `glm` | fixed-effects GLMs (GLFixedEffectModels), MixedModels.jl |
| SAS | `sas/estrec.sas`: `%estrec_write(path=, ...)` after a procedure, from its ODS OUTPUT tables, written with PROC JSON | REG, GLM (incl. ABSORB), SURVEYREG, LOGISTIC, SURVEYLOGISTIC, GENMOD (incl. GEE) | PANEL, SYSLIN 2SLS, MIXED, GLIMMIX |
| SPSS | `spss/` extension commands `ESTREC BEGIN` / `ESTREC END OUTFILE=` (Ted 2026-11-13), Python (SPSS's own) reading the procedures' OMS output | REGRESSION, UNIANOVA (incl. /ROBUST), LOGISTIC REGRESSION, GENLIN (incl. GEE) | MIXED, GENLINMIXED. Complex Samples (CSGLM, CSLOGISTIC) dropped: Ted's licence lacks the module |

Profiles: `inference` everywhere; `linear-fe` for absorbed / fixed-effects fits; `glm`;
`iv`; `survey` for SAS's SURVEY* procedures; `mixed` for MIXED, GLIMMIX, GENLINMIXED and
MixedModels.jl.

## Testing

- **Julia** on valiant: Julia under `/opt`, packages in `/srv/dfeols/.julia` (owned by
  dfclaude, added by Ted; the sandbox has no package registry). Tests in `julia/test/` and a
  Python test like `tests/test_stata.py` that validates every record.
- **SAS** on valiant (Ted installing SAS 9.4 for Linux, 2026-11-13): Claude runs the probe
  and the tests in batch, with WORK under `tmp/` and modest MEMSIZE/CPUCOUNT (shared machine).
- **SPSS** on Ted's laptop (no Linux licence): Ted runs the probe and the test programs.
  For both:
  1. **Probe** (`sas/dev/probe.sas`, `spss/dev/probe.sps`): runs every target procedure on
     `tests/data/writers_probe.csv` and saves all output tables (SAS: ODS OUTPUT to CSV at
     best32.; SPSS: OMS OXML). The writers are built against that real output.
  2. **Test programs** (later): run the writer on the same models; Ted sends back the
     records, which are validated here and compared with R / Python estimates on the same
     data (`tests/data/writers_probe.csv` is shared by all three tools).
- Shared data: `tests/data/make_writers_probe.py` (100 units x 20 years; clusters, strata,
  PSUs, weights; continuous, binary and count outcomes; an instrument; 3 missing x2).

## Questions the probes answer

- SAS: exact ODS table and column names per procedure and option (HCC covariance, GEE
  empirical covariance, PANEL's tables), whether `CovB` carries full precision, the class
  parameter naming (`cat 2`), and the NObs read/used counts for `sample.dropped`.
- SPSS: whether OXML numbers keep full precision; the coefficient covariance tables
  (REGRESSION BCOV, GENLIN COVB, MIXED COVB); whether GENLINMIXED gives pivot tables at all;
  what the Notes table holds (filter, weight, split, syntax) for `specification.state`; and
  that the bundled Python 3 runs (for the extension command).

## SPSS probe findings (2026-11-13, SPSS on Ted's Mac; `raw/estrec_probe_spss/`)

The probe ran everything except Complex Samples (not licensed: dropped). GENLINMIXED needs the
subject variable's measurement level nominal (`probe2.sps`); it then gives pivot tables.

- **Precision**: OXML `number` attributes carry ~14 significant digits. REGRESSION's
  intercept and SE match R's lm to all 14.
- **Labels are display text in the output language** ("Std. Error", "Sig."), so ESTREC BEGIN
  sets `OLANG=ENGLISH` and END restores it. Variable categories also carry `varName`.
- **Notes table** (every procedure): the syntax as run, active dataset, filter, weight, split
  file, missing-value rule, N of rows, and the data file's path (identifying: user name).
- **REGRESSION**: Coefficients (B, SE, t, Sig., CI with CI(95)); Model Summary (R², adj. R²,
  SE of estimate); ANOVA (SS, df, F); BCOV gives a "Coefficient Correlations" table whose
  Covariances block covers the **slopes only, not the constant**: the record's vcov labels
  the slopes it has.
- **UNIANOVA**: Parameter Estimates rows `Intercept`, `[cat=1]`...; the last level is the
  reference (B = 0, other cells "."; footnote "redundant") -> `dropped: "reference"`. /ROBUST
  adds "Parameter Estimates with Robust Standard Errors" (footnote "HC1 method"). No
  covariance matrix. R² in a footnote of Tests of Between-Subjects Effects.
- **LOGISTIC REGRESSION**: "Variables in the Equation" appears twice (Step 0, then Step 1:
  use the last step); factor levels are positional (`cat(1)`, `cat(2)`), mapped to values by
  "Categorical Variables Codings"; Wald chi-square per row (record z = B/SE, same p); no
  covariance, but `/PRINT=CORR` gives a Correlation Matrix (labels padded with spaces):
  cov = corr * se_i * se_j. Model Summary: -2LL, Cox & Snell, Nagelkerke; iterations in a
  footnote. Dependent Variable Encoding gives the modelled category.
- **GENLIN**: ModelInformation (dependent, distribution, link; footnote says which category is
  modelled); Goodness of Fit (deviance, Pearson, full log likelihood, AIC, BIC); Parameter
  Estimates (B, SE, Wald CI, Wald chi-square, df, Sig.; reference level B = 0 with "."); COVB
  gives "Covariances of Parameter Estimates" (full, robust when COVB=ROBUST); /REPEATED gives
  a Correlated Data Summary (number of subjects = clusters).
- **MIXED**: Estimates of Fixed Effects with a per-row `df` (Satterthwaite) -> parameter `df`;
  Covariance Matrix for Estimates of Fixed Effects; Estimates of Covariance Parameters
  (Residual; `Intercept [subject = id]` Variance); Information Criteria (-2 REML LL, AIC,
  BIC); Model Dimension.
- **GENLINMIXED**: Fixed Coefficients (t tests), Covariances of Fixed Coefficients,
  Covariance Parameters (Var(Intercept)), Model Summary (target, distribution, link, AICC,
  BIC). With TARGET_CATEGORY_ORDER=ASCENDING its signs are the opposite of LOGISTIC
  REGRESSION's: it models the other category, so the writer must record the modelled
  category (from the target's reference setting).
