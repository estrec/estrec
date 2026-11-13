* Encoding: UTF-8.
* estrec for SPSS: first test of the installed bundle (estrec.spe).
* 1. Install estrec.spe: Extensions > Install Local Extension Bundle. Restart SPSS if asked.
* 2. Set the two paths below (out folder must exist), Run All.
* 3. Copy the out folder's *.estrec.json files, and the Viewer exported as test_bundle.pdf
*    (all items, including any errors), to valiant.

FILE HANDLE csv /NAME='/Users/you/Desktop/spss/writers_probe.csv'.
FILE HANDLE out /NAME='/Users/you/Desktop/spss/estrec_test'.

GET DATA /TYPE=TXT /FILE=csv /ENCODING='UTF8' /DELIMITERS=',' /QUALIFIER='"'
  /ARRANGEMENT=DELIMITED /FIRSTCASE=2
  /VARIABLES=id F8.0 year F8.0 grp F8.0 stratum F8.0 psu F8.0 cat F8.0
   x1 F12.6 x2 F12.6 z F12.6 w F12.6 y F12.6 ybin F8.0 cnt F8.0.
DATASET NAME probe WINDOW=FRONT.
VARIABLE LEVEL id grp stratum psu cat ybin (NOMINAL).

* A: one procedure, one record, with a title.
ESTREC BEGIN.
REGRESSION /MISSING LISTWISE /STATISTICS COEFF OUTS CI(95) R ANOVA BCOV
  /DEPENDENT y /METHOD=ENTER x1 x2.
ESTREC END OUTFILE='out/a_reg.estrec.json' TITLE='OLS of y on x1 and x2'.

* B: several procedures (and an unsupported one) -> numbered files b-1, b-2, ...
ESTREC BEGIN.
DESCRIPTIVES VARIABLES=y x1 x2.
LOGISTIC REGRESSION VARIABLES ybin /METHOD=ENTER cat x1 x2
  /CONTRAST (cat)=Indicator(1) /PRINT=CI(95) CORR.
GENLIN cnt WITH x1 x2 /MODEL x1 x2 INTERCEPT=YES DISTRIBUTION=POISSON LINK=LOG
  /REPEATED SUBJECT=grp CORRTYPE=INDEPENDENT COVB=ROBUST
  /PRINT CPS MODELINFO FIT SUMMARY SOLUTION COVB.
UNIANOVA y BY cat WITH x1 x2 /ROBUST=HC3 /PRINT=PARAMETER /DESIGN=cat x1 x2.
ESTREC END OUTFILE='out/b.estrec.json'.

* C: MIXED under a filter (years after 2005): its record counts the cases itself.
COMPUTE late = (year > 2005).
FILTER BY late.
ESTREC BEGIN.
MIXED y BY cat WITH x1 x2 /FIXED=cat x1 x2 | SSTYPE(3) /METHOD=REML
  /PRINT=SOLUTION TESTCOV COVB /RANDOM=INTERCEPT | SUBJECT(id) COVTYPE(VC).
ESTREC END OUTFILE='out/c_mixed_filtered.estrec.json'.
FILTER OFF.

* D: output language: set to German, capture, and check it is German again afterwards.
SET OLANG=GERMAN.
ESTREC BEGIN.
GENLINMIXED /DATA_STRUCTURE SUBJECTS=id /FIELDS TARGET=ybin
  /TARGET_OPTIONS DISTRIBUTION=BINOMIAL LINK=LOGIT
  /FIXED EFFECTS=x1 x2 USE_INTERCEPT=TRUE
  /RANDOM USE_INTERCEPT=TRUE SUBJECTS=id COVARIANCE_TYPE=VARIANCE_COMPONENTS.
ESTREC END OUTFILE='out/d_glmm.estrec.json'.
SHOW OLANG.
SET OLANG=ENGLISH.

* E: errors: END without BEGIN (should give a clear message).
ESTREC END OUTFILE='out/e_none.estrec.json'.
