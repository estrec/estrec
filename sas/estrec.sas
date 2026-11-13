/* estrec for SAS: writes procedure results as estrec records (https://estrec.org).

   %include "estrec.sas";
   %estrec_begin;
   proc logistic data=mydata; class grp / param=ref; model y(event='1') = grp x / covb; run;
   %estrec_end(out=/path/fit.estrec.json);

   %estrec_begin opens an ODS document; the procedures' output goes to it as well as to
   your usual destinations. %estrec_end closes it and writes one record per supported
   procedure run in between (numbered fit-1, fit-2, ... when there are several):
   REG, GLM, SURVEYREG, LOGISTIC, SURVEYLOGISTIC and GENMOD (including GEE).

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
    file "&file" recfm=n encoding='utf-8' lrecl=32767;
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
        piece = cats('"', er_str(c), '":'); if &pretty then piece = catt(piece, ' ');
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
      piece = cats('"', er_str(c), '":'); if &pretty then piece = catt(piece, ' ');
      len = lengthn(piece) + &pretty; put piece $varying32767. len @;
    end;
    if kind = 's' then val = cats('"', er_str(sval), '"');
    else val = strip(sval);
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
    %_er_s('provenance/software/#0002/name', 'estrec for SAS');
    %_er_s('provenance/software/#0002/version', "&_er_version");
    %_er_s('provenance/software/#0002/role', 'writer');
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
  data work._er_cov; set work._er_cb;
    array v{*} _numeric_; array c{200}; _j = 0;
    do _i = 1 to dim(v); if upcase(vname(v{_i})) not in ('_RUN_') then do; _j + 1; c{_j} = v{_i}; end; end;
    keep c:;
  run;
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
  data work._er_cov; set work._er_cb;
    array v{*} _numeric_; array c{200}; _j = 0;
    do _i = 1 to dim(v); if upcase(vname(v{_i})) not in ('_RUN_') then do; _j + 1; c{_j} = v{_i}; end; end;
    keep c:;
  run;
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

/* ------------------------------------------------------------------ end */
%macro estrec_end(out=, title=, identifying=NO);
  %local nproc i dir proc file nrec k stem ext;
  %global _er_partno _er_family _er_method _er_dist _er_link _er_resp _er_profiles _er_title
          _er_cmd _er_dataset _er_rows _er_nobs _er_status _er_skip _er_msgs _er_identifying
          _er_dfr _er_rss _er_tss _er_F _er_Fp _er_dfm _er_sigma _er_r2 _er_ar2 _er_full
          _er_m2ll _er_aic _er_bic _er_conv _er_ll _er_dev _er_pear _er_qic _er_disp _er_ncl
          _er_subj _er_isgee _er_hcm _er_digest _er_strat _er_clv _er_wv _er_nstr _er_sw _er_pos;
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
    supported = proc in ('REG', 'GLM', 'SURVEYREG', 'LOGISTIC', 'SURVEYLOGISTIC', 'GENMOD');
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
      %let _er_dist =; %let _er_link =;
      %if %length(&title) %then %let _er_title = &title; %else %let _er_title = PROC &_er_cmd;
      proc datasets lib=work nolist nowarn; delete _er_rec _er_par _er_cov; quit;
      %if &_er_cmd = REG %then %_er_reg(&_er_dir);
      %else %if &_er_cmd = LOGISTIC %then %_er_logistic(&_er_dir);
      %else %if &_er_cmd = GENMOD %then %_er_genmod(&_er_dir);
      %else %if &_er_cmd = GLM %then %_er_glm(&_er_dir);
      %else %if &_er_cmd = SURVEYREG %then %_er_surveyreg(&_er_dir);
      %else %if &_er_cmd = SURVEYLOGISTIC %then %_er_surveylogistic(&_er_dir);
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
  %if %index(&_er_msgs, no_vcov_matrix) %then %do;
    %_er_part(msg)
      %_er_s('meta/messages/#0001/level', 'info');
      %_er_s('meta/messages/#0001/code', 'no_vcov_matrix');
      %_er_s('meta/messages/#0001/source', 'estrec');
      %_er_s('meta/messages/#0001/message', 'the procedure printed no covariance matrix of the estimates: the record has the variances (squared standard errors) and null covariances; ask for COVB to record it');
    %_er_endpart(msg)
    data work._er_rec; set work._er_rec; if path =: 'meta/messages' then part = 1.5; run;
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
    data work._er_rec; set work._er_rec; if path =: 'meta/core_digest' then part = 1.9; run;
  %end;
  %else %put NOTE: estrec: no core digest (SAS could not load OpenSSL for HASHING_FILE), estrec digest (Python) can add it.;
  proc sort data=work._er_rec; by part seq; run;
  %_er_write(work._er_rec, &file, pretty=1)
  %put NOTE: estrec: wrote &file (PROC &_er_cmd).;
%mend;
