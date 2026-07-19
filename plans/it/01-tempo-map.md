# 01 — Tempo-map transport (`(tempo …)` segments)

**Repo:** pacer
**Wire impact:** one appended `Compile.Code` variant; one new `'PACM'` TLV
section `'TMPO'` (append-only, omit-when-degenerate); no `'PACT'`/`'PACW'` change
**Gates:** `zig build verify` + `audit-diagnostics`; npm gate
**Size:** the largest plan of this set — it touches a determinism seam. Five
phases, each one context window.

## Why

The transport is constant-BPM. Tracker modules (and any real piece of music)
change tempo: batida's `export-score` can only emit second-unit positions for
tempo-mapped modules today — sync-exact but musically unreadable, and the
studio timeline's beat grid lies (filed as a risk in the batida set, it 09).
Engine-agnostic by design: a tempo map is plain score data any producer can
emit — batida from a module walk, a hand edit, a DAW export.

## Design (freeze in Phase 1)

New top-level form, one per tempo change, generated-text friendly:

```
(transport :bpm 125 :meter [4 4] :dur 400b :end loop :emit [beat bpm])
(tempo :at 160b :bpm 150)
(tempo :at 200b :bpm 96.5)
```

- **Segments**: transport `:bpm` is segment 0 at tick 0; each `(tempo …)`
  starts a new segment. `:at` must be **> 0, strictly ascending, b/bar units
  only** (an `s` position is circular — it would need the map being defined;
  the trigger `:at` discipline: reject, don't sort). `:bpm` reuses the
  `bpm-value` kind (1..1000, fractional legal). Both keys schema-optional →
  every shape defect is a `tempo_map_invalid` diagnostic with a span (the
  scene/trigger discipline), NOT a bare SJON error. Duplicate/descending
  `:at`, `:at 0b`/negative, unit `s`, missing key → `tempo_map_invalid`.
  Cap `MAX_TEMPO_SEGMENTS = 512` (generators coalesce adjacent-equal bpm;
  overflow → `tempo_map_invalid` with the first overflowing form's span).
- **Only seconds↔ticks moves.** Keys/scenes/triggers in b/bar are already
  exact integer ticks and stay untouched; `beat`/`bar`/`phase`/`beats-since`
  are tick-derived and stay untouched. The piecewise map lives entirely in
  `TimeMap`: a compile-built table `{tick_i, sec_i (f64), tps_i (f64)}` with
  cumulative `sec_i` accumulated in one documented op order. Conversion =
  linear scan to the active segment (≤512, ascending, deterministic) + the
  same one `mul + floor` as today against the segment origin. The degenerate
  1-segment table MUST take the exact code path that reproduces today's math
  bit-for-bit — every existing golden stays byte-identical (pinned in
  Phase 5).
- **Loop/hold wrap in seconds, then convert.** Today eval wraps ticks; under a
  map, tick-wrapping would replay iteration 2 at the final segment's tempo.
  New order: `loop_secs = sec(dur_ticks)` (exact f64 from the table, computed
  once at compile); `:end loop` → `t' = fmod(t, loop_secs)`; `:end hold` →
  clamp `t` at `loop_secs`; then one seconds→ticks conversion. IEEE `fmod` is
  exact, but this is a **new determinism seam** — documented next to the
  `mul + floor` seam, corpus-pinned (Phase 5). Degenerate 1-segment scores:
  the seconds-wrap result must equal today's tick-wrap result bit-for-bit
  (Phase 2 red).
- **Env + emit**: the `bpm` binding (expr env and the `:emit [bpm]` lane)
  becomes "active segment's bpm at the wrapped tick" — a step function, f64
  exact from the score literal. `t` stays the raw input seconds; `dur`/
  `cycle`/`beat`/`bar`/`phase` unchanged.
- **Wire**: `'PACM'` grows a `'TMPO'` TLV section after `'EASE'` (fixed emit
  order, decoders dispatch by id): `[count u32][{tick i64 LE, bpm f64 LE} ×
  count]`, **including** segment 0 (self-contained; consumers need no
  transport join). Omit when count == 1 — old blobs and mapless scores stay
  byte-stable. Section 4-CC is wire-stable per the ../01 framing convention;
  `META_VERSION` never bumps. `tempo_map_invalid` is appended to
  `Compile.Code` at the next free number (by-name audit test names it; never
  renumber).

## Phases

### Phase 1 — schema + validation (RED first)
Load: `schema/pacer.sjon` (transport + trigger forms as pattern),
`src/Compile.zig` (transport handling + Code enum), one diag test as pattern.
Reds: missing `:at`/`:bpm` → `tempo_map_invalid` with the form's span;
`:at 0b`, descending pair, duplicate tick, `:at 30s` → `tempo_map_invalid`;
513 generated forms → cap diagnostic; clean two-segment score compiles with 0
diags; a `(tempo …)` with no `(transport …)` joins the default transport.
Green: `tempo` form in the schema; `Transport.segments` slice built + checked
at compile (sorted invariant established here, so eval never sorts).
Gate: `zig build test`, `audit-diagnostics` (one new code, tested by name),
`zig build wasm` (freestanding still compiles).

### Phase 2 — the piecewise TimeMap (RED first)
Load: `src/TimeMap.zig` (whole — it is small and IS the seam), CLAUDE.md's
determinism-seams section.
Reds: two-segment map — seconds→ticks lands exactly on hand-computed ticks on
both sides of the boundary and AT it; ticks→seconds inverts on segment
origins; **degenerate 1-segment: bit-identical to the current implementation
across a sweep of times** (keep the old function in the test as the oracle);
loop wrap: t past `loop_secs` with a mid-score tempo change lands in the
correct EARLY segment (the bug the seconds-wrap exists to prevent); hold
clamps at `loop_secs`; `TickOverflow` still guards.
Green: segment table (cumulative build, documented op order) + conversions +
seconds-domain wrap/clamp; `bpm` env lookup by wrapped tick.
Gate: `zig build test`.

### Phase 3 — eval integration (RED first)
Load: `src/Eval.zig`, `src/ExprTrack.zig` (env binding), `src/TrackTable.zig`.
Reds: a key `:at 90s` in a tempo-mapped score lands on the map-correct tick
(not the constant-bpm tick); same for a scene `:at`/`:dur` and a trigger `:at`
in `s`; `:emit [bpm]` steps at the boundary and a `(track :expr bpm)` matches
it bit-exactly (the ../04 emit-vs-expr discipline); a trigger's
`beats-since` lane is unaffected by the map (tick-derived).
Green: all `s`-unit resolution routed through the map (one seam, no
duplicated formulas — `TimeMap` is the only converter).
Gate: `zig build test`.

### Phase 4 — wire + npm parity (RED first)
Load: `src/Abi.zig` (`encodeMeta` + the `//!` framing spec),
`npm/pacer/src/index.js` (`get meta`), `npm/pacer/src/types.js`.
Reds (JS side runs against a rebuilt wasm): `meta.tempoMap` decodes
`[{tick, bpm}]` for a mapped score; absent (undefined/empty) for a mapless
score — old-blob tolerance by the TLV walk; a types lockstep test.
Green: `'TMPO'` encode (omit-when-1) after `'EASE'`; Abi `//!` header row; npm
DataView decode + `MetaTempoSeg` typedef.
Gate: `zig build verify` + npm gate. Decide here (log it): whether the studio
timeline consumes `meta.tempoMap` now or a later studio plan draws it.

### Phase 5 — goldens + seams doc (RED first)
Load: `corpus/transport-emit/` as template, `src/corpus_runner.zig`
`renderMeta`, `npm/pacer/test/corpus.test.js` parity renderer.
Work: `tempo-map/` golden — two segments + a `90s` key + `:emit [beat bpm]` +
a loop wrap crossing the boundary + a hold edge; `diag-tempo/` golden freezing
`tempo_map_invalid`'s number + span + message native == wasm; extend BOTH
`renderMeta`s with `(mtempo :tick T :bpm B)` lines (the ../01 both-renderers
rule); `zig build corpus -- --update`, review: **every pre-existing golden
must be byte-identical** (the degenerate-path pin). Amend CLAUDE.md's
determinism-seams list (piecewise table build + the loop-wrap `fmod`) and the
README score-language paragraph.
Gate: `zig build verify` (all cases native+wasm) + npm gate + audit.

## Progress log

(empty — plan not started)
