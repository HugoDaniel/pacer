#!/usr/bin/env node
// tools/measure_size.mjs — C2 per-file size columns (plan 06 Group C).
//
// Method: the `animader/animader/.agent/releases/meridian.size.json`
// per-file convention — raw bytes plus the encoded length of each file on
// its own, gzip level 9 and brotli quality 11 (node:zlib), never an archive
// total and never an HTTP wire measurement. The script reads the actual
// files named on the command line; nothing is copied from an old row.
//
// Usage:
//   node tools/measure_size.mjs OUTDIR [ablate-pacm.wasm] [pattern-free.wasm]
//
// Emits sizes.tsv, groups.tsv, scores.tsv, meridian-program.tsv.

import { readFileSync, writeFileSync, mkdirSync, readdirSync } from 'node:fs';
import { gzipSync, brotliCompressSync, constants as zc } from 'node:zlib';

const out = process.argv[2] ?? '.agent/control/cache-c/c2';
const ablatePacm = process.argv[3];
const patternFree = process.argv[4];

const measure = (p) => {
  const b = readFileSync(p);
  return {
    path: p,
    bytes: b.length,
    gzip9: gzipSync(b, { level: 9 }).length,
    brotli11: brotliCompressSync(b, {
      params: { [zc.BROTLI_PARAM_QUALITY]: 11 },
    }).length,
  };
};

const fileRows = [];
const add = (label, p) => {
  const m = measure(p);
  fileRows.push({ label, ...m });
  return m;
};

const basename = (p) => p.split('/').pop();

add('pacer.wasm (full driver, current HEAD)', 'zig-out/bin/pacer.wasm');
add('pacer-rt.wasm (full capability, binding)', 'zig-out/bin/pacer-rt.wasm');
if (patternFree) add('pacer-rt.wasm (pattern-free, P2 trend rebuild)', patternFree);
if (ablatePacm) add('pacer-rt.wasm (Pacm-reader ablation)', ablatePacm);

// JS glue files (actual shipped sources).
const src = 'npm/pacer/src';
const js = (n) => `${src}/${n}`;
for (const f of readdirSync(src).filter((f) => f.endsWith('.js')).sort()) {
  add(`js ${f}`, js(f));
}

// Published package file set: the package.json "files" surface. Types are
// declaration text, not runtime code; report them separately.
const published = [];
for (const f of readdirSync(src).filter((f) => f.endsWith('.js')).sort()) published.push(js(f));
for (const f of readdirSync('npm/pacer/types').filter((f) => f.endsWith('.d.ts') || f.endsWith('.d.ts.map')).sort()) published.push(`npm/pacer/types/${f}`);
for (const f of ['npm/pacer/README.md', 'npm/pacer/LICENSE', 'npm/pacer/pacer.wasm', 'npm/pacer/pacer-rt.wasm']) published.push(f);
for (const p of published) add(`published ${p.replace('npm/pacer/', '')}`, p);

// Explicit groups, each summed per-file (the same convention).
const group = (label, paths) => {
  const rows = paths.map((p) => fileRows.find((r) => r.path === p));
  const sum = rows.reduce((a, r) => ({
    bytes: a.bytes + r.bytes,
    gzip9: a.gzip9 + r.gzip9,
    brotli11: a.brotli11 + r.brotli11,
  }), { bytes: 0, gzip9: 0, brotli11: 0 });
  return { label, files: rows.length, ...sum };
};

const rtClosure = [js('rt.js'), js('pact.js'), js('meta.js')];
const textClosure = [js('index.js'), js('pact.js'), js('meta.js')];
const playerClosure = [js('rt.js'), js('pact.js'), js('meta.js'), js('route.js'), js('lane.js'), js('clock.js'), js('audio.js')];
const groups = [
  group('text glue: index.js alone', [js('index.js')]),
  group('text glue: index.js + shared (pact,meta)', textClosure),
  group('rt glue: rt.js alone', [js('rt.js')]),
  group('rt glue: rt.js + shared (pact,meta)', rtClosure),
  group('player glue: rt.js + pact/meta/route/lane/clock/audio', playerClosure),
  group('all published JS sources', readdirSync(src).filter((f) => f.endsWith('.js')).sort().map(js)),
  group('published package file set (JS + types + wasm + docs)', published),
];

// Score pair: the real Meridian export score vs its packed PACB. Pack
// output recorded pacm_bytes=5651 for this exact pair.
const scoreRow = [];
const sjon = '.agent/control/cache-c/fixtures/meridian.score.sjon';
const pacb = '.agent/control/cache-c/fixtures/meridian.score.pacb';
const sm = measure(sjon);
const pm = measure(pacb);
scoreRow.push({ label: 'Meridian score.sjon', ...sm });
scoreRow.push({ label: 'Meridian score.pacb', ...pm });
scoreRow.push({
  label: 'Meridian PACM embedded in PACB (from pack report)',
  path: '(embedded)', bytes: 5651, gzip9: '', brotli11: '',
});

// The historical Meridian program total, music excluded (musicPath
// scoping). Read the cited release report; do not recompress the export.
const meridian = JSON.parse(readFileSync('../animader/animader/.agent/releases/meridian.size.json', 'utf8'));
const all = meridian.sums.all;
const music = meridian.sums.music;
const program = {
  raw: all.raw - music.raw,
  gzip9: all.gzip9 - music.gzip9,
  brotli11: all.brotli11 - music.brotli11,
};
const norm = (x) => ({ bytes: x.raw, gzip9: x.gzip9, brotli11: x.brotli11 });
const meridianRows = [
  { label: 'Meridian export all files', ...norm(all) },
  { label: 'Meridian export music (excluded)', ...norm(music) },
  { label: 'Meridian export program total (music excluded)', ...norm(program) },
];

// Pacer-local program totals (the C2 measured set), music excluded by
// construction (no audio file exists in this set).
const fullRt = fileRows.find((r) => r.label.startsWith('pacer-rt.wasm (full'));
const fullText = fileRows.find((r) => r.label.startsWith('pacer.wasm (full'));
const rtGlue = groups.find((g) => g.label.startsWith('rt glue: rt.js + shared'));
const textGlue = groups.find((g) => g.label.startsWith('text glue: index.js + shared'));
const pacerProgram = [
  { label: 'pacer program total: rt.wasm + rt glue + score.pacb', bytes: fullRt.bytes + rtGlue.bytes + pm.bytes, gzip9: fullRt.gzip9 + rtGlue.gzip9 + pm.gzip9, brotli11: fullRt.brotli11 + rtGlue.brotli11 + pm.brotli11 },
  { label: 'pacer program total: pacer.wasm + text glue + score.sjon', bytes: fullText.bytes + textGlue.bytes + sm.bytes, gzip9: fullText.gzip9 + textGlue.gzip9 + sm.gzip9, brotli11: fullText.brotli11 + textGlue.brotli11 + sm.brotli11 },
];

const tsv = (rows, cols) => [cols.join('\t'), ...rows.map((r) => cols.map((c) => r[c] ?? '').join('\t'))].join('\n') + '\n';
mkdirSync(out, { recursive: true });
writeFileSync(`${out}/sizes.tsv`, tsv(fileRows, ['label', 'path', 'bytes', 'gzip9', 'brotli11']));
writeFileSync(`${out}/groups.tsv`, tsv(groups, ['label', 'files', 'bytes', 'gzip9', 'brotli11']));
writeFileSync(`${out}/scores.tsv`, tsv(scoreRow, ['label', 'path', 'bytes', 'gzip9', 'brotli11']));
writeFileSync(`${out}/meridian-program.tsv`, tsv([...meridianRows, ...pacerProgram], ['label', 'bytes', 'gzip9', 'brotli11']));
writeFileSync(`${out}/provenance.tsv`, [
  'key\tvalue',
  `node\t${process.version}`,
  `method\tper-file raw + node:zlib gzip level 9 + brotli quality 11; not an archive`,
  `pattern_free_source\tpacer aac3eda (P2 trend) rebuilt with the current toolchain and sibling SJON; pattern capability absent; incomplete/trend-only`,
  `pacm_ablation\tHEAD f7fa639; only Pacm.decode and Pacb.verifyRouting stubbed (return null); same recipe`,
  `meridian_size_json\t../animader/animader/.agent/releases/meridian.size.json`,
].join('\n') + '\n');

console.log(tsv(fileRows, ['label', 'bytes', 'gzip9', 'brotli11']));
console.log('--- groups');
console.log(tsv(groups, ['label', 'files', 'bytes', 'gzip9', 'brotli11']));
console.log('--- scores');
console.log(tsv(scoreRow, ['label', 'bytes', 'gzip9', 'brotli11']));
console.log('--- totals');
console.log(tsv([...meridianRows, ...pacerProgram], ['label', 'bytes', 'gzip9', 'brotli11']));
