* Encoding: UTF-8.
* estrec for SPSS, development probe, part 2: re-runs the two blocks that failed in probe.sps
* (GENLINMIXED needed id as nominal; Complex Samples). Set the two paths as before, Run All,
* then add the new XML files and the Viewer exported as probe2.pdf (all items, including
* errors and warnings) to the out folder.

FILE HANDLE csv /NAME='/Users/you/Desktop/spss/writers_probe.csv'.
FILE HANDLE out /NAME='/Users/you/Desktop/spss/estrec_probe_spss'.

SET TNUMBERS=VALUES TVARS=NAMES ONUMBERS=VALUES OVARS=NAMES PRINTBACK=ON.

GET DATA /TYPE=TXT /FILE=csv /ENCODING='UTF8' /DELIMITERS=',' /QUALIFIER='"'
  /ARRANGEMENT=DELIMITED /FIRSTCASE=2
  /VARIABLES=id F8.0 year F8.0 grp F8.0 stratum F8.0 psu F8.0 cat F8.0
   x1 F12.6 x2 F12.6 z F12.6 w F12.6 y F12.6 ybin F8.0 cnt F8.0.
DATASET NAME probe WINDOW=FRONT.
VARIABLE LEVEL id grp stratum psu cat ybin (NOMINAL).
SORT CASES BY id year.

* Which modules this licence has (Complex Samples is an add-on).
SHOW LICENSE.

* GENLINMIXED: logit random intercept; ask for pivot tables instead of the Model Viewer.
OMS /SELECT ALL /DESTINATION FORMAT=OXML OUTFILE='out/glmm2.xml' /TAG='glmm2'.
GENLINMIXED
  /DATA_STRUCTURE SUBJECTS=id
  /FIELDS TARGET=ybin TRIALS=NONE OFFSET=NONE
  /TARGET_OPTIONS DISTRIBUTION=BINOMIAL LINK=LOGIT
  /FIXED EFFECTS=x1 x2 USE_INTERCEPT=TRUE
  /RANDOM USE_INTERCEPT=TRUE SUBJECTS=id COVARIANCE_TYPE=VARIANCE_COMPONENTS
  /BUILD_OPTIONS TARGET_CATEGORY_ORDER=ASCENDING INPUTS_CATEGORY_ORDER=ASCENDING
    MAX_ITERATIONS=100 CONFIDENCE_LEVEL=95 DF_METHOD=RESIDUAL COVB=MODEL
  /EMMEANS_OPTIONS SCALE=ORIGINAL PADJUST=LSD
  /OUTFILE MODEL='out/glmm2_model.zip'.
OMSEND TAG='glmm2'.

* Complex Samples: the plan step on its own (its errors go to the Viewer), then the models.
OMS /SELECT ALL /DESTINATION FORMAT=OXML OUTFILE='out/csplan2.xml' /TAG='csplan2'.
CSPLAN ANALYSIS
  /PLAN FILE='out/probe2.csaplan'
  /PLANVARS ANALYSISWEIGHT=w
  /DESIGN STRATA=stratum CLUSTER=psu
  /ESTIMATOR TYPE=WR.
OMSEND TAG='csplan2'.
OMS /SELECT ALL /DESTINATION FORMAT=OXML OUTFILE='out/csglm2.xml' /TAG='csglm2'.
CSGLM y WITH x1 x2
  /PLAN FILE='out/probe2.csaplan'
  /MODEL x1 x2
  /INTERCEPT INCLUDE=YES SHOW=YES
  /STATISTICS PARAMETER SE CINTERVAL TTEST DEFF
  /PRINT SUMMARY VARIABLEINFO SAMPLEINFO
  /MISSING CLASSMISSING=EXCLUDE
  /CRITERIA CILEVEL=95.
OMSEND TAG='csglm2'.
OMS /SELECT ALL /DESTINATION FORMAT=OXML OUTFILE='out/cslogit2.xml' /TAG='cslogit2'.
CSLOGISTIC ybin (HIGH) WITH x1 x2
  /PLAN FILE='out/probe2.csaplan'
  /MODEL x1 x2
  /INTERCEPT INCLUDE=YES SHOW=YES
  /STATISTICS PARAMETER EXP SE CINTERVAL TTEST
  /PRINT SUMMARY VARIABLEINFO SAMPLEINFO
  /CRITERIA CILEVEL=95.
OMSEND TAG='cslogit2'.

OMSEND.
ECHO 'PROBE2 done'.
