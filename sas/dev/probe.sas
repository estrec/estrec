/* estrec for SAS, development probe.
   Runs the procedures the SAS writer will cover on tests/data/writers_probe.csv and saves
   every ODS output table they produce, at full precision, as CSV, so the writer can be built
   against real output. Nothing is written outside &out.

   1. Copy writers_probe.csv next to this file (or anywhere) and set the two paths below.
   2. Run the whole program (SAS 9.4 or Viya). It takes about a minute.
   3. Zip the &out folder (CSV files, probe.log, probe.lst) and send it back.

   A procedure your site doesn't license (e.g. SAS/ETS for PANEL) just logs an error; the
   rest still run. */

%let csv = C:\temp\writers_probe.csv;   /* the data file */
%let out = C:\temp\estrec_probe_sas;    /* created if missing; results go here */

options dlcreatedir nonotes;
libname _mk "&out"; libname _mk clear;
options notes;
proc printto log="&out/probe.log" print="&out/probe.lst" new; run;

%put PROBE sysvlong=&sysvlong sysscp=&sysscp sysscpl=&sysscpl sysencoding=&sysencoding;
proc product_status; run;

data probe;
  infile "&csv" dsd firstobs=2 truncover;
  input id year grp stratum psu cat x1 x2 z w y ybin cnt;
run;
proc sort data=probe; by id year; run;
data probe_ts; set probe; run;   /* PANEL needs sorted cross-section/time */

/* ods output for a list of table names, each to work.p_<tag>_<name> */
%macro grab(tag, names);
  %local i n;
  ods output
  %do i = 1 %to %sysfunc(countw(&names));
    %let n = %scan(&names, &i);
    &n.(persist=proc)=p_&tag._&n
  %end;
  ;
%mend;
%let common = ModelInfo NObs Dimensions ClassLevels ResponseProfile ConvergenceStatus
  IterHistory FitStatistics ModelFit GlobalTests ANOVA OverallANOVA ModelANOVA
  ParameterEstimates CovB ACovEst InvXPX OddsRatios Type3 Tests3 Effects DataSummary
  DesignSummary StrataInfo ClusterInfo CovParms SolutionF SolutionR CovParmParms
  GEEModInfo GEEEmpPEst GEEModPEst GEERCov GEENCov GEEFitCriteria ModelDescription
  FixedEffectsTest FitStatistics2 VarianceComponents HausmanTest BreuschPaganTest
  CondFitStatistics Association;

ods trace on;

/* 1. OLS; weighted; heteroskedasticity-consistent (HC0/HC1) covariance */
%grab(reg, &common);
proc reg data=probe plots=none;
  model y = x1 x2 / covb hcc hccmethod=1;
run; quit;
%grab(regw, &common);
proc reg data=probe plots=none;
  weight w;
  model y = x1 x2 / covb;
run; quit;

/* 2. GLM with a class variable, and with the unit absorbed (one-way fixed effects) */
%grab(glm, &common);
proc glm data=probe plots=none;
  class cat;
  model y = cat x1 x2 / solution;
run; quit;
%grab(glmabs, &common);
proc glm data=probe plots=none;
  absorb id;
  model y = x1 x2 / solution;
run; quit;

/* 3. Cluster-robust OLS */
%grab(sreg, &common);
proc surveyreg data=probe;
  cluster grp;
  class cat;
  model y = cat x1 x2 / solution covb;
run;
/* survey design: strata, PSUs, weights */
%grab(sregd, &common);
proc surveyreg data=probe;
  strata stratum; cluster psu; weight w;
  model y = x1 x2 / solution covb;
run;

/* 4. Logit (models P(ybin=1)); and a survey logit */
%grab(logit, &common);
proc logistic data=probe;
  class cat / param=ref ref=first;
  model ybin(event='1') = cat x1 x2 / covb clparm=wald;
run;
%grab(slogit, &common);
proc surveylogistic data=probe;
  strata stratum; cluster psu; weight w;
  model ybin(event='1') = x1 x2 / covb;
run;

/* 5. GLMs: logit and Poisson; Poisson with cluster-robust (GEE independence) errors */
%grab(gmlogit, &common);
proc genmod data=probe;
  class cat / param=ref ref=first;
  model ybin(event='1') = cat x1 x2 / dist=binomial link=logit covb;
run;
%grab(gmpois, &common);
proc genmod data=probe;
  class grp;
  model cnt = x1 x2 / dist=poisson link=log covb;
  repeated subject=grp / type=ind covb;
run;

/* 6. Panel: two-way fixed effects, one-way random effects (SAS/ETS) */
%grab(pfe, &common);
proc panel data=probe_ts;
  id id year;
  model y = x1 x2 / fixtwo;
run;
%grab(pre, &common);
proc panel data=probe_ts;
  id id year;
  model y = x1 x2 / ranone;
run;

/* 7. IV: two-stage least squares (SAS/ETS) */
%grab(iv, &common);
proc syslin data=probe 2sls;
  endogenous x1;
  instruments z x2;
  model y = x1 x2;
run;

/* 8. Mixed: random intercept by unit (REML); logit random intercept (GLIMMIX) */
%grab(mixed, &common);
proc mixed data=probe method=reml;
  class id cat;
  model y = cat x1 x2 / solution covb ddfm=kr;
  random intercept / subject=id;
run;
%grab(glmix, &common);
proc glimmix data=probe method=laplace;
  class id;
  model ybin(event='1') = x1 x2 / dist=binary link=logit solution covb;
  random intercept / subject=id;
run;

ods trace off;
ods output close;

/* every p_ table: numbers at full precision (best32.), then CSV */
proc sql noprint;
  select memname into :tabs separated by ' ' from dictionary.tables
  where libname = 'WORK' and memname like 'P^_%' escape '^';
quit;
%macro export_all;
  %local i t;
  %do i = 1 %to %sysfunc(countw(&tabs));
    %let t = %scan(&tabs, &i);
    proc datasets lib=work nolist; modify &t; format _numeric_ best32.; quit;
    proc export data=work.&t outfile="&out/%lowcase(&t).csv" dbms=csv replace; run;
  %end;
%mend;
%export_all;
/* the tables' columns: names, labels, types, original formats */
proc contents data=work._all_ out=_cols(keep=memname name label type format formatl formatd varnum) noprint; run;
proc export data=_cols(where=(memname like 'P^_%' escape '^')) outfile="&out/_columns.csv" dbms=csv replace; run;

proc printto; run;
%put PROBE done: results in &out;
