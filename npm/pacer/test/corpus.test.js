// The wasm half of the determinism gate: walk corpus/<case>/, load each
// score into the real pacer.wasm, render the canonical golden text from
// its raw output blobs, and compare byte-equal against expected.sjon —
// the SAME golden the native runner (src/corpus_runner.zig) checks.
// Native green + this green ⇒ native and wasm32 produce identical
// 'PACW'/'PACD'/'PACM' bytes for every pinned (score, time, directive).
//
// The `(meta …)` block is rendered here from the DECODED `driver.meta`
// object (the native runner renders the SAME text from the encoded
// 'PACM' blob), so this pair gates the meta encoder AND the JS decoder.
// Script directives (set-control / clear-control / set-bpm /
// register-control) execute in document order and echo their acceptance.
//
// The canonical format is defined in src/corpus_runner.zig's header;
// regenerate goldens with `zig build corpus -- --update` (never here —
// the native rendering is the authority, this file only re-derives it).

import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { Pacer } from '../src/index.js';
import { parseHarness, renderCase } from './harness.js';

const corpusDir = fileURLToPath(new URL('../../../corpus/', import.meta.url));
const wasmPath = fileURLToPath(new URL('../../../zig-out/bin/pacer.wasm', import.meta.url));
const wasmModule = new WebAssembly.Module(readFileSync(wasmPath));

const cases = readdirSync(corpusDir, { withFileTypes: true })
  .filter((e) => e.isDirectory() && !e.name.startsWith('.'))
  .map((e) => e.name)
  .sort();
assert.ok(cases.length > 0, 'no corpus cases found');

for (const name of cases) {
  test(`corpus parity: ${name}`, async () => {
    const read = (file) => readFileSync(`${corpusDir}${name}/${file}`, 'utf8');
    const harness = parseHarness(read('times.sjon'));
    const doc = read('doc.sjon');
    const driver = await Pacer.load(wasmModule, doc, { registries: harness.registries });
    const actual = await renderCase(doc, harness, driver);
    assert.equal(actual, read('expected.sjon'));
  });
}
