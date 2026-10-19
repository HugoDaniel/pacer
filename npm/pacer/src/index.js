// pacer — JS glue around pacer.wasm.
//
// The driver is a pure function of time: write a score + the target
// registries in, call `eval(seconds)` per frame, read packed writes
// back. This file mirrors the four wire formats pinned on the Zig
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
//
// The canonical 'PACT' encoder and the 'PACM' decode half are shared
// leaves (pact.js / meta.js, 02 T3.1) — the playback runtime's glue
// imports the same code; behavior here is unchanged.

import { decodeMeta } from './meta.js';
import { encodeTargets } from './pact.js';

const PACD_MAGIC = 0x44434150;
const PACD_VERSION = 1;
const PACW_MAGIC = 0x57434150;
const PACW_VERSION = 1;
const PACW_HEADER_LEN = 12;
const PACW_ENTRY_LEN = 20;
const PACD_HEADER_LEN = 12;
const PACD_RECORD_LEN = 16;
const NO_SLOT = 0xffffffff;

const LOAD_OK = 0;
const LOAD_DIAGNOSTICS = 1;

// sjon.wasm's executable-plugin dispatch import. Pacer scores never
// declare `:impl "wasm:…"` plugins, so this is never called for a
// valid score; returning null (0) maps to a clean PluginFuncAllocFailed
// diagnostic on the Zig side rather than a trap.
const IMPORTS = { env: { sjon_host_invoke_plugin: () => 0 } };

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** @typedef {import('./types.js').Registries} Registries */
/** @typedef {import('./types.js').TargetSpec} TargetSpec */
/** @typedef {import('./types.js').WriteEntry} WriteEntry */
/** @typedef {import('./types.js').Diagnostic} Diagnostic */
/** @typedef {import('./types.js').LoadResult} LoadResult */
/** @typedef {import('./types.js').Meta} Meta */
/** @typedef {import('./types.js').Span} Span */
/** @typedef {import('./types.js').ControlRef} ControlRef */
/** @typedef {import('./types.js').ControlValue} ControlValue */
/** @typedef {import('./types.js').PacerExports} PacerExports */

export class Pacer {
  /** @type {PacerExports} The pinned drv_* ABI surface. */
  #exports;
  /**
   * Flattened registries; the flat index IS the target_id.
   * @type {import('./types.js').FlatTarget[]}
   */
  #flat;
  /** @type {Uint8Array} The encoded 'PACT' target blob. */
  #targetsBlob;
  /** @type {WriteEntry[]} Reused frame to frame. */
  #entries = [];
  /** @type {Meta | null} Decoded 'PACM', cached until the next reload. */
  #meta = null;
  /**
   * The current score's UTF-8 bytes — the source for span slicing. Scene
   * names ride 'PACM' as spans (not inline bytes), so `meta` slices them
   * from here; meta spans are USER coordinates, matching these bytes.
   * @type {Uint8Array}
   */
  #docBytes = new Uint8Array(0);

  /** Table live, eval armed. @type {boolean} */
  ok = false;
  /**
   * Diagnostics from the last (re)load, decoded from 'PACD'.
   * @type {ReadonlyArray<Diagnostic>}
   */
  diagnostics = [];

  /**
   * Instantiate pacer.wasm and compile a score against the host's
   * ordered registry list.
   *
   * @param {BufferSource | WebAssembly.Module} wasmSource
   * @param {string} docText - the SJON score
   * @param {{ registries?: Registries }} [opts]
   *   `registries[0]` is conventionally the visual bus (pngine uniform
   *   names), `registries[1]` the audio bus; the index rides into each
   *   write entry's `registry` field for routing. Optional (defaults to
   *   `[]`): a compose-mode score declares its own targets with
   *   `(target …)` and loads standalone against no registries at all.
   * @returns {Promise<Pacer>} loaded driver; check `.ok` / `.diagnostics`.
   */
  static async load(wasmSource, docText, { registries = [] } = {}) {
    const instance =
      wasmSource instanceof WebAssembly.Module
        ? await WebAssembly.instantiate(wasmSource, IMPORTS)
        : (await WebAssembly.instantiate(wasmSource, IMPORTS)).instance;
    const driver = new Pacer(instance, registries);
    driver.reload(docText);
    return driver;
  }

  /**
   * @param {WebAssembly.Instance} instance
   * @param {Registries} registries
   */
  constructor(instance, registries) {
    // The wasm exports are untyped at the boundary; cast once to the
    // pinned `drv_*` ABI so every call site type-checks against it.
    this.#exports = /** @type {PacerExports} */ (/** @type {unknown} */ (instance.exports));
    if (this.#exports.drv_abiVersion() !== 1) {
      throw new Error(`pacer: unsupported ABI version ${this.#exports.drv_abiVersion()}`);
    }
    // Flatten the ordered registries; the flat index IS the target_id.
    this.#flat = registries.flatMap((targets, registry) =>
      targets.map(({ name, ncomp = 1 }) => ({ name, ncomp, registry })),
    );
    this.#targetsBlob = encodeTargets(this.#flat);
    // The blob is written verbatim into the fixed targets zone on every
    // reload; reject an over-cap blob here rather than let `reload` scribble
    // past the zone into wasm linear memory.
    const cap = this.#exports.drv_targetsCap();
    if (this.#targetsBlob.length > cap) {
      throw new Error(
        `pacer: targets blob is ${this.#targetsBlob.length} bytes, over drv_targetsCap (${cap})`,
      );
    }
  }

  /**
   * (Re)compile a score against the registries given at load. Safe at
   * any time; on failure `ok` is false, `diagnostics` carries spans in
   * the score's own coordinates, and `eval` returns null. ALL control
   * state (held values, dynamic slots) is torn down — re-apply held
   * widgets after a reload.
   *
   * @param {string} docText
   * @returns {LoadResult}
   */
  reload(docText) {
    const e = this.#exports;
    const doc = encoder.encode(docText);
    if (doc.length > e.drv_docCap()) {
      throw new Error(`pacer: score exceeds ${e.drv_docCap()} bytes`);
    }
    new Uint8Array(e.memory.buffer).set(this.#targetsBlob, e.drv_targetsPtr());
    new Uint8Array(e.memory.buffer).set(doc, e.drv_docPtr());
    this.#docBytes = doc;
    const status = e.drv_load(doc.length, this.#targetsBlob.length);
    this.diagnostics = this.#readDiags();
    this.ok = status === LOAD_OK;
    this.#meta = null;
    if (status !== LOAD_OK && status !== LOAD_DIAGNOSTICS) {
      throw new Error(`pacer: load failed with status ${status} (glue bug or OOM)`);
    }
    return { ok: this.ok, diagnostics: this.diagnostics };
  }

  /**
   * Score metadata ('PACM'), decoded lazily and cached until the next
   * reload: `{ transport, tracks, controls, scenes, easePrograms,
   * tempoMap }` with key ticks (BigInt) and spans in the score's own
   * coordinates — a control's `valueSpan` is the commit-to-text anchor
   * for its widget, and each scene's `nameSpan` anchors its `:name`.
   * `scenes` is `[]` when the score declares none; `tempoMap` is `[]`
   * for a constant-tempo score and otherwise lists the `(tempo …)`
   * segments INCLUDING segment 0 (the transport's own `:bpm` at tick 0).
   * Null when not loaded.
   *
   * Spans (like diagnostic spans) are BYTE offsets into the UTF-8
   * score; they equal string indices only while the score is ASCII —
   * editors with non-ASCII text must map through a byte index.
   *
   * `transport` mirrors the *document*: a live {@link Pacer#setBpm} nudge
   * does not re-encode it, so `transport.bpm` stays the score's tempo.
   *
   * @returns {Meta | null}
   */
  get meta() {
    if (this.#meta) return this.#meta;
    const e = this.#exports;
    const len = e.drv_metaLen();
    if (len === 0) return null;
    // The decode half is the shared leaf (meta.js); it builds its views
    // from the CURRENT memory buffer on every call — growth detaches
    // older buffers, so views are never cached across calls.
    this.#meta = decodeMeta(
      e.memory.buffer,
      e.drv_metaPtr(),
      len,
      this.#docBytes,
      (id) => this.#target(id).name,
    );
    return this.#meta;
  }

  /**
   * Hold a live control value (a widget drag): replaces the document's
   * :value — for writes AND expression bindings — until `clearControl`.
   * `ref` is a control id or slot index; `value` a number or up-to-4
   * array. False when rejected: unknown id, out-of-range slot, or a
   * non-finite component.
   *
   * @param {ControlRef} ref
   * @param {ControlValue} value
   * @returns {boolean}
   */
  setControl(ref, value) {
    const slot = this.#controlSlot(ref);
    if (slot === null) return false;
    const [x = 0, y = 0, z = 0, w = 0] = typeof value === 'number' ? [value] : value;
    return this.#exports.drv_setControl(slot, x, y, z, w) === 0;
  }

  /**
   * Return authority to the document (or silence a dynamic slot). False
   * when rejected: unknown id or out-of-range slot.
   * @param {ControlRef} ref
   * @returns {boolean}
   */
  clearControl(ref) {
    const slot = this.#controlSlot(ref);
    if (slot === null) return false;
    return this.#exports.drv_clearControl(slot) === 0;
  }

  /**
   * Register a dynamic control slot for a target with no (control …)
   * pin in the text (editor lifts). Returns the slot index for
   * `setControl`/`clearControl`, or null. Dynamic slots write only
   * while held and never enter the expression environment.
   *
   * @param {string} targetName
   * @returns {number | null}
   */
  registerControl(targetName) {
    const targetId = this.#flat.findIndex((t) => t.name === targetName);
    if (targetId < 0) return null;
    const { registry, ncomp } = this.#target(targetId);
    const slot = this.#exports.drv_registerControl(targetId, registry, ncomp);
    return slot === NO_SLOT ? null : slot;
  }

  /**
   * Live tempo nudge: rescales the seconds↔ticks projection; musical
   * (tick) positions stand still. False outside 1..1000 bpm, or on a
   * score with a `(tempo …)` map (its tempo truth is the score text).
   * Evaluator state like a held control: `reload` resets it.
   *
   * A nudge does NOT re-encode {@link Pacer#meta}: `meta.transport.bpm`
   * keeps reporting the *document* tempo (the score text is the
   * authority), so read this back from your own widget state, not meta.
   *
   * @param {number} bpm
   * @returns {boolean}
   */
  setBpm(bpm) {
    return this.#exports.drv_setBpm(bpm) === 0;
  }

  /**
   * Lifetime count of frames a track's write was omitted by a runtime
   * failure — an expr that raised or yielded the wrong shape, or a
   * pattern whose query refused or dropped its hap — since the last
   * (re)load (the counter predates pattern tracks; the wire-frozen name
   * stays). A debugging probe, not semantics. 0 while nothing is loaded;
   * resets every reload.
   *
   * @returns {number}
   */
  get exprFailures() {
    return this.#exports.drv_exprFailures();
  }

  /**
   * Resolve a control reference to its slot index, or null when it names
   * nothing — a slot index rides through unchanged (the wasm range-checks
   * it), an id resolves through the decoded meta.
   * @param {ControlRef} ref
   * @returns {number | null}
   */
  #controlSlot(ref) {
    if (typeof ref === 'number') return ref;
    const ctl = this.meta?.controls.find((c) => c.id === ref);
    return ctl ? ctl.index : null;
  }

  /**
   * The frame path: master-clock seconds in, write entries out.
   * Returns null when not loaded or the clock is out of range. The
   * returned array and its entries are reused — consume before the
   * next eval, copy if you must keep them.
   *
   * @param {number} seconds
   * @returns {WriteEntry[] | null}
   */
  eval(seconds) {
    return this.#decodeWrites(this.#exports.drv_eval(seconds));
  }

  /**
   * Tick-domain twin (tests, corpus tooling). Takes a BigInt.
   * @param {bigint | number} tick
   * @returns {WriteEntry[] | null}
   */
  evalTicks(tick) {
    return this.#decodeWrites(this.#exports.drv_evalTicks(BigInt(tick)));
  }

  /**
   * Like `eval` but returns a copy of the raw 'PACW' bytes — the unit
   * of the determinism claim (corpus tooling compares these).
   *
   * @param {number} seconds
   * @returns {Uint8Array | null}
   */
  evalBytes(seconds) {
    const len = this.#exports.drv_eval(seconds);
    if (len === 0) return null;
    const e = this.#exports;
    return new Uint8Array(e.memory.buffer, e.drv_writesPtr(), len).slice();
  }

  /**
   * Resolve a wasm-emitted `target_id` to its name. An id in
   * `0..#flat.length` is a host-registered target, so its name is known.
   * An id PAST the flat list is a compose-mode declared-only target: the
   * score declared it with `(target …)` but this host never registered it,
   * so the host has no name for it (declared names ride in the score
   * source, not on the wire). Such a write is the host's to ignore or
   * route by `registry`; we surface `name: null` rather than throw, so a
   * standalone or partially-hosted score doesn't crash the decode. The
   * `registry`/`ncomp` for these come from the write/track record itself,
   * never from this lookup.
   *
   * @param {number} targetId
   * @returns {{ name: string | null, ncomp: number, registry: number }}
   */
  #target(targetId) {
    return this.#flat[targetId] ?? { name: null, ncomp: 0, registry: 0 };
  }

  /**
   * @param {number} len
   * @returns {WriteEntry[] | null}
   */
  #decodeWrites(len) {
    if (len === 0) return null;
    const e = this.#exports;
    const dv = new DataView(e.memory.buffer, e.drv_writesPtr(), len);
    if (dv.getUint32(0, true) !== PACW_MAGIC || dv.getUint32(4, true) !== PACW_VERSION) {
      throw new Error('pacer: corrupt write buffer');
    }
    const count = dv.getUint32(8, true);
    const entries = this.#entries;
    for (let i = 0; i < count; i++) {
      const off = PACW_HEADER_LEN + i * PACW_ENTRY_LEN;
      // Grow (never shrink) the reused pool: a fresh slot is allocated
      // only while the frame's write count is still climbing, so the
      // steady state allocates nothing.
      let entry = entries[i];
      if (entry === undefined) {
        entry = { name: '', targetId: 0, registry: 0, ncomp: 0, value: new Float32Array(4) };
        entries.push(entry);
      }
      entry.targetId = dv.getUint16(off, true);
      // The 'PACW' flags byte is exactly the registry index today
      // (Writes.Entry reserves it for future bit-packing — any packing
      // bumps PACW_VERSION and this read together).
      entry.registry = dv.getUint8(off + 2);
      entry.ncomp = dv.getUint8(off + 3);
      entry.name = this.#target(entry.targetId).name;
      for (let c = 0; c < 4; c++) entry.value[c] = dv.getFloat32(off + 4 + c * 4, true);
    }
    entries.length = count;
    return entries;
  }

  /**
   * @returns {Diagnostic[]}
   */
  #readDiags() {
    const e = this.#exports;
    const len = e.drv_diagLen();
    // An empty zone means no load ever wrote it (a bad-call or OOM
    // status) — a written zone always carries at least the 12-byte
    // header. Let the caller report the status instead of tripping here.
    if (len === 0) return [];
    const dv = new DataView(e.memory.buffer, e.drv_diagPtr(), len);
    if (dv.getUint32(0, true) !== PACD_MAGIC || dv.getUint32(4, true) !== PACD_VERSION) {
      throw new Error('pacer: corrupt diagnostics buffer');
    }
    const count = dv.getUint32(8, true);
    const bytes = new Uint8Array(e.memory.buffer, e.drv_diagPtr(), len);
    /** @type {Diagnostic[]} */
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
        message: decoder.decode(
          bytes.subarray(off + PACD_RECORD_LEN, off + PACD_RECORD_LEN + msgLen),
        ),
      });
      off += PACD_RECORD_LEN + msgLen;
    }
    return diags;
  }
}
