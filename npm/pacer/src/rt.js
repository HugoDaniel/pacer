// pacer — JS glue around pacer-rt.wasm, the playback-only runtime
// (02 P3, T3.2).
//
// A `PacerRt` instance loads a compiled 'PACB' score packed offline by
// `pacer pack`; it never parses or compiles source text. The frame path
// is the same pure function of time as `Pacer`: `eval(seconds)` writes a
// packed 'PACW' buffer, and the caller reads it back through the SAME
// `route.js` / `lane.js` consumers. The canonical 'PACT' encoder and the
// 'PACM' decoder are the shared leaves (pact.js / meta.js) — one
// spelling of each, never a second implementation that can drift.
//
// Hot-path discipline (mirrors index.js): `eval` allocates nothing after
// warm-up, entry objects + their Float32Array values are reused, and
// views are re-taken from `exports.memory.buffer` on every call — never
// cached across a load (memory growth detaches older buffers).
//
// No `reload(text)` exists on the class BY DESIGN: the runtime has no
// parser and no text path. `load(pacbBytes)` is the only load verb; a
// refused load is transactional (the previously armed score, its held
// controls, bpm nudge, and failure counter stay live).

import { decodeMeta } from './meta.js';
import { encodeTargets } from './pact.js';

const PACW_MAGIC = 0x57434150;
const PACW_VERSION = 1;
const PACW_HEADER_LEN = 12;
const PACW_ENTRY_LEN = 20;
const NO_SLOT = 0xffffffff;

const LOAD_OK = 0;
const LOAD_REFUSED = 1;

// The one statically retained import (layer 2's frozen allowance). A
// valid packed score never reaches an executable plugin; if it somehow
// does, the null return maps to SJON's clean PluginFuncAllocFailed path
// rather than a trap.
const IMPORTS = { env: { sjon_host_invoke_plugin: () => 0 } };

// Binary scores carry no source text, but since the 'SNAM' section the
// scene NAMES ride the blob itself — `decodeMeta` reads them from the
// served 'PACM' exactly. `decodeMeta` slices source-derived values from
// this empty buffer only for the pre-'SNAM' FALLBACK: a blob without
// 'SNAM' (every old cartridge) decodes its scene names as '' — never a
// fabricated name and never a text fallback.
const EMPTY_DOC_BYTES = new Uint8Array(0);

/** @typedef {import('./types.js').Registries} Registries */
/** @typedef {import('./types.js').WriteEntry} WriteEntry */
/** @typedef {import('./types.js').Diagnostic} Diagnostic */
/** @typedef {import('./types.js').LoadResult} LoadResult */
/** @typedef {import('./types.js').Meta} Meta */
/** @typedef {import('./types.js').ControlRef} ControlRef */
/** @typedef {import('./types.js').ControlValue} ControlValue */
/** @typedef {import('./types.js').PacerRtExports} PacerRtExports */

/**
 * Coerce the score bytes to a Uint8Array without copying. Buffer is a
 * Uint8Array subclass; an ArrayBuffer is wrapped once.
 * @param {Uint8Array | ArrayBuffer} source
 * @returns {Uint8Array}
 */
function toBytes(source) {
  if (source instanceof Uint8Array) return source;
  if (source instanceof ArrayBuffer) return new Uint8Array(source);
  throw new TypeError('pacer-rt: pacbBytes must be a Uint8Array or ArrayBuffer');
}

export class PacerRt {
  /** @type {PacerRtExports} The pinned prt_* ABI surface. */
  #exports;
  /**
   * Flattened registries; the flat index IS the target_id for the host
   * half of the joined registry (declared-only ids append after it).
   * @type {import('./types.js').FlatTarget[]}
   */
  #flat;
  /** @type {Uint8Array} The encoded 'PACT' target blob. */
  #targetsBlob;
  /** @type {WriteEntry[]} Reused frame to frame. */
  #entries = [];
  /** @type {Meta | null} Decoded 'PACM', cached until the next successful load. */
  #meta = null;

  /**
   * Last load's status (0 ok / 1 refused / 2 bad call / 3 oom). A
   * refused load leaves the previously armed score live, so `ok` reports
   * whether a score is live/armed, not just whether the last load was
   * accepted. `status` and `reason` report the load itself.
   * @type {number}
   */
  status = -1;
  /**
   * `prt_loadError()` snapshot from the last load. Meaningful only when
   * `status === 1` (the export retains its previous value on success and
   * on bad calls, exactly as rt_entry.zig documents).
   * @type {number}
   */
  reason = 0;
  /**
   * A score is live and eval armed. A refused reload leaves the OLD
   * score live (that is the runtime's transactional contract), so this
   * stays true across a status-1 refusal once a score has loaded. A
   * refused first load is false.
   * @type {boolean}
   */
  ok = false;
  /**
   * The binary path has no 'PACD' blob: refusals are reported by
   * `status` / `reason`, never manufactured into compiler diagnostics.
   * Kept on the class so the shared harness/driver shape is identical.
   * @type {ReadonlyArray<Diagnostic>}
   */
  diagnostics = [];

  /**
   * Instantiate pacer-rt.wasm and load a packed score against the host's
   * ordered registry list. A refused load returns a driver with
   * `ok: false`; a bad call or OOM throws (a glue bug, not a score
   * refusal).
   *
   * @param {BufferSource | WebAssembly.Module} wasmSource
   * @param {Uint8Array | ArrayBuffer} pacbBytes - the packed 'PACB' score
   * @param {{ registries?: Registries }} [opts]
   *   `registries[0]` is conventionally the visual bus, `registries[1]`
   *   the audio bus. Optional (defaults to `[]`): a pack-time score whose
   *   targets were all declared in source has an empty host join.
   * @returns {Promise<PacerRt>} loaded driver; check `.ok` / `.status`.
   */
  static async load(wasmSource, pacbBytes, { registries = [] } = {}) {
    const instance =
      wasmSource instanceof WebAssembly.Module
        ? await WebAssembly.instantiate(wasmSource, IMPORTS)
        : (await WebAssembly.instantiate(wasmSource, IMPORTS)).instance;
    const driver = new PacerRt(instance, registries);
    driver.load(pacbBytes);
    return driver;
  }

  /**
   * @param {WebAssembly.Instance} instance
   * @param {Registries} registries
   */
  constructor(instance, registries) {
    // The wasm exports are untyped at the boundary; cast once to the
    // pinned `prt_*` ABI so every call site type-checks against it.
    this.#exports = /** @type {PacerRtExports} */ (/** @type {unknown} */ (instance.exports));
    if (this.#exports.prt_abiVersion() !== 1) {
      throw new Error(`pacer-rt: unsupported ABI version ${this.#exports.prt_abiVersion()}`);
    }
    // Flatten the ordered registries; the flat index IS the target_id.
    this.#flat = registries.flatMap((targets, registry) =>
      targets.map(({ name, ncomp = 1 }) => ({ name, ncomp, registry })),
    );
    this.#targetsBlob = encodeTargets(this.#flat);
    // The blob is written verbatim into the fixed targets zone on every
    // load; reject an over-cap blob here rather than let `load` scribble
    // past the zone into wasm linear memory.
    const cap = this.#exports.prt_targetsCap();
    if (this.#targetsBlob.length > cap) {
      throw new Error(
        `pacer-rt: targets blob is ${this.#targetsBlob.length} bytes, over prt_targetsCap (${cap})`,
      );
    }
  }

  /**
   * (Re)load a packed score. Transactional on the wasm side: a refusal
   * (`status === 1`) leaves the previously armed score evaluable with
   * ALL runtime state intact (held controls, dynamic slots, a bpm nudge,
   * `exprFailures`), so `driver.ok` stays true when a score was already
   * live. The returned `ok` is the LOAD's acceptance; use `status` /
   * `reason` for the refusal class.
   *
   * @param {Uint8Array | ArrayBuffer} pacbBytes
   * @returns {LoadResult}
   */
  load(pacbBytes) {
    const e = this.#exports;
    const bytes = toBytes(pacbBytes);
    const cap = e.prt_pacbCap();
    if (bytes.length > cap) {
      throw new Error(`pacer-rt: PACB is ${bytes.length} bytes, over prt_pacbCap (${cap})`);
    }
    // Re-take the linear-memory view: an earlier load may have grown it,
    // which detaches every previously held Uint8Array.
    new Uint8Array(e.memory.buffer).set(this.#targetsBlob, e.prt_targetsPtr());
    new Uint8Array(e.memory.buffer).set(bytes, e.prt_pacbPtr());
    const status = e.prt_load(bytes.length, this.#targetsBlob.length);
    const accepted = status === LOAD_OK;
    this.status = status;
    this.reason = e.prt_loadError();
    this.ok = accepted || this.ok;
    this.diagnostics = [];
    if (accepted) this.#meta = null;
    if (!accepted && status !== LOAD_REFUSED) {
      throw new Error(`pacer-rt: load failed with status ${status} (glue bug or OOM)`);
    }
    return { ok: accepted, diagnostics: this.diagnostics };
  }

  /**
   * Score metadata ('PACM') from the packed score, decoded lazily and
   * cached until the next successful load: `{ transport, tracks,
   * controls, scenes, easePrograms, tempoMap }` with key ticks (BigInt)
   * and spans in the ORIGINAL compile-time source coordinates.
   *
   * Scene names travel in the blob's 'SNAM' section and decode exactly —
   * no source text needed. A blob without 'SNAM' (pre-SNAM cartridges)
   * falls back to the source slice each nameSpan anchors, so with no
   * source held its names are '' (the span stays authoritative).
   * Declared-only target names are null because 'DECL' carries
   * registry/ncomp, never names (the same null the text driver reports
   * for an unhosted declared target). Host-registered names resolve
   * from `registries`.
   *
   * Null when nothing is loaded.
   *
   * @returns {Meta | null}
   */
  get meta() {
    if (this.#meta) return this.#meta;
    const e = this.#exports;
    const len = e.prt_metaLen();
    if (len === 0) return null;
    // The decode half is the shared leaf (meta.js); it builds its views
    // from the CURRENT memory buffer on every call — growth detaches
    // older buffers, so views are never cached across calls.
    this.#meta = decodeMeta(
      e.memory.buffer,
      e.prt_metaPtr(),
      len,
      EMPTY_DOC_BYTES,
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
    return this.#exports.prt_setControl(slot, x, y, z, w) === 0;
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
    return this.#exports.prt_clearControl(slot) === 0;
  }

  /**
   * Live tempo nudge: rescales the seconds↔ticks projection; musical
   * (tick) positions stand still. False outside 1..1000 bpm, or on a
   * score with a `(tempo …)` map (its tempo truth is the score itself).
   * Evaluator state like a held control: a successful `load` resets it.
   *
   * @param {number} bpm
   * @returns {boolean}
   */
  setBpm(bpm) {
    return this.#exports.prt_setBpm(bpm) === 0;
  }

  /**
   * Lifetime count of frames a track's write was omitted by a runtime
   * failure since the last successful load (the counter predates pattern
   * tracks; the wire-frozen name stays). A debugging probe, not
   * semantics. 0 while nothing is loaded; reset every successful load.
   *
   * @returns {number}
   */
  get exprFailures() {
    return this.#exports.prt_exprFailures();
  }

  /**
   * Register a dynamic control slot for a host-registered target with no
   * (control …) pin in the packed score. Returns the slot index for
   * `setControl`/`clearControl`, or null. A declared-only target cannot
   * be named here: its name never crossed the wire. Dynamic slots write
   * only while held and never enter the expression environment.
   *
   * @param {string} targetName
   * @returns {number | null}
   */
  registerControl(targetName) {
    const targetId = this.#flat.findIndex((t) => t.name === targetName);
    if (targetId < 0) return null;
    const { registry, ncomp } = this.#target(targetId);
    const slot = this.#exports.prt_registerControl(targetId, registry, ncomp);
    return slot === NO_SLOT ? null : slot;
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
   * The frame path: master-clock seconds in, write entries out. Returns
   * null when no score is live or the clock is out of range. The
   * returned array and its entries are reused — consume before the next
   * eval, copy if you must keep them.
   *
   * @param {number} seconds
   * @returns {WriteEntry[] | null}
   */
  eval(seconds) {
    return this.#decodeWrites(this.#exports.prt_eval(seconds));
  }

  /**
   * Tick-domain twin (tests, corpus tooling). Takes a BigInt or number.
   * @param {bigint | number} tick
   * @returns {WriteEntry[] | null}
   */
  evalTicks(tick) {
    return this.#decodeWrites(this.#exports.prt_evalTicks(BigInt(tick)));
  }

  /**
   * Like `eval` but returns a copy of the raw 'PACW' bytes — the unit of
   * the determinism claim (parity tooling compares these).
   *
   * @param {number} seconds
   * @returns {Uint8Array | null}
   */
  evalBytes(seconds) {
    const len = this.#exports.prt_eval(seconds);
    if (len === 0) return null;
    const e = this.#exports;
    return new Uint8Array(e.memory.buffer, e.prt_writesPtr(), len).slice();
  }

  /**
   * Resolve a wasm-emitted `target_id` to its host-registry name. An id
   * PAST the flat host join is a declared-only target: the pack-time
   * source holds its name, but it never crosses the wire, so the host
   * has no name for it (`null`). Route such a write by `registry`.
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
    const dv = new DataView(e.memory.buffer, e.prt_writesPtr(), len);
    if (dv.getUint32(0, true) !== PACW_MAGIC || dv.getUint32(4, true) !== PACW_VERSION) {
      throw new Error('pacer-rt: corrupt write buffer');
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
      entry.registry = dv.getUint8(off + 2);
      entry.ncomp = dv.getUint8(off + 3);
      entry.name = this.#target(entry.targetId).name;
      for (let c = 0; c < 4; c++) entry.value[c] = dv.getFloat32(off + 4 + c * 4, true);
    }
    entries.length = count;
    return entries;
  }
}
