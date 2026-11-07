{smcl}
{* *! version 0.1.0  07nov2026}{...}
{title:Title}

{phang}
{bf:estrec} {hline 2} Save Stata estimation results as estrec records (JSON)


{title:Syntax}

{p 8 16 2}
{cmd:estrec write using} {it:filename} [{cmd:,} {it:options}]

{synoptset 22}{...}
{synopthdr}
{synoptline}
{synopt:{opt replace}}overwrite {it:filename}{p_end}
{synopt:{opt lev:el(#)}}disclosure level, 1 to 5; default {cmd:level(4)}{p_end}
{synopt:{opt noident:ifying}}leave out user, host and the data file's path (written only at level 5){p_end}
{synopt:{opt nodatasig:nature}}skip the {helpb datasignature} checksum of the data in memory{p_end}
{synopt:{opt call(string)}}the command as you want it recorded; default {cmd:e(cmdline)}{p_end}
{synopt:{opt noestat}}don't run {cmd:estat}: {cmd:estat firststage}, {cmd:estat overid} and {cmd:estat endogenous} after {cmd:ivregress}, {cmd:estat gof} after {cmd:poisson}, {cmd:logit}, {cmd:logistic} and {cmd:probit}, {cmd:estat phtest} after {cmd:stcox}{p_end}
{synopt:{opt imp:utation(string)}}after {cmd:mi estimate}: how the data were imputed ({cmd:chained}, {cmd:mvn}, {cmd:monotone}, {cmd:regress}, ...), which Stata doesn't keep{p_end}
{synoptline}


{title:Description}

{pstd}
{cmd:estrec write} reads the results in {cmd:e()} and writes them as an
{it:estimation record}: a small JSON file with the estimates, standard errors and
p-values, the variance matrix and the small-sample correction behind it, the number of
observations and why rows were dropped, the model's tests, and the software that ran it.
Records written by Stata, R and Python can be compared side by side, so you can see why two
runs differ without rerunning either. Run it right after the estimation command.

{pstd}
The record claims the profiles of the format that fit the command:

{p2colset 9 36 38 2}{...}
{p2col:{cmd:regress}}inference{p_end}
{p2col:{cmd:areg}, {cmd:xtreg, fe}, {cmd:reghdfe}}inference, linear-fe{p_end}
{p2col:{cmd:xtreg, re}}inference{p_end}
{p2col:{cmd:ivregress}, {cmd:ivreg2}}inference, iv{p_end}
{p2col:{cmd:ivreghdfe}}inference, iv, linear-fe{p_end}
{p2col:{cmd:logit}, {cmd:logistic}, {cmd:probit}, {cmd:poisson}, {cmd:nbreg}}inference, glm{p_end}
{p2col:{cmd:glm}}inference, glm ({cmd:glm, irls}: inference only){p_end}
{p2col:{cmd:ppmlhdfe}}inference, glm, ppmlhdfe{p_end}
{p2col:{cmd:clogit}}inference, conditional-logit{p_end}
{p2col:{cmd:stcox}, {cmd:streg}}inference, survival{p_end}
{p2col:{cmd:mixed}, {cmd:melogit}, {cmd:mepoisson}, ...}mixed{p_end}
{p2colreset}{...}

{pstd}
Prefixes: after {cmd:svy:} the record claims inference and survey; after {cmd:bootstrap:} (or
{cmd:vce(bootstrap)}) it adds resampling to the command's profiles; after {cmd:mi estimate:} it
claims inference and, with {opt imputation()}, mi. Other prefixes ({cmd:jackknife:},
{cmd:permute:}, ...) aren't supported yet. Any other e-class command that posts {cmd:e(b)} and
{cmd:e(V)} gets a record with the core fields only.

{pstd}
Estimates are always on the estimation scale, as in {cmd:e(b)}: log-odds after
{cmd:logistic} and log hazards after {cmd:stcox}, not the ratios they display; log standard
deviations after {cmd:mixed}, as in {cmd:mixed, estmetric}. Tests and intervals are the ones
Stata's results table shows: a variance component Stata doesn't test gets none.


{title:Disclosure levels}

{pstd}
{opt level(1)} holds only the estimates, standard errors, p-values, intervals, N and df.
Level 2 adds the other statistics, the variance matrix and the tests; 3 the specification,
clusters and fixed-effect counts; 4 (the default) Stata, the estimation command and
{cmd:estrec} with their versions and the data's size and checksum; 5 the environment, the
data file's path, user and host.


{title:Examples}

{phang2}{cmd:. sysuse auto}{p_end}
{phang2}{cmd:. regress price mpg weight, vce(robust)}{p_end}
{phang2}{cmd:. estrec write using "price.estrec.json", replace}{p_end}

{phang2}{cmd:. ivregress 2sls price weight (mpg = length turn)}{p_end}
{phang2}{cmd:. estrec write using "iv.estrec.json", replace level(1)}{p_end}

{pstd}
To view records, open them in the record viewer at
{browse "https://estrec.org/viewer/"}
(files are read in the browser, not uploaded), or use the Python tool:
{cmd:estrec show price.estrec.json}.


{title:Remarks}

{pstd}
The record has no core digest (optional in the format), since computing it needs
canonical JSON; {cmd:estrec digest --write} {it:filename} adds it.
{cmd:estrec write} reads the UTC time from the operating system with {helpb shell}.


{title:Also see}

{pstd}
The format: {browse "https://github.com/estrec/estrec"}
