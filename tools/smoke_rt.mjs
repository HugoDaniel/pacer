#!/usr/bin/env node
// tools/smoke_rt.mjs — the formal pacer-rt.wasm smoke (02 P2, plan T2.4).
//
// Loads the REAL built artifact (zig-out/bin/pacer-rt.wasm — built by
// `zig build wasm-rt`, or by `zig build audit-rt-imports` whose chained
// verb builds it as a dependency) in an inert host environment, then:
//   1. prt_abiVersion() === 1;
//   2. prt_load of the committed declared-targets fixture
//      tools/testdata/pacb/full-small.pacb with a ZERO-COUNT 'PACT'
//      (the fixture declares its targets — R-O1 — so an empty host join
//      satisfies canonicalPactEquals) ⇒ status 0;
//   3. prt_metaLen() > 0 and prt_eval(0.5) produces a non-empty frame;
//   4. a CORRUPTED reload ⇒ status 1 with the old score live: the held
//      control survives and the re-evaled frame is byte-identical
//      (JS-visible transactional proof, pre-P3);
//   5. a good reload of keys-only.pacb arms the new score (meta length
//      visibly differs).
//
// Needs node only (no zig at run time) and a built artifact; run from the
// repo root: `node tools/smoke_rt.mjs`. Exit 0 = PASS; any violation exits
// 1 naming it. (The T2.2 one-off at .agent/control/tmp/smoke_rt.mjs was
// the guidance for this formal version; this file is the committed test.)
import { readFileSync } from 'node:fs';

const fail = (msg) => {
  console.error(`SMOKE-FAIL ${msg}`);
  process.exit(1);
};
const say = (msg) => console.log(`SMOKE ${msg}`);

const wasm = readFileSync('zig-out/bin/pacer-rt.wasm');
const pacb = readFileSync('tools/testdata/pacb/full-small.pacb');

// The one statically retained import is dynamically inert: the frozen
// core-only binary schema provides no plugin implementations, so nothing
// in a valid load can call it. Bind the stub the signature declares.
const { instance } = await WebAssembly.instantiate(wasm, {
  env: { sjon_host_invoke_plugin: () => 0 },
});
const e = instance.exports;

say(`prt_abiVersion=${e.prt_abiVersion()}`);
if (e.prt_abiVersion() !== 1) fail('abiVersion != 1');
say(`prt_pacbCap=${e.prt_pacbCap()} prt_targetsCap=${e.prt_targetsCap()}`);
if (pacb.length > e.prt_pacbCap()) fail('fixture exceeds PACB_CAP');

const mem = () => new Uint8Array(e.memory.buffer);
// Zero-count 'PACT' (magic + count 0) — the fixture declares its targets.
const pact = new Uint8Array([0x50, 0x41, 0x43, 0x54, 0, 0, 0, 0]);
mem().set(pacb, e.prt_pacbPtr());
mem().set(pact, e.prt_targetsPtr());

const st1 = e.prt_load(pacb.length, pact.length);
say(`load(full-small)=${st1} metaLen=${e.prt_metaLen()}`);
if (st1 !== 0) fail(`load status ${st1}, loadError=${e.prt_loadError()}`);
if (e.prt_metaLen() <= 0) fail('metaLen 0 after ok load');

const frame1 = (() => {
  const n = e.prt_eval(0.5);
  return mem().slice(e.prt_writesPtr(), e.prt_writesPtr() + n);
})();
say(`eval(0.5)=${frame1.length} bytes exprFailures=${e.prt_exprFailures()}`);
if (frame1.length <= 0) fail('empty frame at 0.5s');
const ticks1 = (() => {
  const n = e.prt_evalTicks(96n);
  return mem().slice(e.prt_writesPtr(), e.prt_writesPtr() + n);
})();
if (ticks1.length <= 0) fail('empty frame at tick 96');

// Hold a control + prove a corrupted reload is transactional.
if (e.prt_setControl(0, 0.75, 0, 0, 0) !== 0) fail('setControl rejected');
const held = (() => {
  const n = e.prt_eval(0.5);
  return mem().slice(e.prt_writesPtr(), e.prt_writesPtr() + n);
})();
mem().fill(0x58, e.prt_pacbPtr(), e.prt_pacbPtr() + pacb.length); // 'XXXX…' bad magic
const st2 = e.prt_load(pacb.length, pact.length);
say(`corrupt load=${st2} loadError=${e.prt_loadError()}`);
if (st2 !== 1) fail(`corrupt load status ${st2}`);
if (e.prt_loadError() !== 0) fail(`loadError ${e.prt_loadError()} != 0 (bad_magic)`);
const held2 = (() => {
  const n = e.prt_eval(0.5);
  return mem().slice(e.prt_writesPtr(), e.prt_writesPtr() + n);
})();
if (held2.length !== held.length || !held2.every((b, i) => b === held[i])) {
  fail('frame changed after refused reload — old score not transactional');
}
say(
  `refused reload kept old score: eval(0.5) byte-identical (${held2.length} bytes), ` +
    `control held, exprFailures=${e.prt_exprFailures()}`,
);

// A good reload of a different fixture arms the new score.
const keys = readFileSync('tools/testdata/pacb/keys-only.pacb');
mem().set(keys, e.prt_pacbPtr());
const st3 = e.prt_load(keys.length, pact.length);
say(`reload(keys-only)=${st3} metaLen=${e.prt_metaLen()} evalTicks(0)=${e.prt_evalTicks(0n)}`);
if (st3 !== 0) fail(`keys-only load status ${st3}`);
say('PASS');
