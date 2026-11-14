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

## SAS probe findings (2026-11-13, SAS 9.4M9 on valiant, batch as dfclaude)

SAS is at `/usr/local/SASHome/SASFoundation/9.4/sas` (licence to 30JUN2027: Base, STAT, ETS,
IML, ...). Run batch with `-nodms -work tmp/sas/work -memsize 4G -cpucount 4`. The probe
(`sas/dev/probe.sas`, paths settable before `%include`) runs clean; output in
`tmp/sas/probe/` (one CSV per ODS table, `p_<model>_<table>.csv`, plus probe.log with the
ODS trace).

- ODS OUTPUT requests need `persist=run` (REG's run groups) and `ods output clear;` between
  procedures: `persist=proc` carries a request into later procedures, which overwrite it.
- Tables per procedure (as created): REG NObs ANOVA FitStatistics ParameterEstimates (with
  HCStdErr/HCCMethod under `hcc`) CovB (model-based; the HC matrix needs `acov`: ACovEst);
  GLM NObs OverallANOVA FitStatistics ModelANOVA ParameterEstimates (no CovB); SURVEYREG
  DataSummary DesignSummary FitStatistics Effects ParameterEstimates CovB; LOGISTIC ModelInfo
  NObs ResponseProfile ConvergenceStatus FitStatistics GlobalTests ModelANOVA (was Type3)
  ParameterEstimates OddsRatios CovB; GENMOD ModelInfo NObs ClassLevels ModelFit
  ConvergenceStatus ParameterEstimates CovB, with REPEATED GEEModInfo GEEEmpPEst GEERCov
  (robust) GEENCov GEEFitCriteria; PANEL ModelDescription FitStatistics FixedEffectsTest /
  VarianceComponents ParameterEstimates (covariance needs its option); SYSLIN ANOVA
  FitStatistics ParameterEstimates; MIXED ModelInfo Dimensions NObs CovParms FitStatistics
  SolutionF CovB Tests3; GLIMMIX the same with ParameterEstimates.
- **Precision**: PROC JSON writes 12 significant digits, so the writer can't use it: it
  writes the JSON in a DATA step. PROC EXPORT CSV keeps ~16 characters (10 significant
  digits for small numbers), so the probe's CSVs are for layout, not values. No SAS format
  prints all 17 digits: E32 gives 14, fixed w.d about 15 (10,000 random doubles: worst
  relative error 1.5e-13 with one fixed rule). The writer picks, per number, the candidate
  text (BEST32, E32, fixed w.d) that reads back closest to the double.

## SPSS bundle: what SPSS 32 needs (2026-11-13, Ted's Mac)

- Installs and works from `spss/dist/estrec.spe` built by `spss/build_bundle.py` (804ab49):
  Extension Hub lists it, ESTREC BEGIN/END run, `spss/dev/test_bundle.sps` passes all five
  checks (records in `raw/estrec_test/`).
- The manifest must look like SPSS's own Create Extension Bundle output: no `Plugins:` or
  `Python-Version:` headers (with them SPSS 32 abandoned the install, leaving nothing),
  72-byte Java manifest lines, comma lists without spaces.
- Command specs: `Language="Python" LanguageVersion="3"`. `Language="Python3"` ran the code
  as `BEGIN PROGRAM PYTHON2` with warning 8502.
- Hand-copied commands must sit directly in the EXTPATHS EXTENSIONS folder, not a subfolder.
- `spss.GetDefaultPlugInVersion()` gives `spss320`; the writer records it as 32.0.

## PROCESS (2026-11-14)

Ted: PROCESS models must be recordable. No writer produces them yet; `mediation/0.1` already
maps PROCESS's options and effect rows. In SPSS, PROCESS runs inside MATRIX, so its output is
text, not pivot tables: the writer parses that text from the OMS capture (ESTREC BEGIN/END
already captures it). PROCESS for R and SAS print the same text, so the parser can serve those
later. First step: `spss/dev/probe_process.sps` (models 1, 4 with covariates/contrasts/HC3/
binary Y/multicategorical X/saved draws, 6, 7, 14), outputs to `raw/estrec_probe_process/`.

### PROCESS 5.1 source and local runs (2026-11-14)

Ted downloaded PROCESS 5.1 (`raw/process/processv51.zip`). Its license forbids storing it
anywhere public or distributing modified copies, so the source (unzipped in
`tmp/process_src/v51/`), its documentation and its output stay out of this repo; writers only
read PROCESS's output, and users install PROCESS from afhayes.com.

Read before running (Ted agreed to the runs): R and SAS versions print only (no files, system or
network calls); loading either runs an activation call that prints "ready". SPSS changes
settings inside PRESERVE/RESTORE, and its `save=` replaces the active dataset (`save ... /outfile
= *`), so the SPSS writer must not use it.

Runs on valiant (`tmp/process_runs/`, scripts there): R 5.1.1 (11 models) and SAS 5.1.1 (7).
- Printed text has `decimals` places (R 9.4, SAS 10.4, SPSS F10.4): 4 decimals by default.
- `save=2` returns every printed table's numbers at full precision, one matrix row per printed
  table row in print order, padded (NA in R), last row the error counts (bad bootstraps,
  singular, errors-in-variables). Checked row by row on models 4 and 7: the text gives the
  labels and section structure, the matrix the numbers. The constant of y matches R `lm`
  (1.24732275732714).
- SAS prints the same sections in the same order (variable names upper-cased); its bootstrap
  draws differ from R's (own RNG), so intervals differ in the third decimal.
Writer plan: one reader of PROCESS's text (sections, labels, which row is which), plus the
`save=2` matrix in R and SAS for precision; SPSS from OMS, `display=tables` pivot tables at full
precision where PROCESS 5 provides them (probe `t_*` runs), else the printed decimals with a
precision message.

### PROCESS writers for R and SAS (2026-11-14)

- R (`r/R/process.R`, 6520cf2): `record_process(process(...))` adds `save = 2` (which also sets
  `intprobe = 1`), prints PROCESS's output and ports the Python reader. Matrix rows follow the
  printed rows except "Coding of" tables (not in the matrix), blank rows at section breaks and
  the closing error-count row, so each printed row takes the next matrix row that agrees to its
  printed decimals.
- SAS (`sas/estrec.sas`, bd06fb2): PROCESS for SAS's IML matrices reach the ODS document at full
  precision: character matrices hold its text, numeric ones its tables, titled as printed (an
  untitled table's title is the `_LIT` line above it); column labels keep PROCESS's headings
  (`R-sq`, `-2LL`, `F(HC3)`). Ported to one DATA step. PROCESS for SAS prints `{C1)` for `(C1)`
  and `Ind1 : X1 -> ...` keys.
- `tests/test_process.py` checks both against the Python reader on 7 models (R: its printed
  text; SAS: its listing).
