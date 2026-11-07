*! version 0.1.0  estrec: Stata estimation results as estimation records
*
* estrec write using FILE [, replace level(#) noidentifying nodatasignature call() noestat]
*
* Run it right after an estimation command. It reads e() and writes one record (JSON)
* claiming the profiles the command fits:
*
*   regress                         inference/0.1
*   areg, xtreg fe, reghdfe         inference/0.1, linear-fe/0.1
*   xtreg re                        inference/0.1
*   ivregress, ivreg2               inference/0.1, iv/0.1
*   ivreghdfe                       inference/0.1, iv/0.1, linear-fe/0.1
*   logit, logistic, probit,        inference/0.1, glm/0.1
*     poisson, nbreg
*   glm                             inference/0.1, glm/0.1 (glm, irls: inference/0.1 only)
*   ppmlhdfe                        inference/0.1, glm/0.1, ppmlhdfe/0.1
*   clogit                          inference/0.1, conditional-logit/0.1
*   stcox, streg                    inference/0.1, survival/0.1
*   mixed, me* (meglm)              inference/0.1, mixed/0.1
*
* Prefixes: svy: claims inference/0.1 and survey/0.1; bootstrap: (and vce(bootstrap)) adds
* resampling/0.1 to the command's profiles; mi estimate: claims inference/0.1 and mi/0.1.
* Any other e-class command with e(b) and e(V) gets a core record with no profile claims.
*
* Options:
*   replace          overwrite the file
*   level(#)         disclosure level, 1-5 (spec 4.9; default 4)
*   noidentifying    leave out user, host and the data file's path (level 5 only)
*   nodatasignature  skip the in-memory data checksum (datasignature)
*   call(string)     the command as written (default: e(cmdline))
*   noestat          don't run estat (firststage/overid/endogenous after ivregress, gof after
*                    poisson, logit, logistic, probit, phtest after stcox)
*   imputation(str)  after mi estimate: how the data were imputed (chained, mvn, monotone, ...),
*                    which Stata doesn't keep (mi/0.1 expects it)
*
* The record has no core digest (meta.core_digest is optional): computing it needs RFC 8785
* canonical JSON. Add it with the reference tool: `estrec digest --write FILE`.

program define estrec
	version 16
	gettoken sub 0 : 0, parse(" ,")
	if `"`sub'"' == "write" {
		_estrec_write `0'
	}
	else if `"`sub'"' == "" | `"`sub'"' == "version" {
		di as txt "estrec 0.1.0"
	}
	else {
		di as err `"estrec: unknown subcommand {bf:`sub'}; use {bf:estrec write using} {it:file}"'
		exit 199
	}
end

program define _estrec_write
	version 16
	syntax using/ [, REPLACE noIDENTifying noDATASIGnature CALL(string asis) LEVel(integer 4) noESTat IMPutation(string)]
	if `level' < 1 | `level' > 5 {
		di as err "estrec write: level() must be 1 to 5"
		exit 198
	}
	if "`e(cmd)'" == "" {
		di as err "estrec write: no estimation results; run an estimation command first"
		exit 301
	}
	* Prefixes: svy, bootstrap (also vce(bootstrap)) and mi estimate (e(mi), not e(prefix))
	local prefix "`e(prefix)'"
	if "`e(mi)'" == "mi" local prefix mi
	if !inlist("`prefix'", "", "svy", "bootstrap", "mi") {
		di as err "estrec write: results from the `prefix' prefix aren't supported yet"
		exit 198
	}
	* mi estimate keeps the pooled results in e(b_mi), e(V_mi) (in e(b), e(V) too with post)
	local bm = cond("`prefix'" == "mi", "b_mi", "b")
	local vm = cond("`prefix'" == "mi", "V_mi", "V")
	capture confirm matrix e(`bm')
	local rc = _rc
	capture confirm matrix e(`vm')
	if `rc' | _rc {
		di as err "estrec write: `e(cmd)' posted no e(`bm') and e(`vm')"
		exit 301
	}
	if "`prefix'" == "mi" & `"`call'"' == "" local call `"`e(cmdline_mi)'"'
	if `"`call'"' == "" local call `"`e(cmdline)'"'

	* Which mapping applies: the command inside a prefix
	local cmd `e(cmd)'
	if "`prefix'" == "mi" local cmd `e(cmd_mi)'
	if "`cmd'" == "regress" local kind regress
	else if "`cmd'" == "areg" local kind areg
	else if "`cmd'" == "xtreg" & inlist("`e(model)'", "fe", "re") local kind xtreg_`e(model)'
	else if "`cmd'" == "reghdfe" & "`e(model)'" == "ols" local kind reghdfe
	else if "`cmd'" == "ivregress" local kind ivregress
	else if inlist("`cmd'", "ivreg2", "ivreghdfe") local kind `cmd'
	else if inlist("`cmd'", "logit", "logistic", "probit", "poisson", "nbreg") local kind ml
	else if "`cmd'" == "glm" local kind glm
	else if "`cmd'" == "ppmlhdfe" local kind ppmlhdfe
	else if "`cmd'" == "clogit" local kind clogit
	else if "`cmd'" == "cox" & "`e(cmd2)'" == "stcox" local kind stcox
	else if "`e(cmd2)'" == "streg" & inlist("`cmd'", "ereg", "weibull", "gompertz", "lnormal", "llogistic", "gamma") local kind streg
	else if "`cmd'" == "mixed" local kind mixed
	else if "`cmd'" == "meglm" local kind meglm
	else local kind generic
	* The command as typed (stcox stores e(cmd) cox, streg the distribution, melogit meglm)
	local vcmd `cmd'
	if inlist("`kind'", "stcox", "streg", "meglm") local vcmd `e(cmd2)'

	* The data as the user has it, before any temporary variable is added
	local nvars = c(k)
	local rows_input = c(N)
	if "`datasignature'" == "" {
		quietly datasignature
		local datasig "`r(datasignature)'"
	}

	* Rows dropped for missing values: the model's variables, marked out over the whole data
	local names `e(depvar)' `e(absvars)' `e(absvar)' `e(clustvar)' `e(ivar)' `e(instd)' `e(insts)' `e(exog)' `e(endog)'
	local names `names' `e(group)' `e(ivars)' `e(wvar)' `e(su1)' `e(strata1)' `e(cluster)'
	local cols : colnames e(`bm')
	local cols = subinstr(`"`cols'"', "#", " ", .)
	foreach t of local cols {
		local names `names' `=ustrregexra("`t'", "^.*\.", "")'
	}
	local wvar = trim(subinstr("`e(wexp)'", "=", "", 1))
	local ovar = ustrregexra("`e(offset)'", "^ln\((.*)\)$", "$1")
	local names `names' `wvar' `ovar'
	local vars
	foreach t of local names {
		capture confirm variable `t', exact
		if !_rc local vars `vars' `t'
	}
	local vars : list uniq vars
	* stset's variables are missing outside the st sample, which isn't a missing value of the data
	local stvars _t _t0 _d _st
	local vars : list vars - stvars
	tempvar touse
	quietly generate byte `touse' = 1
	if "`vars'" != "" markout `touse' `vars', strok
	quietly count if `touse'
	local n_complete = r(N)
	drop `touse'
	capture quietly count if e(sample)
	local n_used = cond(_rc | r(N) == 0, ., r(N))

	* Versions from the first line of each package's ado file
	foreach p in `vcmd' ftools ranktest ivreg2 reghdfe {
		local ver_`p'
		capture findfile `p'.ado
		if !_rc {
			tempname fh
			file open `fh' using `"`r(fn)'"', read text
			file read `fh' line
			file close `fh'
			if ustrregexm(`"`line'"', "([0-9]+\.[0-9]+(\.[0-9]+)*)") local ver_`p' = ustrregexs(1)
		}
	}
	local ver_cmd `ver_`vcmd''

	* UTC time from the OS (Stata has none)
	tempfile clock
	if c(os) == "Windows" {
		quietly shell powershell -NoProfile -Command "[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')" > "`clock'"
	}
	else {
		quietly shell date -u +%Y-%m-%dT%H:%M:%SZ > "`clock'"
	}
	local created
	capture {
		tempname fh
		file open `fh' using "`clock'", read text
		file read `fh' created
		file close `fh'
	}
	local created = trim(`"`created'"')
	if !ustrregexm(`"`created'"', "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") {
		di as err "estrec write: couldn't read the UTC time from the operating system"
		exit 198
	}

	local doestat = "`estat'" == ""
	local ident = "`identifying'" == ""
	local tis : char _dta[tis]
	local iis : char _dta[iis]
	mata: _er_write(`"`using'"', "`replace'" != "", `level')
	di as txt `"estimation record written to {browse "`using'"}"'
end


version 16
mata:
mata set matastrict on

// ---- JSON --------------------------------------------------------------------------

string scalar _ej_s(string scalar s)
{
	string scalar r
	real scalar i
	r = subinstr(s, "\", "\\")
	r = subinstr(r, `"""', `"\""')
	r = subinstr(r, char(10), "\n")
	r = subinstr(r, char(13), "\r")
	r = subinstr(r, char(9), "\t")
	for (i = 1; i < 32; i++) {
		if (i != 9 & i != 10 & i != 13) r = subinstr(r, char(i), "\u00" + (i < 16 ? "0" : "") + inbase(16, i))
	}
	return(`"""' + r + `"""')
}

// JSON number; Stata missing -> null. 17 significant digits round-trip a double
string scalar _ej_n(real scalar x)
{
	string scalar r
	if (missing(x)) return("null")
	if (x == trunc(x) & abs(x) < 1e15) return(strtrim(sprintf("%20.0f", x)))
	r = strtrim(sprintf("%24.17g", x))
	if (substr(r, 1, 1) == ".") r = "0" + r
	if (substr(r, 1, 2) == "-.") r = "-0" + substr(r, 2, .)
	return(r)
}

// A number, or "" (left out) when missing
string scalar _ej_nx(real scalar x)
{
	return(missing(x) ? "" : _ej_n(x))
}

string scalar _ej_b(real scalar x)
{
	return(x ? "true" : "false")
}

string scalar _ej_sa(string vector v)
{
	string scalar r
	real scalar i
	r = "["
	for (i = 1; i <= length(v); i++) r = r + (i > 1 ? ", " : "") + _ej_s(v[i])
	return(r + "]")
}

string scalar _ej_na(real vector v)
{
	string scalar r
	real scalar i
	r = "["
	for (i = 1; i <= length(v); i++) r = r + (i > 1 ? ", " : "") + _ej_n(v[i])
	return(r + "]")
}

// [a, b, ...] of already-encoded values; "" when empty
string scalar _ej_l(string vector v)
{
	return(length(v) ? "[" + invtokens(v, ", ") + "]" : "")
}

// {"k": v, ...}; entries whose value is "" are left out
string scalar _ej_o(string vector k, string vector v)
{
	string scalar r
	real scalar i, n
	r = "{"
	n = 0
	for (i = 1; i <= length(k); i++) {
		if (v[i] == "") continue
		r = r + (n++ ? ", " : "") + _ej_s(k[i]) + ": " + v[i]
	}
	return(r + "}")
}

// {value, definition}
string scalar _ej_def(string scalar v, string scalar definition)
{
	if (v == "" | definition == "") return(v)
	return(_ej_o(("value", "definition"), (v, _ej_s(definition))))
}

// An object built field by field, each field with its disclosure level (spec 4.9)
struct erobj {
	string rowvector k, v
	real rowvector l
}

struct erobj scalar _on()
{
	struct erobj scalar o
	o.k = J(1, 0, "")
	o.v = J(1, 0, "")
	o.l = J(1, 0, .)
	return(o)
}

void _oa(struct erobj scalar o, string scalar key, string scalar val, real scalar lvl)
{
	if (val == "") return
	o.k = o.k, key
	o.v = o.v, val
	o.l = o.l, lvl
}

// The fields at or below level lv; "" when none is left
string scalar _or(struct erobj scalar o, real scalar lv)
{
	string scalar r
	real scalar i, n
	r = "{"
	n = 0
	for (i = 1; i <= length(o.k); i++) {
		if (o.l[i] > lv) continue
		r = r + (n++ ? ", " : "") + _ej_s(o.k[i]) + ": " + o.v[i]
	}
	return(n ? r + "}" : "")
}

// ---- e() ---------------------------------------------------------------------------

// A scalar, or missing when it isn't set (st_numscalar returns 0 x 0 then)
real scalar _sc(string scalar name)
{
	real matrix x
	x = st_numscalar(name)
	return(rows(x) ? x : .)
}

real scalar _e(string scalar name)
{
	return(_sc("e(" + name + ")"))
}

string scalar _en(string scalar name)
{
	return(_ej_nx(_e(name)))
}

string scalar _eg(string scalar name)
{
	return(st_global("e(" + name + ")"))
}

real scalar _isin(string scalar s, string vector set)
{
	return(anyof(set, s))
}

// One Stata column name -> canonical JSON and the dropped reason ("" when kept)
void _er_term(string scalar term, string scalar canon, string scalar dropped)
{
	string vector parts
	string rowvector factors
	string scalar p, var, level, flags, name
	real scalar i, nlev, ncont

	dropped = ""
	if (term == "_cons") {
		canon = `"{"name": "(Intercept)", "factors": []}"'
		return
	}
	parts = tokens(term, "#")
	parts = select(parts, parts :!= "#")
	factors = J(1, 0, "")
	name = ""
	nlev = ncont = 0
	for (i = 1; i <= length(parts); i++) {
		p = parts[i]
		if (regexm(p, "^([0-9]+)([a-z]*)\.(.+)$")) {
			level = regexs(1); flags = regexs(2); var = regexs(3)
			if (strpos(flags, "b")) dropped = "reference"
			if (strpos(flags, "o")) dropped = "collinear"
			factors = factors, _ej_o(("variable", "level"), (_ej_s(var), _ej_s(level)))
			name = name + (i > 1 ? "#" : "") + level + "." + var
			nlev++
		}
		else {
			if (regexm(p, "^([a-z]*)\.(.+)$")) {
				flags = regexs(1); var = regexs(2)
				if (strpos(flags, "o")) dropped = "collinear"
			}
			else var = p
			factors = factors, _ej_o("variable", _ej_s(var))
			name = name + (i > 1 ? "#" : "") + "c." + var
			ncont++
		}
	}
	// R form except factor x continuous, which keeps Stata's form (spec 4.4.1)
	if (!(nlev & ncont)) {
		name = ""
		for (i = 1; i <= length(parts); i++) {
			p = parts[i]
			if (regexm(p, "^([0-9]+)[a-z]*\.(.+)$")) name = name + (i > 1 ? ":" : "") + regexs(2) + regexs(1)
			else if (regexm(p, "^[a-z]*\.(.+)$")) name = name + (i > 1 ? ":" : "") + regexs(1)
			else name = name + (i > 1 ? ":" : "") + p
		}
	}
	canon = _ej_o(("name", "factors"), (_ej_s(name), "[" + invtokens(factors, ", ") + "]"))
}

// ---- tests -------------------------------------------------------------------------

struct ertests {
	string rowvector t
	real scalar n
}

// One test: name, category, statistic, distribution ("F", "chi2", "chibar2" or ""), df1, df2, p
void _ta(struct ertests scalar T, string scalar category, string scalar name, real scalar stat,
	string scalar dist, real scalar df1, real scalar df2, real scalar p, string scalar origin,
	string scalar response, string scalar label, string scalar source)
{
	_tae(T, category, name, stat, dist, df1, df2, p, origin, response, label, source, J(1, 0, ""), J(1, 0, ""))
}

// The same, with more fields (already encoded): terms, options, ...
void _tae(struct ertests scalar T, string scalar category, string scalar name, real scalar stat,
	string scalar dist, real scalar df1, real scalar df2, real scalar p, string scalar origin,
	string scalar response, string scalar label, string scalar source, string rowvector xk, string rowvector xv)
{
	string rowvector k, v
	if (missing(stat) & missing(p)) return
	T.n = T.n + 1
	k = ("id", "category", "name", "origin", "response", "label", "statistic", "distribution")
	v = (_ej_s("t" + strofreal(T.n)), _ej_s(category), _ej_s(name), _ej_s(origin),
		(response != "" ? _ej_s(response) : ""), (label != "" ? _ej_s(label) : ""),
		_ej_nx(stat), (dist != "" & !missing(stat) ? _ej_s(dist) : ""))
	if (dist == "F") {
		k = k, ("df1", "df2")
		v = v, (_ej_nx(df1), _ej_nx(df2))
	}
	else if (dist == "chi2" | dist == "chibar2") {
		k = k, "df"
		v = v, _ej_nx(df1)
	}
	k = k, ("p_value", "source"), xk
	v = v, (_ej_nx(p), source), xv
	T.t = T.t, _ej_o(k, v)
}

// ---- the record --------------------------------------------------------------------

void _er_write(string scalar fn, real scalar replace, real scalar lv)
{
	string scalar cmd, kind, wver, vce, vtype, wtype, wvar, conv, formula, kcounts, dfdef
	string scalar canon, dropped, term, eq, eq1, created, nl, rec, depvar, s, ver_cmd, src
	string matrix cs, rs
	string rowvector clusters, absvars, params, vrows, fe, software, sections, endog, insts, exogr
	string rowvector profiles, messages, perendog, rn, cn, fcn, vcovs, histk, histv
	real matrix b, V, dof, M, Vm
	real scalar N, nobs, dfr, dft, small, linear, ml, iv, ncl, i, j, k, se, t, crit, level, lvconf
	real scalar nsing, rows_input, n_complete, n_used, n_missing, n_other, conv_ok, fh, ident, rank
	real scalar doestat, dev, alpha, rc, isiid, haveabs, fw, gofd, gofp, gofdf, gofpd, gofpp
	struct erobj scalar meta, metrics, spec, sample, structures, prov, est, vc, opts, num, vm
	struct ertests scalar T
	string scalar prefix, vcmd, mimethod
	real matrix RT, dfmi
	real scalar svy, bs, mi, mlx, mixedk, survk, dfrow, crow, nsep, inf, kr
	real matrix Vraw, dfv
	string scalar rgroup, rvc
	string rowvector rk, rx
	string matrix reqs

	cmd = st_local("cmd")       // the command, inside any prefix
	vcmd = st_local("vcmd")     // as typed (stcox, streg, melogit)
	kind = st_local("kind")
	prefix = st_local("prefix")
	mimethod = strlower(strtrim(st_local("imputation")))
	svy = prefix == "svy"
	bs = prefix == "bootstrap"
	mi = prefix == "mi"
	wver = "0.1.0"
	ver_cmd = st_local("ver_cmd")
	ident = strtoreal(st_local("ident"))
	doestat = strtoreal(st_local("doestat")) & prefix == ""
	created = st_local("created")
	rows_input = strtoreal(st_local("rows_input"))
	n_complete = strtoreal(st_local("n_complete"))
	n_used = strtoreal(st_local("n_used"))
	depvar = _eg("depvar")

	b = st_matrix("e(" + st_local("bm") + ")")
	V = st_matrix("e(" + st_local("vm") + ")")
	cs = st_matrixcolstripe("e(" + st_local("bm") + ")")
	N = mi ? _e("N_mi") : _e("N")
	// mi estimate leaves the complete-data e(df_r) (or none); its tests use each row's e(df_mi)
	dfr = mi ? . : _e("df_r")
	rank = _e("rank")
	if (missing(rank) & !mi) rank = sum(diagonal(V) :!= 0)
	level = mi & !missing(_e("cilevel_mi")) ? _e("cilevel_mi") : c("level")
	dfmi = mi ? st_matrix("e(df_mi)") : J(0, 0, .)
	// mixed, dfmethod(kroger): Stata's table uses the adjusted e(V_df); e(V) is the unadjusted one
	Vraw = st_matrix("e(V_df)")
	kr = kind == "mixed" & rows(Vraw) == rows(V)
	if (kr) {
		Vraw = V
		V = st_matrix("e(V_df)")
	}
	wtype = _eg("wtype")
	wvar = strtrim(subinstr(_eg("wexp"), "=", "", 1))
	fw = wtype == "fweight"
	nobs = N    // as Stata reports it; with fweights e(N) is the sum of the weights (Ted, 2026-11-07)

	linear = _isin(kind, ("regress", "areg", "xtreg_fe", "xtreg_re", "reghdfe", "ivregress", "ivreg2", "ivreghdfe"))
	ml = _isin(kind, ("ml", "glm", "ppmlhdfe"))
	mixedk = _isin(kind, ("mixed", "meglm"))
	survk = _isin(kind, ("stcox", "streg"))
	// likelihood fits: z tests, oim, ML robust and cluster adjustments
	mlx = ml | mixedk | survk | kind == "clogit"
	endog = tokens(kind == "ivregress" ? _eg("endog") : _eg("instd"))
	iv = length(endog) > 0
	if (kind == "ivregress") {
		exogr = tokens(_eg("exogr"))
		insts = tokens(_eg("exog"))
		insts = length(exogr) ? select(insts, !_er_in(insts, exogr)) : insts
	}
	else insts = tokens(_eg("exexog"))
	absvars = tokens(kind == "areg" ? _eg("absvar") : (kind == "xtreg_fe" ? _eg("ivar") : _eg("absvars")))
	haveabs = length(absvars) > 0
	if (kind == "ivregress") small = _eg("small") == "small"
	else if (_isin(kind, ("regress", "areg", "xtreg_fe", "reghdfe"))) small = 1
	else if (_isin(kind, ("ivreg2", "ivreghdfe"))) small = !missing(dfr)
	else if (kind == "xtreg_re" | mlx) small = 0
	else small = !missing(dfr)
	dft = small ? dfr : .
	if (kind == "glm" | kind == "generic") dft = dfr
	// svy: t tests on the design df, for every command; bootstrap: z tests; mi: per-row df
	if (svy) dft = dfr
	if (bs | mi) dft = .

	// ---- vcov ----
	vce = strlower(mi ? _eg("wvce_mi") : _eg("vce"))
	clusters = tokens(_eg("clustvar"))
	// clogit's vce(robust) clusters on the groups (its footnote says so, and it equals
	// vce(cluster group)); Stata posts no e(clustvar) or e(N_clust) for it
	if (kind == "clogit" & vce == "robust") clusters = tokens(_eg("group"))
	if (svy | bs) clusters = J(1, 0, "")
	ncl = length(clusters)
	if (svy | bs) vtype = vce
	else if (ncl == 2) vtype = "twoway"
	else if (ncl > 2) vtype = "multiway"
	else if (ncl == 1) vtype = "CRV1"
	else if (_eg("kernel") != "") vtype = "HAC"
	else if (vce == "hc2") vtype = "HC2"
	else if (vce == "hc3") vtype = "HC3"
	else if (_isin(vce, ("oim", "opg", "eim"))) vtype = vce
	else if (strpos(vce, "robust")) vtype = kind == "generic" ? "robust" : ((linear & small) ? "HC1" : "HC0")
	else if (_isin(vce, ("", "ols", "unadjusted", "conventional"))) vtype = linear | kind == "generic" ? "iid" : "oim"
	else vtype = vce
	if (kr) vtype = "kenward_roger"
	isiid = vtype == "iid"

	_er_ssc(conv, formula, kcounts, kind, cmd, vtype, small, haveabs, linear, mlx, mixedk, svy, bs, mi, isiid)

	vrows = J(1, rows(V), "")
	for (i = 1; i <= rows(V); i++) vrows[i] = _ej_na(V[i, .])
	params = J(1, 0, "")
	cn = J(1, cols(b), "")
	eq1 = cs[1, 1]
	for (j = 1; j <= cols(b); j++) {
		eq = cs[j, 1]
		term = cs[j, 2]
		if (eq == "/") term = "/" + term
		else if (kind == "mixed" & eq != eq1) term = eq + ":" + term    // lns1_1_1:_cons, as _b[] names it
		cn[j] = term
	}

	vc = _on()
	_oa(vc, "kind", _ej_s("matrix"), 2)
	_oa(vc, "labels", _ej_sa(cn), 2)
	_oa(vc, "data", "[" + invtokens(vrows, ", ") + "]", 2)
	_oa(vc, "type", _ej_s(vtype), 2)
	_oa(vc, "tool_type", (vtype != vce & vce != "" ? _ej_s(vce) : ""), 2)
	_oa(vc, "cluster", (ncl ? _ej_sa(clusters) : ""), 3)
	if (ncl) {
		rn = J(1, ncl, "")
		for (i = 1; i <= ncl; i++) rn[i] = _ej_nx(ncl == 1 ? _e("N_clust") : _e(sprintf("N_clust%g", i)))
		if (any(rn :!= "")) _oa(vc, "n_clusters", _ej_o(clusters, rn), 3)
		_oa(vc, "n_clusters_min", _en("N_clust"), 3)
	}
	_oa(vc, "ssc", _ej_o(("convention", "formula", "K_counts", "factors"), (_ej_s(conv),
		(formula != "" ? _ej_s(formula) : ""), (kcounts != "" ? _ej_s(kcounts) : ""),
		(kind == "reghdfe" | (kind == "ivreghdfe" & haveabs) ? _ej_o(("dofmethod", "df_a", "df_a_nested", "df_a_redundant"),
			(_ej_s(_eg("dofmethod")), _en("df_a"), _en("df_a_nested"), _en("df_a_redundant"))) : ""))), 2)
	_oa(vc, "df_t", _ej_n(dft), 2)
	_oa(vc, "default", "true", 2)
	vcovs = _or(vc, lv)

	// mixed with Kenward-Roger: the unadjusted e(V) beside the adjusted default
	if (kr) {
		for (i = 1; i <= rows(Vraw); i++) vrows[i] = _ej_na(Vraw[i, .])
		vm = _on()
		_oa(vm, "kind", _ej_s("matrix"), 2)
		_oa(vm, "labels", _ej_sa(cn), 2)
		_oa(vm, "data", "[" + invtokens(vrows, ", ") + "]", 2)
		_oa(vm, "type", _ej_s("oim"), 2)
		_oa(vm, "tool_type", _ej_s("V"), 2)
		_oa(vm, "ssc", _ej_o(("convention", "formula"), (_ej_s("stata"), _ej_s("none"))), 2)
		_oa(vm, "df_t", "null", 2)
		_oa(vm, "default", "false", 2)
		vcovs = vcovs, _or(vm, lv)
	}

	// The model-based vcov kept beside a robust or cluster one
	Vm = st_matrix("e(V_modelbased)")
	if (rows(Vm) == rows(V) & (kind == "regress" | ml | kind == "clogit" | survk) & !svy & !mi) {
		for (i = 1; i <= rows(Vm); i++) vrows[i] = _ej_na(Vm[i, .])
		vm = _on()
		_oa(vm, "kind", _ej_s("matrix"), 2)
		_oa(vm, "labels", _ej_sa(cn), 2)
		_oa(vm, "data", "[" + invtokens(vrows, ", ") + "]", 2)
		_oa(vm, "type", _ej_s(kind == "regress" ? "iid" : ((kind == "glm" & _eg("opt") == "irls") ? "eim" : "oim")), 2)
		_oa(vm, "tool_type", _ej_s("V_modelbased"), 2)
		_oa(vm, "ssc", _ej_o(("convention", "formula", "K_counts"), (_ej_s(bs ? "stata" : conv),
			_ej_s(kind == "regress" ? "s2 = RSS/(N-K)" : "none"), (kind == "regress" ? _ej_s("K = rank") : ""))), 2)
		_oa(vm, "df_t", _ej_n(kind == "regress" ? N - rank : .), 2)
		_oa(vm, "default", "false", 2)
		vcovs = vcovs, _or(vm, lv)
	}

	// ---- parameters (from the default vcov; t with df_t, else z) ----
	// mixed and me*: the variance components as Stata's table reports them, from a replay
	// (mixed in its estimation metric, the metric of e(b)); a replay leaves e() as it is
	RT = J(0, 0, .)
	if (mixedk) {
		if (!_stata(kind == "mixed" ? "quietly mixed, estmetric" : "quietly meglm", 1)) RT = st_matrix("r(table)")
		if (cols(RT) != cols(b) | rows(RT) < 7) RT = J(0, 0, .)
	}
	// per-row df: mi estimate's e(df_mi); mixed's e(df) with dfmethod() (a replay drops it, so
	// the fixed effects' tests come from e(df) and the vcov, e(V_df) with Kenward-Roger)
	dfv = mi ? dfmi : (kind == "mixed" & _eg("dfmethod") != "" ? st_matrix("e(df)") : J(0, 0, .))
	if (mixedk) _er_reqs(reqs, kind, cs, eq1)
	crit = missing(dft) ? invnormal(1 - (1 - level / 100) / 2) : invttail(dft, (1 - level / 100) / 2)
	for (j = 1; j <= cols(b); j++) {
		eq = cs[j, 1]
		term = cn[j]
		canon = dropped = rgroup = rvc = ""
		if (mixedk) _er_vcrow(reqs, kind, eq, cs[j, 2], eq1, rgroup, rvc)
		if (eq != "/" & rvc == "") _er_term(cs[j, 2], canon, dropped)
		s = rvc != "" ? _ej_s("random") : (eq == "/" ? _ej_s("auxiliary") : ((eq != eq1 & eq != "") ? _ej_s(eq) : ""))
		if (dropped != "") {
			params = params, _ej_o(("term", "canonical", "component", "dropped"), (_ej_s(term), canon, s, _ej_s(dropped)))
			continue
		}
		se = sqrt(V[j, j])
		t = b[j] / se
		// Unmapped commands: Stata tests no ancillary parameter of theirs we can't vouch for
		if (kind == "generic" & eq == "/") {
			params = params, _ej_o(("term", "component", "estimate", "std_error"), (_ej_s(term), s, _ej_n(b[j]), _ej_n(se)))
			continue
		}
		rk = ("term", "canonical", "component", "group", "vc", "estimate", "std_error")
		rx = (_ej_s(term), canon, s, (rgroup != "" ? _ej_s(rgroup) : ""), rvc, _ej_n(b[j]), _ej_n(se))
		if (rvc != "" & rows(RT)) {
			// as Stata's table has them: no test or interval where it shows none
			rk = rk, ("statistic", "p_value", "conf_low", "conf_high")
			rx = rx, (_ej_nx(RT[3, j]), _ej_nx(RT[4, j]), _ej_nx(RT[5, j]), _ej_nx(RT[6, j]))
		}
		else if (mixedk & rvc != "") {
			// no table to read: estimate and standard error only
		}
		else if (cmd == "nbreg" & eq == "/") {
			// nbreg shows an interval for /lnalpha but no test
			rk = rk, ("conf_low", "conf_high")
			rx = rx, (_ej_n(b[j] - crit * se), _ej_n(b[j] + crit * se))
		}
		else {
			dfrow = cols(dfv) >= j ? dfv[j] : dft
			crow = cols(dfv) >= j ? invttail(dfrow, (1 - level / 100) / 2) : crit
			rk = rk, ("statistic", "p_value", "conf_low", "conf_high", "df")
			rx = rx, (_ej_n(t), _ej_n(missing(dfrow) ? 2 * normal(-abs(t)) : 2 * ttail(dfrow, abs(t))),
				_ej_n(b[j] - crow * se), _ej_n(b[j] + crow * se), (cols(dfv) >= j ? _ej_nx(dfrow) : ""))
		}
		if (mi) {
			rk = rk, "mi"
			rx = rx, _ej_o(("ubar", "b", "riv", "fmi", "df", "relative_efficiency"),
				(_ej_nx(_er_at("e(W_mi)", j, j)), _ej_nx(_er_at("e(B_mi)", j, j)), _ej_nx(_er_at("e(rvi_mi)", 1, j)),
				 _ej_nx(_er_at("e(fmi_mi)", 1, j)), _ej_nx(dfmi[j]), _ej_nx(_er_at("e(re_mi)", 1, j))))
		}
		if (bs) {
			rk = rk, "resampling"
			rx = rx, _ej_o(("std_error", "mean", "bias", "reps", "statistic", "p_value", "conf_low", "conf_high", "intervals"),
				(_ej_nx(_er_at("e(se)", 1, j)), _ej_nx(_er_at("e(b_bs)", 1, j)), _ej_nx(_er_at("e(bias)", 1, j)),
				 _ej_nx(_er_at("e(reps)", 1, j)), _ej_n(t), _ej_n(2 * normal(-abs(t))),
				 _ej_nx(_er_at("e(ci_normal)", 1, j)), _ej_nx(_er_at("e(ci_normal)", 2, j)),
				 _ej_o(("normal", "percentile", "bias_corrected", "bca"), (_er_ci("e(ci_normal)", j),
					_er_ci("e(ci_percentile)", j), _er_ci("e(ci_bc)", j), _er_ci("e(ci_bca)", j)))))
		}
		params = params, _ej_o(rk, rx)
	}

	// ---- convergence ----
	conv_ok = _e("converged")
	messages = J(1, 0, "")
	if (kind == "glm" & _eg("opt") == "irls") messages = messages, _ej_o(("level", "code", "source", "message"),
		(_ej_s("info"), _ej_s("convergence_unknown"), _ej_s("estrec"), _ej_s("glm, irls doesn't store whether it converged, so the record doesn't claim glm/0.1")))
	if (conv_ok == 0) messages = messages, _ej_o(("level", "code", "source", "message"),
		(_ej_s("warning"), _ej_s("not_converged"), _ej_s(cmd), _ej_s("convergence not achieved")))

	// ---- metrics ----
	gofd = gofp = gofdf = gofpd = gofpp = .
	if (ml & cmd == "poisson" & doestat) {
		if (!_stata("quietly estat gof", 1)) {
			gofd = _sc("r(chi2_d)"); gofp = _sc("r(chi2_p)"); gofdf = _sc("r(df)")
			gofpd = _sc("r(p_d)"); gofpp = _sc("r(p_p)")
		}
	}
	nsing = _isin(kind, ("reghdfe", "ivreghdfe", "ppmlhdfe")) ? _e("num_singletons") : (_isin(kind, ("areg", "xtreg_fe")) ? 0 : .)
	metrics = _on()
	_oa(metrics, "nobs", _ej_def(_ej_n(nobs), fw ? "Stata e(N): with frequency weights each row counts as its weight's number of observations" : ""), 1)
	_oa(metrics, "nobs_full", _en("N_full"), 2)
	_oa(metrics, "n_singletons", _ej_nx(nsing), 2)
	dfdef = ""
	if (!missing(dfr)) {
		if (svy) dfdef = "design df (svy e(df_r)): PSUs minus strata"
		else if (ncl & kind == "reghdfe") dfdef = "min(G) - 1 under clustering (reghdfe e(df_r))"
		else if (ncl) dfdef = (ncl == 1 ? "G - 1" : "min(G) - 1") + " under clustering (" + cmd + " e(df_r))"
		_oa(metrics, "df_residual", _ej_def(_ej_n(dfr), dfdef), 1)
	}
	else if (kind == "glm" | kind == "ppmlhdfe") _oa(metrics, "df_residual", _en("df"), 1)
	// z-test fits (no e(df_r)) record no df_residual: the default vcov's df_t is null (inference/0.1)
	_oa(metrics, "df_model", _ej_def(_en("df_m"), kind == "xtreg_fe" ? "regressors plus absorbed levels (xtreg, fe e(df_m))" : ""), 2)
	if (_isin(kind, ("areg", "xtreg_fe", "reghdfe", "ivreghdfe", "ppmlhdfe"))) {
		_oa(metrics, "df_absorbed", _en("df_a"), 2)
		_oa(metrics, "df_absorbed_nested", _en("df_a_nested"), 2)
	}
	_er_metrics1(metrics, kind, cmd, linear, ml, small, wtype, gofd, gofp)
	if (iv) {
		_oa(metrics, "kappa", (kind == "ivregress" ? (_eg("estimator") == "liml" ? _en("kappa") : "") : _en("lambda")), 2)
		_oa(metrics, "fuller", _en("fuller"), 2)
	}
	_er_metrics2(metrics, kind, cmd, survk, svy, bs, mi)
	_oa(metrics, "sum_weights", fw ? _ej_def(_ej_n(N), "Stata e(N), which with frequency weights is the sum of the weights") : _en("sumweights"), 2)
	_oa(metrics, "rank", _ej_nx(rank), 2)
	_oa(metrics, "conf_level", _ej_n(level / 100), 1)

	// ---- tests ----
	T.t = J(1, 0, "")
	T.n = 0
	if (svy) {
		// svy's adjusted Wald F: F(df_m, df_r - df_m + 1), as its header shows it, with e(p)
		_ta(T, "model", "wald", _e("F"), "F", _e("df_m"), dfr - _e("df_m") + 1, _e("p"), "estimation", "", "adjusted Wald", "")
	}
	else if (mi) {
		_ta(T, "model", "wald", _e("F_mi"), "F", _e("df_m_mi"), _e("df_r_mi"), _e("p_mi"), "estimation", "",
			_eg("modeltest_mi") != "" ? "model F test, " + _eg("modeltest_mi") : "", "")
	}
	else if (!missing(_e("F"))) {
		if (_isin(kind, ("ivreg2", "ivreghdfe"))) _ta(T, "model", isiid ? "f" : "wald", _e("F"), "F", _e("Fdf1"), _e("Fdf2"), _e("Fp"), "estimation", "", "", "")
		else {
			// xtreg, fe counts the absorbed levels in e(df_m); its F test doesn't
			k = kind == "xtreg_fe" ? _e("df_m") - _e("df_a") : _e("df_m")
			_ta(T, "model", isiid ? "f" : "wald", _e("F"), "F", k, dfr, Ftail(k, dfr, _e("F")), "estimation", "", "", "")
		}
	}
	else if (!missing(_e("chi2"))) {
		s = strlower(_eg("chi2type"))
		_ta(T, "model", s == "lr" ? "likelihood_ratio" : "wald", _e("chi2"), "chi2", _e("df_m"), ., chi2tail(_e("df_m"), _e("chi2")), "estimation", "", "", "")
	}
	if (kind == "xtreg_fe") _ta(T, "fixed_effects", "f", _e("F_f"), "F", _e("df_a"), dfr, _e("p_f"), "estimation", "", "", "")
	// mixed, me*: LR test against the model without random effects; with one variance component
	// it's on the boundary, chibar2(01), else Stata calls its chi2 conservative
	if (mixedk & !svy & !mi) {
		if (_e("df_c") == 1) _ta(T, "random_effects", "likelihood_ratio", _e("chi2_c"), "chibar2", 1, ., _e("p_c"), "estimation", "", "chibar2(01), against the model without random effects", "")
		else _ta(T, "random_effects", "likelihood_ratio", _e("chi2_c"), "chi2", _e("df_c"), ., _e("p_c"), "estimation", "", "against the model without random effects; conservative (Stata)", "")
	}
	if (iv & _isin(kind, ("ivreg2", "ivreghdfe"))) {
		_ta(T, "underidentification", isiid ? "anderson_lm" : "kleibergen_paap_rk_lm", _e("idstat"), "chi2", _e("iddf"), ., _e("idp"), "estimation", "", "", "")
		_ta(T, "weak_identification", "cragg_donald_f", _e("cdf"), "", ., ., ., "estimation", "", "", "")
		if (!isiid) _ta(T, "weak_identification", "kleibergen_paap_rk_wald_f", _e("rkf"), "", ., ., ., "estimation", "", "", "")
		_ta(T, "weak_identification", "anderson_rubin", _e("arf"), "F", _e("ardf"), _e("ardf_r"), _e("arfp"), "estimation", "", "", "")
		_ta(T, "weak_identification", "anderson_rubin", _e("archi2"), "chi2", _e("ardf"), ., _e("archi2p"), "estimation", "", "", "")
		_ta(T, "weak_identification", "stock_wright", _e("sstat"), "chi2", _e("sstatdf"), ., _e("sstatp"), "estimation", "", "", "")
		if (_e("jdf") > 0) _ta(T, "overidentification", isiid ? "sargan" : "hansen_j", _e("j"), "chi2", _e("jdf"), ., _e("jp"), "estimation", "", "", "")
		_ta(T, "endogeneity", "c", _e("estat"), "chi2", _e("estatdf"), ., _e("estatp"), "estimation", "", "", "")
	}

	// ---- first stage ----
	perendog = J(1, 0, "")
	if (iv & _isin(kind, ("ivreg2", "ivreghdfe"))) {
		M = st_matrix("e(first)")
		if (rows(M)) {
			rn = st_matrixrowstripe("e(first)")[., 2]'
			fcn = st_matrixcolstripe("e(first)")[., 2]'
			for (k = 1; k <= cols(M); k++) {
				_ta(T, "first_stage", isiid ? "f" : "wald", _er_row(M, rn, "F", k), "F", _er_row(M, rn, "df", k), _er_row(M, rn, "df_r", k), _er_row(M, rn, "pvalue", k), "estimation", fcn[k], "", "")
				_ta(T, "first_stage", "sanderson_windmeijer_f", _er_row(M, rn, "SWF", k), "F", _er_row(M, rn, "SWFdf1", k), _er_row(M, rn, "SWFdf2", k), _er_row(M, rn, "SWFp", k), "estimation", fcn[k], "", "")
				_ta(T, "first_stage", "angrist_pischke_f", _er_row(M, rn, "APF", k), "F", _er_row(M, rn, "APFdf1", k), _er_row(M, rn, "APFdf2", k), _er_row(M, rn, "APFp", k), "estimation", fcn[k], "", "")
				perendog = perendog, _ej_o(("endogenous", "partial_r2", "shea_partial_r2"),
					(_ej_s(fcn[k]), _ej_nx(_er_row(M, rn, "pr2", k)), _ej_nx(_er_row(M, rn, "sheapr2", k))))
			}
		}
	}
	if (iv & kind == "ivregress" & doestat) _er_estat(T, perendog, endog, isiid, lv)
	if (kind == "stcox" & doestat) _er_phtest(T, cn, lv)
	if (ml & doestat) {
		s = lv < 4 ? "" : _ej_o(("name", "version", "call"), (_ej_s("stata"), _ej_s(strofreal(c("stata_version"))), _ej_s("estat gof")))
		if (!missing(gofd)) {
			_ta(T, "model_fit", "deviance", gofd, "chi2", gofdf, ., gofpd, "postestimation", "", "Deviance goodness-of-fit", s)
			_ta(T, "model_fit", "pearson", gofp, "chi2", gofdf, ., gofpp, "postestimation", "", "Pearson goodness-of-fit", s)
		}
		else if (_isin(cmd, ("logit", "logistic", "probit"))) {
			if (!_stata("quietly estat gof", 1)) _ta(T, "model_fit", "pearson", _sc("r(chi2)"), "chi2", _sc("r(df)"), ., _sc("r(p)"),
				"postestimation", "", sprintf("Pearson chi2 over %g covariate patterns", _sc("r(m)")), s)
		}
	}

	// ---- specification ----
	sample = _on()
	n_missing = rows_input - n_complete
	nsep = kind == "ppmlhdfe" ? _e("num_separated") : .
	n_other = rows_input - n_missing - (missing(n_used) ? N : n_used) - (missing(nsing) ? 0 : nsing) - (missing(nsep) ? 0 : nsep)
	_oa(sample, "restriction", "null", 3)
	// mi data hold the imputations as extra rows (or columns), so the rows in memory aren't the input
	if (!mi) {
		_oa(sample, "rows_input", _ej_n(rows_input), 3)
		_oa(sample, "dropped", _ej_o(("missing", "singletons", "separated", "other"),
			(_ej_n(n_missing), _ej_nx(nsing), _ej_nx(nsep), (n_other > 0 ? _ej_n(n_other) : ""))), 3)
	}

	opts = _on()
	if (_isin(kind, ("reghdfe", "ivreghdfe", "ppmlhdfe"))) _oa(opts, "drop_singletons", _ej_b(_e("drop_singletons")), 3)
	else if (_isin(kind, ("areg", "xtreg_fe"))) _oa(opts, "drop_singletons", "false", 3)
	if (kind == "ivregress") _oa(opts, "small", _ej_b(small), 3)
	if (cmd == "nbreg") _oa(opts, "dispersion", _ej_s(_eg("dispers")), 3)
	if (kind == "glm") _oa(opts, "algorithm", _ej_s(_eg("opt") == "irls" ? "irls" : "ml"), 3)
	_er_opts2(opts, kind, survk, mlx, mi, vtype)

	s = _eg("offset")
	spec = _on()
	_oa(spec, "call", _ej_s(st_local("call")), 3)
	// the command inside a prefix: svy and bootstrap keep it in e(command), mi estimate in e(cmdline)
	_oa(spec, "formula", _ej_o(("text", "syntax"), (_ej_s(_er_formula((svy | bs) & _eg("command") != "" ? _eg("command") : _eg("cmdline"), absvars, kind)), _ej_s("stata"))), 3)
	_oa(spec, "terms", _ej_sa(cn), 3)
	_oa(spec, "weights", (wtype == "" ? "null" : _ej_o(("variable", "type"), (_ej_s(wvar),
		_ej_s(wtype == "aweight" ? "analytic" : (wtype == "fweight" ? "frequency" : (wtype == "pweight" ? "probability" : (wtype == "iweight" ? "importance" : wtype))))))), 3)
	if (haveabs) _oa(spec, "fixed_effects", _ej_sa(absvars), 3)
	_oa(spec, "clusters", ncl ? _ej_sa(clusters) : "[]", 3)
	if (iv) {
		_oa(spec, "endogenous", _ej_sa(endog), 3)
		_oa(spec, "instruments", _ej_sa(insts), 3)
	}
	if (ml) _oa(spec, "offset", (s == "" ? "null" : (regexm(s, "^ln\((.*)\)$") ?
		_ej_o(("variable", "exposure"), (_ej_s(regexs(1)), "true")) : _ej_o(("variable", "exposure"), (_ej_s(s), "false")))), 3)
	if (kind == "clogit") _oa(spec, "groups", _ej_sa(tokens(_eg("group"))), 3)
	if (survk) _oa(spec, "survival", _er_stset(), 3)
	if (mixedk) _oa(spec, "random_effects", _er_respec(reqs), 3)
	if (svy) _oa(spec, "survey_design", _er_svyset(), 3)
	if (bs) _oa(spec, "resampling", _er_bsspec(), 3)
	if (mi) _oa(spec, "imputation", _ej_o(("m", "method", "imputed", "style"), (_en("M_mi"),
		(mimethod != "" ? _ej_s(mimethod) : ""), _ej_sa(tokens(st_global("_dta[_mi_ivars]"))),
		(st_global("_dta[_mi_style]") != "" ? _ej_s(st_global("_dta[_mi_style]")) : ""))), 3)
	_oa(spec, "sample", _or(sample, lv), 3)
	if (_isin(kind, ("xtreg_fe", "xtreg_re"))) _oa(spec, "state", _ej_o("xtset", _ej_o(("panelvar", "timevar"),
		(_ej_s(st_local("iis")), (st_local("tis") != "" ? _ej_s(st_local("tis")) : "")))), 3)
	_oa(spec, "options", _or(opts, lv) != "" ? _or(opts, lv) : "", 3)

	// ---- structures ----
	fe = J(1, 0, "")
	if (_isin(kind, ("reghdfe", "ivreghdfe", "ppmlhdfe"))) {
		dof = st_matrix("e(dof_table)")
		if (rows(dof)) {
			rs = st_matrixrowstripe("e(dof_table)")
			for (i = 1; i <= rows(dof); i++) {
				fe = fe, _ej_o(("kind", "name", "levels", "redundant", "redundant_method", "nested_in", "constant_reported"),
					(_ej_s("object"), _ej_s(rs[i, 2]), _ej_n(dof[i, 1]), _ej_n(dof[i, 2]),
					 (dof[i, 2] > 0 ? _ej_s(dof[i, 5] == 1 ? "nested" : (dof[i, 4] == 1 ? "pairwise" : "exact")) : ""),
					 ((dof[i, 5] == 1 & ncl) ? _ej_sa(clusters) : ""), _ej_b(_e("report_constant") == 1)))
			}
		}
	}
	else if (kind == "areg") fe = _ej_o(("kind", "name", "levels", "constant_reported"),
		(_ej_s("object"), _ej_s(absvars[1]), _en("k_absorb"), "true"))
	else if (kind == "xtreg_fe") fe = _ej_o(("kind", "name", "levels", "group_size", "nested_in", "constant_reported"),
		(_ej_s("object"), _ej_s(absvars[1]), _en("N_g"),
		 _ej_o(("min", "mean", "max"), (_en("g_min"), _en("g_avg"), _en("g_max"))),
		 (ncl ? _ej_sa(clusters) : ""), "true"))

	num = _on()
	if (kind == "reghdfe") {
		_oa(num, "kind", _ej_s("object"), 4)
		_oa(num, "iterative", "true", 4)
		_oa(num, "iterations", _en("ic"), 4)
		_oa(num, "converged", _ej_b(conv_ok), 4)
	}
	else if (mlx) {
		_oa(num, "kind", _ej_s("object"), 4)
		_oa(num, "iterative", "true", 4)
		_oa(num, "algorithm", ((_eg("opt") == "irls" | kind == "ppmlhdfe") ? _ej_s("irls") : (_eg("technique") != "" ? _ej_s(_eg("technique")) : "")), 4)
		_oa(num, "iterations", _en("ic"), 4)
		if (kind == "ppmlhdfe") _oa(num, "fixef_iterations", _ej_def(_en("ic2"), "reghdfe iterations summed over the IRLS steps (ppmlhdfe e(ic2))"), 4)
		_oa(num, "converged", missing(conv_ok) ? "" : _ej_b(conv_ok), 4)
	}

	structures = _on()
	_oa(structures, "vcov", _ej_l(vcovs), 2)
	_oa(structures, "fixed_effects", _ej_l(fe), 3)
	_oa(structures, "first_stage", length(perendog) ? _ej_o(("kind", "per_endogenous"), (_ej_s("object"), _ej_l(perendog))) : "", 2)
	_oa(structures, "numerics", _or(num, lv), 4)
	if (kind == "clogit") _oa(structures, "groups", _ej_o(("kind", "multiple_positive"), (_ej_s("object"), _ej_b(_eg("multiple") == "multiple"))), 3)
	if (mixedk) _oa(structures, "random_effects", _er_restruct(reqs), 3)

	// ---- provenance ----
	prov = _er_prov(cmd, vcmd, ver_cmd, wver, lv, ident, bs, rows_input)

	// ---- meta ----
	// Model profiles describe a fit, not results pooled over imputations or a design-based fit;
	// svy and mi results claim inference and their own profile
	_er_profiles(profiles, messages, kind, lv, linear, ml, iv, survk, mixedk, svy, bs, mi, conv_ok, mimethod)
	if (kind == "generic") messages = messages, _ej_o(("level", "code", "source", "message"),
		(_ej_s("info"), _ej_s("no_profile"), _ej_s("estrec"), _ej_s("estrec has no mapping for " + cmd + ": core fields only, no profiles claimed")))
	if (!missing(nsing) & nsing > 0) messages = messages, _ej_o(("level", "code", "source", "message"),
		(_ej_s("info"), _ej_s("singletons"), _ej_s(cmd), _ej_s(strofreal(nsing) + " singleton rows dropped")))

	est = _on()
	_er_estimator(est, kind, cmd, iv)
	meta = _on()
	if (lv == 1) created = substr(created, 1, 10)   // a date, not a time
	_oa(meta, "id", _ej_s(_er_uuid()), 1)
	_oa(meta, "created", _ej_s(created), 1)
	_oa(meta, "status", _ej_s(conv_ok == 0 ? "warning" : "ok"), 1)
	_oa(meta, "estimator", _or(est, lv), 2)
	_oa(meta, "responses", _ej_sa(tokens(depvar)), 2)
	_oa(meta, "profiles", length(profiles) ? _ej_sa(profiles) : "", 1)
	_oa(meta, "disclosure", _ej_o("level", _ej_n(lv)), 1)
	_oa(meta, "producer", _ej_o(("name", "version"), (_ej_s("estrec"), _ej_s(wver))), 4)
	_oa(meta, "messages", _ej_l(messages), 2)

	sections = ("meta", "metrics", "parameters")
	if (lv >= 3) sections = sections, "specification"
	if (lv >= 2) sections = sections, "structures"
	if (lv >= 4) sections = sections, "provenance"
	if (lv >= 2 & T.n) sections = sections, "tests"
	histk = ("when", "by", "action", "level", "sections")
	histv = (_ej_s(created), (lv >= 4 ? _ej_o(("name", "version"), (_ej_s("estrec"), _ej_s(wver))) : ""),
		_ej_s("created"), _ej_n(lv), (lv >= 2 ? _ej_sa(sections) : ""))

	nl = char(10)
	rec = "{" + nl +
		" " + _ej_s("schema") + ": " + _ej_s("estrec/0.1") + "," + nl +
		" " + _ej_s("meta") + ": " + _or(meta, lv) + "," + nl +
		(lv >= 3 ? " " + _ej_s("specification") + ": " + _or(spec, lv) + "," + nl : "") +
		" " + _ej_s("metrics") + ": " + _or(metrics, lv) + "," + nl +
		" " + _ej_s("parameters") + ": [" + nl + "  " + invtokens(params, "," + nl + "  ") + nl + " ]," + nl +
		(lv >= 2 ? " " + _ej_s("structures") + ": " + _or(structures, lv) + "," + nl : "") +
		(lv >= 2 & T.n ? " " + _ej_s("tests") + ": [" + nl + "  " + invtokens(T.t, "," + nl + "  ") + nl + " ]," + nl : "") +
		(lv >= 4 ? " " + _ej_s("provenance") + ": " + _or(prov, lv) + "," + nl : "") +
		" " + _ej_s("history") + ": [" + _ej_o(histk, histv) + "]" + nl + "}" + nl

	if (fileexists(fn)) {
		if (!replace) {
			errprintf("file %s already exists; use replace\n", fn)
			exit(602)
		}
		unlink(fn)
	}
	fh = fopen(fn, "w")
	fwrite(fh, rec)
	fclose(fh)
}

// Metrics of the Tier 2 commands and prefixes
void _er_metrics2(struct erobj scalar metrics, string scalar kind, string scalar cmd, real scalar survk,
	real scalar svy, real scalar bs, real scalar mi)
{
	if (kind == "clogit") {
		_oa(metrics, "pseudo_r2", _en("r2_p"), 2)
		_oa(metrics, "n_dropped_uninformative", _en("N_drop"), 2)
		_oa(metrics, "n_groups_dropped", _en("N_group_drop"), 2)
	}
	if (survk) {
		_oa(metrics, "n_events", _en("N_fail"), 2)
		_oa(metrics, "n_subjects", _en("N_sub"), 2)
		_oa(metrics, "time_at_risk", _en("risk"), 2)
		_oa(metrics, "pseudo_r2", _en("r2_p"), 2)
		// streg's ancillary parameters, as posted
		if (_isin(cmd, ("weibull", "gompertz"))) _oa(metrics, "shape", _ej_def(_en(cmd == "weibull" ? "aux_p" : "gamma"), cmd == "weibull" ? "Weibull p (streg e(aux_p))" : "Gompertz gamma (streg e(gamma))"), 2)
		if (cmd == "lnormal") _oa(metrics, "scale", _ej_def(_en("sigma"), "lognormal sigma (streg e(sigma))"), 2)
		if (cmd == "llogistic") _oa(metrics, "scale", _ej_def(_en("gamma"), "loglogistic gamma (streg e(gamma))"), 2)
		if (cmd == "gamma") {
			_oa(metrics, "scale", _ej_def(_en("sigma"), "generalized gamma sigma (streg e(sigma))"), 2)
			_oa(metrics, "shape", _ej_def(_en("kappa"), "generalized gamma kappa (streg e(kappa))"), 2)
		}
	}
	if (svy) {
		_oa(metrics, "n_strata", _en("N_strata"), 2)
		_oa(metrics, "n_psu", _en("N_psu"), 2)
		_oa(metrics, "population_size", _en("N_pop"), 2)
		_oa(metrics, "df_design", _en("df_r"), 2)
		_oa(metrics, "n_subpop", _ej_def(_en("N_sub"), "observations in the subpopulation (svy e(N_sub))"), 2)
		_oa(metrics, "subpop_size", _ej_def(_en("N_subpop"), "subpopulation size, the sum of its weights (svy e(N_subpop))"), 2)
	}
	if (bs) _oa(metrics, "n_reps_failed", _en("N_misreps"), 2)
	if (mi) {
		_oa(metrics, "nobs_min", (_e("N_min_mi") != _e("N_max_mi") ? _en("N_min_mi") : ""), 2)
		_oa(metrics, "nobs_max", (_e("N_min_mi") != _e("N_max_mi") ? _en("N_max_mi") : ""), 2)
	}
}

// specification.options of the Tier 2 commands and prefixes
void _er_opts2(struct erobj scalar opts, string scalar kind, real scalar survk, real scalar mlx,
	real scalar mi, string scalar vtype)
{
	string scalar s
	if (kind == "ppmlhdfe") {
		// e(separation) as a list; ppmlhdfe's ir is relu (its help file)
		_oa(opts, "separation", _ej_sa(_er_sub(tokens(_eg("separation")), "ir", "relu")), 3)
		_oa(opts, "tolerance", _en("tolerance"), 3)
		_oa(opts, "fixef_tolerance", _en("itolerance"), 3)
		_oa(opts, "max_iterations", _en("maxiterations"), 3)
		_oa(opts, "guess", (_eg("guess") != "" ? _ej_s(_eg("guess")) : ""), 3)
	}
	if (kind == "clogit") {
		_oa(opts, "likelihood", _ej_s("exact"), 3)
		_oa(opts, "drop_uninformative", "true", 3)
	}
	if (kind == "stcox") {
		s = _eg("ties")
		_oa(opts, "ties", _ej_s(s == "exactm" ? "exact_marginal" : (s == "exactp" ? "exact_partial" : s)), 3)
	}
	if (survk) _oa(opts, "robust", _ej_b(vtype != "oim"), 3)
	if (kind == "mixed" & _eg("dfmethod") != "") {
		s = strlower(_eg("dfmethod"))
		_oa(opts, "df_method", _ej_s(s == "kroger" ? "kenward_roger" : s), 3)
	}
	if (kind == "meglm") _oa(opts, "n_quadrature", _ej_nx(strtoreal(_eg("n_quad"))), 3)
	if ((mlx & kind != "glm") | kind == "glm" & _eg("opt") != "irls") _oa(opts, "optimizer", (_eg("technique") != "" ? _ej_s(_eg("technique")) : ""), 3)
	if (mi) {
		s = strlower(_eg("dfadjust_mi"))
		_oa(opts, "combining_rule", _ej_s("rubin"), 3)
		_oa(opts, "df_method", (s == "small sample" ? _ej_s("barnard_rubin") : (s == "large sample" ? _ej_s("rubin_1987") : "")), 3)
		_oa(opts, "dfcom", _en("df_c_mi"), 3)
	}
}

// The profiles a record claims
void _er_profiles(string rowvector profiles, string rowvector messages, string scalar kind, real scalar lv,
	real scalar linear, real scalar ml, real scalar iv, real scalar survk, real scalar mixedk, real scalar svy,
	real scalar bs, real scalar mi, real scalar conv_ok, string scalar mimethod)
{
	real scalar inf
	profiles = J(1, 0, "")
	inf = linear | ml | kind == "clogit" | survk | mixedk
	if (lv >= 2 & inf) profiles = profiles, "inference/0.1"
	if (!svy & !mi) {
		if (lv >= 3 & iv) profiles = profiles, "iv/0.1"
		if (lv >= 3 & _isin(kind, ("areg", "xtreg_fe", "reghdfe", "ivreghdfe"))) profiles = profiles, "linear-fe/0.1"
		if (lv >= 4 & ml & !missing(conv_ok)) profiles = profiles, "glm/0.1"
		if (lv >= 4 & kind == "ppmlhdfe" & !missing(conv_ok)) profiles = profiles, "ppmlhdfe/0.1"
		if (lv >= 3 & kind == "clogit") profiles = profiles, "conditional-logit/0.1"
		if (lv >= 3 & survk) profiles = profiles, "survival/0.1"
		if (lv >= 4 & mixedk & !missing(conv_ok)) profiles = profiles, "mixed/0.1"
	}
	if (lv >= 3 & svy & inf) profiles = profiles, "survey/0.1"
	if (lv >= 3 & bs & kind != "generic") profiles = profiles, "resampling/0.1"
	if (lv >= 3 & mi & inf) profiles = profiles, "mi/0.1"
}

// Metrics of the linear and GLM-type fits
void _er_metrics1(struct erobj scalar metrics, string scalar kind, string scalar cmd, real scalar linear,
	real scalar ml, real scalar small, string scalar wtype, real scalar gofd, real scalar gofp)
{
	string scalar s
	if (linear) {
		s = (wtype == "aweight" & kind == "reghdfe") ? ", with aweights rescaled to sum to N" : ""
		_oa(metrics, "rss", _ej_def(_en("rss"), s != "" ? "weighted RSS" + s : ""), 2)
		if (_isin(kind, ("regress", "ivregress")) & !missing(_e("mss"))) _oa(metrics, "tss", _ej_n(_e("mss") + _e("rss")), 2)
		else if (kind != "xtreg_re") _oa(metrics, "tss", _en("tss"), 2)
		_oa(metrics, "tss_within", _en("tss_within"), 2)
		_oa(metrics, "r2", _en("r2"), 2)
		_oa(metrics, "adj_r2", _en("r2_a"), 2)
		_oa(metrics, "r2_within", (kind == "reghdfe" | kind == "ivreghdfe") ? _en("r2_within") : _en("r2_w"), 2)
		_oa(metrics, "adj_r2_within", _en("r2_a_within"), 2)
		_oa(metrics, "r2_between", _en("r2_b"), 2)
		_oa(metrics, "r2_overall", _en("r2_o"), 2)
		if (kind == "xtreg_re") _oa(metrics, "sigma", _ej_def(_en("sigma_e"), "sigma_e, the SD of the idiosyncratic error"), 2)
		else _oa(metrics, "sigma", _ej_def(_en("rmse"), small ? (s != "" ? "sqrt(RSS / (N - K))" + s : "") : "sqrt(RSS / N)"), 2)
		_oa(metrics, "sigma_fe", _en("sigma_u"), 2)
		_oa(metrics, "rho", _en("rho"), 2)
	}
	_oa(metrics, "log_lik", _ej_def(_en("ll"), (kind == "mixed" & _eg("method") == "REML") ? "restricted (REML) log-likelihood (mixed e(ll))" : ""), 2)
	// ppmlhdfe's e(ll_0) is the FE-only model's
	_oa(metrics, kind == "ppmlhdfe" ? "log_lik_fe_only" : "log_lik_null", _en("ll_0"), 2)
	if (ml) {
		// Only what Stata reports (Ted, 2026-11-07): glm's e(deviance), or after poisson the deviance
		// goodness-of-fit of estat gof (equal to glm, family(poisson)'s e(deviance)); logit, probit
		// and nbreg report none
		if (kind == "glm" | kind == "ppmlhdfe") _oa(metrics, "deviance", _en("deviance"), 2)
		else _oa(metrics, "deviance", _ej_def(_ej_nx(gofd), "Stata estat gof, Deviance goodness-of-fit (r(chi2_d))"), 2)
		_oa(metrics, "pseudo_r2", _ej_def(_en("r2_p"), kind == "ppmlhdfe" ? "1 - ll/ll_0, ll_0 FE-only" : ""), 2)
		if (kind == "ppmlhdfe") _oa(metrics, "n_separated", _en("num_separated"), 2)
		if (!missing(_e("N_cds"))) _oa(metrics, "n_completely_determined", _ej_n(_e("N_cds") + _e("N_cdf")), 2)
		_oa(metrics, "alpha", _en("alpha"), 2)
		_oa(metrics, "aic", _ej_def(_en("aic"), "(-2 log_lik + 2 K) / N, per observation (Stata glm)"), 2)
		_oa(metrics, "bic", _ej_def(_en("bic"), "deviance - df_residual * ln(N) (Stata glm)"), 2)
		_oa(metrics, "dispersion", _en("phi"), 2)
		if (kind == "glm") _oa(metrics, "pearson_chi2", _en("deviance_p"), 2)
		else _oa(metrics, "pearson_chi2", _ej_def(_ej_nx(gofp), "Stata estat gof, Pearson goodness-of-fit (r(chi2_p))"), 2)
	}
}

// The default vcov's small-sample correction: convention, formula and what K counts
void _er_ssc(string scalar conv, string scalar formula, string scalar kcounts, string scalar kind,
	string scalar cmd, string scalar vtype, real scalar small, real scalar haveabs, real scalar linear,
	real scalar mlx, real scalar mixedk, real scalar svy, real scalar bs, real scalar mi, real scalar isiid)
{
	conv = "stata"
	formula = kcounts = ""
	if (svy) {
		conv = "stata svy"
		if (vtype == "linearized") formula = "linearized: sum over strata of (1 - f_h) n_h/(n_h - 1) times the spread of the PSU score totals"
	}
	else if (bs) {
		conv = "stata bootstrap"
		formula = _eg("mse") != "" ? "sum over replications of (b_r - b)^2 / R (mse)" : "sum over replications of (b_r - mean(b_r))^2 / (R - 1)"
	}
	else if (kind == "reghdfe" | (kind == "ivreghdfe" & small & haveabs)) {
		conv = cmd
		// The worked converter's strings (converters/reghdfe), so its records and these compare equal
		formula = vtype == "CRV1" ? "(N-1)/(N-K) * G/(G-1), K = df_m + df_a" : (vtype == "HC1" ? "N/(N-K), K = df_m + df_a" : (isiid ? "s2 = RSS/(N-K), K = df_m + df_a" : ""))
		kcounts = "df_m regressors plus df_a absorbed levels (initial minus redundant minus nested in clusters)"
	}
	else if (linear & small) {
		conv = kind == "areg" ? "stata areg" : (kind == "xtreg_fe" ? "stata xtreg" : (kind == "regress" ? "stata" : (kind == "ivregress" ? "stata ivregress" : cmd)))
		formula = vtype == "CRV1" ? "(N-1)/(N-K) * G/(G-1)" : (vtype == "HC1" ? "N/(N-K)" : (isiid ? "s2 = RSS/(N-K)" : ""))
		if (kind == "areg") kcounts = "K = rank + df_a: absorbed levels counted even when nested in the clusters"
		else if (kind == "xtreg_fe") kcounts = vtype == "CRV1" ? "K = rank: the panels are nested in the clusters, so absorbed levels are not counted" : "K = rank + df_a"
		else kcounts = "K = rank"
	}
	else if (_isin(kind, ("ivregress", "ivreg2", "ivreghdfe"))) {
		conv = kind == "ivregress" ? "stata ivregress" : cmd
		formula = isiid ? "s2 = RSS/N" : ((vtype == "HC0" | vtype == "CRV1" | vtype == "twoway") ? "none: no N/(N-K), (N-1)/(N-K) or G/(G-1)" : "")
	}
	else if (kind == "xtreg_re") conv = "stata xtreg"
	else if (mixedk) formula = _isin(vtype, ("oim", "opg", "eim")) ? "none" : (vtype == "kenward_roger" ? "Kenward-Roger adjustment of the REML vcov (mixed e(V_df))" : "")
	else if (mlx) {
		if (kind == "ppmlhdfe") conv = "ppmlhdfe"
		formula = _isin(vtype, ("oim", "opg", "eim")) ? "none" : (vtype == "HC0" ? "N/(N-1)" : (vtype == "CRV1" ? "G/(G-1)" : ""))
	}
	// mi: Rubin's rules over the imputations' vcovs, each with its command's correction
	if (mi) {
		formula = "T = W + (1 + 1/M) B, W the mean within-imputation vcov" + (formula != "" ? " (" + formula + ")" : "") + ", B the between-imputation variance"
		conv = "stata mi estimate, " + conv
	}
}
// provenance
struct erobj scalar _er_prov(string scalar cmd, string scalar vcmd, string scalar ver_cmd, string scalar wver, real scalar lv,
	real scalar ident, real scalar bs, real scalar rows_input)
{
	struct erobj scalar prov
	string rowvector software
	string scalar src, s
	prov = _on()
	src = _isin(cmd, ("reghdfe", "ivreghdfe", "ivreg2", "ppmlhdfe")) ? "SSC" : "Stata"
	software = _ej_o(("name", "version", "purl", "role", "source"), (_ej_s(vcmd),
		(ver_cmd != "" ? _ej_s(ver_cmd) : _ej_s(strofreal(c("stata_version")))),
		(src == "SSC" & ver_cmd != "" ? _ej_s("pkg:generic/" + cmd + "@" + ver_cmd) : ""), _ej_s("estimator"), _ej_s(src)))
	software = software, _ej_o(("name", "version", "purl", "role", "attributes"), (_ej_s("stata"), _ej_s(strofreal(c("stata_version"))),
		_ej_s("pkg:generic/stata@" + strofreal(c("stata_version"))), _ej_s("language"),
		(lv >= 5 ? _ej_o(("edition", "born_date", "processors"), (_ej_s(c("edition_real")), _ej_s(c("born_date")), _ej_n(c("processors")))) : "")))
	software = software, _ej_o(("name", "version", "role"), (_ej_s("estrec"), _ej_s(wver), _ej_s("writer")))
	if (lv >= 5) {
		if (cmd == "ppmlhdfe") software = software, _er_dep("reghdfe", st_local("ver_reghdfe"))
		if (_isin(cmd, ("reghdfe", "ivreghdfe", "ppmlhdfe"))) software = software, _er_dep("ftools", st_local("ver_ftools"))
		if (cmd == "ivreghdfe") software = software, _er_dep("ivreg2", st_local("ver_ivreg2"))
		if (_isin(cmd, ("ivreg2", "ivreghdfe"))) software = software, _er_dep("ranktest", st_local("ver_ranktest"))
	}
	s = st_local("datasig")
	_oa(prov, "software", _ej_l(software), 4)
	_oa(prov, "environment", _ej_o(("os", "machine", "random"), (_ej_s(c("os")), _ej_s(c("machine_type")),
		_ej_o(("rngtype", "rngstate"), (_ej_s(c("rngtype")), (bs & _eg("rngstate") != "" ? _ej_s(_eg("rngstate")) : ""))))), 5)
	_oa(prov, "data", "[" + _ej_o(("role", "location", "rows", "columns", "checksum"),
		(_ej_s("estimation"), (ident & lv >= 5 & c("filename") != "" ? _ej_s(c("filename")) : ""), _ej_n(rows_input), st_local("nvars"),
		 (s != "" ? _ej_o(("algorithm", "value", "of", "method"), (_ej_s("datasignature"), _ej_s(s), _ej_s("in-memory"), _ej_s("Stata datasignature (rows, columns, names, contents)"))) : ""))) + "]", 4)
	if (ident) _oa(prov, "agent", _ej_o(("user", "host"), (_ej_s(c("username")), _ej_s(c("hostname")))), 5)
	return(prov)
}

// Which elements of a are in b
real rowvector _er_in(string rowvector a, string rowvector b)
{
	real rowvector r
	real scalar i
	r = J(1, length(a), 0)
	for (i = 1; i <= length(a); i++) r[i] = anyof(b, a[i])
	return(r)
}

// Row `name' of column k of a matrix with row names rn, or missing
real scalar _er_row(real matrix M, string rowvector rn, string scalar name, real scalar k)
{
	real scalar i
	for (i = 1; i <= length(rn); i++) if (rn[i] == name) return(M[i, k])
	return(.)
}

string rowvector _er_terms(string matrix cs)
{
	string rowvector r
	real scalar j
	r = J(1, rows(cs), "")
	for (j = 1; j <= rows(cs); j++) r[j] = (cs[j, 1] == "/" ? "/" : "") + cs[j, 2]
	return(r)
}

// The model as written: the command line without the command, weights, if/in and options
string scalar _er_formula(string scalar cmdline, string rowvector absvars, string scalar kind)
{
	string scalar s
	s = cmdline
	if (strpos(s, ",")) s = substr(s, 1, strpos(s, ",") - 1)
	s = ustrregexra(s, "\[[^\]]*\]", "")
	s = ustrregexra(s, "\s(if|in)\s.*$", "")
	s = ustrregexra(s, "^\s*\S+\s+(2sls|liml|gmm)?\s*", "")
	s = strtrim(stritrim(s))
	if (length(absvars) & kind != "xtreg_fe") s = s + ", absorb(" + invtokens(absvars) + ")"
	return(s)
}

void _er_estimator(struct erobj scalar est, string scalar kind, string scalar cmd, real scalar iv)
{
	string scalar m, d, l
	if (kind == "generic") return
	if (kind == "clogit") {
		_oa(est, "family", _ej_s("conditional_logit"), 2)
		_oa(est, "method", _ej_s("conditional_mle"), 2)
		_oa(est, "distribution", _ej_s("binomial"), 2)
		_oa(est, "link", _ej_s("logit"), 2)
		return
	}
	if (kind == "stcox" | kind == "streg") {
		_oa(est, "family", _ej_s("survival"), 2)
		_oa(est, "method", _ej_s(kind == "stcox" ? "cox" : "parametric"), 2)
		if (kind == "streg") {
			d = cmd == "ereg" ? "exponential" : (cmd == "lnormal" ? "lognormal" : (cmd == "llogistic" ? "loglogistic" : (cmd == "gamma" ? "generalized_gamma" : cmd)))
			_oa(est, "distribution", _ej_s(d), 2)
			// e(frm2): hazard (PH metric) or time (AFT)
			_oa(est, "metric", _ej_s(_eg("frm2") == "hazard" ? "ph" : "aft"), 2)
		}
		return
	}
	if (kind == "mixed") {
		_oa(est, "family", _ej_s("mixed"), 2)
		_oa(est, "method", _ej_s(strlower(_eg("method"))), 2)
		return
	}
	if (kind == "meglm") {
		_oa(est, "family", _ej_s("mixed"), 2)
		_oa(est, "method", _ej_s(_eg("intmethod") == "laplace" ? "laplace" : "agq"), 2)
		_oa(est, "integration", _ej_s(_eg("intmethod")), 2)
		d = strlower(_eg("family"))
		_oa(est, "distribution", _ej_s(d == "bernoulli" ? "binomial" : (d == "nbinomial" ? "negative_binomial" : d)), 2)
		_oa(est, "link", _ej_s(strlower(_eg("link"))), 2)
		return
	}
	if (kind == "ppmlhdfe") {
		_oa(est, "family", _ej_s("glm"), 2)
		_oa(est, "method", _ej_s("irls"), 2)
		_oa(est, "distribution", _ej_s("poisson"), 2)
		_oa(est, "link", _ej_s("log"), 2)
		return
	}
	if (kind == "ml" | kind == "glm") {
		_oa(est, "family", _ej_s("glm"), 2)
		_oa(est, "method", _ej_s(kind == "glm" & _eg("opt") == "irls" ? "irls" : "mle"), 2)
		if (_isin(cmd, ("logit", "logistic"))) { d = "binomial"; l = "logit"; }
		else if (cmd == "probit") { d = "binomial"; l = "probit"; }
		else if (cmd == "poisson") { d = "poisson"; l = "log"; }
		else if (cmd == "nbreg") { d = "negative_binomial"; l = "log"; }
		else {
			d = strlower(_eg("varfunct"))
			d = d == "bernoulli" ? "binomial" : (d == "neg. binomial" ? "negative_binomial" : (d == "inverse gaussian" ? "inverse_gaussian" : d))
			l = strlower(_eg("linkt"))
			l = l == "neg. binomial" ? "negative_binomial" : (l == "log-log" ? "loglog" : (l == "log-compl" ? "logc" : (l == "reciprocal" ? "inverse" : l)))
		}
		_oa(est, "distribution", _ej_s(d), 2)
		_oa(est, "link", _ej_s(l), 2)
		return
	}
	_oa(est, "family", _ej_s("linear"), 2)
	m = "ols"
	if (kind == "ivregress") m = _eg("estimator")
	else if (iv) {
		m = _eg("model")
		m = m == "iv" ? "2sls" : (m == "gmm2s" ? "gmm" : m)
		if (!missing(_e("fuller"))) m = "fuller"
	}
	else if (kind == "xtreg_re") m = "gls"
	_oa(est, "method", _ej_s(m), 2)
	if (kind == "xtreg_re") _oa(est, "panel", _ej_s("random_effects"), 2)
	if (kind == "xtreg_fe") _oa(est, "panel", _ej_s("fixed_effects"), 2)
}

string scalar _er_dep(string scalar name, string scalar ver)
{
	return(_ej_o(("name", "version", "purl", "role", "source"), (_ej_s(name), (ver != "" ? _ej_s(ver) : ""),
		(ver != "" ? _ej_s("pkg:generic/" + name + "@" + ver) : ""), _ej_s("dependency"), _ej_s("SSC"))))
}

// ivregress first-stage, overidentification and endogeneity tests (estat)
void _er_estat(struct ertests scalar T, string rowvector perendog, string rowvector endog,
	real scalar isiid, real scalar lv)
{
	real matrix S, Mu
	real scalar k, mineig, df
	string scalar s

	s = lv < 4 ? "" : _ej_o(("name", "version", "call"), (_ej_s("stata"), _ej_s(strofreal(c("stata_version"))), _ej_s("estat firststage, all")))
	if (!_stata("quietly estat firststage, all", 1)) {
		mineig = _sc("r(mineig)")
		S = st_matrix("r(singleresults)")
		Mu = st_matrix("r(multiresults)")
		for (k = 1; k <= rows(S) & k <= length(endog); k++) {
			_ta(T, "first_stage", isiid ? "f" : "wald", S[k, 4], "F", S[k, 5], S[k, 6], S[k, 7], "postestimation", endog[k], "", s)
			perendog = perendog, _ej_o(("endogenous", "r2", "partial_r2", "shea_partial_r2"),
				(_ej_s(endog[k]), _ej_nx(S[k, 1]), _ej_nx(S[k, 3]), (rows(Mu) >= k ? _ej_nx(Mu[k, 1]) : "")))
		}
		_ta(T, "weak_identification", "cragg_donald_f", mineig, "", ., ., ., "postestimation", "", "minimum eigenvalue statistic", s)
	}
	s = lv < 4 ? "" : _ej_o(("name", "version", "call"), (_ej_s("stata"), _ej_s(strofreal(c("stata_version"))), _ej_s("estat overid")))
	if (!_stata("quietly estat overid", 1)) {
		df = _sc("r(df)")
		_ta(T, "overidentification", "sargan", _sc("r(sargan)"), "chi2", df, ., _sc("r(p_sargan)"), "postestimation", "", "", s)
		if (missing(_sc("r(basmann_df_n)"))) _ta(T, "overidentification", "basmann", _sc("r(basmann)"), "chi2", df, ., _sc("r(p_basmann)"), "postestimation", "", "", s)
		else _ta(T, "overidentification", "basmann", _sc("r(basmann)"), "F", _sc("r(basmann_df_n)"), _sc("r(basmann_df_d)"), _sc("r(p_basmann)"), "postestimation", "", "", s)
		if (missing(_sc("r(sargan)"))) _ta(T, "overidentification", "score", _sc("r(score)"), "chi2", df, ., _sc("r(p_score)"), "postestimation", "", "", s)
		_ta(T, "overidentification", "hansen_j", _sc("r(HansenJ)"), "chi2", _sc("r(J_df)"), ., _sc("r(p_HansenJ)"), "postestimation", "", "", s)
		_ta(T, "overidentification", "anderson_rubin", _sc("r(ar)"), "chi2", _sc("r(ar_df)"), ., _sc("r(p_ar)"), "postestimation", "", "", s)
	}
	s = lv < 4 ? "" : _ej_o(("name", "version", "call"), (_ej_s("stata"), _ej_s(strofreal(c("stata_version"))), _ej_s("estat endogenous")))
	if (!_stata("quietly estat endogenous", 1)) {
		df = _sc("r(df)")
		_ta(T, "endogeneity", "durbin", _sc("r(durbin)"), "chi2", df, ., _sc("r(p_durbin)"), "postestimation", "", "", s)
		_ta(T, "endogeneity", "wu_hausman", _sc("r(wu)"), "F", df, _sc("r(wudf_r)"), _sc("r(p_wu)"), "postestimation", "", "", s)
		_ta(T, "endogeneity", "score", _sc("r(r_score)"), "chi2", df, ., _sc("r(p_r_score)"), "postestimation", "", "robust score", s)
		_ta(T, "endogeneity", "f", _sc("r(regF)"), "F", _sc("r(regFdf_n)"), _sc("r(regFdf_d)"), _sc("r(p_regF)"), "postestimation", "", "robust regression-based", s)
	}
}

// Element (i, j) of a Stata matrix, or missing
real scalar _er_at(string scalar name, real scalar i, real scalar j)
{
	real matrix M
	M = st_matrix(name)
	return(rows(M) >= i & cols(M) >= j ? M[i, j] : .)
}

// Column j of a 2 x k interval matrix (bootstrap e(ci_*)) as [low, high]; "" when absent
string scalar _er_ci(string scalar name, real scalar j)
{
	real scalar lo, hi
	lo = _er_at(name, 1, j)
	hi = _er_at(name, 2, j)
	if (missing(lo) & missing(hi)) return("")
	return("[" + _ej_n(lo) + ", " + _ej_n(hi) + "]")
}

string rowvector _er_sub(string rowvector v, string scalar a, string scalar b)
{
	real scalar i
	for (i = 1; i <= length(v); i++) if (v[i] == a) v[i] = b
	return(v)
}

// A random-effect term in the record's form: the random intercept is (Intercept)
string scalar _er_reterm(string scalar t)
{
	return(t == "_cons" ? "(Intercept)" : t)
}

// The random-effects equations, one row each: ivar, level, index within the level,
// covariance (Stata's word), terms (space-separated, as Stata names them), text as written
void _er_reqs(string matrix R, string scalar kind, string matrix cs, string scalar eq1)
{
	string rowvector iv, vt, rv, segs, levs, gt, parts
	real rowvector dim
	real scalar e, pos, j, i, l
	string scalar g, t, cmdline

	// the || parts of the command line, one per equation
	cmdline = _eg("cmdline")
	segs = J(1, 0, "")
	while ((pos = strpos(cmdline, "||"))) {
		cmdline = substr(cmdline, pos + 2, .)
		t = strpos(cmdline, "||") ? substr(cmdline, 1, strpos(cmdline, "||") - 1) : cmdline
		// up to its options: the last equation's comma also starts the command's own options
		if (strpos(t, ",")) t = substr(t, 1, strpos(t, ",") - 1)
		segs = segs, "|| " + strtrim(t)
	}
	if (kind == "mixed") {
		iv = tokens(_eg("ivars"))
		vt = tokens(_eg("vartypes"))
		rv = tokens(_eg("revars"))
		dim = strtoreal(tokens(_eg("redim")))
		R = J(length(iv), 6, "")
		levs = J(1, 0, "")
		pos = 0
		for (e = 1; e <= length(iv); e++) {
			if (!anyof(levs, iv[e])) levs = levs, iv[e]
			for (l = 1; l <= length(levs); l++) if (levs[l] == iv[e]) break
			R[e, 1] = iv[e]
			R[e, 2] = strofreal(l)
			R[e, 3] = strofreal(e > 1 ? sum(R[1..e-1, 1] :== iv[e]) + 1 : 1)
			R[e, 4] = e <= length(vt) ? vt[e] : ""
			R[e, 5] = e <= length(dim) & pos + dim[e] <= length(rv) ? invtokens(rv[pos+1..pos+dim[e]]) : ""
			R[e, 6] = e <= length(segs) ? segs[e] : ""
			if (e <= length(dim)) pos = pos + dim[e]
		}
		return
	}
	// me*: the groups and terms of the var() and cov() rows of e(b)
	iv = tokens(_eg("ivars"))
	R = J(0, 6, "")
	for (j = 1; j <= rows(cs); j++) {
		if (cs[j, 1] != "/" | !regexm(cs[j, 2], "^var\((.*)\)$")) continue
		t = regexs(1)
		if (!regexm(t, "^(.+)\[(.+)\]$")) continue
		g = regexs(2)
		t = regexs(1)
		gt = tokens(g, ">")
		g = gt[length(gt)]
		for (i = 1; i <= rows(R); i++) if (R[i, 1] == g) break
		if (i > rows(R)) {
			for (l = 1; l <= length(iv); l++) if (iv[l] == g) break
			R = R \ (g, strofreal(l), "1", "", t, (rows(R) < length(segs) ? segs[rows(R) + 1] : ""))
		}
		else R[i, 5] = R[i, 5] + " " + t
	}
}

// For one column of e(b): its group and vc object when it is a variance component, else ""
void _er_vcrow(string matrix R, string scalar kind, string scalar eq, string scalar name,
	string scalar eq1, string scalar group, string scalar vc)
{
	string rowvector terms, parts, tl, ps
	string scalar ty, inner, g
	real scalar l, k, i, j, r, n

	group = vc = ""
	tl = J(1, 0, "")
	if (kind == "mixed") {
		if (eq == "lnsig_e") {
			group = "Residual"
			tl = "Residual"
			ty = "log_sd"
		}
		else if (regexm(eq, "^(lns|atr)([0-9]+)_([0-9]+)_([0-9]+)(_([0-9]+))?$")) {
			ty = regexs(1) == "lns" ? "log_sd" : "atanh_cor"
			l = strtoreal(regexs(2))
			k = strtoreal(regexs(3))
			i = strtoreal(regexs(4))
			j = regexs(6) != "" ? strtoreal(regexs(6)) : .
			for (r = 1; r <= rows(R); r++) if (R[r, 2] == strofreal(l) & R[r, 3] == strofreal(k)) break
			if (r > rows(R)) return
			group = R[r, 1]
			terms = tokens(R[r, 5])
			// identity and exchangeable: one variance (and one correlation) for all the terms
			if (anyof(("identity", "exchangeable"), strlower(R[r, 4]))) tl = terms
			else if (ty == "log_sd" & i <= length(terms)) tl = terms[i]
			else if (ty == "atanh_cor" & i <= length(terms) & j <= length(terms)) tl = (terms[i], terms[j])
		}
		else if (regexm(eq, "^r_(lns|atr)")) {
			group = "Residual"
			tl = eq
			ty = regexs(1) == "lns" ? "log_sd" : "atanh_cor"
		}
		else return
	}
	else {
		if (eq != "/" | !regexm(name, "^(var|cov)\((.*)\)$")) return
		ty = regexs(1)
		inner = regexs(2)
		parts = tokens(inner, ",")
		parts = select(parts, parts :!= ",")
		for (n = 1; n <= length(parts); n++) {
			if (regexm(parts[n], "^e\.(.+)$")) {
				g = "Residual"
				tl = tl, "Residual"
			}
			else if (regexm(parts[n], "^(.+)\[(.+)\]$")) {
				ps = tokens(regexs(2), ">")
				g = ps[length(ps)]
				tl = tl, regexs(1)
			}
			else return
		}
		group = g
	}
	for (n = 1; n <= length(tl); n++) tl[n] = _er_reterm(tl[n])
	vc = _ej_o(("group", "terms", "type"), (_ej_s(group), _ej_sa(tl), _ej_s(ty)))
}

// specification.random_effects: one entry per equation
string scalar _er_respec(string matrix R)
{
	string rowvector out, tl
	string scalar cv, nest
	real scalar e, n, l
	out = J(1, 0, "")
	for (e = 1; e <= rows(R); e++) {
		tl = tokens(R[e, 5])
		for (n = 1; n <= length(tl); n++) tl[n] = _er_reterm(tl[n])
		cv = strlower(R[e, 4])
		cv = cv == "independent" ? "diagonal" : cv
		// a level is nested in the one before it
		nest = ""
		l = strtoreal(R[e, 2])
		if (l > 1) for (n = 1; n <= rows(R); n++) if (R[n, 2] == strofreal(l - 1)) nest = R[n, 1]
		out = out, _ej_o(("group", "terms", "covariance", "nested_in", "text"), (_ej_s(R[e, 1]), _ej_sa(tl),
			(cv != "" ? _ej_s(cv) : ""), (nest != "" ? _ej_s(nest) : ""), (R[e, 6] != "" ? _ej_s(R[e, 6]) : "")))
	}
	return(_ej_l(out))
}

// structures.random_effects: one entry per level, with e(N_g) and the group sizes
string scalar _er_restruct(string matrix R)
{
	string rowvector out
	real scalar e, l
	out = J(1, 0, "")
	for (e = 1; e <= rows(R); e++) {
		if (R[e, 3] != "1") continue
		l = strtoreal(R[e, 2])
		out = out, _ej_o(("kind", "group", "levels", "size"), (_ej_s("object"), _ej_s(R[e, 1]), _ej_nx(_er_at("e(N_g)", 1, l)),
			_ej_o(("min", "mean", "max"), (_ej_nx(_er_at("e(g_min)", 1, l)), _ej_nx(_er_at("e(g_avg)", 1, l)), _ej_nx(_er_at("e(g_max)", 1, l))))))
	}
	return(_ej_l(out))
}

// specification.survival from stset's characteristics
string scalar _er_stset()
{
	string scalar t, d, ev, id, t0, codes
	real rowvector x
	t = st_global("_dta[st_bt]")
	d = st_global("_dta[st_bd]")
	ev = st_global("_dta[st_ev]")
	id = st_global("_dta[st_id]")
	t0 = st_global("_dta[st_bt0]")
	codes = ""
	if (ev != "") {
		x = strtoreal(tokens(ev))
		codes = missing(x) ? _ej_sa(tokens(ev)) : _ej_na(x)
	}
	return(_ej_o(("time", "start", "event", "event_codes", "id", "strata", "time_varying"),
		(_ej_s(t), (t0 != "" ? _ej_s(t0) : "null"), (d != "" ? _ej_s(d) : ""), codes, (id != "" ? _ej_s(id) : "null"),
		 (_eg("strata") != "" ? _ej_sa(tokens(_eg("strata"))) : ""), (_eg("tvc") != "" ? _ej_sa(tokens(_eg("tvc"))) : ""))))
}

// specification.survey_design from what svy posted
string scalar _er_svyset()
{
	string rowvector st, su
	string scalar fpc, v, vce
	real scalar i, stages
	real matrix x
	stages = _e("stages")
	if (missing(stages)) stages = 1
	st = su = J(1, 0, "")
	for (i = 1; i <= stages; i++) {
		if (_eg("strata" + strofreal(i)) != "") st = st, _eg("strata" + strofreal(i))
		if (_eg("su" + strofreal(i)) != "") su = su, _eg("su" + strofreal(i))
	}
	// the first stage's fpc; Stata reads values up to 1 as sampling rates, others as population sizes
	fpc = "null"
	v = _eg("fpc1")
	if (v != "") {
		x = st_data(., v)
		fpc = _ej_o(("variable", "convention"), (_ej_s(v), _ej_s(max(x) <= 1 ? "sampling_fraction" : "population_size")))
	}
	vce = strlower(_eg("vce"))
	return(_ej_o(("weights", "strata", "psu", "fpc", "variance", "single_psu", "subpopulation", "calibration", "stages"),
		((_eg("wvar") != "" ? _ej_s(_eg("wvar")) : "null"), _ej_sa(st), _ej_sa(su), fpc,
		 _ej_s(vce == "linearized" ? "linearization" : vce), _ej_s(_eg("singleunit")),
		 (_eg("subpop") != "" ? _ej_s(_eg("subpop")) : "null"),
		 (_eg("poststrata") != "" ? _ej_o(("poststrata", "postweight"), (_ej_s(_eg("poststrata")), _ej_s(_eg("postweight")))) : "null"),
		 _ej_n(stages))))
}

// specification.resampling for the bootstrap prefix (and vce(bootstrap))
string scalar _er_bsspec()
{
	string rowvector cl, st
	string scalar seed
	real scalar reps
	reps = _e("N_reps") + (missing(_e("N_misreps")) ? 0 : _e("N_misreps"))
	// the seed as given in seed(); Stata keeps only the state it left (e(rngstate))
	seed = "null"
	if (regexm(_eg("cmdline"), "seed\(([^)]*)\)")) {
		seed = strtrim(regexs(1))
		seed = missing(strtoreal(seed)) ? _ej_s(seed) : _ej_n(strtoreal(seed))
	}
	cl = tokens(_eg("cluster"))
	st = tokens(_eg("strata"))
	return(_ej_o(("method", "reps", "seed", "cluster", "strata", "ci_method", "statistic", "mse"),
		(_ej_s(length(cl) ? "cluster_bootstrap" : "pairs_bootstrap"), _ej_nx(reps), seed,
		 (length(cl) ? _ej_sa(cl) : ""), (length(st) ? _ej_sa(st) : ""), _ej_s("normal"), _ej_s("coefficient"),
		 _ej_b(_eg("mse") != ""))))
}

// stcox: estat phtest, detail (scaled Schoenfeld residuals against analysis time)
void _er_phtest(struct ertests scalar T, string rowvector cn, real scalar lv)
{
	real matrix M
	string rowvector rn
	string scalar s, opt
	real scalar i
	s = lv < 4 ? "" : _ej_o(("name", "version", "call"), (_ej_s("stata"), _ej_s(strofreal(c("stata_version"))), _ej_s("estat phtest, detail")))
	if (_stata("quietly estat phtest, detail", 1)) return
	opt = _ej_o("transform", _ej_s("identity"))
	_tae(T, "proportional_hazards", "schoenfeld", _sc("r(chi2)"), "chi2", _sc("r(df)"), ., _sc("r(p)"), "postestimation",
		"", "global test, against analysis time", s, "options", opt)
	M = st_matrix("r(phtest)")
	if (!rows(M)) return
	rn = st_matrixrowstripe("r(phtest)")[., 2]'
	for (i = 1; i <= rows(M); i++) {
		_tae(T, "proportional_hazards", "schoenfeld", M[i, 2], "chi2", M[i, 3], ., M[i, 4], "postestimation",
			"", "against analysis time", s, ("terms", "options", "rho"), (_ej_sa(rn[i]), opt, _ej_nx(M[i, 1])))
	}
}

string scalar _er_uuid()
{
	transmorphic state
	real rowvector h
	string scalar s
	real scalar i
	state = rngstate()
	rseed(floor(runiform(1, 1) * 1e9) + clock(c("current_date") + " " + c("current_time"), "DMYhms") / 1000)
	h = floor(runiform(1, 16) * 256)
	rngstate(state)
	h[7] = mod(h[7], 16) + 64      // version 4
	h[9] = mod(h[9], 64) + 128     // variant 10xx
	s = ""
	for (i = 1; i <= 16; i++) {
		s = s + (h[i] < 16 ? "0" : "") + inbase(16, h[i])
		if (i == 4 | i == 6 | i == 8 | i == 10) s = s + "-"
	}
	return(s)
}

end
