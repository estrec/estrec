/* estrec for SAS: writes procedure results as estrec records (https://estrec.org).

   %include "estrec.sas";
   %estrec_begin;
   proc logistic data=mydata; class grp / param=ref; model y(event='1') = grp x / covb; run;
   %estrec_end(out=/path/fit.estrec.json);

   %estrec_begin opens an ODS document; the procedures' output goes to it as well as to
   your usual destinations. %estrec_end closes it and writes one record per supported
   procedure run in between (numbered fit-1, fit-2, ... when there are several):
   REG, GLM, SURVEYREG, LOGISTIC, SURVEYLOGISTIC, GENMOD (including GEE), MIXED, GLIMMIX,
   PANEL, SYSLIN, and PROCESS (Hayes's macro, which runs in IML; not part of estrec).

   Options of %estrec_end: OUT= (required), TITLE=, IDENTIFYING=NO (YES also records the
   data set name).

   Numbers: SAS formats print at most about 15 significant digits, so each number is
   written with the most precise of BEST32., E32. and a fixed w.d format. The record's
   core digest needs SAS's OpenSSL support (HASHING_FILE); where that isn't available the
   record says so and `estrec digest` (Python) can add it. Version 0.1.0. MIT licence. */

%let _er_version = 0.1.0;

/* ------------------------------------------------------------------ functions */
proc fcmp outlib=work._estrec_f.f;
  /* a double as JSON text in the RFC 8785 (ECMAScript) form, at most 15 significant digits */
  function er_num(x) $ 48;
    length c t mant digits ip fp $ 48 s sign $ 1;
    if missing(x) then return ('null');
    if x = 0 then return ('0');
    if x = round(x) and abs(x) < 1e15 then return (strip(put(x, 32.)));
    e = floor(log10(abs(x)));
    best = .; c = '';
    do k = 1 to 3;
      if k = 1 then t = strip(put(x, best32.));
      else if k = 2 then t = strip(put(x, e32.));
      else if -10 <= e <= 14 then t = strip(putn(x, cats('32.', min(max(14 - e, 0), 30))));
      else t = '';
      if t ne '' then do;
        d = abs(inputn(t, '32.') - x);
        if best = . or d < best then do; best = d; c = t; end;
      end;
    end;
    t = upcase(strip(c));
    sign = '';
    if substr(t, 1, 1) = '-' then do; sign = '-'; t = substr(t, 2); end;
    ex = 0;
    if index(t, 'E') then do;
      ex = inputn(scan(t, 2, 'E'), '8.');
      t = scan(t, 1, 'E');
    end;
    if index(t, '.') then do;
      ip = scan(t, 1, '.');
      if substr(t, 1, 1) = '.' then do; ip = ''; fp = substr(t, 2); end;
      else fp = substr(t, index(t, '.') + 1);
    end;
    else do; ip = t; fp = ''; end;
    digits = cats(ip, fp);
    n = length(strip(ip)) + ex;
    if strip(ip) = '' then n = ex;
    /* strip leading zeros (moving the point) and trailing zeros */
    do while (length(digits) > 1 and substr(digits, 1, 1) = '0');
      digits = substr(digits, 2); n = n - 1;
    end;
    do while (length(digits) > 1 and substr(digits, length(digits), 1) = '0');
      digits = substr(digits, 1, length(digits) - 1);
    end;
    /* at most 15 significant digits, rounded */
    if length(digits) > 15 then do;
      up = (substr(digits, 16, 1) >= '5');
      v = inputn(substr(digits, 1, 15), '15.') + up;
      digits = strip(put(v, 16.));
      if length(digits) = 16 then n = n + 1;
      do while (length(digits) > 1 and substr(digits, length(digits), 1) = '0');
        digits = substr(digits, 1, length(digits) - 1);
      end;
    end;
    kk = length(digits);
    if kk <= n and n <= 21 then do;
      if n > kk then return (cats(sign, digits, repeat('0', n - kk - 1)));
      return (cats(sign, digits));
    end;
    if 0 < n and n <= 21 then return (cats(sign, substr(digits, 1, n), '.', substr(digits, n + 1)));
    if -6 < n and n <= 0 then do;
      if n = 0 then return (cats(sign, '0.', digits));
      return (cats(sign, '0.', repeat('0', -n - 1), digits));
    end;
    ee = n - 1;
    if kk > 1 then t = cats(substr(digits, 1, 1), '.', substr(digits, 2));
    else t = digits;
    if ee > 0 then return (cats(sign, t, 'e+', ee));
    return (cats(sign, t, 'e-', abs(ee)));
  endsub;

  /* a string as JSON text (without the quotes) */
  function er_str(s $) $ 32767;
    length o $ 32767;
    o = tranwrd(s, '\', '\\');
    o = tranwrd(o, '"', '\"');
    o = tranwrd(o, byte(10), '\n');
    o = tranwrd(o, byte(13), '\r');
    o = tranwrd(o, byte(9), '\t');
    do r = 0 to 31;
      if r not in (9, 10, 13) and index(o, byte(r)) then o = tranwrd(o, byte(r), cats('\u00', put(r, hex2.)));
    end;
    return (trim(o));
  endsub;
  /* the value under the first column heading in NAMES ('|'-separated, lowercase) */
  /* the same, past the first SKIP columns (a conditional table's moderator values) */
  function er_pcol2(names $, cn[*] $, v[*], skip);
    length n h $ 200;
    do i = 1 to countw(names, '|');
      n = scan(names, i, '|');
      do j = skip + 1 to dim(cn);
        h = cn[j];
        if h ne '' then do;
          if h = n or prxchange('s/\(.*\)$//', 1, trim(h)) = n then return (v[j]);
        end;
      end;
    end;
    return (.);
  endsub;
  function er_pcol(names $, cn[*] $, v[*]);
    return (er_pcol2(names, cn, v, 0));
  endsub;
  /* a moderator value for a row's name: to 4 decimals (half away from zero), then 3, as the
     Python and R readers do */
  function er_mvfmt(v) $ 40;
    length s $ 40;
    if missing(v) then return ('');
    if v = round(v) then return (strip(put(v, 32.)));
    n4 = floor(abs(v) * 10000 + 0.5);
    if n4 = 0 then return ('0');
    s = ifc(v < 0, '-', '');
    if n4 < 100 then return (cats(s, '0.00', prxchange('s/0+$//', 1, put(n4, z2.))));
    n3 = floor((n4 + 5) / 10);
    return (cats(s, put(floor(n3 / 1000), 32.), '.', put(mod(n3, 1000), z3.)));
  endsub;
quit;
options append=(cmplib=work._estrec_f);

/* ------------------------------------------------------------------ begin */
%macro estrec_begin;
  ods document name=work._estrec(write);
  %put NOTE: estrec: capturing output for estrec records (%nrstr(%estrec_end) writes them).;
%mend;

/* ------------------------------------------------------------------ row helpers
   A record is built as rows (path, kind, sval) in work._er_rec, then serialised. Paths are
   '/'-separated; '#0001'-style components are array positions. kind: s string, n number,
   i integer, b boolean, z null, a empty array, o empty object. Use inside a DATA step that
   declares: length path $ 600 kind $ 1 sval $ 32767; and keeps path kind sval seq. */
%macro _er_s(p, v);  path = &p; kind = 's'; sval = &v; seq + 1; output; %mend;
%macro _er_n(p, v);  path = &p; if missing(&v) then do; kind = 'z'; sval = 'null'; end;
                     else do; kind = 'n'; sval = er_num(&v); end; seq + 1; output; %mend;
%macro _er_i(p, v);  path = &p; if missing(&v) then do; kind = 'z'; sval = 'null'; end;
                     else do; kind = 'i'; sval = strip(put(&v, 32.)); end; seq + 1; output; %mend;
%macro _er_b(p, v);  path = &p; kind = 'b'; sval = ifc(&v, 'true', 'false'); seq + 1; output; %mend;
/* a number only when present (metrics the procedure didn't print are left out) */
%macro _er_nn(p, v); if not missing(&v) then do; path = &p; kind = 'n'; sval = er_num(&v); seq + 1; output; end; %mend;
%macro _er_z(p);     path = &p; kind = 'z'; sval = 'null'; seq + 1; output; %mend;
%macro _er_ea(p);    path = &p; kind = 'a'; sval = '[]'; seq + 1; output; %mend;
%macro _er_eo(p);    path = &p; kind = 'o'; sval = '{}'; seq + 1; output; %mend;
%macro _er_ix(i);    cats('#', put(&i, z4.)) %mend;

%macro _er_part(name);
  data work._er_p_&name;
    length path $ 600 kind $ 1 sval $ 32767;
    retain seq 0 part &_er_partno;
    keep part seq path kind sval;
%mend;
%macro _er_endpart(name);
  run;
  proc append base=work._er_rec data=work._er_p_&name force; run;
  proc datasets lib=work nolist; delete _er_p_&name; quit;
  %let _er_partno = %eval(&_er_partno + 1);
%mend;

/* ------------------------------------------------------------------ replay helper */
/* Copies table &table of procedure directory &dir into work.&out (quietly). Sets &out to
   _NONE_ in macro var _er_got if the procedure didn't produce it. */
%macro _er_get(dir, table, out);
  %local p;
  %let p =;
  proc sql noprint;
    select path into :p trimmed from work._er_list
    where type = 'Table' and upcase(substr(path, 1, length("&dir") + 1)) = upcase(cats("&dir", '\'))
      and upcase(scan(scan(path, -1, '\'), 1, '#')) = upcase("&table")
    order by _ord;
  quit;
  %if %length(&p) %then %do;
    ods exclude all;
    proc document name=work._estrec;
      ods output &table = work.&out;
      replay &p;
    run; quit;
    ods exclude none;
  %end;
  %else %do;
    data work.&out; stop; run;
  %end;
%mend;

%macro _er_has(ds);
  %local dsid n rc;
  %let n = 0;
  %if %sysfunc(exist(work.&ds)) %then %do;
    %let dsid = %sysfunc(open(work.&ds));
    %let n = %sysfunc(attrn(&dsid, nlobs));
    %let rc = %sysfunc(close(&dsid));
  %end;
  %eval(&n > 0)
%mend;
%macro _er_nrows(ds);
  %local dsid n rc;
  %let dsid = %sysfunc(open(work.&ds));
  %let n = %sysfunc(attrn(&dsid, nlobs));
  %let rc = %sysfunc(close(&dsid));
  &n
%mend;
%macro _er_hasvar(ds, var);
  %local dsid n rc;
  %let n = 0;
  %if %sysfunc(exist(work.&ds)) %then %do;
    %let dsid = %sysfunc(open(work.&ds));
    %let n = %sysfunc(varnum(&dsid, &var));
    %let rc = %sysfunc(close(&dsid));
  %end;
  %eval(&n > 0)
%mend;

/* ------------------------------------------------------------------ serialiser */
/* Writes work._er_rec (sorted as given) as JSON to &file. PRETTY=1: indented, in row order;
   PRETTY=0: no whitespace (for the canonical form, rows sorted by path). */
%macro _er_write(data, file, pretty=1);
  data _null_;
    set &data end=last;
    file "&file" recfm=n lrecl=32767;   /* bytes as written: text is converted to UTF-8 below */
    length piece $ 32767 c $ 200 val $ 32767;
    array comp{0:40} $ 200 _temporary_;
    array isarr{0:40} _temporary_;
    array used{0:40} _temporary_;
    retain depth 0;
    nl = byte(10);
    if _n_ = 1 then do;
      piece = '{'; len = 1; put piece $varying32767. len @;
      depth = 0; isarr{0} = 0; used{0} = 0;
    end;
    n = countw(path, '/');
    /* common prefix of the open containers and this row's containers */
    k = 0;
    do j = 1 to min(depth, n - 1);
      if comp{j} = scan(path, j, '/') then k = j; else leave;
    end;
    /* close deeper containers */
    do j = depth to k + 1 by -1;
      if &pretty then do; piece = cat(nl, repeat(' ', j - 2)); if j = 1 then piece = nl; len = j; put piece $varying32767. len @; end;
      piece = ifc(isarr{j}, ']', '}'); len = 1; put piece $varying32767. len @;
    end;
    depth = k;
    /* open new containers */
    do j = k + 1 to n - 1;
      c = scan(path, j, '/');
      if used{j - 1} then do; piece = ','; len = 1; put piece $varying32767. len @; end;
      used{j - 1} = 1;
      if &pretty then do; piece = cat(nl, repeat(' ', j - 2)); if j = 1 then piece = nl; len = j; put piece $varying32767. len @; end;
      if not isarr{j - 1} then do;
        piece = cats('"', er_str(c), '":');
        %if %qupcase(&sysencoding) ne %str(UTF-8) %then %do; piece = kcvt(piece, "&sysencoding", 'utf-8'); %end;
        if &pretty then piece = catt(piece, ' ');
        len = lengthn(piece) + &pretty; put piece $varying32767. len @;
      end;
      isarr{j} = (substr(scan(path, j + 1, '/'), 1, 1) = '#');
      piece = ifc(isarr{j}, '[', '{'); len = 1; put piece $varying32767. len @;
      comp{j} = c; used{j} = 0;
    end;
    depth = n - 1;
    /* the value */
    if used{depth} then do; piece = ','; len = 1; put piece $varying32767. len @; end;
    used{depth} = 1;
    if &pretty then do; piece = cat(nl, repeat(' ', n - 2)); if n = 1 then piece = nl; len = n; put piece $varying32767. len @; end;
    c = scan(path, n, '/');
    if not isarr{depth} then do;
      piece = cats('"', er_str(c), '":');
      %if %qupcase(&sysencoding) ne %str(UTF-8) %then %do; piece = kcvt(piece, "&sysencoding", 'utf-8'); %end;
      if &pretty then piece = catt(piece, ' ');
      len = lengthn(piece) + &pretty; put piece $varying32767. len @;
    end;
    if kind = 's' then val = cats('"', er_str(sval), '"');
    else val = strip(sval);
    %if %qupcase(&sysencoding) ne %str(UTF-8) %then %do;
      if kind = 's' then val = kcvt(val, "&sysencoding", 'utf-8');
    %end;
    len = lengthn(val); put val $varying32767. len @;
    if last then do;
      do j = depth to 1 by -1;
        if &pretty then do; piece = cat(nl, repeat(' ', j - 2)); if j = 1 then piece = nl; len = j; put piece $varying32767. len @; end;
        piece = ifc(isarr{j}, ']', '}'); len = 1; put piece $varying32767. len @;
      end;
      if &pretty then do; piece = cat(nl, '}', nl); len = 3; put piece $varying32767. len; end;
      else do; piece = '}'; len = 1; put piece $varying32767. len; end;
    end;
  run;
%mend;

/* ------------------------------------------------------------------ shared record parts */
/* meta, provenance and history rows; estimator etc. come from macro variables set by the
   procedure builder: _er_family _er_method _er_dist _er_link _er_resp _er_profiles (space
   separated) _er_title _er_cmd _er_dataset */
%macro _er_common;
  %_er_part(common)
    length id $ 36 now $ 20;
    id = lowcase(uuidgen());
    substr(id, 15, 1) = '4'; substr(id, 20, 1) = substr('89ab', mod(rank(substr(id, 20, 1)), 4) + 1, 1);
    now = cats(put(tzones2u(datetime()), e8601dt19.), 'Z');
    %_er_s('schema', 'estrec/0.1');
    %_er_s('meta/id', id);
    %_er_s('meta/created', now);
    %_er_s('meta/status', "&_er_status");
    %_er_s('meta/estimator/family', "&_er_family");
    %_er_s('meta/estimator/method', "&_er_method");
    %if %length(&_er_dist) %then %_er_s('meta/estimator/distribution', "&_er_dist");;
    %if %length(&_er_link) %then %_er_s('meta/estimator/link', "&_er_link");;
    %if %length(&_er_resp) %then %_er_s('meta/responses/#0001', "&_er_resp");;
    %local i;
    %do i = 1 %to %sysfunc(countw(&_er_profiles, %str( )));
      %_er_s("meta/profiles/#%sysfunc(putn(&i, z4.))", "%scan(&_er_profiles, &i, %str( ))");
    %end;
    %_er_s('meta/title', symget('_er_title'));
    %_er_s('meta/producer/name', 'estrec for SAS');
    %_er_s('meta/producer/version', "&_er_version");
  %_er_endpart(common)
%mend;

%macro _er_tail;
  %_er_part(tail)
    length now $ 20;
    now = cats(put(tzones2u(datetime()), e8601dt19.), 'Z');
    %_er_s('provenance/software/#0001/name', 'SAS');
    %_er_s('provenance/software/#0001/version', "&sysvlong");
    %_er_s('provenance/software/#0001/purl', "pkg:generic/sas@&sysvlong");
    %_er_s('provenance/software/#0001/role', 'estimator');
    %_er_s('provenance/software/#0001/command', "&_er_cmd");
    %if &_er_pisproc %then %do;   /* PROCESS (Hayes) ran in IML */
      %_er_s('provenance/software/#0002/name', 'PROCESS');
      %if %length(&_er_pver) %then %_er_s('provenance/software/#0002/version', "&_er_pver");;
      %_er_s('provenance/software/#0002/role', 'estimator');
      %_er_s('provenance/software/#0002/url', 'https://www.afhayes.com/download.html');
      %_er_s('provenance/software/#0002/command', "PROCESS model &_er_pmodel");
    %end;
    %_er_s("provenance/software/#000%eval(2 + &_er_pisproc)/name", 'estrec for SAS');
    %_er_s("provenance/software/#000%eval(2 + &_er_pisproc)/version", "&_er_version");
    %_er_s("provenance/software/#000%eval(2 + &_er_pisproc)/role", 'writer');
    %_er_s('provenance/data/#0001/role', 'estimation');
    %if %length(&_er_rows) %then %_er_i('provenance/data/#0001/rows', &_er_rows);;
    %if %upcase(&_er_identifying) = YES and %length(&_er_dataset) %then
      %_er_s('provenance/data/#0001/name', "&_er_dataset");;
    %_er_s('history/#0001/when', now);
    %_er_s('history/#0001/by/name', 'estrec for SAS');
    %_er_s('history/#0001/by/version', "&_er_version");
    %_er_s('history/#0001/action', 'created');
  %_er_endpart(tail)
%mend;

/* parameters from work._er_par: term, est, se, stat, p, lo, hi, df, dropped ('' or
   'reference'/'collinear'), var1 lev1 var2 lev2 (canonical factors; var1 '(Intercept)' for
   the intercept) */
%macro _er_params;
  %_er_part(params)
    set work._er_par end=_last;
    length base $ 60 cname $ 400;
    retain _k 0;
    _k + 1;
    base = cats('parameters/#', put(_k, z4.));
    %_er_s(cats(base, '/term'), term);
    if var1 = '(Intercept)' then do;
      %_er_s(cats(base, '/canonical/name'), '(Intercept)');
      %_er_ea(cats(base, '/canonical/factors'));
    end;
    else if var1 ne '' then do;
      if var2 = '' then cname = cats(var1, lev1);
      else if (lev1 = '') = (lev2 = '') then cname = catx(':', cats(var1, lev1), cats(var2, lev2));
      else cname = catx('#', ifc(lev1 = '', cats('c.', var1), cats(lev1, '.', var1)),
                             ifc(lev2 = '', cats('c.', var2), cats(lev2, '.', var2)));
      %_er_s(cats(base, '/canonical/name'), cname);
      %_er_s(cats(base, '/canonical/factors/#0001/variable'), var1);
      if lev1 ne '' then do; %_er_s(cats(base, '/canonical/factors/#0001/level'), lev1); end;
      if var2 ne '' then do;
        %_er_s(cats(base, '/canonical/factors/#0002/variable'), var2);
        if lev2 ne '' then do; %_er_s(cats(base, '/canonical/factors/#0002/level'), lev2); end;
      end;
    end;
    if dropped ne '' then do; %_er_s(cats(base, '/dropped'), dropped); end;
    else do;
      %_er_n(cats(base, '/estimate'), est);
      %_er_n(cats(base, '/std_error'), se);
      if not missing(stat) then do; %_er_n(cats(base, '/statistic'), stat); end;
      if not missing(p) then do; %_er_n(cats(base, '/p_value'), p); end;
      if not missing(lo) then do; %_er_n(cats(base, '/conf_low'), lo); end;
      if not missing(hi) then do; %_er_n(cats(base, '/conf_high'), hi); end;
      if not missing(df) then do; %_er_n(cats(base, '/df'), df); end;
    end;
  %_er_endpart(params)
%mend;

/* the default vcov from work._er_cov (term, c1..cK in the order of the non-dropped
   parameters) or, when that has no rows, the variances only (squared standard errors)
   with null covariances. &type &convention &formula; &dft = df_t (blank: none). */
%macro _er_vcov(idx=1, type=, convention=, formula=, dft=, default=1, tooltype=,
                cluster=, nclusters=);
  %local K;
  proc sql noprint; select count(*) into :K trimmed from work._er_par where dropped = ''; quit;
  data work._er_terms; set work._er_par(where=(dropped = '')); keep term se; run;
  %let _er_full = %_er_has(_er_cov);
  %if &_er_full %then %do;
    %local NA;
    proc sql noprint; select count(*) into :NA trimmed from work._er_par; quit;
    %if %_er_nrows(_er_cov) = &NA and &NA > &K %then %do;
      data work._er_keep; set work._er_par; _pos = _n_; if dropped = ''; keep _pos; run;
      proc sql noprint; select _pos into :_er_pos separated by ',' from work._er_keep; quit;
      data work._er_cov; set work._er_cov;
        array a{*} c1-c&NA; array b{&K} _temporary_;
        if whichn(_n_, &_er_pos) = 0 then delete;
        %do _q = 1 %to &K; b{&_q} = a{%scan(%quote(&_er_pos), &_q, %str(,))}; %end;
        do _q = 1 to &K; a{_q} = b{_q}; end;
        drop _q;
      run;
    %end;
  %end;
  %_er_part(vcov&idx)
    length base $ 60;
    base = "structures/vcov/#%sysfunc(putn(&idx, z4.))";
    %_er_s(cats(base, '/kind'), 'matrix');
    do _r = 1 to &K;
      set work._er_terms point=_r;
      %_er_s(cats(base, '/labels/#', put(_r, z4.)), term);
    end;
    %if &_er_full %then %do;
      array cc{*} c1-c&K;
      do _r = 1 to &K;
        set work._er_cov point=_r;
        do _c = 1 to &K;
          %_er_n(cats(base, '/data/#', put(_r, z4.), '/#', put(_c, z4.)), cc{_c});
        end;
      end;
    %end;
    %else %do;
      array ses{&K} _temporary_;
      do _r = 1 to &K; set work._er_terms point=_r; ses{_r} = se; end;
      do _r = 1 to &K;
        do _c = 1 to &K;
          if _r = _c then do; _v = ses{_r} ** 2; %_er_n(cats(base, '/data/#', put(_r, z4.), '/#', put(_c, z4.)), _v); end;
          else do; %_er_z(cats(base, '/data/#', put(_r, z4.), '/#', put(_c, z4.))); end;
        end;
      end;
    %end;
    %_er_s(cats(base, '/type'), "&type");
    %if %length(&tooltype) %then %_er_s(cats(base, '/tool_type'), "&tooltype");;
    %if %length(&nclusters) %then %_er_i(cats(base, '/n_clusters_min'), &nclusters);;
    %if %length(&cluster) %then %_er_s(cats(base, '/cluster/#0001'), "&cluster");;
    %_er_s(cats(base, '/ssc/convention'), "&convention");
    %_er_s(cats(base, '/ssc/formula'), "&formula");
    %if %length(&dft) %then %_er_n(cats(base, '/df_t'), &dft);;
    %_er_b(cats(base, '/default'), &default);
    stop;
  %_er_endpart(vcov&idx)
  %if not &_er_full %then %let _er_msgs = &_er_msgs|no_vcov_matrix;
%mend;

/* ------------------------------------------------------------------ procedures */

/* class variables of the procedure, for splitting 'cat 2' into variable and level */
%macro _er_classvars(dir);
  %_er_get(&dir, ClassLevels, _er_cl)
  %global _er_class;
  %let _er_class =;
  %if %_er_has(_er_cl) %then %do;
    proc sql noprint; select distinct upcase(strip(Class)) into :_er_class separated by ' ' from work._er_cl; quit;
  %end;
  %else %do;
    %_er_get(&dir, ClassVarInfo, _er_cl)
    %if %_er_has(_er_cl) and %_er_hasvar(_er_cl, ClassVar) %then %do;
      proc sql noprint; select distinct upcase(strip(ClassVar)) into :_er_class separated by ' ' from work._er_cl; quit;
    %end;
  %end;
%mend;

/* 'cat 2' / 'cat*x1 2' -> var1 lev1 var2 lev2, given the class variables */
%macro _er_split(name, levels);
  length _w1 $ 200;
  var1 = ''; lev1 = ''; var2 = ''; lev2 = '';
  _w1 = scan(&name, 1, ' ');
  if upcase(_w1) = 'INTERCEPT' then var1 = '(Intercept)';
  else do;
    var1 = scan(_w1, 1, '*'); var2 = scan(_w1, 2, '*');
    _lv = strip(substr(&name, length(_w1) + 1));
    %if %length(&levels) %then %do; if _lv = '' then _lv = strip(&levels); %end;
    _nl = 0;
    if "&_er_class" ne '' then do;
      if indexw("&_er_class", upcase(var1)) then do; _nl + 1; lev1 = scan(_lv, _nl, ' '); end;
      if var2 ne '' and indexw("&_er_class", upcase(var2)) then do; _nl + 1; lev2 = scan(_lv, _nl, ' '); end;
    end;
    else if _lv ne '' then do;   /* no class list: levels follow the variables in order */
      lev1 = scan(_lv, 1, ' ');
      if var2 ne '' then lev2 = scan(_lv, 2, ' ');
    end;
  end;
%mend;

%macro _er_spec_sample(read, used);
  %_er_part(sample)
    %_er_z('specification/sample/restriction');
    %_er_i('specification/sample/rows_input', &read);
    _m = &read - &used;
    %_er_i('specification/sample/dropped/missing', _m);
  %_er_endpart(sample)
%mend;

%macro _er_terms_rows;
  %_er_part(terms)
    set work._er_par(where=(dropped = ''));
    %_er_s(cats('specification/terms/#', put(_n_, z4.)), term);
  %_er_endpart(terms)
%mend;

/* ---- REG */
%macro _er_reg(dir);
  %_er_get(&dir, ParameterEstimates, _er_pe)
  %_er_get(&dir, ANOVA, _er_an)
  %_er_get(&dir, FitStatistics, _er_fs)
  %_er_get(&dir, NObs, _er_no)
  %_er_get(&dir, CovB, _er_cb)
  %_er_get(&dir, ACovEst, _er_acov)
  %if not %_er_has(_er_pe) %then %do; %let _er_skip = REG printed no Parameter Estimates; %return; %end;
  data work._er_par; set work._er_pe;
    length term var1 lev1 var2 lev2 $ 200 dropped $ 12;
    term = strip(Variable);
    est = Estimate; se = StdErr; stat = tValue; p = Probt; df = .;
    %if %_er_hasvar(_er_pe, LowerCL) %then %do; lo = LowerCL; hi = UpperCL; %end;
    %else %do; lo = .; hi = .; %end;
    dropped = ifc(DF = 0, 'collinear', '');
    var1 = ifc(upcase(term) = 'INTERCEPT', '(Intercept)', term); lev1 = ''; var2 = ''; lev2 = '';
    call symputx('_er_resp', Dependent);
    keep term est se stat p lo hi df dropped var1 lev1 var2 lev2 %if %_er_hasvar(_er_pe, HCStdErr) %then HCStdErr HCCMethod;;
  run;
  /* covariance: CovB columns are the regressors, in order */
  data work._er_cov; set work._er_cb;
    array v{*} _numeric_;
    array c{100};
    _j = 0;
    do _i = 1 to dim(v);
      if upcase(vname(v{_i})) not in ('_RUN_') then do; _j + 1; if _j <= 100 then c{_j} = v{_i}; end;
    end;
    keep c:;
  run;
  data _null_; set work._er_no;
    if Label =: 'Number of Observations Read' then call symputx('_er_rows', N);
    if Label =: 'Number of Observations Used' then call symputx('_er_nobs', N);
  run;
  data _null_; set work._er_an;
    if Source = 'Error' then do; call symputx('_er_dfr', DF); call symputx('_er_rss', put(SS, hex16.)); end;
    if Source = 'Corrected Total' then call symputx('_er_tss', put(SS, hex16.));
    if Source = 'Model' then do; call symputx('_er_F', put(FValue, hex16.)); call symputx('_er_Fp', put(ProbF, hex16.)); call symputx('_er_dfm', DF); end;
  run;
  data _null_; set work._er_fs;
    if Label1 = 'Root MSE' then call symputx('_er_sigma', put(nValue1, hex16.));
    if Label2 = 'R-Square' then call symputx('_er_r2', put(nValue2, hex16.));
    if Label2 = 'Adj R-Sq' then call symputx('_er_ar2', put(nValue2, hex16.));
  run;
  %let _er_family = linear; %let _er_method = ols; %let _er_dist =; %let _er_link =;
  %let _er_profiles = inference/0.1;
  %_er_common
  %_er_spec_sample(&_er_rows, &_er_nobs)
  %_er_terms_rows
  %_er_part(metrics)
    %_er_i('metrics/nobs', &_er_nobs);
    %_er_i('metrics/df_residual', &_er_dfr);
    %_er_nn('metrics/r2', input("&_er_r2", hex16.));
    %_er_nn('metrics/adj_r2', input("&_er_ar2", hex16.));
    %_er_nn('metrics/sigma', input("&_er_sigma", hex16.));
    %_er_nn('metrics/rss', input("&_er_rss", hex16.));
    %_er_nn('metrics/tss', input("&_er_tss", hex16.));
    %_er_n('metrics/conf_level', 0.95);
  %_er_endpart(metrics)
  %_er_params
  %_er_vcov(type=iid, convention=SAS REG, formula=%str(sigma^2 (X%'X)^-1, sigma^2 = RSS / (N - K)), dft=&_er_dfr)
  /* heteroskedasticity-consistent standard errors (MODEL / HCC), and the matrix with ACOV */
  %if %_er_hasvar(_er_par, HCStdErr) %then %do;
    data _null_; set work._er_par(obs=1); call symputx('_er_hcm', HCCMethod); run;
    data work._er_par; set work._er_par; se = HCStdErr; run;
    data work._er_cov; set work._er_acov;
      array v{*} _numeric_; array c{100}; _j = 0;
      do _i = 1 to dim(v); if upcase(vname(v{_i})) not in ('_RUN_') then do; _j + 1; c{_j} = v{_i}; end; end;
      keep c:;
    run;
    %_er_vcov(idx=2, type=HC%sysfunc(compress(&_er_hcm, , kd)), convention=SAS REG,
              formula=%str(HC sandwich (MODEL / HCC HCCMETHOD=&_er_hcm)), dft=&_er_dfr, default=0)
  %end;
  %_er_part(tests)
    %_er_s('tests/#0001/id', 't1');
    %_er_s('tests/#0001/category', 'model');
    %_er_s('tests/#0001/name', 'f');
    %_er_s('tests/#0001/origin', 'estimation');
    %_er_n('tests/#0001/statistic', input("&_er_F", hex16.));
    %_er_s('tests/#0001/distribution', 'F');
    %_er_i('tests/#0001/df1', &_er_dfm);
    %_er_i('tests/#0001/df2', &_er_dfr);
    %_er_n('tests/#0001/p_value', input("&_er_Fp", hex16.));
    %_er_s('tests/#0001/vcov', 'iid');
  %_er_endpart(tests)
%mend;

/* ---- LOGISTIC */
%macro _er_logistic(dir);
  %_er_get(&dir, ParameterEstimates, _er_pe)
  %_er_get(&dir, ModelInfo, _er_mi)
  %_er_get(&dir, NObs, _er_no)
  %_er_get(&dir, FitStatistics, _er_fs)
  %_er_get(&dir, GlobalTests, _er_gt)
  %_er_get(&dir, ConvergenceStatus, _er_cs)
  %_er_get(&dir, CovB, _er_cb)
  %_er_get(&dir, ResponseProfile, _er_rp)
  %if not %_er_has(_er_pe) %then %do; %let _er_skip = LOGISTIC printed no Parameter Estimates; %return; %end;
  %let _er_link = logit;
  data _null_; set work._er_mi;
    if Description = 'Response Variable' then call symputx('_er_resp', Value);
    if Description = 'Data Set' then call symputx('_er_dataset', Value);
    if Description = 'Model' then do;
      if index(lowcase(Value), 'probit') then call symputx('_er_link', 'probit');
      else if index(lowcase(Value), 'cloglog') then call symputx('_er_link', 'cloglog');
    end;
  run;
  data work._er_par; set work._er_pe;
    length term var1 lev1 var2 lev2 $ 200 dropped $ 12;
    %if %_er_hasvar(_er_pe, ClassVal0) %then %do;
      term = catx(' ', Variable, ClassVal0); lev1 = strip(ClassVal0);
    %end;
    %else %do; term = strip(Variable); lev1 = ''; %end;
    var1 = ifc(upcase(Variable) = 'INTERCEPT', '(Intercept)', strip(Variable)); var2 = ''; lev2 = '';
    est = Estimate; se = StdErr; p = ProbChiSq; df = .;
    stat = ifn(StdErr > 0, Estimate / StdErr, .);
    lo = .; hi = .;
    dropped = ifc(DF = 0, 'collinear', '');
    keep term est se stat p lo hi df dropped var1 lev1 var2 lev2;
  run;
  data work._er_cov; set work._er_cb;
    array v{*} _numeric_; array c{100}; _j = 0;
    do _i = 1 to dim(v); if upcase(vname(v{_i})) not in ('_RUN_') then do; _j + 1; c{_j} = v{_i}; end; end;
    keep c:;
  run;
  data _null_; set work._er_no;
    if Label =: 'Number of Observations Read' then call symputx('_er_rows', N);
    if Label =: 'Number of Observations Used' then call symputx('_er_nobs', N);
  run;
  %let _er_m2ll =; %let _er_aic =; %let _er_bic =;
  data _null_; set work._er_fs;
    if Criterion = '-2 Log L' then call symputx('_er_m2ll', put(InterceptAndCovariates, hex16.));
    if Criterion = 'AIC' then call symputx('_er_aic', put(InterceptAndCovariates, hex16.));
    if Criterion = 'SC' then call symputx('_er_bic', put(InterceptAndCovariates, hex16.));
  run;
  %let _er_conv = 1;
  data _null_; set work._er_cs; call symputx('_er_conv', Status = 0); run;
  %if not &_er_conv %then %let _er_status = warning;
  %let _er_family = glm; %let _er_method = ml; %let _er_dist = binomial;
  %let _er_profiles = inference/0.1 glm/0.1;
  %_er_common
  %_er_spec_sample(&_er_rows, &_er_nobs)
  %_er_terms_rows
  %_er_part(metrics)
    %_er_i('metrics/nobs', &_er_nobs);
    %if %length(input("&_er_m2ll", hex16.)) %then %do; _ll = -(input("&_er_m2ll", hex16.)) / 2; %_er_nn('metrics/log_lik', _ll); %end;
    %if %length(input("&_er_aic", hex16.)) %then %_er_nn('metrics/aic', input("&_er_aic", hex16.));;
    %if %length(input("&_er_bic", hex16.)) %then %_er_nn('metrics/bic', input("&_er_bic", hex16.));;
    %_er_n('metrics/conf_level', 0.95);
  %_er_endpart(metrics)
  %_er_params
  %_er_vcov(type=iid, convention=SAS LOGISTIC, formula=%str(inverse of the information matrix))
  %_er_part(num)
    %_er_s('structures/numerics/kind', 'object');
    %_er_b('structures/numerics/iterative', 1);
    %_er_s('structures/numerics/algorithm', 'fisher_scoring');
    %_er_b('structures/numerics/converged', &_er_conv);
  %_er_endpart(num)
  %_er_part(tests)
    set work._er_gt(where=(Test = 'Likelihood Ratio'));
    %_er_s('tests/#0001/id', 't1');
    %_er_s('tests/#0001/category', 'model');
    %_er_s('tests/#0001/name', 'likelihood_ratio');
    %_er_s('tests/#0001/origin', 'estimation');
    %_er_n('tests/#0001/statistic', ChiSq);
    %_er_s('tests/#0001/distribution', 'chi2');
    %_er_i('tests/#0001/df', DF);
    %_er_n('tests/#0001/p_value', ProbChiSq);
  %_er_endpart(tests)
%mend;

/* ---- GENMOD (incl. REPEATED: GEE) */
%macro _er_genmod(dir);
  %_er_classvars(&dir)
  %_er_get(&dir, ParameterEstimates, _er_pe)
  %_er_get(&dir, GEEEmpPEst, _er_gee)
  %_er_get(&dir, ModelInfo, _er_mi)
  %_er_get(&dir, NObs, _er_no)
  %_er_get(&dir, ModelFit, _er_mf)
  %_er_get(&dir, ConvergenceStatus, _er_cs)
  %_er_get(&dir, CovB, _er_cb)
  %_er_get(&dir, GEERCov, _er_rc)
  %_er_get(&dir, GEEModInfo, _er_gm)
  %_er_get(&dir, GEEFitCriteria, _er_gf)
  %let _er_isgee = %_er_has(_er_gee);
  %if not %_er_has(_er_pe) and not &_er_isgee %then %do; %let _er_skip = GENMOD printed no Parameter Estimates; %return; %end;
  data _null_; set work._er_mi;
    if Label1 = 'Distribution' then call symputx('_er_dist', lowcase(cValue1));
    if Label1 = 'Link Function' then call symputx('_er_link', lowcase(cValue1));
    if Label1 = 'Dependent Variable' then call symputx('_er_resp', cValue1);
    if Label1 = 'Data Set' then call symputx('_er_dataset', cValue1);
  run;
  %if %quote(&_er_dist) = normal %then %let _er_dist = gaussian;
  %if %quote(&_er_dist) = %quote(negative binomial) %then %let _er_dist = negative_binomial;
  %if %quote(&_er_dist) = %quote(inverse gaussian) %then %let _er_dist = inverse_gaussian;
  %if %quote(&_er_link) = %quote(complementary log-log) %then %let _er_link = cloglog;
  %let _er_disp =;
  %if &_er_isgee %then %do;
    data work._er_par; set work._er_gee;
      length term var1 lev1 var2 lev2 $ 200 dropped $ 12;
      term = catx(' ', Parm, %if %_er_hasvar(_er_gee, Level1) %then Level1; %else ''; );
      %_er_split(term, )
      est = Estimate; se = Stderr; stat = Z; p = ProbZ; lo = LowerCL; hi = UpperCL; df = .;
      dropped = ifc(Estimate = 0 and Stderr = 0, 'reference', '');
      keep term est se stat p lo hi df dropped var1 lev1 var2 lev2;
    run;
    %let _cvds = _er_rc;
  %end;
  %else %do;
    data work._er_par; set work._er_pe;
      length term var1 lev1 var2 lev2 $ 200 dropped $ 12;
      if upcase(Parameter) = 'SCALE' then do; call symputx('_er_disp', put(Estimate, hex16.)); delete; end;
      term = catx(' ', Parameter, %if %_er_hasvar(_er_pe, Level1) %then Level1; %else ''; );
      %_er_split(term, )
      est = Estimate; se = StdErr; p = ProbChiSq; lo = LowerWaldCL; hi = UpperWaldCL; df = .;
      stat = ifn(StdErr > 0, Estimate / StdErr, .);
      dropped = ifc(DF = 0, 'reference', '');
      keep term est se stat p lo hi df dropped var1 lev1 var2 lev2;
    run;
    %let _cvds = _er_cb;
  %end;
  /* Prm-labelled covariance: rows and columns in the order of the non-dropped parameters */
  data work._er_cov; set work.&_cvds;
    array v{*} _numeric_; array c{100}; _j = 0;
    do _i = 1 to dim(v); if upcase(vname(v{_i})) not in ('_RUN_') then do; _j + 1; c{_j} = v{_i}; end; end;
    keep c:;
  run;
  data _null_; set work._er_no;
    if Label =: 'Number of Observations Read' then call symputx('_er_rows', N);
    if Label =: 'Number of Observations Used' then call symputx('_er_nobs', N);
  run;
  %let _er_ll =; %let _er_aic =; %let _er_bic =; %let _er_dev =; %let _er_pear =; %let _er_qic =;
  data _null_; set work._er_mf;
    if Criterion = 'Full Log Likelihood' then call symputx('_er_ll', put(Value, hex16.));
    if Criterion = 'Log Likelihood' and symget('_er_ll') = '' then call symputx('_er_ll', put(Value, hex16.));
    if Criterion = 'AIC (smaller is better)' then call symputx('_er_aic', put(Value, hex16.));
    if Criterion = 'BIC (smaller is better)' then call symputx('_er_bic', put(Value, hex16.));
    if Criterion = 'Deviance' then call symputx('_er_dev', put(Value, hex16.));
    if Criterion = 'Pearson Chi-Square' then call symputx('_er_pear', put(Value, hex16.));
  run;
  %let _er_ncl =; %let _er_subj =;
  %if &_er_isgee %then %do;
    data _null_; set work._er_gm;
      if Label1 = 'Number of Clusters' then call symputx('_er_ncl', nValue1);
      if Label1 = 'Subject Effect' then call symputx('_er_subj', scan(cValue1, 1, ' ('));
    run;
    data _null_; set work._er_gf; if Criterion = 'QIC' then call symputx('_er_qic', put(Value, hex16.)); run;
    %let _er_ll =; %let _er_aic =; %let _er_bic =;
  %end;
  %let _er_conv = 1;
  data _null_; set work._er_cs; call symputx('_er_conv', Status = 0); run;
  %if not &_er_conv %then %let _er_status = warning;
  %let _er_family = glm; %let _er_method = %sysfunc(ifc(&_er_isgee, gee, ml));
  %let _er_profiles = inference/0.1 glm/0.1;
  %_er_common
  %_er_spec_sample(&_er_rows, &_er_nobs)
  %_er_terms_rows
  %if &_er_isgee %then %do;
    %_er_part(clus) %_er_s('specification/clusters/#0001', "&_er_subj"); %_er_endpart(clus)
  %end;
  %_er_part(metrics)
    %_er_i('metrics/nobs', &_er_nobs);
    %if %length(input("&_er_ll", hex16.)) %then %_er_nn('metrics/log_lik', input("&_er_ll", hex16.));;
    %if %length(input("&_er_dev", hex16.)) %then %_er_nn('metrics/deviance', input("&_er_dev", hex16.));;
    %if %length(input("&_er_pear", hex16.)) %then %_er_nn('metrics/pearson_chi2', input("&_er_pear", hex16.));;
    %if %length(input("&_er_aic", hex16.)) %then %_er_nn('metrics/aic', input("&_er_aic", hex16.));;
    %if %length(input("&_er_bic", hex16.)) %then %_er_nn('metrics/bic', input("&_er_bic", hex16.));;
    %if %length(input("&_er_qic", hex16.)) %then %_er_nn('metrics/qic', input("&_er_qic", hex16.));;
    %if %length(input("&_er_disp", hex16.)) %then %_er_nn('metrics/dispersion', input("&_er_disp", hex16.));;
    %_er_n('metrics/conf_level', 0.95);
  %_er_endpart(metrics)
  %_er_params
  %if &_er_isgee %then
    %_er_vcov(type=CRV0, convention=SAS GENMOD, formula=%str(GEE empirical (sandwich) covariance on the subject clusters, no small-sample factor),
              tooltype=empirical, cluster=&_er_subj, nclusters=&_er_ncl);
  %else
    %_er_vcov(type=iid, convention=SAS GENMOD, formula=%str(inverse of the information matrix (times the scale where estimated)), tooltype=model-based);
  %_er_part(num)
    %_er_s('structures/numerics/kind', 'object');
    %_er_b('structures/numerics/iterative', 1);
    %_er_s('structures/numerics/algorithm', 'ridge_stabilized_newton_raphson');
    %_er_b('structures/numerics/converged', &_er_conv);
  %_er_endpart(num)
%mend;


/* ---- GLM */
%macro _er_glm(dir);
  %_er_classvars(&dir)
  %_er_get(&dir, ParameterEstimates, _er_pe)
  %_er_get(&dir, OverallANOVA, _er_an)
  %_er_get(&dir, FitStatistics, _er_fs)
  %_er_get(&dir, NObs, _er_no)
  %if not %_er_has(_er_pe) %then %do; %let _er_skip = GLM printed no Parameter Estimates (add SOLUTION to MODEL); %return; %end;
  data work._er_par; set work._er_pe;
    length term var1 lev1 var2 lev2 $ 200 dropped $ 12;
    term = compbl(strip(Parameter));
    %_er_split(term, )
    est = Estimate; se = StdErr; stat = tValue; p = Probt; lo = .; hi = .; df = .;
    dropped = ifc(missing(StdErr) and Estimate = 0, 'reference', '');
    call symputx('_er_resp', Dependent);
    keep term est se stat p lo hi df dropped var1 lev1 var2 lev2;
  run;
  data work._er_cov; stop; run;
  data _null_; set work._er_no;
    if Label =: 'Number of Observations Read' then call symputx('_er_rows', N);
    if Label =: 'Number of Observations Used' then call symputx('_er_nobs', N);
  run;
  data _null_; set work._er_an;
    if Source = 'Error' then do; call symputx('_er_dfr', DF); call symputx('_er_rss', put(SS, hex16.)); end;
    if Source = 'Corrected Total' then call symputx('_er_tss', put(SS, hex16.));
    if Source = 'Model' then do; call symputx('_er_F', put(FValue, hex16.)); call symputx('_er_Fp', put(ProbF, hex16.)); call symputx('_er_dfm', DF); end;
  run;
  data _null_; set work._er_fs;
    call symputx('_er_r2', put(RSquare, hex16.)); call symputx('_er_sigma', put(RootMSE, hex16.));
  run;
  %let _er_family = linear; %let _er_method = ols; %let _er_profiles = inference/0.1;
  %_er_common
  %_er_spec_sample(&_er_rows, &_er_nobs)
  %_er_terms_rows
  %_er_part(metrics)
    %_er_i('metrics/nobs', &_er_nobs);
    %_er_i('metrics/df_residual', &_er_dfr);
    %_er_nn('metrics/r2', input("&_er_r2", hex16.));
    _r2 = input("&_er_r2", hex16.); _ar2 = 1 - (1 - _r2) * (&_er_nobs - 1) / &_er_dfr;
    %_er_nn('metrics/adj_r2', _ar2);
    %_er_nn('metrics/sigma', input("&_er_sigma", hex16.));
    %_er_nn('metrics/rss', input("&_er_rss", hex16.));
    %_er_nn('metrics/tss', input("&_er_tss", hex16.));
    %_er_n('metrics/conf_level', 0.95);
  %_er_endpart(metrics)
  %_er_params
  %_er_vcov(type=iid, convention=SAS GLM, formula=%str(sigma^2 (X%'X)^- (generalized inverse), sigma^2 = RSS / (N - rank)), dft=&_er_dfr)
  %_er_part(tests)
    %_er_s('tests/#0001/id', 't1');
    %_er_s('tests/#0001/category', 'model');
    %_er_s('tests/#0001/name', 'f');
    %_er_s('tests/#0001/origin', 'estimation');
    %_er_n('tests/#0001/statistic', input("&_er_F", hex16.));
    %_er_s('tests/#0001/distribution', 'F');
    %_er_i('tests/#0001/df1', &_er_dfm);
    %_er_i('tests/#0001/df2', &_er_dfr);
    %_er_n('tests/#0001/p_value', input("&_er_Fp", hex16.));
    %_er_s('tests/#0001/vcov', 'iid');
  %_er_endpart(tests)
%mend;

/* ---- SURVEYREG */
%macro _er_surveyreg(dir);
  %_er_classvars(&dir)
  %_er_get(&dir, ParameterEstimates, _er_pe)
  %_er_get(&dir, DataSummary, _er_ds)
  %_er_get(&dir, DesignSummary, _er_dz)
  %_er_get(&dir, FitStatistics, _er_fs)
  %_er_get(&dir, CovB, _er_cb)
  %if not %_er_has(_er_pe) %then %do; %let _er_skip = SURVEYREG printed no Parameter Estimates (add SOLUTION to MODEL); %return; %end;
  data work._er_par; set work._er_pe;
    length term var1 lev1 var2 lev2 $ 200 dropped $ 12;
    term = compbl(strip(Parameter));
    %_er_split(term, )
    est = Estimate; se = StdErr; stat = tValue; p = Probt; lo = .; hi = .; df = .;
    dropped = ifc((missing(StdErr) or StdErr = 0) and Estimate = 0, 'reference', '');
    keep term est se stat p lo hi df dropped var1 lev1 var2 lev2;
  run;
  %if not %_er_has(_er_cb) %then %do; data work._er_cov; stop; run; %end;
  %else %do;
  data work._er_cov; set work._er_cb;
    array v{*} _numeric_; array c{200}; _j = 0;
    do _i = 1 to dim(v); if upcase(vname(v{_i})) not in ('_RUN_') then do; _j + 1; c{_j} = v{_i}; end; end;
    keep c:;
  run;
  %end;
  %let _er_ncl =; %let _er_nstr =; %let _er_sw =; %let _er_dfr =;
  data _null_; set work._er_ds;
    if Label1 = 'Number of Observations' then call symputx('_er_nobs', nValue1);
    if Label1 = 'Sum of Weights' then call symputx('_er_sw', 1);
  run;
  data _null_; set work._er_dz;
    if Label1 = 'Number of Clusters' then call symputx('_er_ncl', nValue1);
    if Label1 = 'Number of Strata' then call symputx('_er_nstr', nValue1);
  run;
  data _null_; set work._er_fs;
    if Label1 = 'R-Square' then call symputx('_er_r2', put(nValue1, hex16.));
    if Label1 = 'Root MSE' then call symputx('_er_sigma', put(nValue1, hex16.));
    if Label1 = 'Denominator DF' then call symputx('_er_dfr', nValue1);
  run;
  %let _er_rows = &_er_nobs;
  %let _er_family = linear; %let _er_method = %sysfunc(ifc(%length(&_er_sw), wls, ols));
  %let _er_profiles = inference/0.1;
  %_er_common
  %_er_part(sample)
    %_er_z('specification/sample/restriction');
    %_er_i('specification/sample/rows_input', &_er_nobs);
    %_er_eo('specification/sample/dropped');
  %_er_endpart(sample)
  %_er_terms_rows
  %_er_part(metrics)
    %_er_i('metrics/nobs', &_er_nobs);
    %if %length(&_er_dfr) %then %_er_i('metrics/df_residual', &_er_dfr);;
    %_er_nn('metrics/r2', input("&_er_r2", hex16.));
    %_er_nn('metrics/sigma', input("&_er_sigma", hex16.));
    %_er_n('metrics/conf_level', 0.95);
  %_er_endpart(metrics)
  %_er_params
  %if %length(&_er_nstr) or %length(&_er_sw) %then
    %_er_vcov(type=taylor, convention=SAS SURVEYREG, formula=%str(Taylor linearization; VADJUST=DF: (n - 1) / (n - p)), dft=&_er_dfr, nclusters=&_er_ncl);
  %else %if %length(&_er_ncl) %then
    %_er_vcov(type=CRV1, convention=SAS SURVEYREG, formula=%str(cluster sandwich, G / (G - 1) * (N - 1) / (N - K)), dft=&_er_dfr, nclusters=&_er_ncl);
  %else
    %_er_vcov(type=HC1, convention=SAS SURVEYREG, formula=%str(sandwich, N / (N - K)), dft=&_er_dfr);
%mend;

/* ---- SURVEYLOGISTIC */
%macro _er_surveylogistic(dir);
  %_er_get(&dir, ParameterEstimates, _er_pe)
  %_er_get(&dir, ModelInfo, _er_mi)
  %_er_get(&dir, NObs, _er_no)
  %_er_get(&dir, FitStatistics, _er_fs)
  %_er_get(&dir, ConvergenceStatus, _er_cs)
  %_er_get(&dir, CovB, _er_cb)
  %if not %_er_has(_er_pe) %then %do; %let _er_skip = SURVEYLOGISTIC printed no Parameter Estimates; %return; %end;
  %let _er_link = logit; %let _er_strat =; %let _er_clv =; %let _er_wv =; %let _er_ncl =;
  data _null_; set work._er_mi;
    if Description = 'Response Variable' then call symputx('_er_resp', Value);
    if Description = 'Data Set' then call symputx('_er_dataset', Value);
    if Description = 'Stratum Variable' then call symputx('_er_strat', Value);
    if Description = 'Cluster Variable' then call symputx('_er_clv', Value);
    if Description = 'Weight Variable' then call symputx('_er_wv', Value);
    if Description = 'Number of Clusters' then call symputx('_er_ncl', nValue1);
    if Description = 'Model' and index(lowcase(Value), 'probit') then call symputx('_er_link', 'probit');
  run;
  data work._er_par; set work._er_pe;
    length term var1 lev1 var2 lev2 $ 200 dropped $ 12;
    %if %_er_hasvar(_er_pe, ClassVal0) %then %do; term = catx(' ', Variable, ClassVal0); lev1 = strip(ClassVal0); %end;
    %else %do; term = strip(Variable); lev1 = ''; %end;
    var1 = ifc(upcase(Variable) = 'INTERCEPT', '(Intercept)', strip(Variable)); var2 = ''; lev2 = '';
    est = Estimate; se = StdErr; p = ProbChiSq; df = .; lo = .; hi = .;
    stat = ifn(StdErr > 0, Estimate / StdErr, .);
    dropped = '';
    keep term est se stat p lo hi df dropped var1 lev1 var2 lev2;
  run;
  %if not %_er_has(_er_cb) %then %do; data work._er_cov; stop; run; %end;
  %else %do;
  data work._er_cov; set work._er_cb;
    array v{*} _numeric_; array c{200}; _j = 0;
    do _i = 1 to dim(v); if upcase(vname(v{_i})) not in ('_RUN_') then do; _j + 1; c{_j} = v{_i}; end; end;
    keep c:;
  run;
  %end;
  data _null_; set work._er_no;
    if Label =: 'Number of Observations Read' then call symputx('_er_rows', N);
    if Label =: 'Number of Observations Used' then call symputx('_er_nobs', N);
  run;
  %let _er_m2ll =;
  data _null_; set work._er_fs; if Criterion = '-2 Log L' then call symputx('_er_m2ll', put(InterceptAndCovariates, hex16.)); run;
  %let _er_conv = 1;
  data _null_; set work._er_cs; call symputx('_er_conv', Status = 0); run;
  %let _er_family = glm; %let _er_method = ml; %let _er_dist = binomial;
  %let _er_profiles = inference/0.1 glm/0.1;
  %_er_common
  %_er_spec_sample(&_er_rows, &_er_nobs)
  %_er_terms_rows
  %_er_part(design)
    %if %length(&_er_wv) %then %do; %_er_s('specification/weights/variable', "&_er_wv"); %_er_s('specification/weights/type', 'sampling'); %end;
    %if %length(&_er_clv) %then %_er_s('specification/clusters/#0001', "&_er_clv");;
    %if %length(&_er_strat) %then %_er_s('specification/options/strata', "&_er_strat");;
  %_er_endpart(design)
  %_er_part(metrics)
    %_er_i('metrics/nobs', &_er_nobs);
    %if %length(&_er_m2ll) %then %do; _ll = -input("&_er_m2ll", hex16.) / 2; %_er_nn('metrics/log_lik', _ll); %end;
    %_er_n('metrics/conf_level', 0.95);
  %_er_endpart(metrics)
  %_er_params
  %if %length(&_er_strat) or %length(&_er_wv) %then
    %_er_vcov(type=taylor, convention=SAS SURVEYLOGISTIC, formula=%str(Taylor linearization; VADJUST=DF), cluster=&_er_clv, nclusters=&_er_ncl);
  %else
    %_er_vcov(type=CRV1, convention=SAS SURVEYLOGISTIC, formula=%str(cluster sandwich with the degrees-of-freedom adjustment), cluster=&_er_clv, nclusters=&_er_ncl);
  %_er_part(num)
    %_er_s('structures/numerics/kind', 'object');
    %_er_b('structures/numerics/iterative', 1);
    %_er_s('structures/numerics/algorithm', 'fisher_scoring');
    %_er_b('structures/numerics/converged', &_er_conv);
  %_er_endpart(num)
%mend;


/* variance components from work._er_vc (term, est, se, stat, p, grp, vterm, vtype) */
%macro _er_vcrows;
  %_er_part(vcrows)
    set work._er_vc;
    length base $ 60;
    _k = &_er_npar + _n_;
    base = cats('parameters/#', put(_k, z4.));
    %_er_s(cats(base, '/term'), term);
    %_er_n(cats(base, '/estimate'), est);
    if not missing(se) then do; %_er_n(cats(base, '/std_error'), se); end;
    if not missing(stat) then do; %_er_n(cats(base, '/statistic'), stat); end;
    if not missing(p) then do; %_er_n(cats(base, '/p_value'), p); end;
    %_er_s(cats(base, '/component'), 'random');
    %_er_s(cats(base, '/group'), grp);
    %_er_s(cats(base, '/vc/group'), grp);
    %_er_s(cats(base, '/vc/terms/#0001'), vterm);
    %_er_s(cats(base, '/vc/type'), vtype);
  %_er_endpart(vcrows)
%mend;

/* terms of a fixed-effects solution with class columns: Effect plus the class levels.
   %_er_classcols(ds) (outside a DATA step) finds the columns; %_er_effect_terms (inside one)
   builds term. */
%macro _er_classcols(ds);
  %global _er_ccols;
  %let _er_ccols =;
  proc sql noprint;
    select name into :_er_ccols separated by ' ' from dictionary.columns
    where libname = 'WORK' and memname = upcase("&ds") and type = 'char'
      and upcase(name) not in ('EFFECT', '_RUN_', 'ROW');
  quit;
%mend;
%macro _er_effect_terms;
  length _lv $ 200;
  _lv = '';
  %local q;
  %do q = 1 %to %sysfunc(countw(&_er_ccols, %str( )));
    if strip(%scan(&_er_ccols, &q, %str( ))) not in ('', '_') then _lv = catx(' ', _lv, %scan(&_er_ccols, &q, %str( )));
  %end;
  term = catx(' ', Effect, _lv);
%mend;

/* ---- MIXED */
%macro _er_mixed(dir);
  %_er_classvars(&dir)
  %_er_get(&dir, SolutionF, _er_pe)
  %_er_get(&dir, CovB, _er_cb)
  %_er_get(&dir, CovParms, _er_cp)
  %_er_get(&dir, FitStatistics, _er_fs)
  %_er_get(&dir, Dimensions, _er_dm)
  %_er_get(&dir, NObs, _er_no)
  %_er_get(&dir, ModelInfo, _er_mi)
  %_er_get(&dir, ConvergenceStatus, _er_cs)
  %if not %_er_has(_er_pe) %then %do; %let _er_skip = MIXED printed no fixed-effects solution (add SOLUTION to MODEL); %return; %end;
  %_er_classcols(_er_pe)
  data work._er_par; set work._er_pe;
    length term var1 lev1 var2 lev2 $ 200 dropped $ 12;
    %_er_effect_terms
    %_er_split(term, )
    est = Estimate; se = StdErr; stat = tValue; p = Probt; df = DF; lo = .; hi = .;
    dropped = ifc(missing(StdErr) and Estimate = 0, 'reference', '');
    keep term est se stat p lo hi df dropped var1 lev1 var2 lev2;
  run;
  data work._er_cov; set work._er_cb;
    array v{*} Col:; array c{200}; do _i = 1 to dim(v); c{_i} = v{_i}; end; keep c:;
  run;
  %let _er_meth = reml; %let _er_ddfm = containment; %let _er_subj =; %let _er_nsub =;
  data _null_; set work._er_mi;
    if Descr = 'Dependent Variable' then call symputx('_er_resp', Value);
    if Descr = 'Data Set' then call symputx('_er_dataset', Value);
    if Descr = 'Estimation Method' then call symputx('_er_meth', lowcase(Value));
    if Descr = 'Subject Effect' then call symputx('_er_subj', Value);
    if Descr = 'Fixed Effects SE Method' and index(Value, 'Kenward') then call symputx('_er_ddfm', 'kenward_roger');
  run;
  data _null_; set work._er_dm; if Descr = 'Subjects' then call symputx('_er_nsub', Value); run;
  data _null_; set work._er_no;
    if Label =: 'Number of Observations Read' then call symputx('_er_rows', N);
    if Label =: 'Number of Observations Used' then call symputx('_er_nobs', N);
  run;
  %let _er_m2ll =; %let _er_aic =; %let _er_bic =;
  data _null_; set work._er_fs;
    if index(Descr, 'Log Likelihood') then call symputx('_er_m2ll', put(Value, hex16.));
    if Descr =: 'AIC ' then call symputx('_er_aic', put(Value, hex16.));
    if Descr =: 'BIC ' then call symputx('_er_bic', put(Value, hex16.));
  run;
  %let _er_conv = 1;
  data _null_; set work._er_cs; call symputx('_er_conv', Status = 0); run;
  data work._er_vc; set work._er_cp;
    length term grp vterm $ 200 vtype $ 4;
    est = Estimate;
    se = %if %_er_hasvar(_er_cp, StdErr) %then StdErr; %else .;;
    stat = %if %_er_hasvar(_er_cp, ZValue) %then ZValue; %else .;;
    p = %if %_er_hasvar(_er_cp, ProbZ) %then ProbZ; %else .;;
    if upcase(CovParm) = 'RESIDUAL' then do; grp = 'Residual'; vterm = '(Residual)'; term = 'Residual'; end;
    else do;
      grp = strip(%if %_er_hasvar(_er_cp, Subject) %then Subject; %else ''; );
      vterm = ifc(upcase(CovParm) = 'INTERCEPT', '(Intercept)', strip(CovParm));
      term = catx(' ', CovParm, grp);
    end;
    vtype = ifc(index(upcase(CovParm), 'UN(') and scan(CovParm, 2, '(,)') ne scan(CovParm, 3, '(,)'), 'cov', 'var');
    keep term est se stat p grp vterm vtype;
  run;
  proc sql noprint;
    select count(*) into :_er_npar trimmed from work._er_par;
    select count(*) into :_er_vcnose trimmed from work._er_vc where missing(se);
  quit;
  %let _er_family = mixed; %let _er_method = &_er_meth; %let _er_dist =; %let _er_link =;
  %if &_er_vcnose = 0 %then %let _er_profiles = inference/0.1 mixed/0.1;
  %else %let _er_profiles = mixed/0.1;
  %if not &_er_conv %then %let _er_status = warning;
  %_er_common
  %_er_spec_sample(&_er_rows, &_er_nobs)
  %_er_terms_rows
  %_er_part(re)
    %_er_s('specification/random_effects/#0001/group', "&_er_subj");
    %_er_s('specification/random_effects/#0001/terms/#0001', '(Intercept)');
    %_er_s('specification/options/df_method', "&_er_ddfm");
    %_er_s('structures/random_effects/#0001/kind', 'object');
    %_er_s('structures/random_effects/#0001/group', "&_er_subj");
    %if %length(&_er_nsub) %then %_er_i('structures/random_effects/#0001/levels', &_er_nsub);;
    %_er_s('structures/random_effects/#0001/terms/#0001', '(Intercept)');
  %_er_endpart(re)
  %_er_part(metrics)
    %_er_i('metrics/nobs', &_er_nobs);
    %if %length(&_er_m2ll) %then %do;
      _m = input("&_er_m2ll", hex16.); _ll = -_m / 2;
      %_er_nn('metrics/log_lik', _ll);
      %if &_er_meth = reml %then %_er_nn('metrics/reml_criterion', _m);;
    %end;
    %if %length(&_er_aic) %then %_er_nn('metrics/aic', input("&_er_aic", hex16.));;
    %if %length(&_er_bic) %then %_er_nn('metrics/bic', input("&_er_bic", hex16.));;
    %_er_n('metrics/conf_level', 0.95);
  %_er_endpart(metrics)
  %_er_params
  %_er_vcrows
  %_er_vcov(type=iid, convention=SAS MIXED, formula=%str(model-based covariance of the fixed effects (DDFM=&_er_ddfm)), tooltype=model-based)
  %_er_part(num)
    %_er_s('structures/numerics/kind', 'object');
    %_er_b('structures/numerics/iterative', 1);
    %_er_s('structures/numerics/algorithm', 'newton_raphson');
    %_er_b('structures/numerics/converged', &_er_conv);
  %_er_endpart(num)
  %if &_er_vcnose > 0 %then %let _er_msgs = &_er_msgs|vc_no_se;
%mend;

/* ---- GLIMMIX */
%macro _er_glimmix(dir);
  %_er_classvars(&dir)
  %_er_get(&dir, ParameterEstimates, _er_pe)
  %_er_get(&dir, CovB, _er_cb)
  %_er_get(&dir, CovParms, _er_cp)
  %_er_get(&dir, FitStatistics, _er_fs)
  %_er_get(&dir, Dimensions, _er_dm)
  %_er_get(&dir, NObs, _er_no)
  %_er_get(&dir, ModelInfo, _er_mi)
  %_er_get(&dir, ConvergenceStatus, _er_cs)
  %if not %_er_has(_er_pe) %then %do; %let _er_skip = GLIMMIX printed no Parameter Estimates (add SOLUTION to MODEL); %return; %end;
  %_er_classcols(_er_pe)
  data work._er_par; set work._er_pe;
    length term var1 lev1 var2 lev2 $ 200 dropped $ 12;
    %_er_effect_terms
    %_er_split(term, )
    est = Estimate; se = StdErr; stat = tValue; p = Probt; df = DF; lo = .; hi = .;
    dropped = ifc(missing(StdErr) and Estimate = 0, 'reference', '');
    keep term est se stat p lo hi df dropped var1 lev1 var2 lev2;
  run;
  data work._er_cov; set work._er_cb;
    array v{*} Col:; array c{200}; do _i = 1 to dim(v); c{_i} = v{_i}; end; keep c:;
  run;
  %let _er_meth = rspl; %let _er_subj =; %let _er_nsub =;
  data _null_; set work._er_mi;
    if Descr = 'Response Variable' then call symputx('_er_resp', Value);
    if Descr = 'Data Set' then call symputx('_er_dataset', Value);
    if Descr = 'Response Distribution' then call symputx('_er_dist',
      ifc(lowcase(Value) in ('binary', 'binomial'), 'binomial', lowcase(compress(Value, ' '))));
    if Descr = 'Link Function' then call symputx('_er_link', lowcase(Value));
    if Descr = 'Variance Matrix Blocked By' then call symputx('_er_subj', Value);
    if Descr = 'Likelihood Approximation' then call symputx('_er_meth', lowcase(compress(Value, ' ')));
    if Descr = 'Estimation Technique' and index(Value, 'Pseudo') then call symputx('_er_meth', 'rspl');
  run;
  data _null_; set work._er_dm; if Descr =: 'Subjects' then call symputx('_er_nsub', Value); run;
  data _null_; set work._er_no;
    if Label =: 'Number of Observations Read' then call symputx('_er_rows', N);
    if Label =: 'Number of Observations Used' then call symputx('_er_nobs', N);
  run;
  %let _er_m2ll =; %let _er_aic =; %let _er_bic =;
  data _null_; set work._er_fs;
    if Descr = '-2 Log Likelihood' then call symputx('_er_m2ll', put(Value, hex16.));
    if Descr =: 'AIC ' then call symputx('_er_aic', put(Value, hex16.));
    if Descr =: 'BIC ' then call symputx('_er_bic', put(Value, hex16.));
  run;
  %let _er_conv = 1;
  data _null_; set work._er_cs; call symputx('_er_conv', Status = 0); run;
  data work._er_vc; set work._er_cp;
    length term grp vterm $ 200 vtype $ 4;
    est = Estimate; se = %if %_er_hasvar(_er_cp, StdErr) %then StdErr; %else .;; stat = .; p = .;
    grp = strip(%if %_er_hasvar(_er_cp, Subject) %then Subject; %else ''; );
    if upcase(CovParm) = 'RESIDUAL' or upcase(CovParm) = 'SCALE' then do; grp = 'Residual'; vterm = '(Residual)'; end;
    else vterm = ifc(upcase(CovParm) = 'INTERCEPT', '(Intercept)', strip(CovParm));
    term = catx(' ', CovParm, grp);
    vtype = 'var';
    keep term est se stat p grp vterm vtype;
  run;
  proc sql noprint;
    select count(*) into :_er_npar trimmed from work._er_par;
    select count(*) into :_er_vcnose trimmed from work._er_vc where missing(se);
    select max(df) into :_er_dfr trimmed from work._er_par;
  quit;
  %let _er_family = mixed; %let _er_method = &_er_meth;
  %if &_er_vcnose = 0 %then %let _er_profiles = inference/0.1 mixed/0.1;
  %else %let _er_profiles = mixed/0.1;
  %if not &_er_conv %then %let _er_status = warning;
  %_er_common
  %_er_spec_sample(&_er_rows, &_er_nobs)
  %_er_terms_rows
  %_er_part(re)
    %_er_s('specification/random_effects/#0001/group', "&_er_subj");
    %_er_s('specification/random_effects/#0001/terms/#0001', '(Intercept)');
    %_er_s('specification/options/df_method', 'containment');
    %_er_s('structures/random_effects/#0001/kind', 'object');
    %_er_s('structures/random_effects/#0001/group', "&_er_subj");
    %if %length(&_er_nsub) %then %_er_i('structures/random_effects/#0001/levels', &_er_nsub);;
    %_er_s('structures/random_effects/#0001/terms/#0001', '(Intercept)');
  %_er_endpart(re)
  %_er_part(metrics)
    %_er_i('metrics/nobs', &_er_nobs);
    %if %length(&_er_m2ll) %then %do; _ll = -input("&_er_m2ll", hex16.) / 2; %_er_nn('metrics/log_lik', _ll); %end;
    %if %length(&_er_aic) %then %_er_nn('metrics/aic', input("&_er_aic", hex16.));;
    %if %length(&_er_bic) %then %_er_nn('metrics/bic', input("&_er_bic", hex16.));;
    %_er_n('metrics/conf_level', 0.95);
  %_er_endpart(metrics)
  %_er_params
  %_er_vcrows
  %_er_vcov(type=iid, convention=SAS GLIMMIX, formula=%str(model-based covariance of the fixed effects), tooltype=model-based)
  %_er_part(num)
    %_er_s('structures/numerics/kind', 'object');
    %_er_b('structures/numerics/iterative', 1);
    %_er_s('structures/numerics/algorithm', "&_er_meth");
    %_er_b('structures/numerics/converged', &_er_conv);
  %_er_endpart(num)
  %if &_er_vcnose > 0 %then %let _er_msgs = &_er_msgs|vc_no_se;
%mend;

/* ---- PANEL (SAS/ETS) */
%macro _er_panel(dir);
  %_er_get(&dir, ParameterEstimates, _er_pe)
  %_er_get(&dir, FitStatistics, _er_fs)
  %_er_get(&dir, ModelDescription, _er_md)
  %_er_get(&dir, FixedEffectsTest, _er_ft)
  %_er_get(&dir, VarianceComponents, _er_vcm)
  %_er_get(&dir, CovB, _er_cb)
  %_er_get(&dir, NObs, _er_no)
  %if not %_er_has(_er_pe) %then %do; %let _er_skip = PANEL printed no Parameter Estimates; %return; %end;
  data work._er_par; set work._er_pe;
    length term var1 lev1 var2 lev2 $ 200 dropped $ 12;
    term = strip(VarName);
    var1 = ifc(upcase(term) = 'INTERCEPT', '(Intercept)', term); lev1 = ''; var2 = ''; lev2 = '';
    est = Estimate; se = StdErr; stat = tValue; p = Probt; lo = .; hi = .; df = .;
    dropped = ifc(DF = 0, 'collinear', '');
    keep term est se stat p lo hi df dropped var1 lev1 var2 lev2;
  run;
  %if not %_er_has(_er_cb) %then %do; data work._er_cov; stop; run; %end;
  %else %do;
  data work._er_cov; set work._er_cb;
    array v{*} _numeric_; array c{200}; _j = 0;
    do _i = 1 to dim(v); if upcase(vname(v{_i})) not in ('_RUN_') then do; _j + 1; c{_j} = v{_i}; end; end;
    keep c:;
  run;
  %end;
  %let _er_pm =; %let _er_ncs =; %let _er_nts =; %let _er_vu =; %let _er_ve =;
  data _null_; set work._er_md;
    if Label1 = 'Estimation Method' then call symputx('_er_pm', upcase(cValue1));
    if Label1 = 'Number of Cross Sections' then call symputx('_er_ncs', nValue1);
    if Label1 = 'Time Series Length' then call symputx('_er_nts', nValue1);
  run;
  data _null_; set work._er_fs;
    if Label1 = 'SSE' then call symputx('_er_rss', put(nValue1, hex16.));
    if Label2 = 'DFE' then call symputx('_er_dfr', nValue2);
    if Label2 = 'Root MSE' then call symputx('_er_sigma', put(nValue2, hex16.));
    if Label1 = 'R-Square' then call symputx('_er_r2', put(nValue1, hex16.));
  run;
  %if %_er_has(_er_vcm) %then %do;
    data _null_; set work._er_vcm;
      if index(Label1, 'Cross Sections') then call symputx('_er_vu', put(nValue1, hex16.));
      if index(Label1, 'Error') then call symputx('_er_ve', put(nValue1, hex16.));
    run;
  %end;
  %let _er_nobs =;
  %if %_er_has(_er_no) %then %do;
    data _null_; set work._er_no; if Label =: 'Number of Observations Used' then call symputx('_er_nobs', N); run;
  %end;
  %if not %length(&_er_nobs) %then %do;
    proc sql noprint; select count(*) into :_er_np2 trimmed from work._er_par where dropped = ''; quit;
    %let _er_nobs = %eval(&_er_dfr + &_er_np2);
    %if &_er_pm = FIXONE %then %let _er_nobs = %eval(&_er_nobs + &_er_ncs - 1);
    %if &_er_pm = FIXTWO %then %let _er_nobs = %eval(&_er_nobs + &_er_ncs + &_er_nts - 2);
  %end;
  %let _er_family = linear; %let _er_dist =; %let _er_link =;
  %let _er_method = %sysfunc(ifc(%index(&_er_pm, RAN), gls, ols));
  %let _er_profiles = inference/0.1;
  %_er_common
  %_er_part(sample)
    %_er_z('specification/sample/restriction');
    %_er_eo('specification/sample/dropped');
  %_er_endpart(sample)
  %_er_terms_rows
  %_er_part(opts)
    %_er_s('specification/options/panel_method', "&_er_pm");
    %if %index(&_er_pm, FIX) %then %do;
      %_er_s('structures/fixed_effects/#0001/kind', 'object');
      %_er_s('structures/fixed_effects/#0001/name', '(cross section)');
      %_er_i('structures/fixed_effects/#0001/levels', &_er_ncs);
      %if &_er_pm = FIXTWO %then %do;
        %_er_s('structures/fixed_effects/#0002/kind', 'object');
        %_er_s('structures/fixed_effects/#0002/name', '(time period)');
        %_er_i('structures/fixed_effects/#0002/levels', &_er_nts);
      %end;
    %end;
  %_er_endpart(opts)
  %_er_part(metrics)
    %_er_i('metrics/nobs', &_er_nobs);
    %_er_i('metrics/df_residual', &_er_dfr);
    %_er_nn('metrics/r2', input("&_er_r2", hex16.));
    %_er_nn('metrics/rss', input("&_er_rss", hex16.));
    %_er_nn('metrics/sigma', input("&_er_sigma", hex16.));
    %if %length(&_er_vu) %then %_er_nn('metrics/variance_cross_section', input("&_er_vu", hex16.));;
    %if %length(&_er_ve) %then %_er_nn('metrics/variance_error', input("&_er_ve", hex16.));;
    %_er_n('metrics/conf_level', 0.95);
  %_er_endpart(metrics)
  %_er_params
  %_er_vcov(type=iid, convention=SAS PANEL, formula=%str(OLS or GLS model-based covariance; K counts the absorbed effects (&_er_pm)), dft=&_er_dfr)
  %if %_er_has(_er_ft) %then %do;
    %_er_part(tests)
      set work._er_ft;
      %_er_s('tests/#0001/id', 't1');
      %_er_s('tests/#0001/category', 'fixed_effects');
      %_er_s('tests/#0001/name', 'f');
      %_er_s('tests/#0001/origin', 'estimation');
      %_er_n('tests/#0001/statistic', FValue);
      %_er_s('tests/#0001/distribution', 'F');
      %_er_i('tests/#0001/df1', NumDF);
      %_er_i('tests/#0001/df2', DenDF);
      %_er_n('tests/#0001/p_value', Prob);
    %_er_endpart(tests)
  %end;
  %let _er_msgs = &_er_msgs|panel_ids;
%mend;

/* ---- SYSLIN (SAS/ETS): 2SLS and OLS equations; the first MODEL */
%macro _er_syslin(dir);
  %_er_get(&dir, ParameterEstimates, _er_pe)
  %_er_get(&dir, FitStatistics, _er_fs)
  %_er_get(&dir, ANOVA, _er_an)
  %_er_get(&dir, ModelVars, _er_mv)
  %_er_get(&dir, CovB, _er_cb)
  %if not %_er_has(_er_pe) %then %do; %let _er_skip = SYSLIN printed no Parameter Estimates; %return; %end;
  data work._er_par; set work._er_pe;
    length term var1 lev1 var2 lev2 $ 200 dropped $ 12;
    term = strip(Variable);
    var1 = ifc(upcase(term) = 'INTERCEPT', '(Intercept)', term); lev1 = ''; var2 = ''; lev2 = '';
    est = Estimate; se = StdErr; stat = tValue; p = Probt; lo = .; hi = .; df = .;
    dropped = ifc(DF = 0, 'collinear', '');
    keep term est se stat p lo hi df dropped var1 lev1 var2 lev2;
  run;
  %if not %_er_has(_er_cb) %then %do; data work._er_cov; stop; run; %end;
  %else %do;
  data work._er_cov; set work._er_cb;
    array v{*} _numeric_; array c{200}; _j = 0;
    do _i = 1 to dim(v); if upcase(vname(v{_i})) not in ('_RUN_') then do; _j + 1; c{_j} = v{_i}; end; end;
    keep c:;
  run;
  %end;
  data _null_; set work._er_an;
    if Source = 'Error' then do; call symputx('_er_dfr', DF); call symputx('_er_rss', put(SS, hex16.)); end;
    if Source = 'Corrected Total' then do; call symputx('_er_tss', put(SS, hex16.)); call symputx('_er_nobs', DF + 1); end;
    if Source = 'Model' then do; call symputx('_er_F', put(FValue, hex16.)); call symputx('_er_Fp', put(ProbF, hex16.)); call symputx('_er_dfm', DF); end;
  run;
  data _null_; set work._er_fs;
    if Label1 = 'Root MSE' then call symputx('_er_sigma', put(nValue1, hex16.));
    if Label2 = 'R-Square' then call symputx('_er_r2', put(nValue2, hex16.));
    if Label2 = 'Adj R-Sq' then call symputx('_er_ar2', put(nValue2, hex16.));
  run;
  %let _er_endo =; %let _er_inst =;
  %if %_er_has(_er_mv) %then %do;
    data _null_; set work._er_mv;
      length _t $ 400;
      array cv{*} _character_;
      _t = '';
      do _i = 1 to dim(cv); if vname(cv{_i}) ne 'Label1' then _t = catx(' ', _t, cv{_i}); end;
      _l = lowcase(cats(of _character_));
      if index(_l, 'endogenous') then call symputx('_er_endo', scan(_t, -1, ' '));
      if index(_l, 'instrument') then call symputx('_er_inst', _t);
    run;
  %end;
  %let _er_family = linear; %let _er_method = 2sls; %let _er_dist =; %let _er_link =;
  %let _er_profiles = inference/0.1;
  %_er_common
  %_er_part(sample)
    %_er_z('specification/sample/restriction');
    %_er_eo('specification/sample/dropped');
  %_er_endpart(sample)
  %_er_terms_rows
  %_er_part(metrics)
    %_er_i('metrics/nobs', &_er_nobs);
    %_er_i('metrics/df_residual', &_er_dfr);
    %_er_nn('metrics/r2', input("&_er_r2", hex16.));
    %_er_nn('metrics/adj_r2', input("&_er_ar2", hex16.));
    %_er_nn('metrics/sigma', input("&_er_sigma", hex16.));
    %_er_nn('metrics/rss', input("&_er_rss", hex16.));
    %_er_n('metrics/conf_level', 0.95);
  %_er_endpart(metrics)
  %_er_params
  %_er_vcov(type=iid, convention=SAS SYSLIN, formula=%str(2SLS: sigma^2 (Xhat%'Xhat)^-1, sigma^2 = RSS / (N - K)), dft=&_er_dfr)
  %let _er_msgs = &_er_msgs|syslin_iv;
%mend;

/* ---- IML: a record only for PROCESS runs (its banner names it) */
%macro _er_iml(dir);
  %let _er_pisproc = 1;
  %_er_process(&dir)
  %if %length(&_er_skip) %then %let _er_pisproc = 0;
%mend;

/* ---- PROCESS (Andrew F. Hayes's macro for mediation, moderation and conditional process
   models, https://www.afhayes.com/download.html; not part of estrec). PROCESS for SAS prints
   with PROC IML, so its output is an IML directory of matrices: character ones hold its text
   (banners, "Model and Variables", OUTCOME VARIABLE:, paths, keys), numeric ones its tables at
   full precision, titled as printed. They are read in order into the items the Python reader
   (spss/estrec_process.py) reads: text lines, banner headings and table rows, and interpreted
   the same way; tests/test_process.py checks that the records agree. */

%macro _er_process(dir);
  %local n i p nm k;
  /* 1. every table of the IML directory, in order, as (table, row, column) cells */
  ods exclude all;
  proc document name=work._estrec; ods output Properties=work._er_pprops; list &dir / levels=all details; run; quit;
  ods exclude none;
  data work._er_ptabs; set work._er_pprops; where type = 'Table'; tno = _n_;
    length tname $ 32; tname = scan(scan(path, -1, '\'), 1, '#'); run;
  proc sql noprint; select count(*) into :n trimmed from work._er_ptabs; quit;
  proc datasets lib=work nolist nowarn; delete _er_pc; quit;
  %do i = 1 %to &n;
    data _null_; set work._er_ptabs(firstobs=&i obs=&i);
      call symputx('p', cats("&dir", '\', scan(path, -1, '\'))); call symputx('nm', tname);
    run;
    proc datasets lib=work nolist nowarn; delete _er_pt; quit;
    ods exclude all;
    proc document name=work._estrec; ods output &nm = work._er_pt; replay &p; run; quit;
    ods exclude none;
    %if %sysfunc(exist(work._er_pt)) %then %do;
      data work._er_pl1;
        set work._er_pt end=_last;
        retain _er_dn . _er_dc ' ';
        array _nv{*} _numeric_; array _cv{*} _character_;
        length tname $ 32 label cvar $ 200 cname $ 200 chr $ 1000;
        retain _dsid 0;
        if _n_ = 1 then _dsid = open('work._er_pt');
        tno = &i; rno = _n_; tname = "&nm"; label = '';
        do _j = 1 to dim(_cv);
          if upcase(vname(_cv{_j})) = 'ROWNAME' then label = strip(_cv{_j});
        end;
        do _j = 1 to dim(_nv);
          cvar = vname(_nv{_j});
          if cvar not in ('_er_dn', '_dsid', 'tno', 'rno', '_j', '_rc') then do;
            cno = varnum(_dsid, cvar); cname = varlabel(_dsid, cno); if cname = '' then cname = cvar;
            isnum = 1; num = _nv{_j}; chr = ''; output;
          end;
        end;
        do _j = 1 to dim(_cv);
          cvar = vname(_cv{_j});
          if upcase(cvar) not in ('ROWNAME', '_ER_DC', 'TNAME', 'LABEL', 'CVAR', 'CNAME', 'CHR') then do;
            cno = varnum(_dsid, cvar); cname = varlabel(_dsid, cno); if cname = '' then cname = cvar;
            isnum = 0; num = .; chr = strip(_cv{_j}); output;
          end;
        end;
        if _last then _rc = close(_dsid);
        keep tno rno cno tname label cvar cname isnum num chr;
      run;
      proc append base=work._er_pc data=work._er_pl1 force; run;
    %end;
  %end;
  %if not %_er_has(_er_pc) %then %do; %let _er_skip = PROCESS printed nothing it could read; %return; %end;
  proc sort data=work._er_pc; by tno rno cno; run;
  proc sql;
    create table work._er_pc2 as select c.*, t.label as title length=400,
      (select count(*) from work._er_pc d where d.tno = c.tno and not prxmatch('/^Col\d+$/i', strip(d.cvar))) = 0 as generic
    from work._er_pc c left join work._er_ptabs t on c.tno = t.tno order by c.tno, c.rno, c.cno;
  quit;

  /* 2. items in output order: (itype 'line' or 'heading', text) and (itype 'row', table) */
  data work._er_pitems;
    set work._er_pc2; by tno rno;
    length itype $ 8 text ttl $ 2000 tok $ 2000 rlabel $ 200 cn1-cn20 cr1-cr20 $ 200 prevline $ 2000;
    array cn{20} $ cn1-cn20; array cr{20} $ cr1-cr20; array v{20} v1-v20;
    retain tok cn1-cn20 cr1-cr20 v1-v20 ncol prevline ttl;
    keep ino itype text ttl rlabel ncol cn1-cn20 cr1-cr20 v1-v20 tfirst tname;
    retain ino 0;
    if first.rno then do;
      tok = ''; ncol = 0;
      do _j = 1 to 20; cn{_j} = ''; cr{_j} = ''; v{_j} = .; end;
    end;
    if first.tno then do;
      ttl = strip(title);
      if generic and ttl ne '' and substr(ttl, 1, 1) ne '*' then do;
        itype = 'line'; text = ttl; ino + 1; output; prevline = '';
      end;
      if not generic and ttl = '' then ttl = prevline;   /* the title printed above an untitled table */
    end;
    if generic then do;
      if isnum then do;
        if missing(num) then tok = catx(' ', tok, '.');
        else if num = round(num) then tok = catx(' ', tok, strip(put(num, 32.)));
        else tok = catx(' ', tok, er_num(num));
      end;
      else if chr ne '' then tok = catx(' ', tok, chr);
    end;
    else do;
      ncol + 1;
      if ncol <= 20 then do; cr{ncol} = strip(cname); cn{ncol} = lowcase(compbl(strip(cname))); v{ncol} = num; end;
    end;
    if last.rno then do;
      if generic then do;
        text = catx(' ', ifc(prxmatch('/^row\d+$/i', strip(label)), '', strip(label)), tok);
        if text ne '' then do;
          if substr(text, 1, 1) = '*' then do;
            if index(text, 'PROCESS Procedure for') then do;
              itype = 'line'; text = prxchange('s/^[* ]+|[* ]+$//', -1, trim(text)); ino + 1; output;
            end;
            else if prxmatch('/\*\s*([A-Za-z][A-Za-z ,()]+[A-Za-z)])\s*\*/', text) then do;
              itype = 'heading'; text = prxchange('s/.*?\*\s*([A-Za-z][A-Za-z ,()]+[A-Za-z)])\s*\*.*/$1/', 1, trim(text));
              ino + 1; output;
            end;
            prevline = '';
          end;
          else do;
            itype = 'line'; ino + 1; output;
            prevline = ifc(upcase(substr(tname, 1, 4)) = '_LIT' and not index(text, '->'), text, '');
          end;
        end;
      end;
      else do;
        itype = 'row'; text = ''; rlabel = ifc(prxmatch('/^row\d+$/i', strip(label)), '', strip(label));
        rlabel = prxchange('s/^\{(C\d+\))$/($1/', 1, trim(rlabel));   /* PROCESS for SAS prints {C1) */
        tfirst = (rno = 1);
        ino + 1; output;
        prevline = '';
      end;
    end;
  run;
  /* the last row of each table */
  data work._er_pitems;
    merge work._er_pitems work._er_pitems(firstobs=2 keep=itype tfirst rename=(itype=_nt tfirst=_nf));
    tlast = (itype = 'row' and (_nt ne 'row' or _nf = 1));
    drop _nt _nf;
  run;

  %if %symexist(_er_debug) %then %do; data work.dbg_items; set work._er_pitems; run; %end;
  /* 3. interpret, in order (spss/estrec_process.py interpret()) */
  data work._er_peq(keep=pno term resp comp est se stat p lo hi)
       work._er_pef(keep=pno term resp comp est se stat p lo hi m_effect m_med m_treat m_mvn m_mvs m_path m_ind m_lab)
       work._er_pts(keep=tsn cat name label stat df df2 p resp comp est se dist fitno)
       work._er_pfit(keep=fitno resp comp r2 adj_r2 mse dfr dev pr2 csr2 nkr2)
       work._er_pan(keep=fitno resp a_mse a_dfr a_dfreg)
       work._er_pkey(keep=kname kpath) work._er_pctr(keep=kname kpath) work._er_pprod(keep=kname kpath)
       work._er_pskip(keep=label);
    set work._er_pitems end=_e;
    array cn{20} $ cn1-cn20; array cr{20} $ cr1-cr20; array v{20} v1-v20;
    length _t2 $ 2000 outcome $ 200 path $ 2000 ind_ctx k k_ctx $ 400 seen $ 2000 hy hx hw hz $ 200 hm hcov $ 2000
           hver hplat $ 40 term label $ 2000 resp comp $ 200 m_effect m_med m_treat $ 200 m_mvs $ 400
           m_path $ 2000 m_ind m_lab $ 40 cat name dist $ 40 kname $ 40 kpath $ 2000 atx $ 400 _t $ 2000
           mods $ 2000;
    retain outcome path ind_ctx seen hy hx hw hz hm hcov hver hplat '' total_model await hdr_done want_cov want_seed 0
           hmodel hnobs hseed hconf hreps . pno tsn fitno 0 mres_mse mres_dfr mreg_df . nmod 0 mods '';
    if itype = 'heading' then do;
      if prxmatch('/total effect model/i', text) then total_model = 1;
      goto next;
    end;
    if itype = 'line' then do;
      _t = strip(text);
      /* header fields (before the first OUTCOME VARIABLE), and values anywhere */
      if want_cov then do; hcov = _t; want_cov = 0; end;
      if want_seed then do; if prxmatch('/^\d+$/', trim(_t)) then hseed = input(_t, 32.); want_seed = 0; end;
      if prxmatch('/^outcome variable\s*:?\s*(\S*)\s*$/i', _t) then hdr_done = 1;
      if not hdr_done and prxmatch('/^(Model|Y|X|M\d*|W|Z|Covariates?)\s*:\s*(.*)$/i', _t) then do;
        k = lowcase(prxchange('s/^(Model|Y|X|M\d*|W|Z|Covariates?)\s*:\s*(.*)$/$1/i', 1, _t));
        label = strip(prxchange('s/^(Model|Y|X|M\d*|W|Z|Covariates?)\s*:\s*(.*)$/$2/i', 1, _t));
        if substr(k, 1, 3) = 'cov' then do; if label ne '' then hcov = catx(' ', hcov, label); else want_cov = 1; end;
        else if k = 'model' and label ne '' then hmodel = int(input(scan(label, 1, ' '), ?? 32.));
        else if substr(k, 1, 1) = 'm' and label ne '' then hm = catx(' ', hm, label);
        else if k = 'y' then hy = label; else if k = 'x' then hx = label;
        else if k = 'w' then hw = label; else if k = 'z' then hz = label;
      end;
      if missing(hnobs) and prxmatch('/sample\s*size\s*:?\s*(\d+)/i', _t) then
        hnobs = input(prxchange('s/.*sample\s*size\s*:?\s*(\d+).*/$1/i', 1, _t), 32.);
      if missing(hseed) and prxmatch('/custom\s*seed/i', _t) then do;
        if prxmatch('/custom\s*seed\s*:?\s*(\d+)/i', _t) then hseed = input(prxchange('s/.*custom\s*seed\s*:?\s*(\d+).*/$1/i', 1, _t), 32.);
        else want_seed = 1;
      end;
      if hver = '' and prxmatch('/PROCESS Procedure for (\w+) Version\s+([\d.]+)/', _t) then do;
        hplat = prxchange('s/.*PROCESS Procedure for (\w+) Version\s+([\d.]+).*/$1/', 1, _t);
        hver = prxchange('s/.*PROCESS Procedure for (\w+) Version\s+([\d.]+).*/$2/', 1, _t);
      end;
      if missing(hconf) and prxmatch('/level of confidence/i', _t) and prxmatch('/:\s*[-+]?\d*\.?\d+\s*$/', _t) then
        hconf = input(prxchange('s/.*:\s*([-+]?\d*\.?\d+)\s*$/$1/', 1, _t), 32.);
      if missing(hreps) and prxmatch('/number of bootstrap/i', _t) and prxmatch('/:\s*[-+]?\d*\.?\d+\s*$/', _t) then
        hreps = input(prxchange('s/.*:\s*([-+]?\d*\.?\d+)\s*$/$1/', 1, _t), 32.);
      /* outcome, paths and keys */
      if prxmatch('/^outcome variable\s*:?\s*(\S*)\s*$/i', _t) then do;
        outcome = prxchange('s/^outcome variable\s*:?\s*(\S*)\s*$/$1/i', 1, _t);
        await = (outcome = ''); path = '';
        goto next;
      end;
      if await then do;
        outcome = scan(_t, 1, ' '); await = 0;
        if findw(seen, strip(outcome), ' ', 'e') and outcome = hy then total_model = 1;
        seen = catx(' ', seen, outcome);
        goto next;
      end;
      if outcome ne '' and seen = '' then seen = outcome;
      if prxmatch('/^(relative )?(conditional )?indirect effects?(\(s\))?/i', _t) then
        ind_ctx = lowcase(compbl(prxchange('s/:+\s*$//', 1, _t)));
      if index(_t, '->') then do;
        _t2 = tranwrd(tranwrd(cat(' ', _t, ' '), ' -> ', ' '), ' : ', ' ');
        _t2 = compbl(strip(_t2));
        if prxmatch('/^Ind\d+$/', trim(scan(_t2, 1, ' '))) then do;
          kname = scan(_t2, 1, ' '); kpath = substr(_t2, length(kname) + 2); output work._er_pkey;
        end;
        else path = _t2;
      end;
      if prxmatch('/^[({](C\d+)\)\s+(.*)$/', _t) then do;
        kname = prxchange('s/^[({](C\d+)\)\s+(.*)$/$1/', 1, _t);
        kpath = compbl(prxchange('s/^[({](C\d+)\)\s+(.*)$/$2/', 1, trim(_t))); output work._er_pctr;
      end;
      if prxmatch('/^(Int_\d+)\s*:?\s*(.*)$/i', _t) then do;
        kname = lowcase(prxchange('s/^(Int_\d+)\s*:?\s*(.*)$/$1/i', 1, _t));
        kpath = '';
        _t2 = prxchange('s/^(Int_\d+)\s*:?\s*(.*)$/$2/i', 1, _t);
        do _j = 1 to countw(_t2, ' ');
          if scan(_t2, _j, ' ') not in ('x', ':') then kpath = catx(' ', kpath, scan(_t2, _j, ' '));
        end;
        output work._er_pprod;
      end;
      goto next;
    end;
    /* a table row */
    k = lowcase(compbl(prxchange('s/:+\s*$//', 1, strip(ttl))));
    if k = '' and path ne '' and ind_ctx ne '' then k_ctx = ind_ctx; else k_ctx = k;
    resp = outcome; comp = ifc(total_model, 'total_effect_model', '');
    est = .; se = .; stat = .; p = .; lo = .; hi = .;
    m_effect = ''; m_med = ''; m_treat = ''; m_mvn = .; m_mvs = ''; m_path = ''; m_ind = ''; m_lab = '';
    /* moderator columns: those before effect / index / coeff */
    if tfirst then do;
      nmod = 0; mods = '';
      do _j = 1 to ncol;
        if cn{_j} in ('effect', 'index', 'coeff') then leave;
        nmod + 1; mods = catx('|', mods, cr{_j});
      end;
      if _j > ncol then do; nmod = 0; mods = ''; end;
    end;
    atx = '';
    if nmod = 1 then do; m_mvn = v{1}; atx = cat(', at ', strip(scan(mods, 1, '|')), ' = ', strip(er_mvfmt(v{1}))); end;
    else if nmod > 1 then do;
      atx = ', at';
      do _j = 1 to nmod;
        m_mvs = catx(', ', m_mvs, cats(scan(mods, _j, '|'), '=', er_num(v{_j})));
        atx = catx(' ', atx, strip(scan(mods, _j, '|')), '=', cats(er_mvfmt(v{_j}), ifc(_j < nmod, ',', '')));
      end;
    end;
    est = er_pcol2('coeff|effect|index', cn, v, nmod); se = er_pcol2('se|bootse', cn, v, nmod);
    stat = er_pcol2('t|z', cn, v, nmod); p = er_pcol2('p', cn, v, nmod);
    lo = er_pcol2('llci|bootllci', cn, v, nmod); hi = er_pcol2('ulci|bootulci', cn, v, nmod);
    if k = 'model summary' then do;
      fitno + 1;
      r2 = er_pcol('r-sq', cn, v); adj_r2 = er_pcol('adj r-sq|adj_r-sq', cn, v); mse = er_pcol('mse', cn, v);
      dfr = er_pcol('df2', cn, v); dev = er_pcol('-2ll', cn, v); pr2 = er_pcol('mcfadden', cn, v);
      csr2 = er_pcol('coxsnell', cn, v); nkr2 = er_pcol('nagelkrk', cn, v);
      output work._er_pfit;
      tsn + 1; cat = 'model'; dist = '';
      _f = er_pcol('f', cn, v);
      name = ifc(missing(_f), 'likelihood_ratio', 'f');
      label = cat('Model summary, ', strip(outcome));
      if total_model then label = cat(strip(label), ' (total effect model)');
      stat = ifn(missing(_f), er_pcol('modelll|-2ll', cn, v), _f);
      df = er_pcol('df1|df', cn, v); df2 = er_pcol('df2', cn, v); p = er_pcol('p', cn, v); est = .; se = .;
      output work._er_pts;
      goto next;
    end;
    if k = 'model' then do;
      pno + 1;
      term = ifc(lowcase(rlabel) = 'constant', '(Intercept)', rlabel);
      output work._er_peq;
      goto next;
    end;
    if k =: 'test(s) of highest order' or k =: 'omnibus test' then do;
      tsn + 1; cat = 'restriction'; dist = ''; fitno_t = .;
      _f = er_pcol('f', cn, v);
      name = ifc(missing(_f), 'chi2', 'f');
      label = catx(' ', prxchange('s/:+\s*$//', 1, strip(ttl)), rlabel);
      stat = ifn(missing(_f), er_pcol('chi-sq', cn, v), _f);
      df = er_pcol('df1|df', cn, v); df2 = er_pcol('df2', cn, v); comp = ''; est = .; se = .;
      _keepfit = fitno; fitno = .; output work._er_pts; fitno = _keepfit;
      goto next;
    end;
    if prxmatch('/^(relative )?total effects?(\(s\))? of x on y/', k) then do;
      pno + 1; resp = ''; comp = ''; m_effect = 'total'; m_treat = rlabel;
      term = 'total effect'; if rlabel ne '' then term = catx(' ', 'total effect:', rlabel);
      output work._er_pef;
      goto next;
    end;
    if prxmatch('/^(relative )?(conditional )?direct effects?(\(s\))? of x on y/', k) then do;
      pno + 1; resp = ''; comp = ''; m_effect = 'direct'; m_treat = rlabel;
      term = 'direct effect'; if rlabel ne '' then term = catx(' ', 'direct effect:', rlabel);
      term = catt(term, atx);
      output work._er_pef;
      goto next;
    end;
    if prxmatch('/^(relative )?(conditional )?indirect effects?(\(s\))? of x on y/', k) or (k = '' and path ne '') then do;
      pno + 1; resp = ''; comp = ''; m_effect = 'indirect';
      _rel = (substr(k_ctx, 1, 8) = 'relative');
      if upcase(rlabel) = 'TOTAL' then m_effect = 'total_indirect';
      else if prxmatch('/^\(C\d+\)$/', trim(rlabel)) then do; m_effect = 'contrast'; m_lab = rlabel; end;
      else if prxmatch('/^Ind\d+$/', trim(rlabel)) then m_ind = rlabel;
      else if _rel and rlabel ne '' then m_treat = rlabel;
      else if rlabel ne '' and nmod = 0 then m_med = rlabel;
      if m_effect = 'indirect' and m_med = '' and m_ind = '' and path ne '' then do;
        if countw(path, ' ') = 3 then m_med = scan(path, 2, ' '); else m_path = path;
      end;
      if m_effect = 'total_indirect' then term = 'total indirect effect';
      else if m_effect = 'contrast' then term = catx(' ', 'contrast', rlabel);
      else do;
        if path ne '' and (_rel or nmod > 0 or rlabel = '') then term = cat('indirect: ', tranwrd(strip(path), ' ', ' -> '));
        else term = cat('indirect: ', strip(coalescec(m_med, rlabel)));
        if m_treat ne '' then term = cat(strip(term), ' [', strip(m_treat), ']');
      end;
      term = catt(term, atx);
      output work._er_pef;
      goto next;
    end;
    if (cn{1} = 'ss' and cn{2} = 'df' and cn{3} = 'ms' and ncol = 3) then do;
      if tfirst then do; mres_mse = .; mres_dfr = .; mreg_df = .; end;
      if substr(lowcase(rlabel), 1, 5) = 'resid' then do; mres_mse = er_pcol('ms', cn, v); mres_dfr = er_pcol('df', cn, v); end;
      if substr(lowcase(rlabel), 1, 5) = 'regre' then mreg_df = er_pcol('df', cn, v);
      if tlast and not missing(mres_dfr) then do;
        a_mse = mres_mse; a_dfr = mres_dfr; a_dfreg = mreg_df; output work._er_pan;
      end;
      goto next;
    end;
    if k =: 'coding of' or k =: 'anova summary' then goto next;
    if prxmatch('/index of (partial |conditional )?moderated mediation/', k) then do;
      pno + 1; resp = ''; comp = ''; m_effect = 'index_moderated_mediation';
      term = 'index of moderated mediation';
      if rlabel ne '' then term = cat(strip(term), ' (', strip(rlabel), ')');
      if path ne '' then term = cat(strip(term), ': ', tranwrd(strip(path), ' ', ' -> '));
      if countw(path, ' ') = 3 then m_med = scan(path, 2, ' ');
      else if countw(path, ' ') > 3 then m_path = path;
      m_mvn = .; m_mvs = '';
      output work._er_pef;
      goto next;
    end;
    if k =: 'normal theory test' then do;
      tsn + 1; cat = 'linear_combination'; name = 'wald'; dist = 'normal';
      label = catx(' ', 'Normal theory (Sobel) test of the indirect effect through', rlabel);
      est = er_pcol('effect', cn, v); se = er_pcol('se', cn, v); stat = er_pcol('z', cn, v); p = er_pcol('p', cn, v);
      df = .; df2 = .; resp = ''; comp = ''; _keepfit = fitno; fitno = .; output work._er_pts; fitno = _keepfit;
      goto next;
    end;
    if prxmatch('/^conditional effects? of (the )?focal predictor/', k) then do;
      pno + 1; comp = 'conditional'; term = catt(hx, atx); m_mvn = .; m_mvs = '';
      output work._er_pef;
      goto next;
    end;
    if tfirst then do;
      label = prxchange('s/:+\s*$//', 1, strip(ttl)); if label = '' then label = '(untitled table)';
      output work._er_pskip;
    end;
    next:
    if _e then do;
      call symputx('_er_pmodel', hmodel, 'G'); call symputx('_er_py', hy, 'G'); call symputx('_er_px', hx, 'G');
      call symputx('_er_pm', hm, 'G'); call symputx('_er_pw', hw, 'G'); call symputx('_er_pz', hz, 'G');
      call symputx('_er_pcov', hcov, 'G'); call symputx('_er_pnobs', hnobs, 'G'); call symputx('_er_pseed', hseed, 'G');
      call symputx('_er_pver', hver, 'G'); call symputx('_er_pconf', hconf, 'G'); call symputx('_er_preps', hreps, 'G');
    end;
  run;
  %if %length(&_er_pver) = 0 %then %do; %let _er_skip = %str(IML output that isn%'t PROCESS); %return; %end;
  /* 4. what the order alone doesn't settle: keys, contrasts, product terms, the ANOVA table's df */
  proc sql;
    create table work._er_pfit2 as select f.*, a.a_mse, a.a_dfr
      from work._er_pfit f left join work._er_pan a on f.fitno = a.fitno and f.resp = a.resp order by f.fitno;
    create table work._er_pts2 as select t.*, a.a_dfr, a.a_dfreg
      from work._er_pts t left join work._er_pan a on t.fitno = a.fitno and t.resp = a.resp and t.name = 'f' order by t.tsn;
  quit;
  data work._er_pfit2; set work._er_pfit2; mse = coalesce(mse, a_mse); dfr = coalesce(dfr, a_dfr); run;
  data work._er_pts2; set work._er_pts2; if name = 'f' then do; df = coalesce(df, a_dfreg); df2 = coalesce(df2, a_dfr); end; run;
  data work._er_pef2;
    if 0 then set work._er_pkey work._er_pctr;
    length short $ 400;
    if _n_ = 1 then do;
      declare hash hk(dataset: 'work._er_pkey'); hk.definekey('kname'); hk.definedata('kpath'); hk.definedone();
      declare hash hc(dataset: 'work._er_pctr(rename=(kpath=cdef))'); hc.definekey('kname'); hc.definedata('cdef'); hc.definedone();
    end;
    length cdef $ 2000;
    set work._er_pef;
    if m_ind ne '' then do;
      kname = m_ind;
      if hk.find() = 0 then do;
        if countw(kpath, ' ') = 3 then m_med = scan(kpath, 2, ' '); else m_path = kpath;
        term = cat('indirect: ', tranwrd(strip(kpath), ' ', ' -> '));
      end;
    end;
    else if m_effect = 'indirect' and m_med ne '' and "&_er_px" ne '' and "&_er_py" ne '' then do;
      short = cat('indirect: ', strip(m_med));
      if term = short or substr(term, 1, length(short) + 1) = cat(strip(short), ' ') then
        term = cat('indirect: ', "&_er_px", ' -> ', strip(m_med), ' -> ', "&_er_py", substr(term, length(short) + 1));
    end;
    if m_effect = 'contrast' then do;
      kname = compress(m_lab, '()'); cdef = '';
      _rc = hc.find();
      term = cat('contrast ', strip(m_lab), ifc(cdef ne '', cat(': ', strip(cdef)), ''));
    end;
    if resp = '' then resp = "&_er_py";
    drop short kname kpath cdef _rc;
  run;
  data work._er_peq2;
    if 0 then set work._er_pprod;
    if _n_ = 1 then do; declare hash hp(dataset: 'work._er_pprod'); hp.definekey('kname'); hp.definedata('kpath'); hp.definedone(); end;
    set work._er_peq;
    kname = lowcase(term); kpath = '';
    if hp.find() ne 0 then kpath = '';
  run;

  /* 5. the record */
  %local ydich nresp resps profiles meds boot msg nmsg skipped fam meth struct imeth;
  proc sql noprint;
    select count(*) > 0 into :ydich trimmed from work._er_pts where name = 'likelihood_ratio' and resp = "&_er_py";
    select count(*) > 0 into :boot trimmed from work._er_pef where m_effect in ('indirect', 'total_indirect', 'index_moderated_mediation');
    select count(*) > 0 into :_er_pind trimmed from work._er_pef where m_effect = 'indirect';
    select label into :skipped separated by '; ' from work._er_pskip;
  quit;
  %if %length(&_er_preps) = 0 or &_er_preps = . %then %let boot = 0;
  data work._er_presp; set work._er_peq(keep=resp pno); by notsorted resp; if first.resp; run;
  proc sort data=work._er_presp nodupkey; by resp; run;
  proc sort data=work._er_presp; by pno; run;
  %if %length(&_er_pm) and &_er_pind %then %let profiles = mediation/0.1;
  %if %superq(_er_title) = %str(PROC IML) %then %let _er_title = PROCESS model &_er_pmodel;
  %let _er_cmd = IML;
  %let _er_pcall = PROCESS y=&_er_py /x=&_er_px;
  %if %length(&_er_pm) %then %let _er_pcall = &_er_pcall /m=&_er_pm;
  %if %length(&_er_pw) %then %let _er_pcall = &_er_pcall /w=&_er_pw;
  %if %length(&_er_pz) %then %let _er_pcall = &_er_pcall /z=&_er_pz;
  %if %length(&_er_pcov) %then %let _er_pcall = &_er_pcall /cov=&_er_pcov;
  %let _er_pcall = &_er_pcall /model=&_er_pmodel..;
  %if %length(&_er_pm) %then %let fam = mediation; %else %let fam = moderation;
  %if &ydich and %length(&_er_pm) = 0 %then %let meth = logit; %else %let meth = ols;
  %if %length(&_er_pw.&_er_pz) %then %let struct = moderated;
  %else %if &_er_pmodel = 6 %then %let struct = serial;
  %else %if %sysfunc(countw(&_er_pm, %str( ))) > 1 %then %let struct = parallel;
  %else %let struct = simple;
  %if &boot %then %let imeth = bootstrap; %else %let imeth = normal;
  %_er_part(pmeta)
    length id $ 36 now $ 20 v $ 2000;
    id = lowcase(uuidgen());
    substr(id, 15, 1) = '4'; substr(id, 20, 1) = substr('89ab', mod(rank(substr(id, 20, 1)), 4) + 1, 1);
    now = cats(put(tzones2u(datetime()), e8601dt19.), 'Z');
    call symputx('_er_pnow', now);
    %_er_s('schema', 'estrec/0.1');
    %_er_s('meta/id', id);
    %_er_s('meta/created', now);
    %_er_s('meta/status', 'ok');
    %_er_s('meta/estimator/family', "&fam");
    %_er_s('meta/estimator/method', "&meth");
    %if %length(&profiles) %then %_er_s('meta/profiles/#0001', "&profiles"); %else %_er_ea('meta/profiles');;
    %_er_s('meta/title', symget('_er_title'));
    %_er_s('meta/producer/name', 'estrec for SAS');
    %_er_s('meta/producer/version', "&_er_version");
    %let nmsg = 0;
    %if %length(&_er_pver) and %sysfunc(indexw(%str(5.0 5.1.1), &_er_pver)) = 0 %then %do;
      %let nmsg = %eval(&nmsg + 1);
      %_er_s("meta/messages/#%sysfunc(putn(&nmsg, z4.))/level", 'warning');
      %_er_s("meta/messages/#%sysfunc(putn(&nmsg, z4.))/code", 'process_version_unchecked');
      %_er_s("meta/messages/#%sysfunc(putn(&nmsg, z4.))/source", 'estrec');
      %_er_s("meta/messages/#%sysfunc(putn(&nmsg, z4.))/message",
             "PROCESS &_er_pver hasn't been checked with this writer (checked: 5.0, 5.1.1); PROCESS changes its output layout between minor versions, so compare the record with PROCESS's output");
    %end;
    %if %length(%superq(skipped)) %then %do;
      %let nmsg = %eval(&nmsg + 1);
      %_er_s("meta/messages/#%sysfunc(putn(&nmsg, z4.))/level", 'info');
      %_er_s("meta/messages/#%sysfunc(putn(&nmsg, z4.))/code", 'process_sections_skipped');
      %_er_s("meta/messages/#%sysfunc(putn(&nmsg, z4.))/source", 'estrec');
      %_er_s("meta/messages/#%sysfunc(putn(&nmsg, z4.))/message", cat('PROCESS output not recorded: ', symget('skipped')));
    %end;
  %_er_endpart(pmeta)
  %_er_part(presp)
    set work._er_presp;
    %_er_s(cats('meta/responses/#', put(_n_, z4.)), resp);
  %_er_endpart(presp)
  %_er_part(pspec)
    %_er_s('specification/formula/text', symget('_er_pcall'));
    %_er_s('specification/formula/syntax', 'PROCESS');
    %if %length(&_er_pm) %then %do;
      %_er_s('specification/mediation/treatment', "&_er_px");
      %do i = 1 %to %sysfunc(countw(&_er_pm, %str( )));
        %_er_s("specification/mediation/mediators/#%sysfunc(putn(&i, z4.))", "%scan(&_er_pm, &i, %str( ))");
      %end;
      %_er_s('specification/mediation/outcome', "&_er_py");
      %if %length(&_er_pcov) %then %do;
        %do i = 1 %to %sysfunc(countw(&_er_pcov, %str( )));
          %_er_s("specification/mediation/covariates/#%sysfunc(putn(&i, z4.))", "%scan(&_er_pcov, &i, %str( ))");
        %end;
      %end;
      %else %_er_ea('specification/mediation/covariates');;
      %let k = 0;
      %if %length(&_er_pw) %then %do; %let k = %eval(&k + 1); %_er_s("specification/mediation/moderators/#%sysfunc(putn(&k, z4.))", "&_er_pw"); %end;
      %if %length(&_er_pz) %then %do; %let k = %eval(&k + 1); %_er_s("specification/mediation/moderators/#%sysfunc(putn(&k, z4.))", "&_er_pz"); %end;
      %_er_s('specification/mediation/structure', "&struct");
      %_er_i('specification/mediation/process_model', &_er_pmodel);
      %_er_s('specification/mediation/inference/method', "&imeth");
      %if &boot %then %do;
        %_er_i('specification/mediation/inference/reps', round(&_er_preps));
        %_er_s('specification/mediation/inference/ci_type', 'percentile');
      %end;
      %if %length(&_er_pseed) and &_er_pseed ne . %then %_er_i('specification/mediation/inference/seed', &_er_pseed);;
    %end;
  %_er_endpart(pspec)
  %if %length(&_er_pm) %then %do;
    %_er_part(pmodels)
      set work._er_presp;
      %_er_s(cats('specification/mediation/models/#', put(_n_, z4.), '/response'), resp);
      %_er_s(cats('specification/mediation/models/#', put(_n_, z4.), '/estimator'), ifc(&ydich and resp = "&_er_py", 'logit', 'ols'));
    %_er_endpart(pmodels)
  %end;
  %_er_part(pmetrics)
    %if %length(&_er_pnobs) and &_er_pnobs ne . %then %_er_i('metrics/nobs', &_er_pnobs);;
    %if %length(&_er_pconf) and &_er_pconf ne . %then %_er_n('metrics/conf_level', &_er_pconf / 100);;
  %_er_endpart(pmetrics)
  data work._er_ppar; set work._er_peq2(in=_q) work._er_pef2; isq = _q; run;
  %_er_part(pparams)
    set work._er_ppar;
    length base $ 60;
    base = cats('parameters/#', put(_n_, z4.));
    %_er_s(cats(base, '/term'), term);
    %_er_n(cats(base, '/estimate'), est);
    %_er_n(cats(base, '/std_error'), se);
    if not missing(stat) then do; %_er_n(cats(base, '/statistic'), stat); end;
    if not missing(p) then do; %_er_n(cats(base, '/p_value'), p); end;
    if not missing(lo) then do; %_er_n(cats(base, '/conf_low'), lo); end;
    if not missing(hi) then do; %_er_n(cats(base, '/conf_high'), hi); end;
    if resp ne '' then do; %_er_s(cats(base, '/response'), resp); end;
    if comp ne '' then do; %_er_s(cats(base, '/component'), comp); end;
    if isq then do;
      if term = '(Intercept)' then do;
        %_er_s(cats(base, '/canonical/name'), '(Intercept)');
        %_er_ea(cats(base, '/canonical/factors'));
      end;
      else if kpath ne '' then do;
        %_er_s(cats(base, '/canonical/name'), tranwrd(strip(kpath), ' ', ':'));
        do _f = 1 to countw(kpath, ' ');
          %_er_s(cats(base, '/canonical/factors/#', put(_f, z4.), '/variable'), scan(kpath, _f, ' '));
        end;
      end;
      else do;
        %_er_s(cats(base, '/canonical/name'), term);
        %_er_s(cats(base, '/canonical/factors/#0001/variable'), term);
      end;
    end;
    if m_effect ne '' then do;
      %_er_s(cats(base, '/mediation/effect'), m_effect);
      if m_med ne '' then do; %_er_s(cats(base, '/mediation/mediator'), m_med); end;
      if m_treat ne '' then do; %_er_s(cats(base, '/mediation/treatment'), m_treat); end;
      if not missing(m_mvn) then do; %_er_n(cats(base, '/mediation/moderator_value'), m_mvn); end;
      else if m_mvs ne '' then do; %_er_s(cats(base, '/mediation/moderator_value'), m_mvs); end;
      if m_path ne '' then do;
        do _f = 1 to countw(m_path, ' ');
          %_er_s(cats(base, '/mediation/path/#', put(_f, z4.)), scan(m_path, _f, ' '));
        end;
      end;
    end;
  %_er_endpart(pparams)
  %if %_er_has(_er_pfit2) %then %do;
    %_er_part(pfits)
      set work._er_pfit2(where=(resp ne ''));
      length base $ 80;
      base = cats('structures/equations/per_response/#', put(_n_, z4.));
      if _n_ = 1 then do; %_er_s('structures/equations/kind', 'object'); end;
      %_er_s(cats(base, '/response'), resp);
      if comp ne '' then do; %_er_s(cats(base, '/component'), comp); end;
      %_er_nn(cats(base, '/r2'), r2); %_er_nn(cats(base, '/adj_r2'), adj_r2); %_er_nn(cats(base, '/mse'), mse);
      if not missing(dfr) then do; %_er_i(cats(base, '/df_residual'), dfr); end;
      %_er_nn(cats(base, '/deviance'), dev); %_er_nn(cats(base, '/pseudo_r2'), pr2);
      %_er_nn(cats(base, '/cox_snell_r2'), csr2); %_er_nn(cats(base, '/nagelkerke_r2'), nkr2);
      %if %length(&_er_pnobs) and &_er_pnobs ne . %then %_er_i(cats(base, '/nobs'), &_er_pnobs);;
    %_er_endpart(pfits)
  %end;
  %if %_er_has(_er_pts2) %then %do;
    %_er_part(ptests)
      set work._er_pts2;
      length base $ 60;
      base = cats('tests/#', put(_n_, z4.));
      %_er_s(cats(base, '/id'), cats('t', _n_));
      %_er_s(cats(base, '/category'), cat);
      %_er_s(cats(base, '/name'), name);
      %_er_s(cats(base, '/label'), label);
      if not missing(est) then do; %_er_n(cats(base, '/estimate'), est); end;
      if not missing(se) then do; %_er_n(cats(base, '/std_error'), se); end;
      if not missing(stat) then do; %_er_n(cats(base, '/statistic'), stat); end;
      if not missing(p) then do; %_er_n(cats(base, '/p_value'), p); end;
      %_er_s(cats(base, '/origin'), 'estimation');
      if resp ne '' then do; %_er_s(cats(base, '/response'), resp); end;
      if comp ne '' then do; %_er_s(cats(base, '/component'), comp); end;
      if name = 'f' then do;
        %_er_s(cats(base, '/distribution'), 'F');
        if not missing(df) then do; %_er_n(cats(base, '/df1'), df); end;
        if not missing(df2) then do; %_er_n(cats(base, '/df2'), df2); end;
      end;
      else do;
        if dist ne '' then do; %_er_s(cats(base, '/distribution'), dist); end;
        if not missing(df) then do; %_er_n(cats(base, '/df'), df); end;
      end;
    %_er_endpart(ptests)
  %end;
%mend;

/* ------------------------------------------------------------------ end */
%macro estrec_end(out=, title=, identifying=NO);
  %local nproc i dir proc file nrec k stem ext;
  %global _er_partno _er_family _er_method _er_dist _er_link _er_resp _er_profiles _er_title
          _er_cmd _er_dataset _er_rows _er_nobs _er_status _er_skip _er_msgs _er_identifying
          _er_dfr _er_rss _er_tss _er_F _er_Fp _er_dfm _er_sigma _er_r2 _er_ar2 _er_full
          _er_m2ll _er_aic _er_bic _er_conv _er_ll _er_dev _er_pear _er_qic _er_disp _er_ncl
          _er_subj _er_isgee _er_hcm _er_digest _er_strat _er_clv _er_wv _er_nstr _er_sw _er_pos _er_npar _er_vcnose
          _er_meth _er_ddfm _er_nsub _er_pm _er_ncs _er_nts _er_vu _er_ve _er_np2 _er_endo _er_inst
          _er_pver _er_pisproc _er_pnow;
  %if %length(&out) = 0 %then %do; %put ERROR: estrec: %nrstr(%estrec_end) needs OUT=; %return; %end;
  ods document close;
  %if not %sysfunc(exist(work._estrec, itemstor)) %then %do;
    %put ERROR: estrec: %nrstr(%estrec_end) without %nrstr(%estrec_begin); %return;
  %end;
  ods exclude all;
  proc document name=work._estrec; ods output Properties=work._er_list; list / levels=all; run; quit;
  ods exclude none;
  data work._er_list; set work._er_list; _ord = _n_; run;
  /* procedures: top-level directories, e.g. \Logistic#1 */
  data work._er_procs; set work._er_list;
    where type = 'Dir' and countc(path, '\') = 1;
    length proc $ 32; proc = upcase(scan(path, 1, '\#'));
    supported = proc in ('REG', 'GLM', 'SURVEYREG', 'LOGISTIC', 'SURVEYLOGISTIC', 'GENMOD', 'MIXED', 'GLIMMIX', 'PANEL', 'SYSLIN', 'IML');
  run;
  proc sql noprint;
    select count(*) into :nrec trimmed from work._er_procs where supported;
    select count(*) into :nproc trimmed from work._er_procs;
  quit;
  %let stem = &out; %let ext = .estrec.json;
  %if %sysfunc(prxmatch(/\.estrec\.json$/i, &out)) %then %let stem = %substr(&out, 1, %length(&out) - 12);
  %else %if %sysfunc(prxmatch(/\.json$/i, &out)) %then %do; %let stem = %substr(&out, 1, %length(&out) - 5); %let ext = .json; %end;
  %let k = 0;
  %do i = 1 %to &nproc;
    data _null_; set work._er_procs(firstobs=&i obs=&i);
      call symputx('_er_dir', path); call symputx('_er_cmd', proc); call symputx('_er_sup', supported);
    run;
    %if not &_er_sup %then %do;
      %put NOTE: estrec: no record for PROC &_er_cmd (not supported yet).;
    %end;
    %else %do;
      options obs=max nosyntaxcheck;   /* one failed step must not stop the other records */
      %let _er_partno = 1; %let _er_resp =; %let _er_dataset =; %let _er_rows =; %let _er_nobs =;
      %let _er_status = ok; %let _er_skip =; %let _er_msgs =; %let _er_identifying = %upcase(&identifying);
      %let _er_dist =; %let _er_link =; %let _er_pver =; %let _er_pisproc = 0;
      %if %length(&title) %then %let _er_title = &title; %else %let _er_title = PROC &_er_cmd;
      proc datasets lib=work nolist nowarn; delete _er_rec _er_par _er_cov; quit;
      %if &_er_cmd = REG %then %_er_reg(&_er_dir);
      %else %if &_er_cmd = LOGISTIC %then %_er_logistic(&_er_dir);
      %else %if &_er_cmd = GENMOD %then %_er_genmod(&_er_dir);
      %else %if &_er_cmd = GLM %then %_er_glm(&_er_dir);
      %else %if &_er_cmd = SURVEYREG %then %_er_surveyreg(&_er_dir);
      %else %if &_er_cmd = SURVEYLOGISTIC %then %_er_surveylogistic(&_er_dir);
      %else %if &_er_cmd = MIXED %then %_er_mixed(&_er_dir);
      %else %if &_er_cmd = GLIMMIX %then %_er_glimmix(&_er_dir);
      %else %if &_er_cmd = PANEL %then %_er_panel(&_er_dir);
      %else %if &_er_cmd = SYSLIN %then %_er_syslin(&_er_dir);
      %else %if &_er_cmd = IML %then %_er_iml(&_er_dir);
      %if %length(&_er_skip) %then %do;
        %put WARNING: estrec: no record for PROC &_er_cmd: &_er_skip..;
      %end;
      %else %do;
        %_er_tail
        %let k = %eval(&k + 1);
        %if &nrec = 1 %then %let file = &out; %else %let file = &stem.-&k.&ext;
        %_er_finish(&file)
      %end;
    %end;
  %end;
  %if &nrec = 0 %then %put WARNING: estrec: no supported procedure ran between %nrstr(%estrec_begin) and %nrstr(%estrec_end).;
  proc datasets lib=work nolist nowarn;
    delete _er_: / memtype=data; delete _estrec / memtype=itemstor;
  quit;
%mend;

/* messages, digest (canonical form of the core sections, sha256), then the file */
%macro _er_finish(file);
  %local m nm code text;
  %let nm = 0;
  %do m = 1 %to %sysfunc(countw(&_er_msgs, |));
    %let code = %scan(&_er_msgs, &m, |);
    %if &code = no_vcov_matrix %then %let text = the procedure printed no covariance matrix of the estimates: the record has the variances (squared standard errors) and null covariances, ask for COVB to record it;
    %else %if &code = vc_no_se %then %let text = the variance components have no standard errors (add COVTEST), so the record claims mixed/0.1 but not inference/0.1;
    %else %if &code = panel_ids %then %let text = PANEL reports the number of cross sections and time periods but not the ID variable names: the fixed effects are named (cross section) and (time period);
    %else %if &code = syslin_iv %then %let text = SYSLIN prints no list of endogenous variables and instruments: the record has the structural equation only;
    %else %let text =;
    %if %length(&text) %then %do;
      %let nm = %eval(&nm + 1);
      %_er_part(msg&m)
        %_er_s("meta/messages/#%sysfunc(putn(&nm, z4.))/level", 'info');
        %_er_s("meta/messages/#%sysfunc(putn(&nm, z4.))/code", "&code");
        %_er_s("meta/messages/#%sysfunc(putn(&nm, z4.))/source", 'estrec');
        %_er_s("meta/messages/#%sysfunc(putn(&nm, z4.))/message", "&text");
      %_er_endpart(msg&m)
    %end;
  %end;
  /* canonical form: core sections, keys in code-unit order ('/' -> '01'x keeps parents first) */
  data work._er_canon; set work._er_rec;
    length _key $ 600;
    if scan(path, 1, '/') in ('meta', 'specification', 'metrics', 'parameters', 'structures');
    _key = translate(path, '01'x, '/');
  run;
  proc sort data=work._er_canon; by _key; run;
  %let _er_digest =;
  %_er_write(work._er_canon, %sysfunc(pathname(work))/_er_canon.json, pretty=0)
  data _null_;
    length h $ 64;
    h = hashing_file('SHA256', "%sysfunc(pathname(work))/_er_canon.json");
    call symputx('_er_digest', lowcase(h));
  run;
  %if %length(&_er_digest) = 64 %then %do;
    %_er_part(digest)
      %_er_s('meta/core_digest/algorithm', 'sha256');
      %_er_s('meta/core_digest/canonicalization', 'RFC8785');
      %_er_s('meta/core_digest/value', "&_er_digest");
    %_er_endpart(digest)
  %end;
  %else %put NOTE: estrec: no core digest (SAS could not load OpenSSL for HASHING_FILE), estrec digest (Python) can add it.;
  /* sections in the format's order; within a section, the order the rows were built */
  data work._er_rec; set work._er_rec;
    _rank = whichc(scan(path, 1, '/'), 'schema', 'meta', 'specification', 'metrics', 'parameters',
                   'structures', 'tests', 'provenance', 'history');
  run;
  proc sort data=work._er_rec; by _rank part seq; run;
  %_er_write(work._er_rec, &file, pretty=1)
  %put NOTE: estrec: wrote &file (PROC &_er_cmd).;
%mend;
