// pacer — JS glue around pacer.wasm.
//
// The driver is a pure function of time: write a score + the target
// registries in, call `eval(seconds)` per frame, read packed writes
// back. This file mirrors the three wire formats pinned on the Zig
// side (src/Abi.zig, src/Writes.zig) byte for byte:
//
//   'PACT' (in)  — flattened target-registry join list
//   'PACD' (out) — load diagnostics, spans in USER source coordinates
//   'PACW' (out) — per-frame write entries (20 bytes each)
//   'PACM' (out) — score metadata: transport, tracks (key ticks +
//                  spans), controls — the editor's timeline anchors
//
// Hot-path discipline: `eval` allocates nothing after warm-up — entry
// objects and their Float32Array values are reused frame to frame, and
// memory views are re-taken from `exports.memory.buffer` every call
// (the buffer detaches when WASM memory grows; never cache views).

const PACT_MAGIC = 0x54434150;
const PACD_MAGIC = 0x44434150;
const PACD_VERSION = 1;
const PACW_MAGIC = 0x57434150;
const PACW_VERSION = 1;
const PACW_HEADER_LEN = 12;
const PACW_ENTRY_LEN = 20;
const PACD_HEADER_LEN = 12;
const PACD_RECORD_LEN = 16;
const PACM_MAGIC = 0x4d434150;
const PACM_VERSION = 1;
const PACM_HEADER_LEN = 40;
const PACM_TRACK_LEN = 24;
const PACM_KEY_LEN = 32;
const PACM_CONTROL_LEN = 64;
const PACM_NO_TARGET = 0xffff;
const NO_SLOT = 0xffffffff;
const CONTROL_TYPES = ['slider', 'xy', 'color'];

const LOAD_OK = 0;
const LOAD_DIAGNOSTICS = 1;

// sjon.wasm's executable-plugin dispatch import. Pacer scores never
// declare `:impl "wasm:…"` plugins, so this is never called for a
// valid score; returning null (0) maps to a clean PluginFuncAllocFailed
// diagnostic on the Zig side rather than a trap.
const IMPORTS = { env: { sjon_host_invoke_plugin: () => 0 } };

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export class Pacer {
  /**
   * Instantiate pacer.wasm and compile a score against the host's
   * ordered registry list.
   *
   * @param {BufferSource | WebAssembly.Module} wasmSource
   * @param {string} docText - the SJON score
   * @param {{ registries: Array<Array<{name: string, ncomp?: number}>> }} opts
   *   `registries[0]` is conventionally the visual bus (pngine uniform
   *   names), `registries[1]` the audio bus; the index rides into each
   *   write entry's `registry` field for routing.
   * @returns {Promise<Pacer>} loaded driver; check `.ok` / `.diagnostics`.
   */
  static async load(wasmSource, docText, { registries }) {
    const instance =
      wasmSource instanceof WebAssembly.Module
        ? await WebAssembly.instantiate(wasmSource, IMPORTS)
        : (await WebAssembly.instantiate(wasmSource, IMPORTS)).instance;
    const driver = new Pacer(instance, registries);
    driver.reload(docText);
    return driver;
  }

  /** @param {WebAssembly.Instance} instance */
  constructor(instance, registries) {
    this._exports = instance.exports;
    if (this._exports.drv_abiVersion() !== 1) {
      throw new Error(`pacer: unsupported ABI version ${this._exports.drv_abiVersion()}`);
    }
    // Flatten the ordered registries; the flat index IS the target_id.
    this._flat = registries.flatMap((targets, registry) =>
      targets.map(({ name, ncomp = 1 }) => ({ name, ncomp, registry })),
    );
    this._targetsBlob = encodeTargets(this._flat);
    /** @type {boolean} table live, eval armed */
    this.ok = false;
    /** Diagnostics from the last (re)load, decoded from 'PACD'. */
    this.diagnostics = [];
    this._entries = [];
    this._meta = null;
  }

  /**
   * (Re)compile a score against the registries given at load. Safe at
   * any time; on failure `ok` is false, `diagnostics` carries spans in
   * the score's own coordinates, and `eval` returns null. ALL control
   * state (held values, dynamic slots) is torn down — re-apply held
   * widgets after a reload.
   */
  reload(docText) {
    const e = this._exports;
    const doc = encoder.encode(docText);
    if (doc.length > e.drv_docCap()) {
      throw new Error(`pacer: score exceeds ${e.drv_docCap()} bytes`);
    }
    new Uint8Array(e.memory.buffer).set(this._targetsBlob, e.drv_targetsPtr());
    new Uint8Array(e.memory.buffer).set(doc, e.drv_docPtr());
    const status = e.drv_load(doc.length, this._targetsBlob.length);
    this.diagnostics = this._readDiags();
    this.ok = status === LOAD_OK;
    this._meta = null;
    if (status !== LOAD_OK && status !== LOAD_DIAGNOSTICS) {
      throw new Error(`pacer: load failed with status ${status} (glue bug or OOM)`);
    }
    return { ok: this.ok, diagnostics: this.diagnostics };
  }

  /**
   * Score metadata ('PACM'), decoded lazily and cached until the next
   * reload: `{ transport, tracks, controls }` with key ticks (BigInt)
   * and spans in the score's own coordinates — a control's `valueSpan`
   * is the commit-to-text anchor for its widget. Null when not loaded.
   *
   * Spans (like diagnostic spans) are BYTE offsets into the UTF-8
   * score; they equal string indices only while the score is ASCII —
   * editors with non-ASCII text must map through a byte index.
   */
  get meta() {
    if (this._meta) return this._meta;
    const e = this._exports;
    const len = e.drv_metaLen();
    if (len === 0) return null;
    const dv = new DataView(e.memory.buffer, e.drv_metaPtr(), len);
    if (dv.getUint32(0, true) !== PACM_MAGIC || dv.getUint32(4, true) !== PACM_VERSION) {
      throw new Error('pacer: corrupt meta buffer');
    }
    const bytes = new Uint8Array(e.memory.buffer, e.drv_metaPtr(), len);
    const lanes = (base) => {
      const a = [];
      for (let c = 0; c < 4; c++) a.push(dv.getFloat32(base + c * 4, true));
      return a;
    };

    const flags = dv.getUint8(26);
    const transport = {
      bpm: dv.getFloat64(8, true),
      beatsPerBar: dv.getUint16(24, true),
      dur: flags & 1 ? dv.getBigInt64(16, true) : null,
      end: flags & 2 ? 'loop' : 'hold',
    };
    const trackCount = dv.getUint32(28, true);
    const keyCount = dv.getUint32(32, true);
    const controlCount = dv.getUint32(36, true);

    let off = PACM_HEADER_LEN;
    const rawTracks = [];
    for (let i = 0; i < trackCount; i++, off += PACM_TRACK_LEN) {
      rawTracks.push({
        targetId: dv.getUint16(off, true),
        registry: dv.getUint8(off + 2),
        ncomp: dv.getUint8(off + 3),
        source: dv.getUint8(off + 4) === 0 ? 'keys' : 'expr',
        keyStart: dv.getUint32(off + 8, true),
        keyLen: dv.getUint32(off + 12, true),
        span: { start: dv.getUint32(off + 16, true), end: dv.getUint32(off + 20, true) },
      });
    }
    const keys = [];
    for (let i = 0; i < keyCount; i++, off += PACM_KEY_LEN) {
      keys.push({
        at: dv.getBigInt64(off, true),
        value: lanes(off + 8),
        span: { start: dv.getUint32(off + 24, true), end: dv.getUint32(off + 28, true) },
      });
    }
    const controls = [];
    for (let i = 0; i < controlCount; i++) {
      const targetId = dv.getUint16(off, true);
      const cflags = dv.getUint8(off + 5);
      const idLen = dv.getUint16(off + 6, true);
      controls.push({
        index: i,
        id: decoder.decode(bytes.subarray(off + PACM_CONTROL_LEN, off + PACM_CONTROL_LEN + idLen)),
        targetId: targetId === PACM_NO_TARGET ? null : targetId,
        name: targetId === PACM_NO_TARGET ? null : this._flat[targetId].name,
        registry: dv.getUint8(off + 2),
        ncomp: dv.getUint8(off + 3),
        type: CONTROL_TYPES[dv.getUint8(off + 4)] ?? 'slider',
        value: lanes(off + 8),
        min: cflags & 1 ? lanes(off + 24) : null,
        max: cflags & 2 ? lanes(off + 40) : null,
        valueSpan: { start: dv.getUint32(off + 56, true), end: dv.getUint32(off + 60, true) },
      });
      off += PACM_CONTROL_LEN + idLen;
    }

    this._meta = {
      transport,
      tracks: rawTracks.map((t) => ({
        targetId: t.targetId,
        name: this._flat[t.targetId].name,
        registry: t.registry,
        ncomp: t.ncomp,
        source: t.source,
        span: t.span,
        keys: keys.slice(t.keyStart, t.keyStart + t.keyLen),
      })),
      controls,
    };
    return this._meta;
  }

  /**
   * Hold a live control value (a widget drag): replaces the document's
   * :value — for writes AND expression bindings — until `clearControl`.
   * `ref` is a control id or slot index; `value` a number or up-to-4
   * array. False when rejected (bad slot, non-finite component).
   */
  setControl(ref, value) {
    const [x = 0, y = 0, z = 0, w = 0] = typeof value === 'number' ? [value] : value;
    return this._exports.drv_setControl(this._controlSlot(ref), x, y, z, w) === 0;
  }

  /** Return authority to the document (or silence a dynamic slot). */
  clearControl(ref) {
    return this._exports.drv_clearControl(this._controlSlot(ref)) === 0;
  }

  /**
   * Register a dynamic control slot for a target with no (control …)
   * pin in the text (editor lifts). Returns the slot index for
   * `setControl`/`clearControl`, or null. Dynamic slots write only
   * while held and never enter the expression environment.
   */
  registerControl(targetName) {
    const targetId = this._flat.findIndex((t) => t.name === targetName);
    if (targetId < 0) return null;
    const { registry, ncomp } = this._flat[targetId];
    const slot = this._exports.drv_registerControl(targetId, registry, ncomp);
    return slot === NO_SLOT ? null : slot;
  }

  /**
   * Live tempo nudge: rescales the seconds↔ticks projection; musical
   * (tick) positions stand still. False outside 1..1000 bpm.
   */
  setBpm(bpm) {
    return this._exports.drv_setBpm(bpm) === 0;
  }

  _controlSlot(ref) {
    if (typeof ref === 'number') return ref;
    const ctl = this.meta?.controls.find((c) => c.id === ref);
    if (!ctl) throw new Error(`pacer: unknown control \`${ref}\``);
    return ctl.index;
  }

  /**
   * The frame path: master-clock seconds in, write entries out.
   * Returns null when not loaded or the clock is out of range. The
   * returned array and its entries are reused — consume before the
   * next eval, copy if you must keep them.
   */
  eval(seconds) {
    return this._decodeWrites(this._exports.drv_eval(seconds));
  }

  /** Tick-domain twin (tests, corpus tooling). Takes a BigInt. */
  evalTicks(tick) {
    return this._decodeWrites(this._exports.drv_evalTicks(BigInt(tick)));
  }

  /**
   * Like `eval` but returns a copy of the raw 'PACW' bytes — the unit
   * of the determinism claim (corpus tooling compares these).
   */
  evalBytes(seconds) {
    const len = this._exports.drv_eval(seconds);
    if (len === 0) return null;
    const e = this._exports;
    return new Uint8Array(e.memory.buffer, e.drv_writesPtr(), len).slice();
  }

  _decodeWrites(len) {
    if (len === 0) return null;
    const e = this._exports;
    const dv = new DataView(e.memory.buffer, e.drv_writesPtr(), len);
    if (dv.getUint32(0, true) !== PACW_MAGIC || dv.getUint32(4, true) !== PACW_VERSION) {
      throw new Error('pacer: corrupt write buffer');
    }
    const count = dv.getUint32(8, true);
    while (this._entries.length < count) {
      this._entries.push({ name: '', targetId: 0, registry: 0, ncomp: 0, value: new Float32Array(4) });
    }
    this._entries.length = count;
    for (let i = 0; i < count; i++) {
      const off = PACW_HEADER_LEN + i * PACW_ENTRY_LEN;
      const entry = this._entries[i];
      entry.targetId = dv.getUint16(off, true);
      entry.registry = dv.getUint8(off + 2);
      entry.ncomp = dv.getUint8(off + 3);
      entry.name = this._flat[entry.targetId].name;
      for (let c = 0; c < 4; c++) entry.value[c] = dv.getFloat32(off + 4 + c * 4, true);
    }
    return this._entries;
  }

  _readDiags() {
    const e = this._exports;
    const len = e.drv_diagLen();
    const dv = new DataView(e.memory.buffer, e.drv_diagPtr(), len);
    if (dv.getUint32(0, true) !== PACD_MAGIC || dv.getUint32(4, true) !== PACD_VERSION) {
      throw new Error('pacer: corrupt diagnostics buffer');
    }
    const count = dv.getUint32(8, true);
    const bytes = new Uint8Array(e.memory.buffer, e.drv_diagPtr(), len);
    const diags = [];
    let off = PACD_HEADER_LEN;
    for (let i = 0; i < count; i++) {
      const msgLen = dv.getUint32(off + 12, true);
      diags.push({
        source: dv.getUint8(off) === 0 ? 'sjon' : 'pacer',
        severity: dv.getUint8(off + 1) === 0 ? 'error' : 'warning',
        code: dv.getUint16(off + 2, true),
        start: dv.getUint32(off + 4, true),
        end: dv.getUint32(off + 8, true),
        message: decoder.decode(bytes.subarray(off + PACD_RECORD_LEN, off + PACD_RECORD_LEN + msgLen)),
      });
      off += PACD_RECORD_LEN + msgLen;
    }
    return diags;
  }
}

/** Encode the flattened target list as a 'PACT' blob. */
function encodeTargets(flat) {
  const names = flat.map((t) => encoder.encode(t.name));
  let len = 8;
  for (const n of names) len += 4 + n.length;
  const blob = new Uint8Array(len);
  const dv = new DataView(blob.buffer);
  dv.setUint32(0, PACT_MAGIC, true);
  dv.setUint32(4, flat.length, true);
  let pos = 8;
  flat.forEach((t, i) => {
    if (t.ncomp < 1 || t.ncomp > 4) throw new Error(`pacer: target ${t.name} has ncomp ${t.ncomp}`);
    blob[pos] = t.ncomp;
    blob[pos + 1] = t.registry;
    dv.setUint16(pos + 2, names[i].length, true);
    pos += 4;
    blob.set(names[i], pos);
    pos += names[i].length;
  });
  return blob;
}
