// Shared structural types for pacer's public API.
//
// JSDoc-only: this module emits no runtime values (`export {}` makes it a
// module so the typedefs are importable). The driver, routing, and audio
// modules name one set of types by referencing `import('./types.js').X`,
// and `tsc` emits them into `types/types.d.ts` for published consumers.
//
// Convention: decoded, consumer-facing values (diagnostics, meta, spans)
// are `readonly` — they are produced once per (re)load and meant to be
// read, not mutated. The lone exception is {@link WriteEntry}, which is
// deliberately mutable: the driver reuses the same entry objects frame to
// frame, so the hot path allocates nothing after warm-up.

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
 * One resolved write produced by `Pacer.eval`. Deliberately mutable: the
 * object and its `value` are reused frame to frame — copy `value` if you
 * must retain it past the next `eval`.
 * @typedef {object} WriteEntry
 * @property {string | null} name Target name from the joined host registry, or
 *   null for a compose-mode declared-only target this host never registered
 *   (route it by `registry`; the score source holds the declared name).
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
 * @property {ReadonlyArray<Diagnostic>} diagnostics
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
 * @property {ReadonlyArray<number>} value Four lanes (trailing lanes are 0).
 * @property {Span} span
 * @property {number} easeRef Index into {@link Meta.easePrograms} for the
 *   segment ENDING at this key; 0 = linear (the default). See the `'EASE'`
 *   section in Abi.zig.
 */

/**
 * A track in score metadata.
 * @typedef {object} MetaTrack
 * @property {number} targetId
 * @property {string | null} name Target name from the joined host registry, or
 *   null for a compose-mode declared-only target this host never registered.
 * @property {number} registry
 * @property {number} ncomp
 * @property {'keys' | 'expr' | 'trigger' | 'pattern'} source Value source: keyframes, an expression, an event schedule, or a pattern.
 * @property {Span} span
 * @property {ReadonlyArray<MetaKey>} keys Empty for expr, trigger, and pattern tracks.
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
 * @property {ReadonlyArray<number>} value Document value (four lanes).
 * @property {ReadonlyArray<number> | null} min Widget floor — editor metadata only.
 * @property {ReadonlyArray<number> | null} max Widget ceiling — editor metadata only.
 * @property {Span} valueSpan Commit-to-text anchor for the value.
 */

/**
 * A scene (named window) in score metadata. Its name is sliced from the
 * score source via `nameSpan` — scenes carry no target, so the name is
 * their identity. The binary runtime (`PacerRt`) has no source text: it
 * preserves `nameSpan` but reports `name: ''` rather than inventing one.
 * @typedef {object} MetaScene
 * @property {string} name The scene's `:name` symbol, sliced from source.
 * @property {bigint} startTick Window start on the PPC tick grid.
 * @property {bigint} durTicks Window length; the scene plays over
 *   `[startTick, startTick + durTicks)`.
 * @property {Span} nameSpan Byte span of the `:name` symbol (commit anchor).
 */

/**
 * One tempo-map segment (`'TMPO'` section): from `tick` onward the
 * transport runs at `bpm`. Ascending; the first segment is always
 * `{tick: 0n, bpm: transport.bpm}` (self-contained — no join needed).
 * @typedef {object} MetaTempoSeg
 * @property {bigint} tick Segment start on the PPC tick grid.
 * @property {number} bpm Tempo in effect from `tick` onward.
 */

/**
 * One primitive op inside a compiled easing program — the wire mirror of
 * `Easing.OpRec`.
 * @typedef {object} MetaEaseOp
 * @property {'linear' | 'hold' | 'smoothstep' | 'in_quad' | 'out_quad' | 'in_out_quad' | 'in_cubic' | 'out_cubic' | 'in_out_cubic' | 'in_quart' | 'out_quart' | 'in_out_quart' | 'in_sine' | 'out_sine' | 'in_out_sine' | 'in_expo' | 'out_expo' | 'in_out_expo' | 'steps_end' | 'steps_start' | 'cubic_bezier' | 'spring'} code
 *   The `Easing.Op` tag.
 * @property {ReadonlyArray<number>} params Four f32 op parameters (`steps` n,
 *   `cubic-bezier` control points, `spring` λ/ω); trailing lanes are 0.
 */

/**
 * One stage of a compiled easing program — the wire mirror of
 * `Easing.Stage`. The stage maps normalized time `[prev.tEnd, tEnd]` onto
 * value `vBase + vSpan · (op-chain applied to the local ramp)`.
 * @typedef {object} MetaEaseStage
 * @property {number} tEnd Cumulative normalized end time (last stage = 1).
 * @property {number} vBase Value base at the stage start.
 * @property {number} vSpan Value span across the stage (may be negative).
 * @property {ReadonlyArray<MetaEaseOp>} ops The stage's flattened op chain.
 */

/**
 * A compiled easing program (`'EASE'` section) — a deduped entry of the
 * score's program table; `easePrograms[0]` is always the default linear.
 * A {@link MetaKey} names one by index via `easeRef`.
 * @typedef {object} MetaEaseProgram
 * @property {number} index Position in the program table (the `easeRef` value).
 * @property {ReadonlyArray<MetaEaseStage>} stages One or more stages.
 */

/**
 * Decoded score metadata ('PACM'): the editor's timeline anchors.
 * @typedef {object} Meta
 * @property {Transport} transport
 * @property {ReadonlyArray<MetaTrack>} tracks
 * @property {ReadonlyArray<MetaControl>} controls
 * @property {ReadonlyArray<MetaScene>} scenes Named windows; `[]` when none.
 * @property {ReadonlyArray<MetaEaseProgram>} easePrograms Deduped easing
 *   program table; `[]` when the score uses only linear easing.
 * @property {ReadonlyArray<MetaTempoSeg>} tempoMap Tempo segments including
 *   segment 0; `[]` for a constant-tempo score (the `'TMPO'` section is
 *   omitted on the wire).
 */

/**
 * One conformance defect reported by `checkAudioTargetHost`
 * (`pacer/host-check`): a stable kebab-case code plus a human message.
 * An empty findings array means the host satisfies the AudioTargetHost
 * contract.
 * @typedef {object} HostFinding
 * @property {string} code Stable finding code (e.g. `param-ncomp`,
 *   `set-param-throws`, `clock-shape`).
 * @property {string} message What was wrong, with the offending spec named.
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
 * The flattened registry entry: the join of all registries, where the
 * flat index IS the `target_id`. Internal to the driver.
 * @typedef {object} FlatTarget
 * @property {string} name
 * @property {number} ncomp
 * @property {number} registry
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
 * @property {() => number} drv_targetsCap
 * @property {(docLen: number, targetsLen: number) => number} drv_load
 * @property {() => number} drv_diagLen
 * @property {() => number} drv_diagPtr
 * @property {() => number} drv_metaLen
 * @property {() => number} drv_metaPtr
 * @property {() => number} drv_writesPtr
 * @property {() => number} drv_exprFailures
 * @property {(seconds: number) => number} drv_eval
 * @property {(tick: bigint) => number} drv_evalTicks
 * @property {(slot: number, x: number, y: number, z: number, w: number) => number} drv_setControl
 * @property {(slot: number) => number} drv_clearControl
 * @property {(targetId: number, registry: number, ncomp: number) => number} drv_registerControl
 * @property {(bpm: number) => number} drv_setBpm
 */

/**
 * The pacer-rt.wasm export surface (the `prt_*` ABI). Modeled explicitly
 * so `PacerRt` type-checks against the boundary instead of reaching
 * through `any`; the constructor casts `instance.exports` to this once.
 * A separate lineage from {@link PacerExports}: `prt_abiVersion` is 1.
 * @typedef {object} PacerRtExports
 * @property {WebAssembly.Memory} memory
 * @property {() => number} prt_abiVersion
 * @property {() => number} prt_pacbPtr
 * @property {() => number} prt_pacbCap
 * @property {() => number} prt_targetsPtr
 * @property {() => number} prt_targetsCap
 * @property {() => number} prt_metaPtr
 * @property {() => number} prt_metaLen
 * @property {() => number} prt_writesPtr
 * @property {(pacbLen: number, targetsLen: number) => number} prt_load
 * @property {() => number} prt_loadError
 * @property {(seconds: number) => number} prt_eval
 * @property {(tick: bigint) => number} prt_evalTicks
 * @property {(slot: number, x: number, y: number, z: number, w: number) => number} prt_setControl
 * @property {(slot: number) => number} prt_clearControl
 * @property {(targetId: number, registry: number, ncomp: number) => number} prt_registerControl
 * @property {(bpm: number) => number} prt_setBpm
 * @property {() => number} prt_exprFailures
 */
