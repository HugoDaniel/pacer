#!/usr/bin/env node
// tools/measure_load.mjs — C3 load-performance samples (plan 06 Group C).
//
// Loads the REAL shipped wasm artifacts (zig-out/bin/pacer.wasm and
// pacer-rt.wasm) in Node on the OpenBSD host. Cold = a fresh WebAssembly
// instance plus the load call; warm = a second load on the live instance.
// The wasm Module itself is compiled once (fetch/compile of the artifact is
// not the score compile under test); every score load is inside the timer.
//
// The two paths are interleaved, alternating order each sample, so machine
// drift cannot favour one. Writes raw samples as TSV; stats are computed
// here from those samples (median, MAD, p10, p90).

import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { gzipSync } from 'node:zlib';
import { encodeTargets } from '../npm/pacer/src/pact.js';

const N = 50;
const OUT = process.argv[2] ?? '.agent/control/cache-c/c3';
const FIX = process.env.PACER_PERF_FIXTURES ?? '.agent/control/cache-c/fixtures';

const CASES = [
  {
    name: 'all-features',
    doc: 'corpus/all-features/doc.sjon',
    pacb: `${FIX}/all-features.pacb`,
    targets: [
      ['beat', 1, 0], ['bpm', 1, 0], ['radius', 1, 0], ['blend', 1, 0],
      ['pat', 1, 0], ['grid', 1, 0], ['hit', 1, 0], ['level', 1, 0],
      ['sweep', 1, 0], ['dropx', 1, 0], ['pulse', 4, 0],
    ],
  },
  {
    name: 'meridian-minimal',
    doc: 'tools/testdata/perf/meridian-minimal.score.sjon',
    pacb: `${FIX}/meridian-minimal.pacb`,
    targets: [['beat', 1, 0], ['heroPos', 2, 0], ['heroTurn', 1, 0], ['heroTint', 1, 0]],
  },
];

const wasmText = await WebAssembly.compile(readFileSync('zig-out/bin/pacer.wasm'));
const wasmRt = await WebAssembly.compile(readFileSync('zig-out/bin/pacer-rt.wasm'));
const imports = { env: { sjon_host_invoke_plugin: () => 0 } };

const nowNs = () => process.hrtime.bigint();

function keep(instance, text) {
  const e = instance.exports;
  return {
    e,
    mem: () => new Uint8Array(e.memory.buffer),
    docPtr: text ? e.drv_docPtr : e.prt_pacbPtr,
    docCap: text ? e.drv_docCap : e.prt_pacbCap,
    targetsPtr: text ? e.drv_targetsPtr : e.prt_targetsPtr,
    targetsCap: text ? e.drv_targetsCap : e.prt_targetsCap,
    load: text ? e.drv_load : e.prt_load,
    eval: text ? e.drv_eval : e.prt_eval,
    setControl: text ? e.drv_setControl : e.prt_setControl,
  };
}

function loadText(instance, doc, pact) {
  const d = keep(instance, true);
  new Uint8Array(d.e.memory.buffer).set(doc, d.docPtr());
  new Uint8Array(d.e.memory.buffer).set(pact, d.targetsPtr());
  return d.load(doc.length, pact.length);
}

function loadBinary(instance, pacb, pact) {
  const d = keep(instance, false);
  new Uint8Array(d.e.memory.buffer).set(pacb, d.docPtr());
  new Uint8Array(d.e.memory.buffer).set(pact, d.targetsPtr());
  return d.load(pacb.length, pact.length);
}

function stats(xs) {
  const s = [...xs].sort((a, b) => a - b);
  const at = (p) => s[Math.min(s.length - 1, Math.floor((s.length * p) / 100))];
  const median = at(50);
  const dev = s.map((v) => Math.abs(v - median)).sort((a, b) => a - b);
  return {
    n: s.length,
    median,
    mad: dev[Math.floor(dev.length / 2)],
    p10: at(10),
    p90: at(90),
    min: s[0],
    max: s[s.length - 1],
  };
}

mkdirSync(OUT, { recursive: true });
const raw = ['case\tkind\tpath\tsample\tns'];
const summary = ['case\tkind\tpath\tn\tmedian_ns\tmad_ns\tp10_ns\tp90_ns\tmin_ns\tmax_ns'];

for (const c of CASES) {
  const doc = readFileSync(c.doc);
  const pacb = readFileSync(c.pacb);
  const pact = encodeTargets(c.targets.map(([name, ncomp, registry]) => ({ name, ncomp, registry })));

  const cold = { text: [], binary: [] };
  for (let i = 0; i < N; i++) {
    const order = i % 2 === 0 ? ['text', 'binary'] : ['binary', 'text'];
    for (const path of order) {
      const t0 = nowNs();
      const instance = await WebAssembly.instantiate(path === 'text' ? wasmText : wasmRt, imports);
      const status = path === 'text' ? loadText(instance, doc, pact) : loadBinary(instance, pacb, pact);
      const dt = Number(nowNs() - t0);
      if (status !== 0) throw new Error(`${c.name} cold ${path} load status ${status}`);
      cold[path].push(dt);
      raw.push(`${c.name}\tcold\t${path}\t${i}\t${dt}`);
    }
  }

  const warm = { text: [], binary: [] };
  const liveText = await WebAssembly.instantiate(wasmText, imports);
  const liveBin = await WebAssembly.instantiate(wasmRt, imports);
  if (loadText(liveText, doc, pact) !== 0) throw new Error(`${c.name} text warm prime failed`);
  if (loadBinary(liveBin, pacb, pact) !== 0) throw new Error(`${c.name} binary warm prime failed`);
  for (let i = 0; i < N; i++) {
    const order = i % 2 === 0 ? ['text', 'binary'] : ['binary', 'text'];
    for (const path of order) {
      const t0 = nowNs();
      const status = path === 'text' ? loadText(liveText, doc, pact) : loadBinary(liveBin, pacb, pact);
      const dt = Number(nowNs() - t0);
      if (status !== 0) throw new Error(`${c.name} warm ${path} load status ${status}`);
      warm[path].push(dt);
      raw.push(`${c.name}\twarm\t${path}\t${i}\t${dt}`);
    }
  }

  for (const kind of ['cold', 'warm']) {
    for (const path of ['text', 'binary']) {
      const s = stats(kind === 'cold' ? cold[path] : warm[path]);
      summary.push(`${c.name}\t${kind}\t${path}\t${s.n}\t${s.median}\t${s.mad}\t${s.p10}\t${s.p90}\t${s.min}\t${s.max}`);
    }
  }
}

writeFileSync(`${OUT}/load-samples.tsv`, `${raw.join('\n')}\n`);
writeFileSync(`${OUT}/load-summary.tsv`, `${summary.join('\n')}\n`);
writeFileSync(`${OUT}/provenance.tsv`, [
  'key\tvalue',
  `node\t${process.version}`,
  `wasm_text_bytes\t${readFileSync('zig-out/bin/pacer.wasm').length}`,
  `wasm_rt_bytes\t${readFileSync('zig-out/bin/pacer-rt.wasm').length}`,
  `wasm_text_gzip9\t${gzipSync(readFileSync('zig-out/bin/pacer.wasm'), { level: 9 }).length}`,
  `cold_definition\tfresh WebAssembly instance + load call; module precompiled once`,
  `warm_definition\tsecond load on the live instance`,
  `n_per_cell\t${N}`,
].join('\n') + '\n');

console.log(summary.join('\n'));
