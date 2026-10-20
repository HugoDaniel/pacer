// pacer — the shared 'PACM' decode leaf (02 T3.1).
//
// Extracted byte-for-byte from the `Pacer` meta getter (index.js) so
// the playback runtime's glue (rt.js) decodes the SAME blob the SAME
// way — one decoder, shared, never two spellings that can drift. No
// format change: the runtime structurally validated this section
// before serving it (01's `Pacm` reader cross-checks it against the
// PACB sections — 00 decision 6), so this decode is not the trust
// boundary. Zero behavior change: this is a pure move of the decode.
// Scene names: blobs carrying the 'SNAM' section own their names
// (decoded exactly, strict Zig-mirror refusals as TypeError); blobs
// without it fall back to slicing docBytes at each nameSpan.

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
const PACM_EASE_ID = 0x45534145; // 'EASE' read little-endian
const PACM_EASE_PROGRAM_LEN = 772;
const PACM_EASE_STAGE_LEN = 96;
const PACM_EASE_OP_LEN = 20;
const PACM_TEMPO_ID = 0x4f504d54; // 'TMPO' read little-endian
const PACM_TEMPO_REC_LEN = 16;
const PACM_SNAM_ID = 0x4d414e53; // 'SNAM' read little-endian
/** Mirror of `Easing.Op` (array index = wire op code). */
const EASE_OPS = /** @type {const} */ ([
  'linear',
  'hold',
  'smoothstep',
  'in_quad',
  'out_quad',
  'in_out_quad',
  'in_cubic',
  'out_cubic',
  'in_out_cubic',
  'in_quart',
  'out_quart',
  'in_out_quart',
  'in_sine',
  'out_sine',
  'in_out_sine',
  'in_expo',
  'out_expo',
  'in_out_expo',
  'steps_end',
  'steps_start',
  'cubic_bezier',
  'spring',
]);
const CONTROL_TYPES = /** @type {const} */ (['slider', 'xy', 'color']);
/** Mirror of `MetaTrackRec.source`: keyframes, an expression, a trigger, or a pattern. */
const TRACK_SOURCES = /** @type {const} */ (['keys', 'expr', 'trigger', 'pattern']);

const decoder = new TextDecoder();

/** @typedef {import('./types.js').Meta} Meta */
/** @typedef {import('./types.js').Span} Span */

/**
 * Decode the 'PACM' score-metadata blob served by the driver:
 * `{ transport, tracks, controls, scenes, easePrograms, tempoMap }`
 * with key ticks (BigInt) and spans in the score's own coordinates.
 *
 * The views are built HERE, from the buffer the caller passes, on every
 * call — wasm memory growth detaches older buffers, so a stale view is
 * never held (callers re-fetch `exports.memory.buffer` per call).
 *
 * Scene names: a blob carrying the `'SNAM'` section carries the names
 * themselves — verbatim source-symbol bytes, decoded exactly (no
 * truncation, no drop, no empty fallback). The strict Zig contracts
 * hold here too: one `'SNAM'`, only after `'SCEN'`, count parallel to
 * the scene records, per-entry u32 lengths bounded against what
 * remains, entries accounting for the payload exactly — every refusal
 * is a TypeError thrown by a bounds check BEFORE the offending read.
 * A blob WITHOUT `'SNAM'` (every pre-SNAM blob) falls back to slicing
 * `docBytes` at each scene's `nameSpan`.
 *
 * @param {ArrayBufferLike} buffer - the driver's CURRENT memory buffer.
 * @param {number} ptr - byte offset of the 'PACM' blob.
 * @param {number} len - blob length in bytes.
 * @param {Uint8Array} docBytes - the current score's UTF-8 bytes, used
 *   ONLY for the pre-'SNAM' fallback: when the blob carries no 'SNAM'
 *   section, scene names are sliced from here at each `nameSpan`
 *   (spans are USER coordinates, matching these bytes). A caller with
 *   no source passes an empty buffer and pre-SNAM names decode ''.
 * @param {(targetId: number) => string | null} targetName - resolves a
 *   wire `target_id` through the host's joined registry list (null for
 *   a compose-mode declared-only target the host never registered).
 * @returns {Meta}
 */
export function decodeMeta(buffer, ptr, len, docBytes, targetName) {
  const dv = new DataView(buffer, ptr, len);
  if (dv.getUint32(0, true) !== PACM_MAGIC || dv.getUint32(4, true) !== PACM_VERSION) {
    throw new Error('pacer: corrupt meta buffer');
  }
  const bytes = new Uint8Array(buffer, ptr, len);
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
   *   source: 'keys' | 'expr' | 'trigger' | 'pattern', keyStart: number, keyLen: number, span: Span }>}
   */
  const rawTracks = [];
  for (let i = 0; i < trackCount; i++, off += PACM_TRACK_LEN) {
    rawTracks.push({
      targetId: dv.getUint16(off, true),
      registry: dv.getUint8(off + 2),
      ncomp: dv.getUint8(off + 3),
      source: TRACK_SOURCES[dv.getUint8(off + 4)] ?? 'keys',
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
      // Default linear; the 'EASE' section (when present) overwrites it.
      easeRef: 0,
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
      name: targetId === PACM_NO_TARGET ? null : targetName(targetId),
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
  /** @type {import('./types.js').MetaEaseProgram[]} */
  const easePrograms = [];
  /** @type {import('./types.js').MetaTempoSeg[]} */
  const tempoMap = [];
  let scenSeen = false;
  /** @type {string[] | null} Scene names from 'SNAM', in scene order. */
  let snamNames = null;
  while (off < len) {
    const id = dv.getUint32(off, true);
    const plen = dv.getUint32(off + 4, true);
    const body = off + PACM_SECTION_HEADER_LEN;
    if (id === PACM_SCENES_ID) {
      scenSeen = true;
      const count = dv.getUint32(body, true);
      let s = body + 4;
      for (let i = 0; i < count; i++, s += PACM_SCENE_REC_LEN) {
        const nameStart = dv.getUint32(s + 16, true);
        const nameEnd = dv.getUint32(s + 20, true);
        scenes.push({
          name: decoder.decode(docBytes.subarray(nameStart, nameEnd)),
          startTick: dv.getBigInt64(s, true),
          durTicks: dv.getBigInt64(s + 8, true),
          nameSpan: { start: nameStart, end: nameEnd },
        });
      }
    } else if (id === PACM_EASE_ID) {
      // Program records (fixed 772 B, unused stage/op slots zeroed) then a
      // per-key `ease_ref` array parallel to the key stream.
      const progCount = dv.getUint32(body, true);
      let p = body + 4;
      for (let i = 0; i < progCount; i++, p += PACM_EASE_PROGRAM_LEN) {
        const stageCount = dv.getUint8(p);
        /** @type {import('./types.js').MetaEaseStage[]} */
        const stages = [];
        for (let s = 0; s < stageCount; s++) {
          const so = p + 4 + s * PACM_EASE_STAGE_LEN;
          const opsLen = dv.getUint8(so + 12);
          /** @type {import('./types.js').MetaEaseOp[]} */
          const ops = [];
          for (let o = 0; o < opsLen; o++) {
            const oo = so + 16 + o * PACM_EASE_OP_LEN;
            ops.push({
              code: EASE_OPS[dv.getUint8(oo)] ?? 'linear',
              params: [
                dv.getFloat32(oo + 4, true),
                dv.getFloat32(oo + 8, true),
                dv.getFloat32(oo + 12, true),
                dv.getFloat32(oo + 16, true),
              ],
            });
          }
          stages.push({
            tEnd: dv.getFloat32(so, true),
            vBase: dv.getFloat32(so + 4, true),
            vSpan: dv.getFloat32(so + 8, true),
            ops,
          });
        }
        easePrograms.push({ index: i, stages });
      }
      // ease_ref per key, in key order — attach to the decoded keys.
      const refCount = dv.getUint32(p, true);
      let r = p + 4;
      for (let i = 0; i < refCount; i++, r += 2) {
        const k = keys[i];
        if (k) k.easeRef = dv.getUint16(r, true);
      }
    } else if (id === PACM_TEMPO_ID) {
      // Tempo segments including segment 0 (self-contained — no
      // transport join); ascending ticks, first is always 0.
      const count = dv.getUint32(body, true);
      let s = body + 4;
      for (let i = 0; i < count; i++, s += PACM_TEMPO_REC_LEN) {
        tempoMap.push({ tick: dv.getBigInt64(s, true), bpm: dv.getFloat64(s + 8, true) });
      }
    } else if (id === PACM_SNAM_ID) {
      // Scene names, carried in-blob (source-free metadata). The same
      // strict contracts as the Zig decoders (Pacm.zig / Abi.decodeMeta):
      // one 'SNAM', only after 'SCEN' (names parallelize the scene
      // records), count equal to the scene count, per-entry lengths
      // compared against what remains BEFORE being added, entries
      // accounting for the payload exactly. Every refusal is a TypeError
      // from a bounds check — never an accidental DataView RangeError.
      if (snamNames !== null) {
        throw new TypeError("pacer: duplicate 'SNAM' section in meta blob");
      }
      if (!scenSeen) {
        throw new TypeError("pacer: 'SNAM' section without a preceding 'SCEN' section");
      }
      if (plen < 4) {
        throw new TypeError("pacer: 'SNAM' payload too short for the count field");
      }
      if (body + plen > len) {
        throw new TypeError("pacer: 'SNAM' section payload overruns the meta blob");
      }
      const count = dv.getUint32(body, true);
      if (count !== scenes.length) {
        throw new TypeError(
          `pacer: 'SNAM' count ${count} does not match the 'SCEN' count ${scenes.length}`,
        );
      }
      const names = [];
      let s = body + 4;
      const end = body + plen;
      while (s < end) {
        if (end - s < 4) {
          throw new TypeError("pacer: 'SNAM' entry length field overruns the section payload");
        }
        const nameLen = dv.getUint32(s, true);
        s += 4;
        if (nameLen > end - s) {
          throw new TypeError("pacer: 'SNAM' name length overruns the section payload");
        }
        names.push(decoder.decode(bytes.subarray(s, s + nameLen)));
        s += nameLen;
      }
      if (names.length !== count) {
        throw new TypeError(
          `pacer: 'SNAM' carries ${names.length} entries for a count of ${count}`,
        );
      }
      snamNames = names;
    }
    off = body + plen;
  }

  // C6 decode chain, present-keyed: a blob that carries 'SNAM' owns the
  // names (a present-but-empty entry is a TRUE empty name — the span
  // never shines through a falsy fallback); a blob without 'SNAM' falls
  // back to the source span each scene record already carries.
  if (snamNames !== null) {
    snamNames.forEach((name, i) => {
      const scene = scenes[i];
      if (scene) scene.name = name;
    });
  }

  return {
    transport,
    tracks: rawTracks.map((t) => ({
      targetId: t.targetId,
      name: targetName(t.targetId),
      registry: t.registry,
      ncomp: t.ncomp,
      source: t.source,
      span: t.span,
      keys: keys.slice(t.keyStart, t.keyStart + t.keyLen),
    })),
    controls,
    scenes,
    easePrograms,
    tempoMap,
  };
}
