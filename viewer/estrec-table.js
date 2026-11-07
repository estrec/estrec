// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ted Matherly and the estrec contributors
//
// Views of estimation records and table specs (spec/table.md) for the browser viewer and for
// node. The same rules as the Python reference (estrec.views and .table): tidy,
// glance, another vcov in the record, and building and rendering a table spec.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.EstTable = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  const TABLE_SCHEMA = "estrec-table/0.1";
  const DEFAULT_STARS = [0.1, 0.05, 0.01];
  const TABLE_METRICS = ["nobs", "r2", "adj_r2", "r2_within", "adj_r2_within", "pseudo_r2", "aic", "bic", "log_lik", "f_stat", "rmse"];
  const STAT_LABELS = {
    nobs: "N", r2: "R²", adj_r2: "Adj. R²", r2_within: "Within R²", adj_r2_within: "Adj. within R²",
    pseudo_r2: "Pseudo R²", aic: "AIC", bic: "BIC", log_lik: "Log lik.", rmse: "RMSE", f_stat: "F",
  };

  // lines under each estimate (spec/table.md section 5)
  const NAMED_LINES = { std_error: "({std_error})", statistic: "({statistic})", p_value: "[{p_value}]", conf_int: "[{conf_low}, {conf_high}]" };
  const PLACEHOLDERS = ["estimate", "std_error", "statistic", "p_value", "conf_low", "conf_high"];
  const PLACEHOLDER = /\{([^{}]*)\}/g;
  const NAMED_NOTES = { std_error: "Standard errors in parentheses.", statistic: "Test statistics in parentheses.", p_value: "p-values in brackets.", conf_int: "Confidence intervals in brackets." };
  const WORDS = { estimate: "estimate", std_error: "standard error", statistic: "test statistic", p_value: "p-value", conf_low: "lower bound", conf_high: "upper bound" };

  const SPARK_COLOR = "#2b5f8e";
  const SPARK_SCALES = ["column", "row", "table"];
  const SPARK_PLACES = ["below", "beside"];
  const SPARK_ALIGNS = ["estimate", "middle"];
  const SPARK_TEXT = "[{conf_low}, {conf_high}]";
  const isObj = (x) => x !== null && typeof x === "object" && !Array.isArray(x);

  function lineItems(spec) {
    const unc = spec.uncertainty === undefined ? "std_error" : spec.uncertainty;
    if (unc === null) return [];
    return Array.isArray(unc) ? unc : [unc];
  }

  // names become templates; a sparkline becomes {sparkline: {color, scale, place, align}} with defaults
  function uncertaintyLines(spec) {
    return lineItems(spec).map((x) => {
      if (isObj(x)) {
        const sp = x.sparkline || {};
        return { sparkline: { color: sp.color !== undefined ? sp.color : SPARK_COLOR, scale: sp.scale !== undefined ? sp.scale : "column", place: sp.place !== undefined ? sp.place : "below", align: sp.align !== undefined ? sp.align : "estimate" } };
      }
      return NAMED_LINES[x] || x;
    });
  }

  function lineIssues(spec) {
    const unc = spec.uncertainty === undefined ? "std_error" : spec.uncertainty;
    if (unc === null) return [];
    const items = Array.isArray(unc) ? unc : [unc];
    const out = [];
    let beside = 0;
    items.forEach((x, j) => {
      const path = Array.isArray(unc) ? `uncertainty[${j}]` : "uncertainty";
      if (isObj(x)) {
        const sp = x.sparkline;
        if (Object.keys(x).join() !== "sparkline" || !isObj(sp)) { out.push(issue("error", path, 'an object line is {"sparkline": {color, scale}}')); return; }
        if ("color" in sp && !(typeof sp.color === "string" && /^#[0-9a-fA-F]{6}$/.test(sp.color))) out.push(issue("error", `${path}.sparkline.color`, "a colour as #rrggbb"));
        if ("scale" in sp && !SPARK_SCALES.includes(sp.scale)) out.push(issue("error", `${path}.sparkline.scale`, "'column', 'row' or 'table'"));
        if ("place" in sp && !SPARK_PLACES.includes(sp.place)) out.push(issue("error", `${path}.sparkline.place`, "'below' or 'beside'"));
        else if (sp.place === "beside" && ++beside > 1) out.push(issue("error", `${path}.sparkline.place`, "one sparkline at most is beside the estimates"));
        if ("align" in sp && !SPARK_ALIGNS.includes(sp.align)) out.push(issue("error", `${path}.sparkline.align`, "'estimate' or 'middle'"));
      } else if (typeof x !== "string") out.push(issue("error", path, "a name, a template string or a sparkline"));
      else if (x in NAMED_LINES) return;
      else if (!x.includes("{")) out.push(issue("error", path, `'${x}' is neither a name (${Object.keys(NAMED_LINES).join(", ")}) nor a template`));
      else {
        const names = [...x.matchAll(PLACEHOLDER)].map((m) => m[1]);
        const bad = names.filter((n) => !PLACEHOLDERS.includes(n));
        if (bad.length) out.push(issue("error", path, `unknown placeholder {${bad[0]}}; use ${PLACEHOLDERS.join(", ")}`));
        else if (!names.length) out.push(issue("error", path, "a template needs at least one placeholder"));
      }
    });
    return out;
  }

  function uncertaintyNote(spec, lines) {
    const unc = spec.uncertainty === undefined ? "std_error" : spec.uncertainty;
    if (unc === null || !lines.length) return null;
    if (typeof unc === "string" && NAMED_NOTES[unc]) return NAMED_NOTES[unc];
    const parts = lines.map((t) => isObj(t) ? "confidence interval drawn as a line, the estimate as a dot, 0 as a grey rule" : t.replace("{conf_low}, {conf_high}", "confidence interval").replace(PLACEHOLDER, (_, n) => WORDS[n] || n));
    return "Under each estimate: " + parts.join("; ") + ".";
  }

  // ------------------------------------------------------------ distributions

  const LANCZOS = [0.99999999999980993, 676.5203681218851, -1259.1392167224028, 771.32342877765313,
    -176.61502916214059, 12.507343278686905, -0.13857109526572012, 9.9843695780195716e-6, 1.5056327351493116e-7];

  function lgamma(x) {
    if (x < 0.5) return Math.log(Math.PI / Math.abs(Math.sin(Math.PI * x))) - lgamma(1 - x);
    x -= 1;
    let a = LANCZOS[0];
    const t = x + 7.5;
    for (let i = 1; i < 9; i++) a += LANCZOS[i] / (x + i);
    return 0.5 * Math.log(2 * Math.PI) + (x + 0.5) * Math.log(t) - t + Math.log(a);
  }

  // erfc to near double precision: a positive series for erf below 2.5, a continued fraction above
  function erfc(x) {
    if (x < 0) return 2 - erfc(-x);
    if (x < 2.5) {
      let term = x, sum = x;
      for (let n = 1; n < 200; n++) {
        term *= (2 * x * x) / (2 * n + 1);
        sum += term;
        if (term < sum * 1e-17) break;
      }
      return 1 - (2 / Math.sqrt(Math.PI)) * Math.exp(-x * x) * sum;
    }
    // Lentz: erfc(x) = exp(-x^2)/sqrt(pi) / (x + (1/2)/(x + 1/(x + (3/2)/(x + ...))))
    const tiny = 1e-300;
    let f = x, c = x, d = 0;
    for (let n = 1; n < 500; n++) {
      const a = n / 2;
      d = x + a * d; d = Math.abs(d) < tiny ? tiny : d; d = 1 / d;
      c = x + a / c; c = Math.abs(c) < tiny ? tiny : c;
      const delta = c * d;
      f *= delta;
      if (Math.abs(delta - 1) < 1e-16) break;
    }
    return Math.exp(-x * x) / Math.sqrt(Math.PI) / f;
  }

  function betacf(a, b, x) {
    const tiny = 1e-300;
    const qab = a + b, qap = a + 1, qam = a - 1;
    let c = 1, d = 1 - (qab * x) / qap;
    d = 1 / (Math.abs(d) > tiny ? d : tiny);
    let h = d;
    for (let m = 1; m < 10000; m++) {
      const m2 = 2 * m;
      let aa = (m * (b - m) * x) / ((qam + m2) * (a + m2));
      d = 1 + aa * d; d = 1 / (Math.abs(d) > tiny ? d : tiny);
      c = 1 + aa / c; c = Math.abs(c) > tiny ? c : tiny;
      h *= d * c;
      aa = (-(a + m) * (qab + m) * x) / ((a + m2) * (qap + m2));
      d = 1 + aa * d; d = 1 / (Math.abs(d) > tiny ? d : tiny);
      c = 1 + aa / c; c = Math.abs(c) > tiny ? c : tiny;
      const delta = d * c;
      h *= delta;
      if (Math.abs(delta - 1) < 1e-15) break;
    }
    return h;
  }

  function lgammaRatioHalf(a) {
    if (a < 50) return lgamma(a + 0.5) - lgamma(a);
    return 0.5 * Math.log(a) - 1 / (8 * a) + 1 / (192 * a ** 3) - 1 / (640 * a ** 5);
  }

  function betaincHalf(a, x, logx, log1mx) {
    // I_x(a, 1/2)
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    const lbt = lgammaRatioHalf(a) - lgamma(0.5) + a * logx + 0.5 * log1mx;
    if (x < (a + 1) / (a + 2.5)) return (Math.exp(lbt) * betacf(a, 0.5, x)) / a;
    return 1 - (Math.exp(lbt) * betacf(0.5, a, 1 - x)) / 0.5;
  }

  // P(|T| > |t|) for Student's t on df (normal when df is null or infinite)
  function twoSidedP(stat, df) {
    if (stat === null || stat === undefined || Number.isNaN(stat)) return NaN;
    const t = Math.abs(stat);
    if (!Number.isFinite(t)) return 0;
    if (df === null || df === undefined || !Number.isFinite(df)) return erfc(t / Math.SQRT2);
    if (t === 0) return 1;
    if (df >= 1e4) {
      // Hill (1970), ACM Algorithm 395
      const a = df - 0.5, b = 48 * a * a;
      let y = a * Math.log1p((t * t) / df);
      y = (((((-0.4 * y - 3.3) * y - 24) * y - 85.5) / (0.8 * y * y + 100 + b) + y + 3) / b + 1) * Math.sqrt(y);
      return erfc(y / Math.SQRT2);
    }
    const r = (t * t) / df;
    return betaincHalf(df / 2, 1 / (1 + r), -Math.log1p(r), Math.log(r) - Math.log1p(r));
  }

  // the normal quantile: Acklam's approximation with one Halley step on erfc
  function qnorm(p) {
    const a = [-3.969683028665376e1, 2.209460984245205e2, -2.759285104469687e2, 1.38357751867269e2, -3.066479806614716e1, 2.506628277459239];
    const b = [-5.447609879822406e1, 1.615858368580409e2, -1.556989798598866e2, 6.680131188771972e1, -1.328068155288572e1];
    const c = [-7.784894002430293e-3, -3.223964580411365e-1, -2.400758277161838, -2.549732539343734, 4.374664141464968, 2.938163982698783];
    const d = [7.784695709041462e-3, 3.224671290700398e-1, 2.445134137142996, 3.754408661907416];
    const lo = 0.02425;
    let x;
    if (p < lo) {
      const q = Math.sqrt(-2 * Math.log(p));
      x = (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1);
    } else if (p <= 1 - lo) {
      const q = p - 0.5, r = q * q;
      x = ((((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q) / (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1);
    } else {
      const q = Math.sqrt(-2 * Math.log(1 - p));
      x = -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1);
    }
    const e = 0.5 * erfc(-x / Math.SQRT2) - p;
    const u = e * Math.sqrt(2 * Math.PI) * Math.exp((x * x) / 2);
    return x - u / (1 + (x * u) / 2);
  }

  function criticalValue(level, df) {
    const alpha = 1 - level;
    const z = qnorm(1 - alpha / 2);
    if (df === null || df === undefined || !Number.isFinite(df)) return z;
    let lo = z, hi = Math.max(2 * z, 1);
    while (twoSidedP(hi, df) > alpha) hi *= 2;
    for (let i = 0; i < 200; i++) {
      const mid = (lo + hi) / 2;
      if (twoSidedP(mid, df) > alpha) lo = mid; else hi = mid;
      if (hi - lo < 1e-14 * hi) break;
    }
    return (lo + hi) / 2;
  }

  // ------------------------------------------------------------ record views

  function num(v) {
    if (v && typeof v === "object" && !Array.isArray(v)) v = v.value;
    if (v === null || v === undefined || typeof v === "boolean") return NaN;
    if (typeof v === "number") return v;
    if (typeof v === "string") return v === "NaN" ? NaN : v === "Inf" ? Infinity : v === "-Inf" ? -Infinity : NaN;
    return NaN;
  }

  function metricValue(v) {
    if (v && typeof v === "object" && !Array.isArray(v)) return "value" in v ? v.value : undefined;
    if (v === "NaN" || v === "Inf" || v === "-Inf") return num(v);
    return v;
  }

  function vcovs(rec) {
    const v = (rec.structures || {}).vcov;
    if (v === undefined || v === null) return [];
    return Array.isArray(v) ? v : [v];
  }

  function clusterList(v) {
    const cl = v.cluster || [];
    return typeof cl === "string" ? [cl] : cl;
  }

  function vcovLabel(v) {
    const cl = clusterList(v);
    return cl.length ? "by: " + cl.join(" & ") : String(v.type || "?");
  }

  function pickVcov(rec, sel) {
    const vs = vcovs(rec);
    if (sel === null || sel === undefined || sel === "") return vs.find((v) => v.default === true) || null;
    if (typeof sel === "number") {
      if (sel < 0 || sel >= vs.length) throw new Error(`the record has ${vs.length} vcov`);
      return vs[sel];
    }
    const hits = vs.filter((v) => [v.type, vcovLabel(v), clusterList(v).join(" & ")].includes(sel));
    if (!hits.length) throw new Error(`no vcov '${sel}'; the record has: ` + vs.map((v) => `${v.type} (${vcovLabel(v)})`).join(", "));
    if (hits.length > 1) throw new Error(`vcov '${sel}' matches ${hits.length} matrices; pick one by position`);
    return hits[0];
  }

  const PARAM = ["estimate", "std_error", "statistic", "p_value", "conf_low", "conf_high"];

  function tidy(rec, opts) {
    opts = opts || {};
    const component = opts.component === undefined ? null : opts.component;
    const rows = [];
    for (const p of rec.parameters || []) {
      const comp = p.component === undefined ? null : p.component;
      if (component === null && comp !== null) continue;
      if (component !== null && component !== "all") {
        const want = Array.isArray(component) ? component : [component];
        if (!want.includes(comp)) continue;
      }
      if (p.dropped !== undefined && p.dropped !== null && !opts.dropped) continue;
      const row = { term: p.term };
      for (const k of ["response", "component", "dropped"]) if (p[k] !== undefined && p[k] !== null) row[k] = p[k];
      for (const k of PARAM) row[k] = num(p[k]);
      rows.push(row);
    }
    const sel = opts.vcov === undefined ? null : opts.vcov;
    const v = pickVcov(rec, sel);
    const recompute = sel !== null && sel !== "" && !(v || {}).default;
    let dft = num((v || {}).df_t);
    dft = Number.isNaN(dft) ? null : dft;
    if (recompute) {
      if (v.kind === "link") throw new Error(`this vcov is in attachment '${v.attachment}'`);
      const labels = v.labels || v.row_labels || [];
      const diag = new Map(labels.map((l, i) => [l, num(v.data[i][i])]));
      for (const r of rows) {
        const vv = diag.has(r.term) ? diag.get(r.term) : NaN;
        const se = vv >= 0 ? Math.sqrt(vv) : NaN;
        r.std_error = se;
        r.statistic = se ? r.estimate / se : NaN;
        r.p_value = twoSidedP(r.statistic, dft);
      }
    }
    const level = num((rec.metrics || {}).conf_level);
    const want = opts.confLevel !== undefined && opts.confLevel !== null ? opts.confLevel : Number.isNaN(level) ? 0.95 : level;
    if (recompute || Number.isNaN(level) || Math.abs(want - level) > 1e-12 || rows.every((r) => Number.isNaN(r.conf_low))) {
      const q = criticalValue(want, dft);
      for (const r of rows) {
        r.conf_low = r.estimate - q * r.std_error;
        r.conf_high = r.estimate + q * r.std_error;
      }
    }
    return rows;
  }

  function glance(rec, opts) {
    opts = opts || {};
    const which = opts.metrics || "table";
    let ms = {};
    for (const [k, v] of Object.entries(rec.metrics || {})) if (k !== "conf_level") ms[k] = v;
    if (which === "table") {
      if (!("rmse" in ms) && "rss" in ms && "nobs" in ms) {
        const n = num(ms.nobs);
        ms.rmse = n > 0 ? Math.sqrt(num(ms.rss) / n) : NaN;
      }
      const kept = {};
      for (const k of TABLE_METRICS) if (k in ms) kept[k] = ms[k];
      ms = kept;
    }
    const out = {};
    for (const [k, v] of Object.entries(ms)) {
      if (v && typeof v === "object" && !Array.isArray(v) && !("value" in v)) continue;
      out[k] = metricValue(v);
    }
    const v = pickVcov(rec, opts.vcov === undefined ? null : opts.vcov);
    if (v) out.vcov_type = vcovLabel(v);
    const fes = (rec.specification || {}).fixed_effects;
    if (fes && fes.length) out.fixed_effects = fes.slice();
    return out;
  }

  // ------------------------------------------------------------ canonical JSON and hashes

  // RFC 8785: ECMAScript number and string forms, keys sorted by UTF-16 code units
  function canonicalJSON(v) {
    if (v === null || typeof v !== "object") return JSON.stringify(v);
    if (Array.isArray(v)) return "[" + v.map(canonicalJSON).join(",") + "]";
    const keys = Object.keys(v).filter((k) => v[k] !== undefined).sort();
    return "{" + keys.map((k) => JSON.stringify(k) + ":" + canonicalJSON(v[k])).join(",") + "}";
  }

  async function sha256Hex(text) {
    const subtle = (typeof crypto !== "undefined" && crypto.subtle) || (typeof require === "function" ? require("crypto").webcrypto.subtle : null);
    if (!subtle) return null;
    const buf = await subtle.digest("SHA-256", new TextEncoder().encode(text));
    return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
  }

  const recordSha256 = (rec) => sha256Hex(canonicalJSON(rec));

  // ------------------------------------------------------------ table specs

  function findTest(rec, key) {
    const tests = rec.tests || [];
    return tests.find((t) => t.label === key) || tests.find((t) => t.name === key) || null;
  }

  function fixed(x, digits) {
    if (x === null || x === undefined || Number.isNaN(x)) return "";
    if (!Number.isFinite(x)) return x > 0 ? "Inf" : "-Inf";
    let s = x.toFixed(digits);
    if (s.startsWith("-") && Number(s) === 0) s = s.slice(1);
    return s;
  }

  function statValue(x, digits, thousands) {
    if (x === null || x === undefined) return "";
    if (typeof x === "boolean") return x ? "Yes" : "No";
    if (typeof x === "string") return x;
    if (Number.isNaN(x)) return "";
    if (Number.isFinite(x) && Number.isInteger(x) && Math.abs(x) < 1e15) {
      const s = Math.abs(x).toString().replace(/\B(?=(\d{3})+(?!\d))/g, thousands);
      return (x < 0 ? "-" : "") + s;
    }
    return fixed(x, digits);
  }

  function pValue(p, digits, style) {
    if (p === null || p === undefined || Number.isNaN(p)) return "";
    if (style === "less_than" && p < 10 ** -digits) return "<" + fixed(10 ** -digits, digits);
    return fixed(p, digits);
  }

  function fill(template, row, digits, pDigits, pStyle, missing) {
    const vals = {};
    for (const m of template.matchAll(PLACEHOLDER)) {
      const x = row[m[1]];
      if (x === null || x === undefined || Number.isNaN(x)) return missing;
      vals[m[1]] = m[1] === "p_value" ? pValue(x, pDigits, pStyle) : fixed(x, digits);
    }
    return template.replace(PLACEHOLDER, (_, n) => vals[n]);
  }

  function starsFor(p, thresholds, symbols) {
    if (p === null || p === undefined || Number.isNaN(p)) return "";
    let out = "";
    thresholds.forEach((t, i) => { if (p < t) out = symbols[i]; });
    return out;
  }

  function issue(level, path, message) { return { level, path, message }; }

  // records: Map of meta.id -> {record, member, source}; also keyed "source\u0000id"
  function indexRecords(items) {
    const idx = new Map();
    for (const it of items) {
      const id = ((it.record || {}).meta || {}).id;
      if (!id) continue;
      if (it.source && !idx.has(it.source + "\u0000" + id)) idx.set(it.source + "\u0000" + id, it);
      if (!idx.has(id)) idx.set(id, it);
    }
    return idx;
  }

  function lookup(idx, col) {
    return (col.source && idx.get(col.source + "\u0000" + col.record)) || idx.get(col.record) || null;
  }

  function validateTable(spec, idx) {
    const out = [];
    if (spec.schema !== TABLE_SCHEMA) out.push(issue("error", "schema", `expected '${TABLE_SCHEMA}'`));
    const cols = Array.isArray(spec.columns) ? spec.columns : [];
    if (!cols.length) out.push(issue("error", "columns", "at least one column"));
    const ids = (spec.sources || []).map((s) => s.id);
    for (const d of new Set(ids.filter((x, i) => ids.indexOf(x) !== i))) out.push(issue("error", "sources", `duplicate source id '${d}'`));
    cols.forEach((c, i) => {
      if (!c || !c.record) out.push(issue("error", `columns[${i}]`, "a column needs `record` (a meta.id)"));
      else if (c.source !== undefined && c.source !== null && !ids.includes(c.source)) out.push(issue("error", `columns[${i}].source`, `no source '${c.source}'`));
    });
    for (const key of ["keep", "drop"]) {
      (spec[key] || []).forEach((p, j) => {
        try { new RegExp(p); } catch (e) { out.push(issue("error", `${key}[${j}]`, `pattern doesn't compile: ${e.message}`)); }
      });
    }
    out.push(...lineIssues(spec));
    if ("estimate" in spec && typeof spec.estimate !== "boolean") out.push(issue("error", "estimate", "true or false"));
    else if (spec.estimate === false && !uncertaintyLines(spec).length) out.push(issue("error", "estimate", "with no estimate and no lines, terms have nothing to show"));
    if (spec.head !== undefined && spec.head !== null) {
      if (!Array.isArray(spec.head)) out.push(issue("error", "head", "a list of 'number', 'response', 'label'"));
      else spec.head.forEach((k, j) => {
        if (!HEAD_KINDS.includes(k)) out.push(issue("error", `head[${j}]`, `'${k}' is not one of 'number', 'response', 'label'`));
        else if (spec.head.indexOf(k) !== j) out.push(issue("error", `head[${j}]`, `'${k}' appears twice`));
      });
    }
    (spec.stats || []).forEach((s, j) => {
      if (s.values && s.values.length !== cols.length) out.push(issue("error", `stats[${j}].values`, `${s.values.length} values for ${cols.length} columns`));
    });
    if (!idx) return out;
    const recs = [];
    cols.forEach((c, i) => {
      if (!c || !c.record) return;
      const f = lookup(idx, c);
      if (!f) { out.push(issue("error", `columns[${i}]`, `record ${c.record} not found`)); return; }
      recs.push(f.record);
      if (c.vcov !== undefined && c.vcov !== null) {
        try { pickVcov(f.record, c.vcov); } catch (e) { out.push(issue("warning", `columns[${i}].vcov`, e.message)); }
      }
    });
    const terms = new Set(recs.flatMap((r) => (r.parameters || []).map((p) => p.term)));
    (spec.rows || []).forEach((row, j) => {
      const names = row.terms || [row.term];
      if (!names.some((n) => terms.has(n))) out.push(issue("warning", `rows[${j}]`, `no column has ${names.join(", ")}`));
    });
    (spec.stats || []).forEach((s, j) => {
      if ("metric" in s) {
        const ok = recs.some((r) => s.metric in (r.metrics || {}) || (s.metric === "rmse" && "rss" in (r.metrics || {})));
        if (!ok) out.push(issue("warning", `stats[${j}]`, `no record has metric '${s.metric}'`));
      } else if ("fixed_effect" in s) {
        if (!recs.some((r) => ((r.specification || {}).fixed_effects || []).includes(s.fixed_effect))) out.push(issue("warning", `stats[${j}]`, `no record has fixed effect '${s.fixed_effect}'`));
      } else if ("test" in s) {
        if (!recs.some((r) => findTest(r, s.test))) out.push(issue("warning", `stats[${j}]`, `no record has test '${s.test}'`));
      }
    });
    return out;
  }

  // Check columns' sha256 pins (async: hashing)
  async function checkPins(spec, idx) {
    const out = [];
    for (const [i, c] of (spec.columns || []).entries()) {
      if (!c.sha256) continue;
      const f = lookup(idx, c);
      if (!f) continue;
      const h = await recordSha256(f.record);
      if (h && h !== c.sha256) out.push(issue("warning", `columns[${i}].sha256`, "the record has changed since the table was made"));
    }
    return out;
  }

  const HEAD_KINDS = ["number", "response", "label"];
  const DEFAULT_HEAD = ["number", "response"];

  // A column's dependent variable: its `response`, else the one response its rows share (a
  // first stage's endogenous variable), else the record's `meta.responses`; then relabelled.
  function columnResponse(c, record, rows, labels) {
    let name = c.response;
    if (!name) {
      const named = [...new Set(rows.filter((r) => r.response).map((r) => r.response))].sort();
      if (named.length === 1) name = named[0];
    }
    if (!name) name = ((record.meta || {}).responses || []).map(String).join(", ");
    return String(Object.prototype.hasOwnProperty.call(labels, name) ? labels[name] : name);
  }

  // The heading rows, top to bottom (spec `head`); a response or label row that would be
  // empty in every column is left out.
  function headRows(spec, cols) {
    const out = [];
    for (const kind of spec.head || DEFAULT_HEAD) {
      const cells = cols.map((c) => c[kind]);
      if (kind !== "number" && !cells.some(Boolean)) continue;
      out.push({ kind, cells });
    }
    return out;
  }

  function sparkMark(r) {
    const v = [r.conf_low, r.estimate, r.conf_high];
    if (v.some((x) => typeof x !== "number" || !Number.isFinite(x))) return null;
    return { low: v[0], estimate: v[1], high: v[2] };
  }

  // each mark's axis [lo, hi], holding 0: shared down a column, along a row or across the
  // table (the line's scale), among sparkline lines with the same scale
  function sparkDomains(rows) {
    const groups = new Map();
    rows.forEach((r, i) => {
      const sp = r.sparkline;
      if (!sp) return;
      sp.marks.forEach((m, j) => {
        if (!m) return;
        const key = sp.scale + "/" + { column: j, row: i, table: 0 }[sp.scale];
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key).push(m);
      });
    });
    for (const ms of groups.values()) {
      let lo = Math.min(0, ...ms.map((m) => m.low));
      let hi = Math.max(0, ...ms.map((m) => m.high));
      if (lo === hi) { lo = -1; hi = 1; }
      for (const m of ms) m.domain = [lo, hi];
    }
  }

  function sparkDark(color) {
    return "#" + [1, 3, 5].map((k) => Math.floor(parseInt(color.slice(k, k + 2), 16) * 13 / 20).toString(16).padStart(2, "0")).join("");
  }

  const SPARK_W = 80, SPARK_H = 16;
  const HALO = 'style="stroke:var(--bg,#ffffff)"';

  // where 0, the low end, the estimate and the high end fall across the 80-pixel width, in
  // tenths of a pixel, rounded half up with integers so every renderer draws the same
  // across the drawing's width: 80 pixels unless a Word table's width sets it
  function sparkXs(m, width) {
    const w = width === undefined ? SPARK_W : width;
    const [lo, hi] = m.domain;
    const pad = 4;
    const x = (v) => Math.floor((pad + (v - lo) / (hi - lo) * (w - 2 * pad)) * 10 + 0.5);
    return [x(0), x(m.low), x(m.estimate), x(m.high)];
  }
  const tenths = (n) => `${Math.floor(n / 10)}.${n % 10}`;
  // (a + 2b) / 3 tenths in hundredths, rounded half up: a quadratic's control point as a cubic's
  const third = (a, b) => { const n = Math.floor((20 * (a + 2 * b) + 3) / 6); return `${Math.floor(n / 100)}.${String(n % 100).padStart(2, "0")}`; };
  const tikzRGB = (c) => { const [r, g, b] = [1, 3, 5].map((k) => parseInt(c.slice(k, k + 2), 16)); return `{rgb,255:red,${r};green,${g};blue,${b}}`; };
  const TIKZ_NOTE = "% Sparklines are TikZ pictures (\\usepackage{tikz}), drawn for 12pt rows (10pt type, \\arraystretch 1) so a column of them joins";

  // the SVG's marks in TikZ (1 px = 0.75 pt), y up from the baseline: the 0 rule over a
  // 12 pt row (-4.8 to 11.2), the interval at 3.2
  function sparkTikz(m, color) {
    if (!m) return "";
    const [n0, nl, ne, nh] = sparkXs(m);
    const [x0, xl, xe, xh] = [n0, nl, ne, nh].map(tenths);
    const a = third(nl, ne), b = third(nh, ne), c = tikzRGB(color), d = tikzRGB(sparkDark(color));
    return "\\tikz[x=.75pt,y=.75pt,baseline=0pt]{\\useasboundingbox (0,-4.8) rectangle (80,11.2);" +
      `\\draw[line width=.75pt,color=${tikzRGB("#555555")}] (${x0},-4.8) -- (${x0},11.2);` +
      `\\fill[color=${c},fill opacity=.22] (${xl},3.2) .. controls (${a},7.2) and (${b},7.2) .. (${xh},3.2)` +
      ` .. controls (${b},-0.8) and (${a},-0.8) .. (${xl},3.2) -- cycle;` +
      `\\draw[line width=.975pt,line cap=round,color=${c}] (${xl},3.2) -- (${xh},3.2);` +
      `\\filldraw[fill=${c},draw=white,line width=.675pt] (${xl},3.2) circle[radius=1.425pt];` +
      `\\filldraw[fill=${c},draw=white,line width=.675pt] (${xh},3.2) circle[radius=1.425pt];` +
      `\\filldraw[fill=${d},draw=white,line width=.825pt] (${xe},3.2) circle[radius=2.175pt];` +
      "}";
  }

  const sparkY = (n) => (n < 0 ? "-" : "") + tenths(Math.abs(n));
  // the band, the line and the dots of one interval, centred at yt tenths of a pixel
  function sparkMarks(xl, xe, xh, yt, color) {
    const y = sparkY(yt), top = sparkY(yt - 60), bottom = sparkY(yt + 60);
    return `<path d="M${xl} ${y}Q${xe} ${top} ${xh} ${y}Q${xe} ${bottom} ${xl} ${y}Z" fill="${color}" fill-opacity="0.22"/>` +
      `<line x1="${xl}" y1="${y}" x2="${xh}" y2="${y}" stroke="${color}" stroke-width="1.3" stroke-linecap="round"/>` +
      `<circle cx="${xl}" cy="${y}" r="1.9" fill="${color}" stroke-width="0.9" ${HALO}/>` +
      `<circle cx="${xh}" cy="${y}" r="1.9" fill="${color}" stroke-width="0.9" ${HALO}/>` +
      `<circle cx="${xe}" cy="${y}" r="2.9" fill="${sparkDark(color)}" stroke-width="1.1" ${HALO}/>`;
  }

  // height: the image's (pixels); the marks sit halfway down, or mid tenths of a pixel down
  function sparkSVG(m, color, label, height, mid, style, width) {
    if (!m) return "";
    const H = height === undefined ? SPARK_H : height;
    const Wd = width === undefined ? SPARK_W : width;
    const [x0, xl, xe, xh] = sparkXs(m, Wd).map(tenths);
    return `<svg xmlns="http://www.w3.org/2000/svg" width="${Wd}" height="${H}" viewBox="0 0 ${Wd} ${H}" role="img"` +
      (label ? ` aria-label="${escHTML(label)}"` : "") + (style ? ` style="${style}"` : "") + ">" +
      `<line x1="${x0}" y1="0" x2="${x0}" y2="${H}" stroke="#555555" stroke-width="1"/>` +
      sparkMarks(xl, xe, xh, mid === undefined || mid === null ? H * 5 : mid, color) + "</svg>";
  }

  // only the 0 rule, for a term's other rows: an image height pixels tall, or (none) an SVG
  // filling its position:relative cell
  function sparkRule(m, height, width) {
    if (!m) return "";
    const Wd = width === undefined ? SPARK_W : width;
    const x0 = tenths(sparkXs(m, Wd)[0]);
    if (height === undefined || height === null) {
      return `<svg xmlns="http://www.w3.org/2000/svg" width="${SPARK_W}" height="100%" aria-hidden="true" style="position:absolute;top:0;left:calc(50% - 40px)">` +
        `<line x1="${x0}" y1="0" x2="${x0}" y2="100%" stroke="#555555" stroke-width="1"/></svg>`;
    }
    return `<svg xmlns="http://www.w3.org/2000/svg" width="${Wd}" height="${height}" viewBox="0 0 ${Wd} ${height}">` +
      `<line x1="${x0}" y1="0" x2="${x0}" y2="${height}" stroke="#555555" stroke-width="1"/></svg>`;
  }

  // a sparkline beside the estimates: as tall as its cell (the term's rows), the 0 rule its
  // full height and the marks halfway down, so a column of them joins into one axis
  function sparkSVGTall(m, color, label) {
    if (!m) return "";
    const [x0, xl, xe, xh] = sparkXs(m).map(tenths);
    return `<svg xmlns="http://www.w3.org/2000/svg" width="${SPARK_W}" height="100%" role="img"` +
      (label ? ` aria-label="${escHTML(label)}"` : "") +
      ' style="position:absolute;top:0;left:calc(50% - 40px);overflow:visible">' +
      `<line x1="${x0}" y1="0" x2="${x0}" y2="100%" stroke="#555555" stroke-width="1"/>` +
      '<svg y="50%" overflow="visible">' + sparkMarks(xl, xe, xh, 0, color) + "</svg></svg>";
  }

  const b64 = (s) => (typeof btoa === "function" ? btoa(s) : Buffer.from(s, "ascii").toString("base64"));

  function sparkImg(m, color, label, height, mid, ruleOnly, width) {
    if (!m) return "";
    const H = height === undefined ? SPARK_H : height;
    const Wd = width === undefined ? SPARK_W : width;
    const svg = ruleOnly ? sparkRule(m, H, Wd) : sparkSVG(m, color, "", H, mid, undefined, Wd);
    return `<img width="${Wd}" height="${H}" style="display:block;margin:0 auto;vertical-align:middle" alt="${ruleOnly ? "" : escHTML(label)}" src="data:image/svg+xml;base64,${b64(svg)}">`;
  }

  function htmlCell(r, j) {
    const sp = r.sparkline;
    if (!sp) return `<td>${escHTML(r.cells[j])}</td>`;
    return `<td class="spark">${sparkSVG(sp.marks[j], sp.color, r.cells[j])}</td>`;
  }

  function buildTable(spec, idx) {
    const issues = validateTable(spec, idx);
    const errors = issues.filter((i) => i.level === "error");
    if (errors.length) throw new Error(errors.map((i) => `${i.path}: ${i.message}`).join("; "));
    const fmt = spec.format || {};
    const digits = fmt.digits !== undefined ? fmt.digits : 3;
    const thousands = fmt.thousands !== undefined ? fmt.thousands : ",";
    const missing = fmt.missing !== undefined ? fmt.missing : "";
    const stars = spec.stars || [];
    const symbols = fmt.star_symbols || stars.map((_, i) => "*".repeat(i + 1));
    const lines = uncertaintyLines(spec);
    const showEst = spec.estimate !== false;
    const pDigits = fmt.p_digits !== undefined ? fmt.p_digits : digits;
    const pStyle = fmt.p_style || "fixed";

    const cols = spec.columns.map((c, i) => {
      const f = lookup(idx, c);
      let rows = tidy(f.record, { vcov: c.vcov, component: c.component });
      if (c.response) rows = rows.filter((r) => r.response === c.response);
      const label = c.header !== undefined ? c.header : (f.member || {}).label || (f.record.meta || {}).title || "";
      return {
        spec: c, found: f, tidy: new Map(rows.map((r) => [r.term, r])), order: rows.map((r) => r.term),
        number: `(${i + 1})`, response: columnResponse(c, f.record, rows, spec.response_labels || {}), label,
      };
    });

    const listed = [];
    const taken = new Set();
    for (const row of spec.rows || []) {
      const names = row.terms || [row.term];
      listed.push([row.label || names[0], names]);
      names.forEach((n) => taken.add(n));
    }
    if (spec.keep_unlisted !== false) {
      const keep = (spec.keep || []).map((p) => new RegExp(p));
      const drop = (spec.drop || []).map((p) => new RegExp(p));
      const seen = [];
      for (const c of cols) {
        for (const t of c.order) {
          if (taken.has(t) || seen.includes(t)) continue;
          if (keep.length && !keep.some((k) => k.test(t))) continue;
          if (drop.some((d) => d.test(t))) continue;
          seen.push(t);
        }
      }
      for (const t of seen) listed.push([t, [t]]);
    }

    const rows = [];
    for (const [label, names] of listed) {
      const est = [];
      const below = lines.map(() => []);
      const marks = lines.map(() => []);
      for (const c of cols) {
        const n = names.find((x) => c.tidy.has(x));
        const r = n === undefined ? null : c.tidy.get(n);
        if (!r) { est.push(missing); below.forEach((b) => b.push(missing)); marks.forEach((m) => m.push(null)); continue; }
        est.push(fixed(r.estimate, digits) + starsFor(r.p_value, stars, symbols));
        lines.forEach((t, k) => {
          if (isObj(t)) { below[k].push(fill(SPARK_TEXT, r, digits, pDigits, pStyle, missing)); marks[k].push(sparkMark(r)); }
          else below[k].push(fill(t, r, digits, pDigits, pStyle, missing));
        });
      }
      const block = [];
      if (showEst) block.push({ label, cells: est, kind: "estimate" });
      lines.forEach((t, k) => {
        const row = { label: "", cells: below[k], kind: "uncertainty" };
        if (isObj(t)) row.sparkline = Object.assign({}, t.sparkline, { marks: marks[k] });
        block.push(row);
      });
      // without the estimate, a term's first line opens its block and carries its label
      Object.assign(block[0], { label, kind: "estimate" });
      rows.push(...block);
    }
    sparkDomains(rows);

    for (const s of spec.stats || []) {
      const d = s.digits !== undefined ? s.digits : digits;
      let cells = [], label;
      if ("values" in s) {
        cells = s.values.map(String);
        label = s.label;
      } else if ("metric" in s) {
        const m = s.metric;
        label = s.label || STAT_LABELS[m] || m;
        for (const c of cols) {
          const g = glance(c.found.record, { vcov: c.spec.vcov, metrics: "all" });
          if (m === "rmse" && !("rmse" in g)) g.rmse = glance(c.found.record, { metrics: "table" }).rmse;
          const v = g[m];
          cells.push(v === undefined || v === null ? missing : statValue(v, d, thousands));
        }
      } else if ("vcov" in s) {
        label = s.label || (s.vcov === "type" ? "Std. errors" : "Clusters");
        for (const c of cols) {
          const v = pickVcov(c.found.record, c.spec.vcov);
          if (!v) cells.push(missing);
          else if (s.vcov === "type") cells.push(vcovLabel(v));
          else {
            const n = v.n_clusters && typeof v.n_clusters === "object" ? Object.values(v.n_clusters) : [];
            cells.push(n.map((x) => statValue(x, 0, thousands)).join(" / ") || missing);
          }
        }
      } else if ("fixed_effect" in s) {
        label = s.label || `FE: ${s.fixed_effect}`;
        const yes = fmt.fe_yes !== undefined ? fmt.fe_yes : "Y", no = fmt.fe_no !== undefined ? fmt.fe_no : "N";
        for (const c of cols) cells.push(((c.found.record.specification || {}).fixed_effects || []).includes(s.fixed_effect) ? yes : no);
      } else if ("test" in s) {
        label = s.label || s.test;
        const which = s.value || "statistic";
        for (const c of cols) {
          const t = findTest(c.found.record, s.test);
          const v = t ? num(t[which]) : NaN;
          if (Number.isNaN(v)) cells.push(missing);
          else if (which === "p_value") cells.push(pValue(v, s.digits !== undefined ? s.digits : pDigits, pStyle));
          else cells.push(fixed(v, d));
        }
      }
      rows.push({ label, cells, kind: "stat" });
    }

    const notes = (spec.notes || []).slice();
    if (stars.length && showEst) notes.push(stars.map((t, i) => `${symbols[i]} p < ${t}`).join(", "));
    const note = uncertaintyNote(spec, lines);
    if (note) notes.push(note);
    return {
      title: spec.title === undefined ? null : spec.title,
      head: headRows(spec, cols),
      header: cols.map((c) => c.number),
      column_records: cols.map((c) => c.found.record.meta.id),
      rows,
      notes,
      warnings: issues.filter((i) => i.level === "warning").map((i) => `warning: ${i.path}: ${i.message}`),
    };
  }

  // ------------------------------------------------------------ rendering

  const LATEX = { "&": "\\&", "%": "\\%", $: "\\$", "#": "\\#", _: "\\_", "{": "\\{", "}": "\\}", "~": "\\textasciitilde{}", "^": "\\textasciicircum{}", "\\": "\\textbackslash{}" };
  const tex = (s) => Array.from(String(s)).map((ch) => LATEX[ch] || ch).join("");
  const escHTML = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#x27;");

  function renderMarkdown(t) {
    const esc = (s) => String(s).replace(/\\/g, "\\\\").replace(/\|/g, "\\|").replace(/\*/g, "\\*");
    const lines = [];
    if (t.title) lines.push(`**${esc(t.title)}**`, "");
    const n = t.header.length;
    const head = t.head.length ? t.head.map((h) => h.cells) : [Array(n).fill("")];
    // Markdown has one heading row: the first; the others open the body
    lines.push("| | " + head[0].map(esc).join(" | ") + " |");
    lines.push("|---|" + "---:|".repeat(n));
    for (const cells of head.slice(1)) lines.push("| | " + cells.map(esc).join(" | ") + " |");
    for (const r of t.rows) lines.push(`| ${esc(r.label)} | ` + r.cells.map(esc).join(" | ") + " |");
    if (t.notes.length) lines.push("", ...t.notes.map((n) => `${esc(n)}  `));
    return lines.join("\n").replace(/\s+$/, "") + "\n";
  }

  function renderLatex(t, opts) {
    const e = opts && opts.escape === false ? (s) => String(s) : tex;
    const n = t.header.length;
    const lines = t.rows.some((r) => r.sparkline) ? [TIKZ_NOTE] : [];
    lines.push("\\begin{table}[htbp]", "\\centering");
    if (t.title) lines.push(`\\caption{${e(t.title)}}`);
    lines.push(`\\begin{tabular}{l${"c".repeat(n)}}`, "\\toprule");
    for (const h of t.head) lines.push(" & " + h.cells.map(e).join(" & ") + " \\\\");
    lines.push("\\midrule");
    let prev = null;
    for (const r of t.rows) {
      if (r.kind === "stat" && prev !== "stat") lines.push("\\midrule");
      const cells = r.sparkline ? r.sparkline.marks.map((m) => sparkTikz(m, r.sparkline.color)) : r.cells.map(e);
      lines.push(`${e(r.label)} & ` + cells.join(" & ") + " \\\\");
      prev = r.kind;
    }
    lines.push("\\bottomrule", "\\end{tabular}");
    if (t.notes.length) lines.push("\\par\\smallskip{\\footnotesize " + t.notes.map(e).join(" ") + "}");
    lines.push("\\end{table}");
    return lines.join("\n") + "\n";
  }

  // a table with a sparkline beside the estimates (HTML, Word): each data column gets a
  // second column, and each term's drawing is one cell there spanning its other rows
  function besidePlan(t) {
    const rows = t.rows;
    const isSide = (r) => !!(r.sparkline && r.sparkline.place === "beside");
    if (!rows.some(isSide)) return null;
    const align = rows.find(isSide).sparkline.align || "estimate";
    const plan = { align, start: new Map(), skip: new Set(), inside: new Map(), label: new Map() };
    let i = 0;
    while (i < rows.length) {
      if (rows[i].kind === "stat") { i++; continue; }
      let j = i + 1;
      while (j < rows.length && rows[j].kind === "uncertainty") j++;
      const side = [], rest = [];
      for (let k = i; k < j; k++) (isSide(rows[k]) ? side : rest).push(k);
      if (side.length && rest.length) {
        plan.start.set(rest[0], [side[0], rest.length, j]);
        plan.skip.add(side[0]);
        rest.slice(1).forEach((k) => plan.inside.set(k, side[0]));
        if (side[0] === i) plan.label.set(rest[0], rows[i].label);
      }
      i = j;
    }
    return plan;
  }
  const rowKind = (t, plan, i) => (plan && plan.label.has(i) ? "estimate" : t.rows[i].kind);
  const SIDE_TD = 'style="position:relative;padding:0;width:80px;min-width:80px"';
  // level with the estimate: the cells keep the rows' vertical padding, so the marks sit on
  // the numbers' line, and the 0 rule fills the whole cell
  const SIDE_TD_ROW = 'style="position:relative;padding-left:0;padding-right:0;width:80px;min-width:80px"';

  function renderHTML(t) {
    const h = escHTML;
    const plan = besidePlan(t);
    const span = plan ? ' colspan="2"' : "";
    const out = ['<table class="estrec-table">'];
    if (t.title) out.push(`<caption>${h(t.title)}</caption>`);
    out.push("<thead>" + t.head.map((r) => `<tr class="head-${r.kind}"><th></th>` + r.cells.map((x) => `<th${span}>${h(x)}</th>`).join("") + "</tr>").join("") + "</thead>");
    out.push("<tbody>");
    let prev = null;
    const rows = t.rows;
    rows.forEach((r, i) => {
      if (plan && plan.skip.has(i)) return;
      const kind = rowKind(t, plan, i);
      const cls = kind + (kind === "stat" && prev !== "stat" ? " first-stat" : "") + (r.sparkline ? " spark-row" : "");
      const label = plan && plan.label.has(i) ? plan.label.get(i) : r.label;
      let cells;
      if (plan && plan.align === "estimate" && (plan.start.has(i) || plan.inside.has(i))) {
        const k = plan.start.has(i) ? plan.start.get(i)[0] : plan.inside.get(i);
        const sp = rows[k].sparkline;
        cells = r.cells.map((_, j) => htmlCell(r, j) + `<td class="spark-side" ${SIDE_TD_ROW}>` + sparkRule(sp.marks[j]) +
          (plan.start.has(i) ? sparkSVG(sp.marks[j], sp.color, rows[k].cells[j], undefined, null, "display:block;margin:0 auto;position:relative") : "") + "</td>").join("");
      } else if (plan && plan.start.has(i)) {
        const [k, n, end] = plan.start.get(i);
        const sp = rows[k].sparkline;
        const side = "spark-side" + (end === rows.length ? " to-end" : "");
        cells = r.cells.map((_, j) => htmlCell(r, j) + `<td class="${side}" rowspan="${n}" ${SIDE_TD}>` + sparkSVGTall(sp.marks[j], sp.color, rows[k].cells[j]) + "</td>").join("");
      } else if (plan && !plan.inside.has(i)) {
        cells = r.cells.map((_, j) => htmlCell(r, j).replace("<td", '<td colspan="2"')).join("");
      } else cells = r.cells.map((_, j) => htmlCell(r, j)).join("");
      out.push(`<tr class="${cls}"><th>${h(label)}</th>` + cells + "</tr>");
      prev = kind;
    });
    out.push("</tbody>");
    if (t.notes.length) out.push(`<tfoot><tr><td colspan="${t.header.length * (plan ? 2 : 1) + 1}">` + t.notes.map(h).join("<br>") + "</td></tr></tfoot>");
    out.push("</table>");
    return out.join("\n") + "\n";
  }

  function renderCSV(t) {
    const q = (s) => (/[",\n\r]/.test(s) ? `"${String(s).replace(/"/g, '""')}"` : String(s));
    const lines = t.head.map((h) => ["", ...h.cells].map(q).join(","));
    for (const r of t.rows) lines.push([r.label, ...r.cells].map(q).join(","));
    return lines.join("\n") + "\n";
  }

  function renderText(t) {
    const head = t.head.map((h) => ["", ...h.cells]);
    const body = t.rows.map((r) => [r.label, ...r.cells]);
    const rows = [...head, ...body, Array(t.header.length + 1).fill("")];
    const widths = rows[0].map((_, i) => Math.max(...rows.map((r) => r[i].length)));
    const line = (r) => r.map((c, i) => (i === 0 ? c.padEnd(widths[0]) : c.padStart(widths[i]))).join("  ").replace(/\s+$/, "");
    const rule = widths.map((w) => "-".repeat(w)).join("  ");
    const out = [];
    if (t.title) out.push(t.title);
    out.push(...head.map(line), rule);
    let prev = null;
    t.rows.forEach((src, i) => {
      if (src.kind === "stat" && prev !== "stat") out.push(rule);
      out.push(line(body[i]));
      prev = src.kind;
    });
    out.push(rule, ...t.notes);
    return out.join("\n") + "\n";
  }

  // Word: inline styles only (Word drops classes and style sheets when pasting), borders as a
  // journal table's three rules, numbers centred, no font family (the document's is kept).
  const WORD_RULE = "solid windowtext";
  const WORD_CELL = "padding:0 5.4pt;border:none;white-space:nowrap";

  function wordCell(text, { left, top = "", bottom = "", padTop = false, raw = null, attrs = "", styleExtra = "" }) {
    let style = WORD_CELL + (left ? ";text-align:left" : ";text-align:center");
    if (top) style += `;border-top:${top} ${WORD_RULE}`;
    if (bottom) style += `;border-bottom:${bottom} ${WORD_RULE}`;
    if (padTop) style += ";padding-top:3pt";
    return `<td${attrs} style="${style}${styleExtra}">${raw === null ? escHTML(text) : raw}</td>`;
  }

  // A whole HTML document that Word, Google Docs, LibreOffice and Excel paste or open as a
  // formatted table (the viewer's Copy for Word puts it on the clipboard). With a sparkline
  // beside the estimates, a term's rows are exactly 12 pt high (15 pt with the space above a
  // term) and its drawing is an image of their height, so a column of them joins.
  // Column widths for a Word table `width` inches wide, in tenths of a point: the label column
  // as wide as its longest label (about 5 pt a character, plus padding), between 36 pt and 40%
  // of the table; the data columns share the rest. Beside the estimates, a data column splits
  // into the numbers (the longest, at least 20 pt) and the drawing (the rest, at least 24 pt).
  function wordWidths(t, plan, width) {
    const total = Math.floor(width * 720 + 0.5);
    const n = t.header.length;
    const rows = t.rows;
    const lab = Math.max(0, ...rows.map((r) => r.label.length));
    const label = Math.min(Math.max(50 * lab + 108, 360), Math.floor((total * 2) / 5));
    const col = Math.floor((total - label) / n);
    const out = { total, label: total - col * n, col, below_px: Math.max(Math.floor(((col - 108) * 4) / 30), 1) };
    if (plan) {
      const block = [...plan.start.keys(), ...plan.inside.keys()].map((i) => rows[i]);
      const numc = Math.max(0, ...block.flatMap((r) => r.cells.map((c) => c.length)));
      const num = col >= 440 ? Math.min(Math.max(55 * numc + 108, 200), col - 240) : Math.floor(col / 2);
      Object.assign(out, { num, side: col - num, side_px: Math.max(Math.floor(((col - num) * 4) / 30), 1) });
    }
    return out;
  }
  const ptOf = (n) => `${Math.floor(n / 10)}.${n % 10}pt`;

  function renderWord(t, opts) {
    const h = escHTML;
    const plan = besidePlan(t);
    const span = plan ? ' colspan="2"' : "";
    const width = opts && opts.width;
    const W = width ? wordWidths(t, plan, width) : null;
    const wd = (n) => (W ? `;width:${ptOf(n)}` : "");
    const spw = W ? W.below_px : SPARK_W;
    const sidew = W && plan ? W.side_px : SPARK_W;
    const out = ["<!doctype html>", '<html><head><meta charset="utf-8">', `<title>${h(t.title || "Estimation table")}</title></head><body>`];
    if (t.title) out.push(`<p style="margin:0 0 6pt 0"><b>${h(t.title)}</b></p>`);
    const fixed = W ? `;width:${ptOf(W.total)};table-layout:fixed` : "";
    out.push(`<table style="border-collapse:collapse;border:none;font-size:10pt${fixed}">`);
    const nh = t.head.length;
    t.head.forEach((hr, k) => {
      const top = k === 0 ? "1.5pt" : "";
      const bottom = k === nh - 1 ? ".75pt" : "";
      out.push("<tr>" + ["", ...hr.cells].map((x, i) => wordCell(x, { left: i === 0, top, bottom, attrs: i ? span : "", styleExtra: W ? wd(i ? W.col : W.label) : "" })).join("") + "</tr>");
    });
    const rows = t.rows;
    let prev = null;
    const last = rows.length - 1;
    const shown = rows.map((_, i) => i).filter((i) => !(plan && plan.skip.has(i)));
    const first = shown.length ? shown[0] : 0;
    // the space above a term; sparkline rows stay unpadded so they join
    const pads = (i) => rowKind(t, plan, i) === "estimate" && i > first && !rows[i].sparkline;
    for (const i of shown) {
      const r = rows[i];
      const kind = rowKind(t, plan, i);
      let top = kind === "stat" && prev !== "stat" ? ".75pt" : "";
      if (i === first && !nh) top = "1.5pt";
      const bottom = i === last ? "1.5pt" : "";
      const sp = r.sparkline;
      const padTop = pads(i);
      const label = plan && plan.label.has(i) ? plan.label.get(i) : r.label;
      const exact = plan && (plan.start.has(i) || plan.inside.has(i));
      const tr = exact ? `<tr style="height:${padTop ? 15 : 12}pt;mso-height-rule:exactly">` : "<tr>";
      const cells = [];
      [label, ...r.cells].forEach((x, c) => {
        const raw = sp && c ? sparkImg(sp.marks[c - 1], sp.color, x, undefined, undefined, false, spw) : null;
        const many = plan && c && !plan.start.has(i) && !plan.inside.has(i);
        const cw = W ? wd(c === 0 ? W.label : plan && !many ? W.num : W.col) : "";
        cells.push(wordCell(x, { left: c === 0, top, bottom, padTop, raw, attrs: many ? ' colspan="2"' : "", styleExtra: cw }));
        if (plan && c && plan.align === "estimate" && (plan.start.has(i) || plan.inside.has(i))) {
          const k = plan.start.has(i) ? plan.start.get(i)[0] : plan.inside.get(i);
          const ssp = rows[k].sparkline;
          const px = padTop ? 20 : 16;
          cells.push(wordCell("", { left: false, top, bottom, raw: sparkImg(ssp.marks[c - 1], ssp.color, rows[k].cells[c - 1], px, (px - 8) * 10, !plan.start.has(i), sidew), styleExtra: ";padding:0;vertical-align:top" + (W ? wd(W.side) : "") }));
        } else if (plan && c && plan.start.has(i)) {
          const [k, n, end] = plan.start.get(i);
          const ssp = rows[k].sparkline;
          let height = 0;
          for (let q = i; q < end; q++) if (!plan.skip.has(q)) height += pads(q) ? 20 : 16;
          cells.push(wordCell("", { left: false, top, bottom: end === rows.length ? "1.5pt" : "", raw: sparkImg(ssp.marks[c - 1], ssp.color, rows[k].cells[c - 1], height, undefined, false, sidew), attrs: ` rowspan="${n}"`, styleExtra: ";padding:0;vertical-align:top" + (W ? wd(W.side) : "") }));
        }
      });
      out.push(tr + cells.join("") + "</tr>");
      prev = kind;
    }
    out.push("</table>");
    for (const n of t.notes) out.push(`<p style="margin:3pt 0 0 0;font-size:9pt">${h(n)}</p>`);
    out.push("</body></html>");
    return out.join("\n") + "\n";
  }

  const RENDERERS = { text: renderText, markdown: renderMarkdown, latex: renderLatex, html: renderHTML, csv: renderCSV, word: renderWord };

  function render(t, format, opts) {
    const f = RENDERERS[format || "text"];
    if (!f) throw new Error("format is one of " + Object.keys(RENDERERS).join(", "));
    return f(t, opts);
  }

  // ------------------------------------------------------------ redaction

  const CORE = ["meta", "specification", "metrics", "parameters", "structures"];

  // A copy of a record without the fields at `paths` (DEFAULT_IDENTIFYING syntax: dotted, with
  // [*] for every list item), plus a history entry naming them, as the Python reference's
  // redact() does. Paths in the sections the core digest covers are left alone.
  function redactRecord(rec, paths, by) {
    const out = JSON.parse(JSON.stringify(rec));
    const changed = [];
    for (const pattern of paths) {
      const parts = pattern.replace(/\[\*\]/g, ".[*]").split(".").filter(Boolean);
      if (!parts.length || CORE.includes(parts[0])) continue;
      const walk = (node, i, prefix) => {
        if (node === null || typeof node !== "object") return;
        const part = parts[i];
        if (part === "[*]") {
          if (!Array.isArray(node)) return;
          node.forEach((x, k) => walk(x, i + 1, `${prefix}[${k}]`));
          return;
        }
        if (Array.isArray(node) || !(part in node)) return;
        const path = prefix ? `${prefix}.${part}` : part;
        if (i === parts.length - 1) { delete node[part]; changed.push(path); }
        else walk(node[part], i + 1, path);
      };
      walk(out, 0, "");
    }
    if (changed.length) {
      out.history = out.history || [];
      out.history.push({ when: new Date().toISOString().replace(/\.\d+Z$/, "Z"), by: by || { name: "estrec viewer", version: "0.1" }, action: "redacted", method: "removed", fields: changed.sort() });
    }
    return { record: out, removed: changed };
  }

  // ------------------------------------------------------------ the web page

  // The spec to publish: estrec.org rebuilds the table from the spec and the bare records,
  // without the collections they came from, so a column labelled by its collection member
  // (member.label) gets that label written into its `header`, and the published table's
  // headings match the viewer's.
  function publishSpec(spec, idx) {
    const out = JSON.parse(JSON.stringify(spec));
    for (const c of out.columns || []) {
      if (!c || c.header !== undefined) continue;
      const f = lookup(idx, c);
      const label = f && (f.member || {}).label;
      if (label) c.header = String(label);
    }
    return out;
  }

  // A self-contained HTML page: the table, and the records behind its columns. Hovering a
  // column heading summarizes its record; clicking it opens the full record.
  function renderWebPage(t, records, opts) {
    opts = opts || {};
    const byId = new Map(records.map((r) => [((r || {}).meta || {}).id, r]));
    const used = [...new Set(t.column_records || [])].map((id) => byId.get(id)).filter(Boolean);
    const json = JSON.stringify({ columns: t.column_records || [], records: used }).replace(/</g, "\\u003c");
    const table = renderHTML(t).replace(/<thead>(<tr class="head-\w+">)<th><\/th>(.*?)<\/tr>/, (_, tr, ths) => {
      let i = 0;
      return "<thead>" + tr + "<th></th>" + ths.replace(/<th( colspan="2")?>(.*?)<\/th>/g, (__, sp, h) => `<th${sp || ""}><button type="button" class="col" data-col="${i++}" aria-haspopup="dialog">${h}</button></th>`) + "</tr>";
    });
    const title = escHTML(t.title || "Estimation table");
    return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
<meta name="generator" content="estrec viewer (estrec-table/0.1)">
<style>
:root { --bg: #ffffff; --ink: #18212b; --muted: #5a6573; --line: #d6dce3; --accent: #2b5f8e; --soft: #eef3f8; }
@media (prefers-color-scheme: dark) { :root { --bg: #14191f; --ink: #e3e8ee; --muted: #97a3b2; --line: #2c3541; --accent: #84b3df; --soft: #1d2732; color-scheme: dark; } }
body { margin: 0; background: var(--bg); color: var(--ink); font: 15px/1.45 Georgia, "Times New Roman", serif; padding: 24px max(16px, env(safe-area-inset-left, 0px)); }
.wrap { overflow-x: auto; }
table.estrec-table { border-collapse: collapse; font-variant-numeric: tabular-nums lining-nums; margin: 0 auto; }
table.estrec-table caption { caption-side: top; text-align: left; font-weight: 600; padding-bottom: 10px; }
table.estrec-table thead th { padding: 2px 14px; font-weight: 400; }
table.estrec-table thead tr:first-child th { border-top: 1.5px solid var(--ink); padding-top: 5px; }
table.estrec-table thead tr:last-child th { border-bottom: 0.75px solid var(--ink); padding-bottom: 5px; }
table.estrec-table th, table.estrec-table td { padding: 1px 14px; white-space: nowrap; }
table.estrec-table tbody th { text-align: left; font-weight: 400; }
table.estrec-table td { text-align: center; }
table.estrec-table tr.uncertainty td { color: var(--muted); }
table.estrec-table tbody tr.spark-row th, table.estrec-table tbody tr.spark-row td { padding-top: 0 !important; padding-bottom: 0 !important; line-height: 16px; }
table.estrec-table td.spark svg { display: block; margin: 0 auto; }
table.estrec-table td.spark-side.to-end { border-bottom: 1.5px solid var(--ink); }
table.estrec-table tbody tr.estimate:not(:first-child) th, table.estrec-table tbody tr.estimate:not(:first-child) td { padding-top: 6px; }
table.estrec-table tr.first-stat th, table.estrec-table tr.first-stat td { border-top: 0.75px solid var(--ink); padding-top: 5px; }
table.estrec-table tbody tr:last-child th, table.estrec-table tbody tr:last-child td { border-bottom: 1.5px solid var(--ink); padding-bottom: 5px; }
table.estrec-table tfoot td { font-size: 13px; color: var(--muted); padding-top: 8px; white-space: normal; text-align: left; }
button.col { font: inherit; color: inherit; background: none; border: 0; padding: 0; cursor: pointer; border-bottom: 1px dotted var(--muted); }
button.col:hover, button.col:focus-visible { color: var(--accent); border-bottom-color: var(--accent); outline: none; }
td.hl, th.hl { background: var(--soft); }
.tip { position: absolute; z-index: 5; max-width: 320px; background: var(--bg); color: var(--ink); border: 1px solid var(--line); border-radius: 6px; padding: 8px 10px; font: 12.5px/1.45 system-ui, sans-serif; box-shadow: 0 4px 16px rgba(0,0,0,.12); pointer-events: none; }
.tip b { font-weight: 600; }
.hint { text-align: center; color: var(--muted); font: 12px system-ui, sans-serif; margin-top: 10px; }
dialog { border: 1px solid var(--line); border-radius: 8px; background: var(--bg); color: var(--ink); max-width: min(860px, calc(100vw - 32px)); width: 100%; padding: 0; font: 14px/1.45 system-ui, sans-serif; }
dialog::backdrop { background: rgba(0,0,0,.35); }
.dhead { display: flex; justify-content: space-between; gap: 12px; align-items: baseline; padding: 14px 16px; border-bottom: 1px solid var(--line); }
.dhead h2 { margin: 0; font-size: 17px; }
.dbody { padding: 14px 16px; display: grid; gap: 14px; max-height: 75vh; overflow: auto; }
.dbody h3 { margin: 0; font-size: 11px; letter-spacing: .08em; text-transform: uppercase; color: var(--muted); }
.kv { display: grid; grid-template-columns: max-content 1fr; gap: 3px 14px; }
.kv dt { color: var(--muted); } .kv dd { margin: 0; overflow-wrap: anywhere; }
.grid { border-collapse: collapse; width: 100%; font-variant-numeric: tabular-nums; font-size: 13px; }
.grid th, .grid td { padding: 3px 8px; border-bottom: 1px solid var(--line); text-align: right; white-space: nowrap; }
.grid th:first-child, .grid td:first-child { text-align: left; }
.grid thead th { color: var(--muted); font-weight: 500; }
.scroll { overflow-x: auto; }
pre { font: 12px/1.45 ui-monospace, Menlo, monospace; background: var(--soft); padding: 10px; border-radius: 6px; overflow: auto; max-height: 360px; }
.btn { font: inherit; border: 1px solid var(--line); background: var(--bg); color: var(--ink); border-radius: 6px; padding: 4px 10px; cursor: pointer; text-decoration: none; }
code { font: 12.5px ui-monospace, Menlo, monospace; }
</style>
</head>
<body>
<div class="wrap">
${table}</div>
<p class="hint">Hover over a column heading for its estimation; click it for the full record.</p>
<dialog id="rec"><div class="dhead"><h2 id="rec-title"></h2><form method="dialog"><button class="btn">Close</button></form></div><div class="dbody" id="rec-body"></div></dialog>
<script type="application/json" id="estrec-records">${json}</script>
<script>
(function () {
  "use strict";
  var data = JSON.parse(document.getElementById("estrec-records").textContent);
  var recs = {}; data.records.forEach(function (r) { recs[r.meta.id] = r; });
  function num(v) { if (v && typeof v === "object") v = v.value; if (typeof v === "number") return v; if (v === "Inf") return Infinity; if (v === "-Inf") return -Infinity; return NaN; }
  function fmt(x) { if (typeof x !== "number") return x == null ? "" : String(x); if (isNaN(x)) return ""; if (!isFinite(x)) return x > 0 ? "Inf" : "-Inf"; if (Number.isInteger(x) && Math.abs(x) < 1e15) return x.toLocaleString("en-US"); var a = Math.abs(x); return a !== 0 && (a < 1e-4 || a >= 1e7) ? x.toExponential(3) : String(Number(x.toPrecision(4))); }
  function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); }
  function vcovs(r) { var v = (r.structures || {}).vcov; return v == null ? [] : Array.isArray(v) ? v : [v]; }
  function vlabel(v) { var cl = v.cluster || []; if (typeof cl === "string") cl = [cl]; return cl.length ? "clustered by " + cl.join(" & ") : (v.type || "?"); }
  function sw(r) { var s = (r.provenance || {}).software || []; if (!Array.isArray(s)) s = [s]; return s.filter(function (x) { return x.role === "estimator" || x.role === "language"; }).map(function (x) { return x.name + (x.version ? " " + x.version : ""); }).join(", "); }
  function formula(r) { var f = (r.specification || {}).formula; return f ? (typeof f === "string" ? f : f.text) : ""; }
  function summary(r) {
    var m = r.meta || {}, e = m.estimator || {}, d = vcovs(r).filter(function (v) { return v.default; })[0];
    var rows = [["", [e.family, e.method].filter(Boolean).join(" / ") + ((m.responses || []).length ? " of " + m.responses.join(", ") : "")],
      ["N", fmt(num((r.metrics || {}).nobs))], ["Std. errors", d ? vlabel(d) : ""],
      ["Fixed effects", ((r.specification || {}).fixed_effects || []).join(", ")], ["Software", sw(r)]];
    return "<b>" + esc(m.title || formula(r) || "Record") + "</b>" + rows.filter(function (x) { return x[1]; }).map(function (x) { return "<br>" + (x[0] ? esc(x[0]) + ": " : "") + esc(x[1]); }).join("");
  }
  function table(head, rows) { return '<div class="scroll"><table class="grid"><thead><tr>' + head.map(function (h) { return "<th>" + esc(h) + "</th>"; }).join("") + "</tr></thead><tbody>" + rows.map(function (r) { return "<tr>" + r.map(function (c) { return "<td>" + esc(c) + "</td>"; }).join("") + "</tr>"; }).join("") + "</tbody></table></div>"; }
  function detail(r) {
    var m = r.meta || {}, s = r.specification || {}, h = [];
    var kv = [["Estimator", [((m.estimator || {}).family), ((m.estimator || {}).method)].filter(Boolean).join(" / ")], ["Response", (m.responses || []).join(", ")], ["Formula", formula(r)], ["Fixed effects", (s.fixed_effects || []).join(", ")], ["Clusters", (s.clusters || []).join(", ")], ["Software", sw(r)], ["Status", m.status], ["Created", m.created], ["Record id", m.id], ["Core digest", m.core_digest]];
    h.push('<dl class="kv">' + kv.filter(function (x) { return x[1]; }).map(function (x) { return "<dt>" + esc(x[0]) + "</dt><dd>" + esc(x[1]) + "</dd>"; }).join("") + "</dl>");
    h.push("<h3>Estimates</h3>" + table(["Term", "Estimate", "Std. error", "Statistic", "p", "CI low", "CI high"], (r.parameters || []).map(function (p) { return [(p.component ? "[" + p.component + "] " : "") + (p.response && (m.responses || []).length > 1 ? p.response + ": " : "") + p.term].concat(p.dropped ? ["(" + p.dropped + ")", "", "", "", "", ""] : ["estimate", "std_error", "statistic", "p_value", "conf_low", "conf_high"].map(function (k) { return fmt(num(p[k])); })); })));
    var ms = r.metrics || {}; var mk = Object.keys(ms);
    if (mk.length) h.push("<h3>Metrics</h3>" + table(["Metric", "Value"], mk.map(function (k) { var v = ms[k]; v = v && typeof v === "object" ? v.value : v; return [k, typeof v === "number" ? fmt(v) : String(v)]; })));
    var vs = vcovs(r);
    if (vs.length) h.push("<h3>Variance estimates</h3>" + table(["Type", "Clusters", "df for t", "Small-sample correction", ""], vs.map(function (v) { return [v.type || "?", v.n_clusters ? Object.keys(v.n_clusters).map(function (k) { return k + " " + fmt(v.n_clusters[k]); }).join(", ") : (v.cluster || []).join(", "), isNaN(num(v.df_t)) ? "normal" : fmt(num(v.df_t)), v.ssc ? [v.ssc.convention, v.ssc.formula].filter(Boolean).join(": ") : "", v.default ? "default" : ""]; })));
    var fe = (r.structures || {}).fixed_effects; if (fe && !Array.isArray(fe)) fe = [fe];
    if (fe && fe.length) h.push("<h3>Fixed effects</h3>" + table(["Name", "Levels", "Redundant"], fe.map(function (f) { return [f.name, fmt(num(f.levels)), f.redundant == null ? "" : fmt(f.redundant)]; })));
    if ((r.tests || []).length) h.push("<h3>Tests</h3>" + table(["Test", "Statistic", "Distribution", "df", "p"], r.tests.map(function (t) { return [t.label || t.name || "", fmt(num(t.statistic)), t.distribution || "", Array.isArray(t.df) ? t.df.join(", ") : t.df == null ? "" : String(t.df), fmt(num(t.p_value))]; })));
    var text = JSON.stringify(r, null, 2);
    var name = (m.title || m.id || "record").replace(/[^A-Za-z0-9]+/g, "-").replace(/^-|-$/g, "").toLowerCase() || "record";
    h.push('<details><summary>The record as JSON</summary><pre>' + esc(text) + '</pre></details><p><a class="btn" download="' + esc(name) + '.estrec.json" href="data:application/json;charset=utf-8,' + encodeURIComponent(text) + '">Download the record</a></p>');
    return h.join("");
  }
  var tip = document.createElement("div"); tip.className = "tip"; tip.hidden = true; document.body.appendChild(tip);
  var dlg = document.getElementById("rec");
  // a column's cells, through colspans and rowspans (a sparkline beside the estimates gives each column two)
  function cells(i, on) {
    var tbl = document.querySelector("table.estrec-table"); if (!tbl) return;
    var w = tbl.querySelector("td.spark-side") ? 2 : 1, lo = 1 + i * w, hi = lo + w, taken = [];
    var trs = tbl.querySelectorAll("tr");
    for (var k = 0; k < trs.length; k++) {
      var col = 0, row = taken[k] || {};
      for (var c = trs[k].firstElementChild; c; c = c.nextElementSibling) {
        while (row[col]) col++;
        var cs = c.colSpan || 1, rs = c.rowSpan || 1;
        for (var q = 1; q < rs; q++) { taken[k + q] = taken[k + q] || {}; for (var x = 0; x < cs; x++) taken[k + q][col + x] = true; }
        if (col < hi && col + cs > lo && c.parentNode.parentNode.tagName !== "TFOOT") c.classList.toggle("hl", on);
        col += cs;
      }
    }
  }
  document.querySelectorAll("button.col").forEach(function (b) {
    var i = Number(b.dataset.col), r = recs[data.columns[i]];
    if (!r) return;
    function show() { tip.innerHTML = summary(r); tip.hidden = false; var q = b.getBoundingClientRect(); tip.style.left = Math.max(8, Math.min(window.scrollX + q.left, window.scrollX + document.documentElement.clientWidth - tip.offsetWidth - 8)) + "px"; tip.style.top = (window.scrollY + q.bottom + 6) + "px"; cells(i, true); }
    function hide() { tip.hidden = true; cells(i, false); }
    b.addEventListener("mouseenter", show); b.addEventListener("focus", show);
    b.addEventListener("mouseleave", hide); b.addEventListener("blur", hide);
    b.addEventListener("click", function () { hide(); document.getElementById("rec-title").textContent = b.textContent + (r.meta.title ? ": " + r.meta.title : ""); document.getElementById("rec-body").innerHTML = detail(r); if (dlg.showModal) dlg.showModal(); else dlg.setAttribute("open", ""); });
  });
})();
</script>
</body>
</html>
`;
  }

  // ------------------------------------------------------------ reading files

  // A parsed JSON document -> [{record, member}] (a record, or a collection's members). Members
  // in a members file are looked up in `jsonl` (a map from file name to its text).
  function recordsIn(doc, jsonl) {
    if (doc && doc.schema === "estrec/0.1") return { items: [{ record: doc, member: null }], missing: [] };
    if (doc && typeof doc.schema === "string" && doc.schema.startsWith("estrec-collection/")) {
      const items = [], missing = [];
      const files = new Map();
      const atts = new Map((doc.attachments || []).map((a) => [a.id, a]));
      for (const m of doc.members || []) {
        let rec = m.record;
        if (!rec && m.attachment) {
          const att = atts.get(m.attachment);
          const name = att && att.path ? att.path.split("/").pop() : null;
          if (name && jsonl && jsonl.has(name)) {
            if (!files.has(name)) {
              const byId = new Map();
              for (const ln of jsonl.get(name).split(/\r?\n/)) if (ln.trim()) { const r = JSON.parse(ln); byId.set((r.meta || {}).id, r); }
              files.set(name, byId);
            }
            rec = files.get(name).get(m.id);
          } else if (name && !missing.includes(name)) missing.push(name);
        }
        if (rec) {
          const member = Object.assign({}, m);
          delete member.record;
          items.push({ record: rec, member });
        }
      }
      return { items, missing };
    }
    return null;
  }

  function newSpec(items, opts) {
    opts = opts || {};
    const uuid = typeof crypto !== "undefined" && crypto.randomUUID ? crypto.randomUUID() : "00000000-0000-4000-8000-" + String(Date.now()).padStart(12, "0").slice(-12);
    const spec = {
      schema: TABLE_SCHEMA,
      meta: { id: uuid, created: new Date().toISOString().replace(/\.\d+Z$/, "Z"), producer: { name: "estrec viewer", version: "0.1" } },
      columns: items.map((it) => ({ record: it.record.meta.id })),
      uncertainty: "std_error",
      stars: DEFAULT_STARS.slice(),
      stats: [{ metric: "nobs" }, { metric: "r2" }, { vcov: "type" }],
    };
    return Object.assign(spec, opts);
  }

  return {
    TABLE_SCHEMA, DEFAULT_STARS, DEFAULT_HEAD, HEAD_KINDS, TABLE_METRICS, STAT_LABELS,
    twoSidedP, criticalValue, erfc, qnorm,
    NAMED_LINES, PLACEHOLDERS, publishSpec, SPARK_COLOR, SPARK_SCALES, SPARK_PLACES, SPARK_ALIGNS, sparkSVG, sparkTikz, uncertaintyLines, pValue,
    num, vcovs, vcovLabel, pickVcov, tidy, glance, findTest,
    canonicalJSON, sha256Hex, recordSha256,
    indexRecords, validateTable, checkPins, columnResponse, buildTable, render, renderers: RENDERERS,
    redactRecord, renderWebPage,
    recordsIn, newSpec, fixed, statValue,
  };
});
