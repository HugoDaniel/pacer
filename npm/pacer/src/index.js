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
  }

  /**
   * (Re)compile a score against the registries given at load. Safe at
   * any time; on failure `ok` is false, `diagnostics` carries spans in
   * the score's own coordinates, and `eval` returns null.
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
    if (status !== LOAD_OK && status !== LOAD_DIAGNOSTICS) {
      throw new Error(`pacer: load failed with status ${status} (glue bug or OOM)`);
    }
    return { ok: this.ok, diagnostics: this.diagnostics };
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
