// Used by tests/test_viewer.py: reads {files, sources, specs, pvals} as JSON on stdin and prints
// the viewer's tables and p-values, built by viewer/estrec-table.js, as JSON.
const E = require("../viewer/estrec-table.js");
let input = "";
process.stdin.on("data", (d) => (input += d));
process.stdin.on("end", async () => {
  const req = JSON.parse(input);
  const jsonl = new Map(req.files.filter((f) => f.name.endsWith(".jsonl")).map((f) => [f.name, f.text]));
  const items = [];
  for (const f of req.files) {
    if (f.name.endsWith(".jsonl")) continue;
    const got = E.recordsIn(JSON.parse(f.text), jsonl);
    for (const it of got.items) items.push(Object.assign(it, { source: req.sources[f.name], file: f.name }));
  }
  const idx = E.indexRecords(items);
  const tables = req.specs.map((s) => { try { return E.buildTable(s, idx); } catch (e) { return { error: e.message }; } });
  const pvals = req.pvals.map(([t, df]) => E.twoSidedP(t, df));
  const crit = req.crit.map(([lv, df]) => E.criticalValue(lv, df));
  const hashes = await Promise.all(items.map((it) => E.recordSha256(it.record)));
  // the viewer's Table spec export of each spec, plain and with pinned versions, and the
  // table each builds when opened again (the open-spec round trip)
  const exported = [];
  const idCount = new Map();
  for (const it of items) idCount.set(it.record.meta.id, (idCount.get(it.record.meta.id) || 0) + 1);
  for (const s of req.specs) {
    // as the viewer holds a table built by clicking: no sources, and a column names its source
    // only where its record id is in several files
    const bare = JSON.parse(JSON.stringify(s));
    delete bare.sources;
    for (const c of bare.columns) if (idCount.get(c.record) === 1) delete c.source;
    const pair = [];
    for (const [pin, from] of [[false, s], [true, s], [false, bare], [true, bare]]) {
      const spec = await E.exportSpec(from, items, { pin });
      const reopened = JSON.parse(JSON.stringify(spec, null, 2) + "\n");
      let table;
      try { table = E.buildTable(reopened, idx); } catch (e) { table = { error: e.message }; }
      pair.push({ spec, table, issues: E.validateTable(reopened, idx), pins: await E.checkPins(reopened, idx) });
    }
    exported.push(pair);
  }
  process.stdout.write(JSON.stringify({ tables, pvals, crit, exported, hashes: items.map((it, i) => [it.record.meta.id, hashes[i]]) }));
});
