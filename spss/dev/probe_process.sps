* Encoding: UTF-8.
* estrec for SPSS: probe of PROCESS (Hayes) output, to build the PROCESS writer against.
* 1. PROCESS must be installed (its custom dialog, or run process.sps once this session).
* 2. Set the two paths below (the out folder must exist), Run All. Takes a minute or two.
* 3. Copy the out folder (p_*.xml, t_*.xml, p_m4save_boot.csv) and the Viewer exported as probe_process.pdf
*    (all items) to valiant raw/estrec_probe_process/. Note your PROCESS version (first line
*    of its output).
* Each model is captured on its own with OMS (all output, as OXML), the way ESTREC BEGIN does.
* PROCESS v5.1 or later (the t_ runs use its display=tables option).

FILE HANDLE csv /NAME='/Users/you/Desktop/spss/writers_probe.csv'.
FILE HANDLE out /NAME='/Users/you/Desktop/spss/estrec_probe_process'.

GET DATA /TYPE=TXT /FILE=csv /ENCODING='UTF8' /DELIMITERS=',' /QUALIFIER='"'
  /ARRANGEMENT=DELIMITED /FIRSTCASE=2
  /VARIABLES=id F8.0 year F8.0 grp F8.0 stratum F8.0 psu F8.0 cat F8.0
   x1 F12.6 x2 F12.6 z F12.6 w F12.6 y F12.6 ybin F8.0 cnt F8.0.
DATASET NAME probe WINDOW=FRONT.
SET OLANG=ENGLISH.

* m4: simple mediation, defaults (5000 percentile bootstrap draws), with a seed.
OMS /SELECT ALL /DESTINATION FORMAT=OXML OUTFILE='out/p_m4.xml' VIEWER=YES /TAG='p'.
PROCESS y=y /x=x1 /m=x2 /model=4 /seed=20261114.
OMSEND TAG='p'.

* m4cov: covariate, effect sizes, total effect, normal-theory (Sobel) test, 1000 draws.
OMS /SELECT ALL /DESTINATION FORMAT=OXML OUTFILE='out/p_m4cov.xml' VIEWER=YES /TAG='p'.
PROCESS y=y /x=x1 /m=x2 /cov=w /model=4 /total=1 /effsize=1 /normal=1 /boot=1000
  /seed=20261114.
OMSEND TAG='p'.

* m4par: two parallel mediators, pairwise contrasts, HC3 errors, decimals to 8 places.
OMS /SELECT ALL /DESTINATION FORMAT=OXML OUTFILE='out/p_m4par.xml' VIEWER=YES /TAG='p'.
PROCESS y=y /x=x1 /m=x2 z /model=4 /contrast=1 /hc=3 /decimals=F12.8 /seed=20261114.
OMSEND TAG='p'.

* m6: serial mediation.
OMS /SELECT ALL /DESTINATION FORMAT=OXML OUTFILE='out/p_m6.xml' VIEWER=YES /TAG='p'.
PROCESS y=y /x=x1 /m=x2 z /model=6 /seed=20261114.
OMSEND TAG='p'.

* m1: moderation, with the conditional effects and the Johnson-Neyman region.
OMS /SELECT ALL /DESTINATION FORMAT=OXML OUTFILE='out/p_m1.xml' VIEWER=YES /TAG='p'.
PROCESS y=y /x=x1 /w=z /model=1 /jn=1 /center=1.
OMSEND TAG='p'.

* m7: moderated mediation (first stage): conditional indirect effects, index.
OMS /SELECT ALL /DESTINATION FORMAT=OXML OUTFILE='out/p_m7.xml' VIEWER=YES /TAG='p'.
PROCESS y=y /x=x1 /m=x2 /w=z /model=7 /seed=20261114.
OMSEND TAG='p'.

* m14: moderated mediation (second stage).
OMS /SELECT ALL /DESTINATION FORMAT=OXML OUTFILE='out/p_m14.xml' VIEWER=YES /TAG='p'.
PROCESS y=y /x=x1 /m=x2 /w=z /model=14 /seed=20261114.
OMSEND TAG='p'.

* m4bin: dichotomous outcome (PROCESS fits the Y model by logistic regression).
OMS /SELECT ALL /DESTINATION FORMAT=OXML OUTFILE='out/p_m4bin.xml' VIEWER=YES /TAG='p'.
PROCESS y=ybin /x=x1 /m=x2 /model=4 /seed=20261114.
OMSEND TAG='p'.

* m4mcx: multicategorical X (indicator coding) with the relative indirect effects.
OMS /SELECT ALL /DESTINATION FORMAT=OXML OUTFILE='out/p_m4mcx.xml' VIEWER=YES /TAG='p'.
PROCESS y=y /x=cat /m=x2 /mcx=1 /model=4 /seed=20261114.
OMSEND TAG='p'.

* m4save: bootstrap estimates saved to a new dataset (how a record could carry draws).
OMS /SELECT ALL /DESTINATION FORMAT=OXML OUTFILE='out/p_m4save.xml' VIEWER=YES /TAG='p'.
PROCESS y=y /x=x1 /m=x2 /model=4 /boot=1000 /save=1 /seed=20261114.
OMSEND TAG='p'.
DATASET NAME process_boot.
SAVE TRANSLATE OUTFILE='out/p_m4save_boot.csv' /TYPE=CSV /ENCODING='UTF8' /FIELDNAMES /REPLACE.
DATASET ACTIVATE probe.

* The same models with display=tables (PROCESS 5): which sections become pivot tables,
* whose OXML carries numbers at full precision rather than the printed decimals.
OMS /SELECT ALL /DESTINATION FORMAT=OXML OUTFILE='out/t_m4cov.xml' VIEWER=YES /TAG='p'.
PROCESS y=y /x=x1 /m=x2 /cov=w /model=4 /total=1 /effsize=1 /normal=1 /boot=1000
  /seed=20261114 /display=tables.
OMSEND TAG='p'.
OMS /SELECT ALL /DESTINATION FORMAT=OXML OUTFILE='out/t_m7.xml' VIEWER=YES /TAG='p'.
PROCESS y=y /x=x1 /m=x2 /w=z /model=7 /seed=20261114 /display=tables.
OMSEND TAG='p'.
OMS /SELECT ALL /DESTINATION FORMAT=OXML OUTFILE='out/t_m1.xml' VIEWER=YES /TAG='p'.
PROCESS y=y /x=x1 /w=z /model=1 /jn=1 /center=1 /display=tables.
OMSEND TAG='p'.
