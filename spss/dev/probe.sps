* Encoding: UTF-8.
* estrec for SPSS, development probe.
* Runs the procedures the SPSS writer will cover on tests/data/writers_probe.csv and saves
* every output table through OMS as OXML (XML with the numbers), one file per procedure, so
* the writer can be built against real output. Nothing is written outside the out folder.
*
* 1. Copy writers_probe.csv somewhere and set the two FILE HANDLEs below. Create the out
*    folder first (SPSS won't).
* 2. Run All (SPSS Statistics 27 or later). A procedure your licence lacks (Complex Samples,
*    Advanced Statistics) just gives an error; the rest still run.
* 3. Zip the out folder and also File > Export the Viewer (all items) as probe.pdf into it,
*    and send it back.

FILE HANDLE csv /NAME='C:\temp\writers_probe.csv'.
FILE HANDLE out /NAME='C:\temp\estrec_probe_spss'.

SET TNUMBERS=VALUES TVARS=NAMES ONUMBERS=VALUES OVARS=NAMES PRINTBACK=ON.
SHOW ALL.
SHOW EXTPATHS.

BEGIN PROGRAM PYTHON3.
import sys, spss
print("PROBE python", sys.version)
print("PROBE spss plugin", spss.GetDefaultPlugInVersion() if hasattr(spss, "GetDefaultPlugInVersion") else "?")
print("PROBE spss version", spss.GetSPSSVersion() if hasattr(spss, "GetSPSSVersion") else "?")
END PROGRAM.

GET DATA /TYPE=TXT /FILE=csv /ENCODING='UTF8' /DELIMITERS=',' /QUALIFIER='"'
  /ARRANGEMENT=DELIMITED /FIRSTCASE=2
  /VARIABLES=id F8.0 year F8.0 grp F8.0 stratum F8.0 psu F8.0 cat F8.0
   x1 F12.6 x2 F12.6 z F12.6 w F12.6 y F12.6 ybin F8.0 cnt F8.0.
DATASET NAME probe WINDOW=FRONT.
SORT CASES BY id year.

* Each procedure: all its tables to out/<tag>.xml.
DEFINE !grab (!POSITIONAL !TOKENS(1))
OMS /SELECT ALL /DESTINATION FORMAT=OXML OUTFILE=!QUOTE(!CONCAT('out/', !1, '.xml')) /TAG=!QUOTE(!1).
!ENDDEFINE.

* 1. OLS with the coefficient covariance; weighted OLS.
!grab reg.
REGRESSION /MISSING LISTWISE
  /STATISTICS COEFF OUTS CI(95) R ANOVA BCOV
  /DEPENDENT y /METHOD=ENTER x1 x2.
OMSEND TAG='reg'.
!grab regw.
REGRESSION /MISSING LISTWISE /REGWGT=w
  /STATISTICS COEFF OUTS CI(95) R ANOVA BCOV
  /DEPENDENT y /METHOD=ENTER x1 x2.
OMSEND TAG='regw'.

* 2. UNIANOVA with a factor; with robust (HC3, HC1) errors; with the unit as a factor (FE).
!grab glm.
UNIANOVA y BY cat WITH x1 x2 /METHOD=SSTYPE(3) /INTERCEPT=INCLUDE
  /PRINT=PARAMETER /CRITERIA=ALPHA(.05) /DESIGN=cat x1 x2.
OMSEND TAG='glm'.
!grab glmhc.
UNIANOVA y BY cat WITH x1 x2 /METHOD=SSTYPE(3) /INTERCEPT=INCLUDE
  /ROBUST=HC1 /PRINT=PARAMETER /CRITERIA=ALPHA(.05) /DESIGN=cat x1 x2.
OMSEND TAG='glmhc'.
!grab glmfe.
UNIANOVA y BY id WITH x1 x2 /METHOD=SSTYPE(3) /INTERCEPT=INCLUDE
  /PRINT=PARAMETER /DESIGN=id x1 x2.
OMSEND TAG='glmfe'.

* 3. Binary logit (LOGISTIC REGRESSION, models P(ybin=1)).
!grab logit.
LOGISTIC REGRESSION VARIABLES ybin /METHOD=ENTER cat x1 x2
  /CONTRAST (cat)=Indicator(1) /PRINT=CI(95) CORR /CRITERIA=PIN(.05) POUT(.10) ITERATE(20) CUT(.5).
OMSEND TAG='logit'.

* 4. GENLIN: logit with model-based and robust covariance; Poisson clustered on grp (GEE).
!grab gllogit.
GENLIN ybin (REFERENCE=FIRST) BY cat (ORDER=ASCENDING) WITH x1 x2
  /MODEL cat x1 x2 INTERCEPT=YES DISTRIBUTION=BINOMIAL LINK=LOGIT
  /CRITERIA METHOD=FISHER(1) SCALE=1 COVB=MODEL MAXITERATIONS=100 CILEVEL=95 LIKELIHOOD=FULL
  /PRINT CPS DESCRIPTIVES MODELINFO FIT SUMMARY SOLUTION COVB.
OMSEND TAG='gllogit'.
!grab gllogitr.
GENLIN ybin (REFERENCE=FIRST) WITH x1 x2
  /MODEL x1 x2 INTERCEPT=YES DISTRIBUTION=BINOMIAL LINK=LOGIT
  /CRITERIA COVB=ROBUST CILEVEL=95 LIKELIHOOD=FULL
  /PRINT CPS MODELINFO FIT SUMMARY SOLUTION COVB.
OMSEND TAG='gllogitr'.
!grab glpois.
GENLIN cnt WITH x1 x2
  /MODEL x1 x2 INTERCEPT=YES DISTRIBUTION=POISSON LINK=LOG
  /REPEATED SUBJECT=grp CORRTYPE=INDEPENDENT ADJUSTCORR=YES COVB=ROBUST
  /PRINT CPS MODELINFO FIT SUMMARY SOLUTION COVB.
OMSEND TAG='glpois'.

* 5. MIXED: random intercept by unit (REML).
!grab mixed.
MIXED y BY cat WITH x1 x2 /CRITERIA=DFMETHOD(SATTERTHWAITE)
  /FIXED=cat x1 x2 | SSTYPE(3) /METHOD=REML
  /PRINT=SOLUTION TESTCOV COVB G
  /RANDOM=INTERCEPT | SUBJECT(id) COVTYPE(VC).
OMSEND TAG='mixed'.

* 6. GENLINMIXED: logit random intercept. Its output is a Model Viewer; the SET below asks
*    for pivot tables where the version supports it.
!grab glmm.
GENLINMIXED
  /DATA_STRUCTURE SUBJECTS=id
  /FIELDS TARGET=ybin TRIALS=NONE OFFSET=NONE
  /TARGET_OPTIONS DISTRIBUTION=BINOMIAL LINK=LOGIT
  /FIXED EFFECTS=x1 x2 USE_INTERCEPT=TRUE
  /RANDOM USE_INTERCEPT=TRUE SUBJECTS=id COVARIANCE_TYPE=VARIANCE_COMPONENTS
  /BUILD_OPTIONS TARGET_CATEGORY_ORDER=ASCENDING INPUTS_CATEGORY_ORDER=ASCENDING
    MAX_ITERATIONS=100 CONFIDENCE_LEVEL=95 DF_METHOD=RESIDUAL COVB=MODEL
  /EMMEANS_OPTIONS SCALE=ORIGINAL PADJUST=LSD.
OMSEND TAG='glmm'.

* 7. Complex Samples: design with strata, PSUs and weights; linear and logistic.
CSPLAN ANALYSIS /PLAN FILE='out/probe.csaplan'
  /PLANVARS ANALYSISWEIGHT=w
  /SRSESTIMATOR TYPE=WR
  /DESIGN STRATA=stratum CLUSTER=psu
  /ESTIMATOR TYPE=WR.
!grab csglm.
CSGLM y WITH x1 x2 /PLAN FILE='out/probe.csaplan'
  /MODEL x1 x2 /INTERCEPT INCLUDE=YES SHOW=YES
  /STATISTICS PARAMETER SE CINTERVAL TTEST DEFF
  /PRINT SUMMARY VARIABLEINFO SAMPLEINFO
  /TEST TYPE=F PADJUST=LSD /MISSING CLASSMISSING=EXCLUDE /CRITERIA CILEVEL=95.
OMSEND TAG='csglm'.
!grab cslogit.
CSLOGISTIC ybin (HIGH) WITH x1 x2 /PLAN FILE='out/probe.csaplan'
  /MODEL x1 x2 /INTERCEPT INCLUDE=YES SHOW=YES
  /STATISTICS PARAMETER EXP SE CINTERVAL TTEST
  /PRINT SUMMARY VARIABLEINFO SAMPLEINFO /CRITERIA CILEVEL=95.
OMSEND TAG='cslogit'.

* 8. The Notes table of the last procedure on its own (filter, weight, syntax, timing).
!grab notes.
DESCRIPTIVES VARIABLES=y x1 x2.
OMSEND TAG='notes'.

OMSEND.
ECHO 'PROBE done: results in the out folder'.
