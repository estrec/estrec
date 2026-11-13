# estrec for SPSS

Writes SPSS procedure results as [estrec](https://estrec.org) records: a JSON file for one
estimation run, saying what was estimated, what came out, and how it ran.

## Install

Download `estrec.spe` and install it with **Extensions > Install Local Extension Bundle**
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

Complex Samples procedures (CSGLM, CSLOGISTIC) aren't covered yet.

## Development

`estrec_oxml.py` reads OMS OXML, `estrec_procedures.py` builds the records (no SPSS needed:
`tests/test_spss.py` runs on saved OXML in `tests/data/spss/`), `estrec_session.py` is the
SPSS side. `python spss/build_bundle.py` makes `spss/dist/estrec.spe`. `dev/` holds the
probes that captured the fixtures.
