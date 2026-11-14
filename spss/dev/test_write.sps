* Encoding: UTF-8.
* estrec for SPSS: test of ESTREC WRITE (what the menu dialog runs). Install the new
* estrec.spe first, set the two paths, Run All, then copy the out folder's *.estrec.json and
* the Viewer exported as test_write.pdf (all items) to valiant raw/estrec_test/write/.

FILE HANDLE csv /NAME='/Users/you/Desktop/spss/writers_probe.csv'.
FILE HANDLE out /NAME='/Users/you/Desktop/spss/estrec_test/write'.

GET DATA /TYPE=TXT /FILE=csv /ENCODING='UTF8' /DELIMITERS=',' /QUALIFIER='"'
  /ARRANGEMENT=DELIMITED /FIRSTCASE=2
  /VARIABLES=id F8.0 year F8.0 grp F8.0 stratum F8.0 psu F8.0 cat F8.0
   x1 F12.6 x2 F12.6 z F12.6 w F12.6 y F12.6 ybin F8.0 cnt F8.0.
DATASET NAME probe WINDOW=FRONT.

* F: a model run the ordinary way (no ESTREC BEGIN), then ESTREC WRITE records it.
REGRESSION /STATISTICS COEFF OUTS CI(95) R ANOVA BCOV /DEPENDENT y /METHOD=ENTER x1 x2.
ESTREC WRITE OUTFILE='out/f_reg.estrec.json' TITLE='Recorded after the fact'.

* G: the last supported procedure, even with other output after it.
LOGISTIC REGRESSION VARIABLES ybin /METHOD=ENTER x1 x2 /PRINT=CI(95) CORR.
DESCRIPTIVES VARIABLES=y.
ESTREC WRITE OUTFILE='out/g_logit.estrec.json'.

* H: output in German: the Notes table is found anyway.
SET OLANG=GERMAN.
UNIANOVA y BY cat WITH x1 x2 /PRINT=PARAMETER /DESIGN=cat x1 x2.
ESTREC WRITE OUTFILE='out/h_unianova.estrec.json'.
SET OLANG=ENGLISH.

* Now try the same from the menus (after installing the dialog, if built): run a
* Regression from Analyze > Regression > Linear, then the Save estimation record item.
* If a WRITE finds nothing, its log lines in the Viewer say where it looked (journal, Viewer).
