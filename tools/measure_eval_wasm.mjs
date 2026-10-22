#!/usr/bin/env node
// tools/measure_eval_wasm.mjs — supplementary real-shipped-WASM frame
// timing (plan 06 C4 context; the binding C4 instrument is the native
// counting-GPA harness). Times only the wasm eval call, no JS frame decode.
//
// Usage: node tools/measure_eval_wasm.mjs OUTDIR CASE FRAMES
//   CASE = all-features | meridian-minimal
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { encodeTargets } from '../npm/pacer/src/pact.js';

const [out, caseName, framesArg] = process.argv.slice(2);
const FIX = process.env.PACER_PERF_FIXTURES ?? '.agent/control/cache-c/fixtures';
const frames = Number(framesArg ?? 100000);
const CASES = {
  'all-features': {
    doc: 'corpus/all-features/doc.sjon',
    pacb: `${FIX}/all-features.pacb`,
    targets: [['beat',1,0],['bpm',1,0],['radius',1,0],['blend',1,0],['pat',1,0],['grid',1,0],['hit',1,0],['level',1,0],['sweep',1,0],['dropx',1,0],['pulse',4,0]],
  },
  'meridian-minimal': {
    doc: 'tools/testdata/perf/meridian-minimal.score.sjon',
    pacb: `${FIX}/meridian-minimal.pacb`,
    targets: [['beat',1,0],['heroPos',2,0],['heroTurn',1,0],['heroTint',1,0]],
  },
};
const c = CASES[caseName];
if (!c) throw new Error(`unknown case ${caseName}`);
const doc = readFileSync(c.doc);
const pacb = readFileSync(c.pacb);
const pact = encodeTargets(c.targets.map(([name, ncomp, registry]) => ({ name, ncomp, registry })));
const imports = { env: { sjon_host_invoke_plugin: () => 0 } };
const textWasm = await WebAssembly.compile(readFileSync('zig-out/bin/pacer.wasm'));
const rtWasm = await WebAssembly.compile(readFileSync('zig-out/bin/pacer-rt.wasm'));

const q = 25000;
const scripted = (i) => {
  const phase = Math.floor(i / q);
  const j = i % q;
  const seek = (bases) => bases[j % bases.length] + ((j / bases.length) % 7) * 0.0001;
  if (caseName === 'all-features') {
    if (phase === 0) return j * 0.0004;
    if (phase === 1) return seek([0, 3.99, 4, 5.99, 6]);
    if (phase === 2) return 6.5 - (j % 200) * 0.01;
    return 5.9 + (j % 20) * 0.01;
  }
  if (phase === 0) return j * 0.0014;
  if (phase === 1) return seek([0, 11.707317, 23.414634, 35.121951]);
  if (phase === 2) return 30 - (j % 200) * 0.01;
  return 35 + (j % 20) * 0.01;
};

const run = (instance, text) => {
  const e = instance.exports;
  const mem = () => new Uint8Array(e.memory.buffer);
  if (text) {
    mem().set(doc, e.drv_docPtr());
    mem().set(pact, e.drv_targetsPtr());
    if (e.drv_load(doc.length, pact.length) !== 0) throw new Error('text load');
  } else {
    mem().set(pacb, e.prt_pacbPtr());
    mem().set(pact, e.prt_targetsPtr());
    if (e.prt_load(pacb.length, pact.length) !== 0) throw new Error('binary load');
  }
  const fn = text ? e.drv_eval : e.prt_eval;
  // This host's clock call is ~20 us; time batches and divide, so the
  // instrument does not dominate a per-frame eval.
  const B = 1000;
  const samples = Math.floor(frames / B);
  const out = new Array(samples);
  let sink = 0;
  for (let s = 0; s < samples; s++) {
    const a = process.hrtime.bigint();
    for (let i = 0; i < B; i++) {
      const n = fn(scripted(s * B + i));
      if (n === 0) throw new Error(`empty frame ${s * B + i}`);
      sink ^= n;
    }
    const b = process.hrtime.bigint();
    out[s] = Number(b - a) / B;
  }
  return { out, sink };
};

const stats = (a) => {
  const s = [...a].sort((x, y) => x - y);
  const at = (p) => s[Math.min(s.length - 1, Math.floor((s.length * p) / 100))];
  const med = at(50);
  const dev = s.map((v) => Math.abs(v - med)).sort((x, y) => x - y);
  return { p50: at(50), p95: at(95), p99: at(99), max: s[s.length - 1], mad: dev[Math.floor(dev.length / 2)] };
};

const ti = await WebAssembly.instantiate(textWasm, imports);
const ri = await WebAssembly.instantiate(rtWasm, imports);
const text = run(ti, true);
const bin = run(ri, false);
const lines = ['path\tp50_ns\tp95_ns\tp99_ns\tmax_ns\tmad_ns'];
for (const [name, r] of [['text-wasm', text], ['binary-wasm', bin]]) {
  const s = stats(r.out);
  lines.push(`${name}\t${s.p50}\t${s.p95}\t${s.p99}\t${s.max}\t${s.mad}`);
}
mkdirSync(out, { recursive: true });
writeFileSync(`${out}/${caseName}.wasm-eval.tsv`, `${lines.join('\n')}\n`);
writeFileSync(`${out}/${caseName}.wasm-eval-raw.tsv`, ['batch\tpath\tns_per_frame', ...text.out.map((v, i) => `${i}\ttext\t${v}`), ...bin.out.map((v, i) => `${i}\tbinary\t${v}`)].join('\n') + '\n');
console.log(lines.join('\n'));
