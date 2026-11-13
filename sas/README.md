# estrec for SAS

Writes SAS procedure results as [estrec](https://estrec.org) records: a JSON file for one
estimation run, saying what was estimated, what came out, and how it ran.

```sas
filename estrec url "https://raw.githubusercontent.com/estrec/estrec/main/sas/estrec.sas";
%include estrec;

%estrec_begin;
proc logistic data=mydata;
  class grp / param=ref ref=first;
  model y(event='1') = grp x / covb;
run;
%estrec_end(out=/path/fit.estrec.json);
```

`%estrec_begin` opens an ODS document; your output still goes to your usual destinations.
`%estrec_end` writes one record per supported procedure run in between (numbered
`fit-1.estrec.json`, `fit-2.estrec.json`, ... when there are several) and notes the
procedures it skipped. Options: `TITLE=`, `IDENTIFYING=YES` (also records the data set name).

| Procedure | Profiles | Ask for | Covariance recorded |
|---|---|---|---|
| REG | inference | `MODEL / COVB` (and `HCC HCCMETHOD= ACOV` for robust) | iid; HC0-HC3 as a second matrix with ACOV |
| GLM | inference | `MODEL / SOLUTION` | none printed: variances only (squared SEs) |
| SURVEYREG | inference | `MODEL / SOLUTION COVB` | cluster only: CRV1; strata or weights: Taylor |
| LOGISTIC | inference, glm | `MODEL / COVB` | iid |
| SURVEYLOGISTIC | inference, glm | `MODEL / COVB` | cluster only: CRV1; strata or weights: Taylor |
| GENMOD | inference, glm | `MODEL / COVB`; with `REPEATED ... / COVB` (GEE) | iid; GEE: cluster sandwich, no G/(G-1) |
| MIXED | mixed (and inference with `COVTEST`) | `MODEL / SOLUTION COVB`, `COVTEST` | model-based; per-coefficient df (DDFM) |
| GLIMMIX | mixed (and inference when the variance components have SEs) | `MODEL / SOLUTION COVB` | model-based |
| PANEL (SAS/ETS) | inference | | model-based; FIXONE/FIXTWO levels recorded as (cross section), (time period) |
| SYSLIN (SAS/ETS) | inference | `2SLS` | 2SLS; the record has no list of endogenous variables or instruments |

Notes:

- **Precision.** SAS formats print at most about 15 significant digits, so numbers are
  written to 15 (PROC JSON would give 12). They're written in the RFC 8785 form, so the
  record's core digest, computed in SAS, agrees with other tools'.
- **Digest.** SAS computes it with `HASHING_FILE`, which needs OpenSSL. On Linux, if the log
  says "no core digest", start SAS with `LD_LIBRARY_PATH` including the system library
  folder (e.g. `/usr/lib/x86_64-linux-gnu`), or add the digest later with the Python
  `estrec` package.
- **Text.** Records are UTF-8; in a non-UTF-8 session (Windows SAS is often WLATIN1) text
  is converted with KCVT.
- **Convergence.** LOGISTIC's default criterion (GCONV=1E-8) stops earlier than R's glm;
  its estimates differ from glm's around the 4th or 5th significant digit. The record keeps
  SAS's numbers.

Tests: `tests/test_sas.py` (runs SAS in batch on `tests/data/writers_probe.csv`). `dev/`
holds the probe that captured each procedure's ODS tables.
