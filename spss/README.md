# estrec for SPSS

Writes SPSS procedure results as [estrec](https://estrec.org) records: a JSON file for one
estimation run, saying what was estimated, what came out, and how it ran.

## Install

Download [`estrec.spe`](https://github.com/estrec/estrec/raw/main/spss/estrec.spe) and install it with **Extensions > Install Local Extension Bundle**
(SPSS Statistics 27 or later; it uses the Python 3 that comes with SPSS).

## Use

Put `ESTREC BEGIN` before the procedures and `ESTREC END` after them, the way
`OMS ... OMSEND` brackets output you want to capture:

```
ESTREC BEGIN.
REGRESSION /STATISTICS COEFF OUTS CI(95) R ANOVA BCOV
  /DEPENDENT y /METHOD=ENTER x1 x2.
ESTREC END OUTFILE='/path/fit.estrec.json'.
```

Each supported procedure run in between gives one record; with several, the files are
numbered (`fit-1.estrec.json`, `fit-2.estrec.json`, ...). `TITLE='...'` sets the record's
title; `IDENTIFYING=YES` also records the data file's path (left out by default). The Viewer
output is unchanged. While capturing, output labels are in English (`SET OLANG`); END
restores your setting.

| Procedure | Profiles | Ask for | Notes |
|---|---|---|---|
| REGRESSION | inference | `/STATISTICS COEFF OUTS CI(95) R ANOVA BCOV` | BCOV gives the slopes' covariances (not the constant's) |
| UNIANOVA | inference | `/PRINT=PARAMETER` (and `/ROBUST=HC1` etc.) | no covariance matrix printed: the record has the variances only |
| LOGISTIC REGRESSION | inference, glm | `/PRINT=CI(95) CORR` | CORR gives the full covariance matrix |
| GENLIN | inference, glm | `/PRINT ... SOLUTION COVB` | `COVB=ROBUST` is HC0; `/REPEATED` (GEE) is cluster-robust without G/(G-1) |
| MIXED | inference, mixed | `/PRINT=SOLUTION TESTCOV COVB` | per-coefficient df (Satterthwaite by default) |
| GENLINMIXED | inference, mixed | (subject variable nominal) | its default reference is the last target category |

**From the menus:** after running a model from the dialogs, **Utilities > Save estimation
record** (below OMS Identifiers) writes a record of the last supported procedure run. It runs
`ESTREC WRITE OUTFILE='...'`, which finds that procedure's syntax in the journal (or, failing
that, the Viewer's Notes tables), re-runs it quietly and records the result, so the record
reflects the active dataset at that moment. Because it runs the model again, a slow model takes as long again; for
those, put `ESTREC BEGIN` / `ESTREC END` around the model in syntax instead. The journal must be on (Edit > Options > File
Locations > Record syntax in journal; it is by default).

The dialog's source is `ESTREC_WRITE.spd` (SPSS's Custom Dialog Builder); the bundle carries
`ESTREC_WRITE.cfe`, the compiled form SPSS makes when the builder installs it, taken from a
bundle SPSS exported. After editing the dialog, install it from the builder, export a bundle,
and replace `ESTREC_WRITE.cfe` with the `.cfe` inside it.

**PROCESS** (Andrew F. Hayes's macro for mediation, moderation and conditional process
models) is recorded too, between `ESTREC BEGIN` and `ESTREC END` like any procedure. estrec
doesn't include PROCESS: get it from https://www.afhayes.com/download.html. To run it from
syntax without opening its dialog first, define the macro at the top of the file:

```
INSERT FILE='/path/to/process51.sps'.
ESTREC BEGIN.
PROCESS y=y /x=x1 /m=x2 /model=4 /seed=20261114 /display=tables.
ESTREC END OUTFILE='mediation.estrec.json'.
```

Add `/display=tables` (PROCESS 5): PROCESS then prints its results as tables, which carry
full precision. Without it PROCESS prints text, and the record has its printed decimals (4 by
default; the record says so). The record claims `mediation/0.1` when the model has mediators:
each equation's coefficients (`response` names the equation's outcome; a `total=1` model's are
`component: total_effect_model`), the direct, indirect, total, conditional and relative
effects, contrasts and indices of moderated mediation as rows tagged `mediation`, and the
model and interaction tests. The seed, bootstrap draws and interval type are in
`specification.mediation.inference`. Not recorded: standardized effects and the
Johnson-Neyman region bounds (the conditional effects table is). Each equation's Model
Summary (R², adjusted R², MSE, or -2LL and pseudo-R²s) is in `structures.equations`, its F in `tests`. `ESTREC WRITE` (the menu item)
doesn't re-run PROCESS.

Checked with PROCESS 5.0 and 5.1.1. Their output differs (5.1 moved MSE and the F's degrees of
freedom into an SS/df/MS table under the Model Summary); both are read. With any other version
the record carries a `process_version_unchecked` warning and `ESTREC END` prints it: compare the
record with PROCESS's output before relying on it.

Complex Samples procedures (CSGLM, CSLOGISTIC) aren't covered yet.

## Development

`estrec_oxml.py` reads OMS OXML, `estrec_procedures.py` builds the records (no SPSS needed:
`tests/test_spss.py` runs on saved OXML in `tests/data/spss/`), `estrec_session.py` is the
SPSS side. `python spss/build_bundle.py` makes `spss/estrec.spe`, which is committed (rebuild it after changing anything here; a test checks) (manifest in the form SPSS's Create Extension Bundle writes). `dev/` holds the
probes that captured the fixtures.
