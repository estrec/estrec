# Writers for Julia, SAS and SPSS

Plan agreed with Ted, 2026-11-13. Each writer runs inside its own tool, so a user needs
nothing else installed, and claims the same profiles as the Stata and R writers for the same
kind of model.

## Scope (Ted: linear and logit core, then panel and mixed)

| Tool | Package / command | First | Then |
|---|---|---|---|
| Julia | `julia/` (EstRec.jl): `write_estimation(model, path)` | FixedEffectModels `reg` (OLS, IV, FE, clusters); GLM.jl `lm`, `glm` | fixed-effects GLMs (GLFixedEffectModels), MixedModels.jl |
| SAS | `sas/estrec.sas`: `%estrec_write(path=, ...)` after a procedure, from its ODS OUTPUT tables, written with PROC JSON | REG, GLM (incl. ABSORB), SURVEYREG, LOGISTIC, SURVEYLOGISTIC, GENMOD (incl. GEE) | PANEL, SYSLIN 2SLS, MIXED, GLIMMIX |
| SPSS | `spss/` extension command `ESTREC WRITE`, Python (SPSS's own) reading the procedure's OMS output | REGRESSION, UNIANOVA (incl. /ROBUST), LOGISTIC REGRESSION, GENLIN (incl. GEE), CSGLM, CSLOGISTIC | MIXED, GENLINMIXED |

Profiles: `inference` everywhere; `linear-fe` for absorbed / fixed-effects fits; `glm`;
`iv`; `survey` for SURVEY*/CS* procedures; `mixed` for MIXED, GLIMMIX, GENLINMIXED and
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
