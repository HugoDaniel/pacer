// The 'SNAM' scene-name section, decoded by the shared meta.js leaf —
// unit level, hand-built blobs, no wasm. The JS decoder must hold the
// SAME strict contracts the Zig decoders pinned in Group 2
// (src/Pacm.zig / src/Abi.zig): one 'SNAM', only after 'SCEN', count
// parallel to the scene records, per-entry u32 lengths bounded against
// what remains, entries accounting for the payload exactly. Every 'SNAM'
// refusal is a TypeError thrown by a bounds check BEFORE the offending
// read — no malformed 'SNAM' section surfaces as a surprise DataView
// RangeError. (Scope note: that guarantee is the SNAM arm's. The generic
// TLV walk's 8-byte section-header read predates SNAM and keeps its
// pre-existing behavior — a blob ending mid-header of ANY id can still
// throw a RangeError, which is why served blobs are wasm-validated
// before this decoder ever sees them.)

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { decodeMeta } from '../src/meta.js';

const PACM_MAGIC = 0x4d434150; // 'PACM' read little-endian
const SCEN_ID = 0x4e454353; // 'SCEN' read little-endian
const SNAM_ID = 0x4d414e53; // 'SNAM' read little-endian
const PACM_HEADER_LEN = 40;
const SCENE_REC_LEN = 24;

const utf8 = (s) => new TextEncoder().encode(s);

/** One 'SCEN' section: [count u32] + count × 24-byte scene records. */
function scenSection(records) {
  const payload = new Uint8Array(4 + records.length * SCENE_REC_LEN);
  const dv = new DataView(payload.buffer);
  dv.setUint32(0, records.length, true);
  records.forEach((r, i) => {
    const o = 4 + i * SCENE_REC_LEN;
    dv.setBigInt64(o, r.startTick ?? 0n, true);
    dv.setBigInt64(o + 8, r.durTicks ?? 0n, true);
    dv.setUint32(o + 16, r.nameSpan?.[0] ?? 0, true);
    dv.setUint32(o + 20, r.nameSpan?.[1] ?? 0, true);
  });
  return { id: SCEN_ID, payload };
}

/** One well-formed 'SNAM' section from raw name byte-strings. */
function snamSection(names) {
  return { id: SNAM_ID, payload: snamPayload(names) };
}

/** 'SNAM' payload bytes: [count u32] + count × [name_len u32][name bytes]. */
function snamPayload(names) {
  const body = 4 + names.reduce((n, b) => n + 4 + b.length, 0);
  const payload = new Uint8Array(body);
  const dv = new DataView(payload.buffer);
  dv.setUint32(0, names.length, true);
  let o = 4;
  for (const b of names) {
    dv.setUint32(o, b.length, true);
    payload.set(b, o + 4);
    o += 4 + b.length;
  }
  return payload;
}

/** A minimal 'PACM' blob: empty header + the given sections in order. */
function pacmBlob(frames) {
  const total = PACM_HEADER_LEN + frames.reduce((n, f) => n + 8 + f.payload.length, 0);
  const buf = new ArrayBuffer(total);
  const dv = new DataView(buf);
  dv.setUint32(0, PACM_MAGIC, true);
  dv.setUint32(4, 1, true);
  dv.setFloat64(8, 120, true);
  dv.setBigInt64(16, 0n, true);
  dv.setUint16(24, 4, true);
  dv.setUint8(26, 0);
  dv.setUint32(28, 0, true);
  dv.setUint32(32, 0, true);
  dv.setUint32(36, 0, true);
  let off = PACM_HEADER_LEN;
  for (const f of frames) {
    dv.setUint32(off, f.id, true);
    dv.setUint32(off + 4, f.payload.length, true);
    new Uint8Array(buf, off + 8, f.payload.length).set(f.payload);
    off += 8 + f.payload.length;
  }
  return buf;
}

const DOC = utf8('the score text around (scene :name drop) lives here');

function decode(buf, docBytes = DOC) {
  return decodeMeta(buf, 0, buf.byteLength, docBytes, () => null);
}

test('SNAM present: scene names decode from the blob, exactly and verbatim', () => {
  // The blob name deliberately differs from the span text so the
  // assertion can only pass if the name came from 'SNAM'.
  const blob = pacmBlob([
    scenSection([{ nameSpan: [35, 39] }]),
    snamSection([utf8('ünïcod drop')]),
  ]);
  const meta = decode(blob);
  assert.equal(meta.scenes.length, 1);
  assert.equal(meta.scenes[0].name, 'ünïcod drop');
  // nameSpan keeps its provenance: the commit anchor is untouched.
  assert.deepEqual(meta.scenes[0].nameSpan, { start: 35, end: 39 });
});

test('SNAM-present-empty: a name_len of 0 is a true empty name, never the span fallback (IM-3)', () => {
  // 'SNAM' is present with one empty entry while the held source slice
  // is non-empty: presence keys the decode — the span must NOT shine
  // through a falsy `snamName || sourceSlice` fallback.
  const blob = pacmBlob([scenSection([{ nameSpan: [35, 39] }]), snamSection([new Uint8Array(0)])]);
  const meta = decode(blob);
  assert.equal(meta.scenes[0].name, '');
  assert.deepEqual(meta.scenes[0].nameSpan, { start: 35, end: 39 });
});

test('SNAM absent: the nameSpan fallback over the held source is preserved', () => {
  // Existing back-compat pin (green from birth, like the Zig Group 2
  // pin-blob test): a pre-SNAM blob decodes names from the source span.
  const blob = pacmBlob([scenSection([{ nameSpan: [35, 39] }])]);
  const meta = decode(blob);
  assert.equal(meta.scenes[0].name, 'drop');
});

test('duplicate SNAM sections are refused with a TypeError', () => {
  const blob = pacmBlob([
    scenSection([{ nameSpan: [35, 39] }]),
    snamSection([utf8('drop')]),
    snamSection([utf8('again')]),
  ]);
  assert.throws(() => decode(blob), TypeError);
});

test('SNAM before SCEN is refused with a TypeError', () => {
  const blob = pacmBlob([snamSection([utf8('drop')]), scenSection([{ nameSpan: [35, 39] }])]);
  assert.throws(() => decode(blob), TypeError);
});

test('SNAM without any SCEN section is refused with a TypeError', () => {
  const blob = pacmBlob([snamSection([utf8('drop')])]);
  assert.throws(() => decode(blob), TypeError);
});

test('SNAM count disagreeing with the SCEN count is refused with a TypeError', () => {
  // Well-formed entries both sides — only the count rule may refuse.
  const blob = pacmBlob([
    scenSection([{ nameSpan: [35, 39] }]),
    snamSection([utf8('drop'), utf8('extra')]),
  ]);
  assert.throws(() => decode(blob), TypeError);
});

test('a SNAM name_len overrunning the section payload is refused with a TypeError', () => {
  // Hand-splice: count 1, name_len 64, only 4 name bytes present.
  const payload = new Uint8Array(4 + 4 + 4);
  const dv = new DataView(payload.buffer);
  dv.setUint32(0, 1, true);
  dv.setUint32(4, 64, true);
  payload.set(utf8('drop'), 8);
  const blob = pacmBlob([scenSection([{ nameSpan: [35, 39] }]), { id: SNAM_ID, payload }]);
  assert.throws(() => decode(blob), TypeError);
});

test('a u32-max name_len is refused by compare-before-add, never by wrapping', () => {
  const payload = new Uint8Array(12);
  const dv = new DataView(payload.buffer);
  dv.setUint32(0, 1, true);
  dv.setUint32(4, 0xffffffff, true);
  const blob = pacmBlob([scenSection([{ nameSpan: [35, 39] }]), { id: SNAM_ID, payload }]);
  assert.throws(() => decode(blob), TypeError);
});

test('SNAM trailing slack (payload not fully accounted for) is refused with a TypeError', () => {
  const names = snamPayload([utf8('drop')]);
  const payload = new Uint8Array(names.length + 1);
  payload.set(names);
  const blob = pacmBlob([scenSection([{ nameSpan: [35, 39] }]), { id: SNAM_ID, payload }]);
  assert.throws(() => decode(blob), TypeError);
});

test('a SNAM payload too short for the count field is refused with a TypeError', () => {
  const blob = pacmBlob([
    scenSection([{ nameSpan: [35, 39] }]),
    { id: SNAM_ID, payload: new Uint8Array(2) },
  ]);
  assert.throws(() => decode(blob), TypeError);
});

test('a SNAM frame whose payload overruns the blob is refused with a TypeError, bounded', () => {
  // The 8-byte section header is in bounds but claims more payload than
  // the blob holds: the bounds check must throw BEFORE any DataView
  // read can surface a RangeError.
  const frames = [scenSection([{ nameSpan: [35, 39] }])];
  const headTotal = PACM_HEADER_LEN + frames.reduce((n, f) => n + 8 + f.payload.length, 0);
  const buf = new ArrayBuffer(headTotal + 8); // SNAM header, no payload
  const dv = new DataView(buf);
  dv.setUint32(0, PACM_MAGIC, true);
  dv.setUint32(4, 1, true);
  dv.setFloat64(8, 120, true);
  dv.setBigInt64(16, 0n, true);
  dv.setUint16(24, 4, true);
  dv.setUint8(26, 0);
  dv.setUint32(28, 0, true);
  dv.setUint32(32, 0, true);
  dv.setUint32(36, 0, true);
  let off = PACM_HEADER_LEN;
  for (const f of frames) {
    dv.setUint32(off, f.id, true);
    dv.setUint32(off + 4, f.payload.length, true);
    new Uint8Array(buf, off + 8, f.payload.length).set(f.payload);
    off += 8 + f.payload.length;
  }
  dv.setUint32(off, SNAM_ID, true);
  dv.setUint32(off + 4, 100, true);
  assert.throws(() => decode(buf), TypeError);
});
