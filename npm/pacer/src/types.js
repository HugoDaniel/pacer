// Shared structural types for pacer's public API.
//
// JSDoc-only: this module emits no runtime values (`export {}` makes it a
// module so the typedefs are importable). The driver, routing, and audio
// modules name one set of types by referencing `import('./types.js').X`,
// and `tsc` emits them into `types/types.d.ts` for published consumers.

export {};

/**
 * A host target as declared to `Pacer.load`: a name plus an optional
 * component count (`ncomp` defaults to 1 — a scalar; 2-4 declare a
 * vec2/vec3/vec4 target).
 * @typedef {object} TargetSpec
 * @property {string} name
 * @property {number} [ncomp]
 */

/**
 * The host's animatable surface: an ordered list of registries (buses).
 * Conventionally `registries[0]` is the visual bus and `registries[1]`
 * the audio bus; the array index becomes each {@link WriteEntry}'s
 * `registry` field, so routing is positional.
 * @typedef {ReadonlyArray<ReadonlyArray<TargetSpec>>} Registries
 */

/**
 * One resolved write produced by `Pacer.eval`. The object and its `value`
 * are reused frame to frame — copy `value` if you must retain it past the
 * next `eval`.
 * @typedef {object} WriteEntry
 * @property {string} name Target name, from the joined host registry.
 * @property {number} targetId Flat index into the joined registry list.
 * @property {number} registry Bus index (the registries-array position).
 * @property {number} ncomp Active lanes: 1 (scalar) … 4 (vec4).
 * @property {Float32Array} value Four lanes; only the first `ncomp` carry meaning.
 */

/**
 * A byte span into the UTF-8 score source — a diagnostic location or a
 * commit-to-text anchor. Equals string indices only while the score is
 * ASCII; map through a byte index for non-ASCII text.
 * @typedef {object} Span
 * @property {number} start
 * @property {number} end
 */

/**
 * A load/reload diagnostic, decoded from the 'PACD' blob with spans in
 * the score's own coordinates.
 * @typedef {object} Diagnostic
 * @property {'sjon' | 'pacer'} source Which layer raised it.
 * @property {'error' | 'warning'} severity
 * @property {number} code Wire-stable diagnostic code.
 * @property {number} start Byte offset into the score.
 * @property {number} end Byte offset into the score.
 * @property {string} message
 */

/**
 * Outcome of a (re)load: `ok` plus any diagnostics.
 * @typedef {object} LoadResult
 * @property {boolean} ok
 * @property {Diagnostic[]} diagnostics
 */

/**
 * Transport metadata from the 'PACM' blob.
 * @typedef {object} Transport
 * @property {number} bpm
 * @property {number} beatsPerBar
 * @property {bigint | null} dur Score length in ticks, or null when open-ended.
 * @property {'loop' | 'hold'} end Playhead behavior past `dur`.
 */

/**
 * A keyframe in score metadata: tick position, up-to-4-lane value, and the
 * byte span of its `(key …)` form.
 * @typedef {object} MetaKey
 * @property {bigint} at Tick position on the PPC grid.
 * @property {number[]} value Four lanes (trailing lanes are 0).
 * @property {Span} span
 */

/**
 * A track in score metadata.
 * @typedef {object} MetaTrack
 * @property {number} targetId
 * @property {string} name
 * @property {number} registry
 * @property {number} ncomp
 * @property {'keys' | 'expr'} source Value source: keyframes or an expression.
 * @property {Span} span
 * @property {MetaKey[]} keys Empty for expr tracks.
 */

/**
 * A control (editor widget) in score metadata.
 * @typedef {object} MetaControl
 * @property {number} index Slot index for setControl / clearControl.
 * @property {string} id Expression-environment binding name.
 * @property {number | null} targetId Write target, or null for a virtual knob.
 * @property {string | null} name Target name, or null.
 * @property {number} registry
 * @property {number} ncomp
 * @property {'slider' | 'xy' | 'color'} type Editor widget hint.
 * @property {number[]} value Document value (four lanes).
 * @property {number[] | null} min Widget floor — editor metadata only.
 * @property {number[] | null} max Widget ceiling — editor metadata only.
 * @property {Span} valueSpan Commit-to-text anchor for the value.
 */

/**
 * Decoded score metadata ('PACM'): the editor's timeline anchors.
 * @typedef {object} Meta
 * @property {Transport} transport
 * @property {MetaTrack[]} tracks
 * @property {MetaControl[]} controls
 */

/**
 * A control reference: its `:id` string or its slot index.
 * @typedef {string | number} ControlRef
 */

/**
 * A control value: a scalar or up to four components.
 * @typedef {number | readonly number[]} ControlValue
 */

/**
 * The pacer.wasm export surface (the `drv_*` ABI). Modeled explicitly so
 * the glue type-checks against the boundary instead of reaching through
 * `any`; the `Pacer` constructor casts `instance.exports` to this once.
 * @typedef {object} PacerExports
 * @property {WebAssembly.Memory} memory
 * @property {() => number} drv_abiVersion
 * @property {() => number} drv_docCap
 * @property {() => number} drv_docPtr
 * @property {() => number} drv_targetsPtr
 * @property {(docLen: number, targetsLen: number) => number} drv_load
 * @property {() => number} drv_diagLen
 * @property {() => number} drv_diagPtr
 * @property {() => number} drv_metaLen
 * @property {() => number} drv_metaPtr
 * @property {() => number} drv_writesPtr
 * @property {(seconds: number) => number} drv_eval
 * @property {(tick: bigint) => number} drv_evalTicks
 * @property {(slot: number, x: number, y: number, z: number, w: number) => number} drv_setControl
 * @property {(slot: number) => number} drv_clearControl
 * @property {(targetId: number, registry: number, ncomp: number) => number} drv_registerControl
 * @property {(bpm: number) => number} drv_setBpm
 */
