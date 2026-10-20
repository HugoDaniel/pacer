// The frozen-old-reader compat proof (binary05 Group 3, leg I3): the
// Group 0 artifacts — the pre-SNAM `pacer-rt.wasm` and the pre-SNAM
// `meta.js` copy — executed against the FRESHLY BUILT 'SNAM'-carrying
// bytes. Old reader on new bytes, actually run, not simulated:
//
//   (a) frozen old rt wasm loads the fresh fixture (TLV length-skip +
//       'TRAN' FNV + routing all pass on the old module), stays fully
//       live, and its served metadata decodes to exact names under the
//       NEW JS glue — the old wasm never needed name knowledge;
//   (b) the old wasm serves the 'PACM' copy VERBATIM (byte-identical to
//       what the new wasm serves), and the FROZEN old meta decoder
//       decodes those same bytes with the 'SNAM' section skipped by
//       length — names '' (the correct '' leg);
//   (c) 'SNAM'-present-empty precedence against a held non-empty source
//       slice (IM-3) — a present-but-empty entry is a true empty name;
//   (d) the frozen pre-SNAM scene-carrying fixture stays first-class on
//       the new runtime: source-free empty names, span preserved.
//
// The artifacts are host-local by design (`.agent/` is git-excluded; the
// big wasm is never committed — reproduce per
// `.agent/control/metadata-frozen-artifacts.md`). An absent artifact is
// an HONEST skip that prints its resolved path; when present, every leg
// here must actually PASS.

import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { decodeMeta } from '../src/meta.js';
import { encodeTargets } from '../src/pact.js';
import { PacerRt } from '../src/rt.js';

const oldWasmPath = fileURLToPath(
  new URL('../../../.agent/artifacts/pacer-rt-pre-SNAM.wasm', import.meta.url),
);
const oldMetaPath = fileURLToPath(
  new URL('../../../.agent/artifacts/meta-pre-SNAM.mjs', import.meta.url),
);
const newWasmPath = fileURLToPath(new URL('../../../zig-out/bin/pacer-rt.wasm', import.meta.url));
const fixture = readFileSync(fileURLToPath(new URL('./rt-fixture.pacb', import.meta.url)));
// The frozen pre-SNAM scene carrier (frozen forever, tools/testdata).
const legacyFixture = readFileSync(
  fileURLToPath(new URL('../../../tools/testdata/pacb/full-small.pacb', import.meta.url)),
);

const oldWasmModule = existsSync(oldWasmPath)
  ? new WebAssembly.Module(readFileSync(oldWasmPath))
  : null;
const oldDecodeMeta = existsSync(oldMetaPath)
  ? (await import(pathToFileURL(oldMetaPath).href)).decodeMeta
  : null;
const newWasmModule = new WebAssembly.Module(readFileSync(newWasmPath));

const IMPORTS = { env: { sjon_host_invoke_plugin: () => 0 } };
const BEAT = 720720n / 4n; // the PPC tick grid, 4/4 meter

/** A raw instance + the rt.js load sequence, for served-byte access. */
async function rawLoaded(wasmModule, pacb) {
  // A WebAssembly.Module instantiates to the Instance directly (the
  // overload rt.js branches on); there is no `.instance` wrapper.
  const instance = await WebAssembly.instantiate(wasmModule, IMPORTS);
  const e = instance.exports;
  const targets = encodeTargets([]);
  new Uint8Array(e.memory.buffer).set(targets, e.prt_targetsPtr());
  new Uint8Array(e.memory.buffer).set(pacb, e.prt_pacbPtr());
  assert.equal(e.prt_load(pacb.length, targets.length), 0);
  return instance;
}

function servedMeta(instance) {
  const e = instance.exports;
  const len = e.prt_metaLen();
  assert.ok(len > 0);
  return new Uint8Array(e.memory.buffer).slice(e.prt_metaPtr(), e.prt_metaPtr() + len);
}

test('frozen old rt wasm runs fresh SNAM bytes: load ok, live, exact names via the new JS glue', async (t) => {
  if (!oldWasmModule) {
    return t.skip(`frozen artifact absent: ${oldWasmPath}`);
  }
  const oldRt = await PacerRt.load(oldWasmModule, fixture);
  assert.equal(oldRt.ok, true);
  assert.equal(oldRt.status, 0);
  // The old module skipped the unknown section by length and everything
  // else — transport, tempo, ease, writes — behaves exactly as before.
  assert.equal(oldRt.meta.scenes.length, 1);
  assert.equal(oldRt.meta.scenes[0].startTick, 8n * BEAT);
  // Names decode EXACT under the new glue (rt.js imports the post-G3
  // meta.js; the old wasm never needed to know 'SNAM' existed).
  assert.equal(oldRt.meta.scenes[0].name, 'drop');
  assert.deepEqual(oldRt.meta.scenes[0].nameSpan, { start: 1335, end: 1339 });
  // The old artifact is fully live on the new bytes: the evalBytes pin.
  assert.equal(oldRt.evalBytes(0.5)?.length, 152);

  // Eval outputs identical, old artifact vs fresh artifact.
  const newRt = await PacerRt.load(newWasmModule, fixture);
  for (const seconds of [0, 0.125, 0.5, 1, 4, -2.5, 60]) {
    assert.deepEqual(oldRt.evalBytes(seconds), newRt.evalBytes(seconds), `t=${seconds}`);
  }
  assert.deepEqual(oldRt.meta, newRt.meta);
});

test('the old wasm serves PACM verbatim and the frozen old decoder yields empty names', async (t) => {
  if (!oldWasmModule || !oldDecodeMeta) {
    return t.skip(`frozen artifacts absent: ${oldWasmPath} / ${oldMetaPath}`);
  }
  // OP-4 provenance: the PACM bytes come from the old wasm's own
  // prt_metaPtr/prt_metaLen — no hand PACB-directory parse in JS.
  const oldServed = servedMeta(await rawLoaded(oldWasmModule, fixture));
  const newServed = servedMeta(await rawLoaded(newWasmModule, fixture));
  // The old module serves the blob verbatim — byte-identical to the new.
  assert.deepEqual(newServed, oldServed);

  // The FROZEN old decoder on those served bytes: sections decode, the
  // unknown 'SNAM' is skipped by length, names decode '' from the empty
  // doc bytes — the correct '' leg (old decoder, old behavior).
  const oldView = oldDecodeMeta(
    oldServed.buffer,
    0,
    oldServed.length,
    new Uint8Array(0),
    () => null,
  );
  assert.equal(oldView.scenes.length, 1);
  assert.equal(oldView.scenes[0].name, '');
  assert.deepEqual(oldView.scenes[0].nameSpan, { start: 1335, end: 1339 });
  assert.deepEqual(oldView.tempoMap, [
    { tick: 0n, bpm: 120 },
    { tick: 8n * BEAT, bpm: 160 },
  ]);
  // The NEW decoder over the SAME served bytes reads the name exactly —
  // one blob, two decoder generations, both behaving per contract.
  const newView = decodeMeta(oldServed.buffer, 0, oldServed.length, new Uint8Array(0), () => null);
  assert.equal(newView.scenes[0].name, 'drop');
});

test('SNAM-present-empty precedence through the runtime decoder (IM-3, mandatory)', () => {
  // Hand-built blob: one 'SCEN' record whose nameSpan covers non-empty
  // source text, then a 'SNAM' section present with ONE empty entry.
  // Presence keys the decode: the span must NOT shine through a falsy
  // `snamName || sourceSlice` fallback — the name is truly ''.
  const scen = new Uint8Array(4 + 24);
  const sv = new DataView(scen.buffer);
  sv.setUint32(0, 1, true);
  sv.setBigInt64(4, 0n, true);
  sv.setBigInt64(12, 0n, true);
  sv.setUint32(20, 4, true); // nameSpan [4, 8) — non-empty slice ahead
  sv.setUint32(24, 8, true);
  const snam = new Uint8Array(4 + 4);
  const nv = new DataView(snam.buffer);
  nv.setUint32(0, 1, true); // count 1
  nv.setUint32(4, 0, true); // name_len 0 — present and EMPTY
  const frames = [
    { id: 0x4e454353, payload: scen },
    { id: 0x4d414e53, payload: snam },
  ];
  const total = 40 + frames.reduce((n, f) => n + 8 + f.payload.length, 0);
  const buf = new ArrayBuffer(total);
  const dv = new DataView(buf);
  dv.setUint32(0, 0x4d434150, true);
  dv.setUint32(4, 1, true);
  dv.setFloat64(8, 120, true);
  dv.setBigInt64(16, 0n, true);
  dv.setUint16(24, 4, true);
  dv.setUint8(26, 0);
  dv.setUint32(28, 0, true);
  dv.setUint32(32, 0, true);
  dv.setUint32(36, 0, true);
  let off = 40;
  for (const f of frames) {
    dv.setUint32(off, f.id, true);
    dv.setUint32(off + 4, f.payload.length, true);
    new Uint8Array(buf, off + 8, f.payload.length).set(f.payload);
    off += 8 + f.payload.length;
  }
  const docBytes = new TextEncoder().encode('12345678'); // span [4,8) = '5678'
  const meta = decodeMeta(buf, 0, buf.byteLength, docBytes, () => null);
  assert.equal(meta.scenes.length, 1);
  assert.equal(meta.scenes[0].name, '');
  assert.deepEqual(meta.scenes[0].nameSpan, { start: 4, end: 8 });
});

test('legacy pre-SNAM fixtures stay first-class: source-free empty names on the new runtime', async () => {
  // The frozen forever full-small cartridge carries scenes but no
  // 'SNAM': the C6 fallback holds the span and reports '' — the old
  // fixture class is a first-class citizen, not a legacy tolerated case.
  const rt = await PacerRt.load(newWasmModule, legacyFixture);
  assert.equal(rt.ok, true);
  assert.equal(rt.status, 0);
  assert.equal(rt.meta.scenes.length, 1);
  assert.equal(rt.meta.scenes[0].name, '');
  assert.deepEqual(rt.meta.scenes[0].nameSpan, { start: 1335, end: 1339 });
});
