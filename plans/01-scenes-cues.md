# 01 — Scenes / cue lists

**Repo:** pacer
**Wire impact:** appends `Compile.Code` variants; appends a scenes section to `'PACM'`
**Gates:** `zig build verify`, `zig build audit-diagnostics`, npm gate

## Why

Already roadmapped in the `schema/pacer.sjon` header. The impulsos demo encodes every
section as WGSL constants (`B_TUNNEL=148`, `B_DROP=160`, `B_TUN_END=200`, ~60 total) and
hand-computed windows `smoothstep(B_X, B_X+len, beat)`. A `(scene …)` form gives those
windows names, scene-local time, and something the studio timeline can display.

## Design (freeze in Phase 1 before writing code)

```
(scene :name drop :at 160b :dur 60b
  (track :target tunnelAmt
    (key :at 0b :value 0)
    (key :at 4b :value 1 :ease out-cubic)))
```

- A scene is a named window `[at, at+dur)` on the transport tick grid. Scenes may
  overlap. Top-level tracks are unchanged (implicitly un-scened).
- Tracks nested in a scene resolve `:at` positions **scene-relative** (exact integer
  tick addition; overflow → existing `tick_overflow`).
- **Outside its window a scened track emits nothing** (write omitted, like expr NaN
  rejection). Rationale: overlapping scenes can hand a target off; the last-listed
  active scene's track wins by write order. Record this ordering in the corpus golden.
- Scene-scoped expr tracks get two extra env bindings: `scene-beat` (beats since scene
  start) and `scene-phase` (0..1 through the window). Bound only inside a scene; they
  join `reserved_names` in `ExprTrack.zig`.
- Caps: `MAX_SCENES = 64` in `TrackTable.zig`.
- New diagnostics (append, in this order): `scene_invalid`, `scene_duplicate_name`,
  `scene_cap_exceeded`.
- `'PACM'` gains a scenes section (name span, start tick, dur ticks) appended after
  the existing sections — verify the blob's section framing tolerates a new trailing
  section for old decoders before choosing the encoding.

## Phases

### Phase 1 — schema + validation (RED first)
Load: `schema/pacer.sjon`, `src/Compile.zig` (top ~400 lines: manifest, validate stage,
Code enum), one existing diagnostic test as pattern.
Reds: Zig tests in `Compile.zig` — a scene missing `:name`/`:at`/`:dur` →
`scene_invalid`; two scenes named `drop` → `scene_duplicate_name`; 65 scenes →
`scene_cap_exceeded`; a valid scene compiles with zero diagnostics.
Green: add `(scene …)` to the schema manifest (name, time-pos at, time-pos dur,
positional track children); append the three `Compile.Code` variants; validation only —
compile may still ignore scene children (tests assert diagnostics, not evaluation).
Gate: `zig build test`, `zig build audit-diagnostics`.
Carry-forward: exact schema form spelling + the three new code numbers.

### Phase 2 — compile into the table (RED first)
Load: `src/Compile.zig` (track walk), `src/TrackTable.zig`.
Reds: compile-unit tests asserting a scened track's keys land at absolute ticks
(scene at + key at), the scene table holds `{name_span, start_tick, dur_ticks}`,
tracks carry a scene index (`NO_SCENE = maxInt(u16)` sentinel), and scene-relative
overflow → `tick_overflow`.
Green: `SceneTable` slice on `TrackTable` + `Track.scene` field; walk scene children
with the offset applied.
Gate: `zig build test`.

### Phase 3 — eval semantics (RED first)
Load: `src/Eval.zig`, `src/ExprTrack.zig`.
Reds: eval tests — inside the window the scened track writes; one tick before/after it
does not; structural landing holds at scene start; `scene-beat`/`scene-phase` bind in a
scened expr track and are absent (compile diagnostic via dry-run failure) top-level;
loop wrap re-enters scenes correctly.
Green: window gate in the track loop; extra env bindings threaded through `ExprTrack`.
Gate: `zig build test`.

### Phase 4 — ABI + npm meta (RED first)
Load: `src/Abi.zig` (meta encode), `npm/pacer/src/index.js` (meta decode),
`npm/pacer/src/types.js`, one npm meta test.
Reds: Zig `Abi` test round-tripping a scenes section; npm test asserting
`pacer.meta.scenes` = `[{name, startTick, durTicks}]` and that a score with no scenes
yields `[]` (old-blob tolerance).
Green: append the section; mirror in one `DataView` pass; extend the typedef.
Gate: `zig build verify` + npm gate.

### Phase 5 — corpus + docs
Load: `corpus/keys-basic/` as the template, `src/corpus_runner.zig` header.
Work: new case `scenes-basic` (overlapping scenes, handoff ordering, scene expr
bindings, wrap re-entry); `zig build corpus -- --update`, review diff; update the
schema header roadmap note and `CLAUDE.md` if the surface list changes.
Gate: `zig build verify` (native + wasm parity green).

## Progress log
(append phase completions here)
