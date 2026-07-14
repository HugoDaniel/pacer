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
// Post-controls section stream (see Abi.zig): [id u32][len u32][payload].
const PACM_SECTION_HEADER_LEN = 8;
const PACM_SCENES_ID = 0x4e454353; // 'SCEN' read little-endian
const PACM_SCENE_REC_LEN = 24;
const NO_SLOT = 0xffffffff;
/** Mirror of `Abi.MAX_TARGETS` — the flat registry join's ceiling. */
const MAX_TARGETS = 1024;
const CONTROL_TYPES = /** @type {const} */ (['slider', 'xy', 'color']);

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
   * @param {{ registries: Registries }} opts
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
   * reload: `{ transport, tracks, controls, scenes }` with key ticks
   * (BigInt) and spans in the score's own coordinates — a control's
   * `valueSpan` is the commit-to-text anchor for its widget, and each
   * scene's `nameSpan` anchors its `:name`. `scenes` is `[]` when the
   * score declares none. Null when not loaded.
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
    const dv = new DataView(e.memory.buffer, e.drv_metaPtr(), len);
    if (dv.getUint32(0, true) !== PACM_MAGIC || dv.getUint32(4, true) !== PACM_VERSION) {
      throw new Error('pacer: corrupt meta buffer');
    }
    const bytes = new Uint8Array(e.memory.buffer, e.drv_metaPtr(), len);
    const lanes = (/** @type {number} */ base) => {
      /** @type {number[]} */
      const a = [];
      for (let c = 0; c < 4; c++) a.push(dv.getFloat32(base + c * 4, true));
      return a;
    };

    const flags = dv.getUint8(26);
    /** @type {import('./types.js').Transport} */
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
    /**
     * @type {Array<{ targetId: number, registry: number, ncomp: number,
     *   source: 'keys' | 'expr', keyStart: number, keyLen: number, span: Span }>}
     */
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
    /** @type {import('./types.js').MetaKey[]} */
    const keys = [];
    for (let i = 0; i < keyCount; i++, off += PACM_KEY_LEN) {
      keys.push({
        at: dv.getBigInt64(off, true),
        value: lanes(off + 8),
        span: { start: dv.getUint32(off + 24, true), end: dv.getUint32(off + 28, true) },
      });
    }
    /** @type {import('./types.js').MetaControl[]} */
    const controls = [];
    for (let i = 0; i < controlCount; i++) {
      const targetId = dv.getUint16(off, true);
      const cflags = dv.getUint8(off + 5);
      const idLen = dv.getUint16(off + 6, true);
      controls.push({
        index: i,
        id: decoder.decode(bytes.subarray(off + PACM_CONTROL_LEN, off + PACM_CONTROL_LEN + idLen)),
        targetId: targetId === PACM_NO_TARGET ? null : targetId,
        name: targetId === PACM_NO_TARGET ? null : this.#target(targetId).name,
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

    // Section stream: TLV frames after the last control, walked to the
    // buffer end. Dispatch known ids, skip unknown ones by length — so a
    // blob carrying a section this glue predates decodes without a throw.
    /** @type {import('./types.js').MetaScene[]} */
    const scenes = [];
    while (off < len) {
      const id = dv.getUint32(off, true);
      const plen = dv.getUint32(off + 4, true);
      const body = off + PACM_SECTION_HEADER_LEN;
      if (id === PACM_SCENES_ID) {
        const count = dv.getUint32(body, true);
        let s = body + 4;
        for (let i = 0; i < count; i++, s += PACM_SCENE_REC_LEN) {
          const nameStart = dv.getUint32(s + 16, true);
          const nameEnd = dv.getUint32(s + 20, true);
          scenes.push({
            name: decoder.decode(this.#docBytes.subarray(nameStart, nameEnd)),
            startTick: dv.getBigInt64(s, true),
            durTicks: dv.getBigInt64(s + 8, true),
            nameSpan: { start: nameStart, end: nameEnd },
          });
        }
      }
      off = body + plen;
    }

    this.#meta = {
      transport,
      tracks: rawTracks.map((t) => ({
        targetId: t.targetId,
        name: this.#target(t.targetId).name,
        registry: t.registry,
        ncomp: t.ncomp,
        source: t.source,
        span: t.span,
        keys: keys.slice(t.keyStart, t.keyStart + t.keyLen),
      })),
      controls,
      scenes,
    };
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
   * (tick) positions stand still. False outside 1..1000 bpm.
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
   * Lifetime count of expr-track evaluations omitted for a runtime
   * failure (non-finite result) since the last (re)load — a debugging
   * probe, not semantics. 0 while nothing is loaded; resets every reload.
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
   * Resolve a wasm-emitted `target_id` to its registry entry. The id is
   * always in range — the wasm only ever emits ids from the 'PACT' table
   * this driver handed it — but the type system can't see that closed
   * loop, so the lookup asserts the invariant at the seam rather than
   * leak `undefined` (or paper over it with `!`) into every call site.
   *
   * @param {number} targetId
   * @returns {import('./types.js').FlatTarget}
   */
  #target(targetId) {
    const entry = this.#flat[targetId];
    if (entry === undefined) {
      throw new Error(
        `pacer: target_id ${targetId} not in the registry table (corrupt wasm output)`,
      );
    }
    return entry;
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

/**
 * Encode the flattened target list as a 'PACT' blob.
 * @param {ReadonlyArray<import('./types.js').FlatTarget>} flat
 * @returns {Uint8Array}
 */
function encodeTargets(flat) {
  if (flat.length > MAX_TARGETS) {
    throw new Error(`pacer: ${flat.length} targets exceed the ${MAX_TARGETS}-target limit`);
  }
  // Pair each target with its UTF-8 name up front so the write loop
  // never re-correlates two arrays by index.
  const encoded = flat.map((target) => ({ target, name: encoder.encode(target.name) }));
  let len = 8;
  for (const { name } of encoded) len += 4 + name.length;
  const blob = new Uint8Array(len);
  const dv = new DataView(blob.buffer);
  dv.setUint32(0, PACT_MAGIC, true);
  dv.setUint32(4, flat.length, true);
  let pos = 8;
  for (const { target, name } of encoded) {
    if (target.ncomp < 1 || target.ncomp > 4) {
      throw new Error(`pacer: target ${target.name} has ncomp ${target.ncomp}`);
    }
    // The name length rides a u16 on the wire; keep it in 1..65535 so it
    // neither wraps the field nor encodes an unnamed target.
    if (name.length < 1 || name.length > 65535) {
      throw new Error(
        `pacer: target ${target.name} name is ${name.length} UTF-8 bytes (need 1..65535)`,
      );
    }
    blob[pos] = target.ncomp;
    blob[pos + 1] = target.registry;
    dv.setUint16(pos + 2, name.length, true);
    pos += 4;
    blob.set(name, pos);
    pos += name.length;
  }
  return blob;
}
