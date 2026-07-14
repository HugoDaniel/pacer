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
  the existing sections, framed per **the section-framing convention below** (frozen
  2026-07-14 as the Wave 1 gate — see 00's Decision log).

## The `'PACM'` section-framing convention (frozen 2026-07-14 — Wave 1 gate)

This is the canonical spec. Both appenders — 01 Phase 4 (scenes) and 11 Phase 3 (ease
programs) — obey it; the Decision log in `00-strategy.md` points here. Grounded on the
two sides read at the gate (`src/Abi.zig` `encodeMeta`, `npm/pacer/src/index.js`
`get meta`) plus `drv_metaLen` returning the exact encoded length (`wasm_entry.zig:205`).

1. **The core body is frozen at `META_VERSION = 1`, append-only.** magic, version, the
   20-byte transport block, the three counts (`track`/`key`/`control`), then the
   tracks/keys/controls arrays — never reordered, retyped, or removed. `META_VERSION`
   moves ONLY for an incompatible change to this core, which append-only forbids in
   practice. Keep the JS decoder's strict `version !== 1` throw — it stays a genuine
   corruption check precisely because we never bump for a section addition.

2. **Everything after the last control is a section stream, walked to end-of-buffer.**
   Zero or more length-prefixed sections (TLV), each:

   ```
   [section_id u32 LE][payload_len u32 LE][payload : payload_len bytes]
   ```

   `section_id` is a 4-CC read LE, matching the house magic style (`'SCEN'` scenes,
   `'EASE'` ease programs — pick distinct 4-CCs, never reuse). `payload_len` counts
   the payload only, not the 8-byte frame header.

3. **Decoder rule (the tolerance guarantee).** After the `control_count`-th control,
   loop `while (off < len)`: read `id`, read `plen`; if `id` is known, decode
   `bytes[off+8 .. off+8+plen]`; **always** `off += 8 + plen`. Unknown ids skip by
   length — that is the whole point. A decoder that predates the stream (today's
   shipped glue) never runs this loop — it returns after controls — so it ignores every
   section with no throw. Verified: `get meta` has no `off === len` check today.

4. **No version bump per section.** A new section = a new id + a longer blob; the
   version field does not move. If a section's *own* internal layout ever needs a
   breaking change, mint a NEW id (`'SCE2'`), never touch `META_VERSION`. Every v1
   decoder then stays valid forever.

5. **Each id appears at most once**; the encoder emits sections in a fixed documented
   order (scenes before ease-programs). Decoders MUST dispatch by id and MUST NOT rely
   on order or presence. **Omit a section when its count is 0** — an absent section and
   an empty one are equivalent to a decoder, and omitting keeps a no-scenes / no-program
   blob byte-identical to today's (so pre-existing goldens stay byte-stable).

6. **Payload internal shape** is the section's business; the house pattern is
   `[count u32][fixed extern-struct record × count]` with a `comptime @sizeOf` pin
   (mirroring `MetaTrackRec`), plus trailing variable-length bytes after the fixed
   records if needed (as controls append id bytes). A knowing decoder MAY assert
   `payload_len` matches its computed size as a corruption check; the outer `payload_len`
   remains authoritative for skipping.

7. **No alignment.** Controls are already variable-length (idLen), so the stream starts
   at an arbitrary byte; every read is explicit-endian `writeInt`/DataView, so no
   natural alignment is assumed. Sections never pad.

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
Applies the section-framing convention above — this is its first consumer, so it also
transcribes the convention into the `Abi.zig` `//!` header (the format's doc of record)
alongside the actual encoder, and adds the post-controls TLV walk to `get meta`.
Section: `'SCEN'`, payload `[count u32][SceneRec × count]`. Recommended `SceneRec`
(finalize here): `{ start_tick i64, dur_ticks i64, name_span_start u32,
name_span_end u32 }` = 24 B (name carried by span like tracks — the editor has the
source; no id bytes, scenes aren't a setControl lookup key). `comptime @sizeOf` pin +
an `@offsetOf` spot-check, mirroring `MetaTrackRec`. Omit the section when there are 0
scenes (keeps the no-scenes blob byte-identical to today's).
Reds: Zig `Abi` test round-tripping a scenes section (encode a 2-scene score, decode
the TLV frame, assert id/len + records); a second Zig test asserting a NO-scenes score
emits NO `'SCEN'` frame (blob ends exactly at the last control). npm test asserting
`pacer.meta.scenes` = `[{name, startTick, durTicks}]` and that a score with no scenes
yields `[]` — decoded through the walk, proving old-blob tolerance (an unknown trailing
id must skip cleanly; add a Zig test that a synthetic unknown-id section is skipped by
`get meta`'s length walk without disturbing scenes).
Green: append the section per the convention; add the post-controls walk to `get meta`;
mirror in one `DataView` pass; extend the typedef; transcribe the convention into the
`Abi.zig` header.
Gate: `zig build verify` + npm gate.

### Phase 5 — corpus + docs
Load: `corpus/keys-basic/` as the template, `src/corpus_runner.zig` header.
Work: new case `scenes-basic` (overlapping scenes, handoff ordering, scene expr
bindings, wrap re-entry); `zig build corpus -- --update`, review diff; update the
schema header roadmap note and `CLAUDE.md` if the surface list changes.
Gate: `zig build verify` (native + wasm parity green).

## Progress log

- **Phase 1 — schema + validation (done, 2026-07-14).** RED first: four Zig tests in
  `Compile.zig` referencing enum members that did not exist yet — `zig build test`
  failed to compile (`enum 'Compile.Code' has no member named 'scene_invalid'`;
  `TrackTable has no member named 'MAX_SCENES'`), the intended red. GREEN in three
  edits:
  - **Schema** (`schema/pacer.sjon`): two value-kinds — `scene-name` (`:underlying
    symbol`, next to `target-name`) and `track-section` (`:underlying form :heads
    (head-set :names [track])`, next to `key-section`/`stage-section`) — plus the form
    `(form :name scene :positional track-section (key :name name :type scene-name
    :optional true) (key :name at :type time-pos :optional true) (key :name dur :type
    time-pos :optional true))`, inserted between `transport` and `track`.
  - **Diagnostics** (`Compile.zig` `Code` enum, append-only): `scene_invalid` = **23**,
    `scene_duplicate_name` = **24**, `scene_cap_exceeded` = **25** (26 codes total, 0…25).
  - **Validation** (`Compile.zig`): `Builder.validateScenes`, called from `build()`
    after `buildTracks` and before the diag-count gate. Walks the top-level forest for
    `(scene …)` forms; enforces the `MAX_SCENES = 64` cap (added to `TrackTable.zig` with
    a `comptime <= maxInt(u16)` layout assert); emits `scene_invalid` when any of
    `:name`/`:at`/`:dur` is absent; tracks seen names (arena-backed) and emits
    `scene_duplicate_name` on a repeat (span on the `:name` node).

  **Design frozen (the carry-forward):** `:name`/`:at`/`:dur` are schema-**optional** on
  purpose — a missing one must surface as the pacer `scene_invalid` code (wire-stable,
  with a span the studio can show), NOT a generic SJON missing-key error. If they were
  schema-required, the absence would set `hasErrors()`, `build()` would never run, and no
  pacer diagnostic would exist — the RED could not be satisfied. So presence is a pacer
  check, uniformity of the `*_invalid` family (cf. `transport_invalid`, `control_invalid`).
  Scene children are NOT walked into the table yet (that is Phase 2); nested `(track …)`
  forms are children, not forest entries, so `buildTracks` never sees them and a valid
  scene compiles clean with an empty tracks table. Gate: `zig build test` ✓,
  `zig build audit-diagnostics` ✓ (26/26, the three scene codes covered by name); also ran
  `zig build corpus` ✓ (13/13 — the manifest grew but diagnostics are stored in user
  coordinates via `userOffset`, so goldens stayed byte-identical). No JS/TS touched.

- **Phase 2 — compile into the table (done, 2026-07-14).** RED first: two Zig tests in
  `Compile.zig` referencing `table.scenes`, `TrackTable.NO_SCENE`, and `Track.scene`
  before any existed — `zig build test` failed to compile (`no field named 'scenes' in
  struct 'TrackTable'`), the intended red. GREEN:
  - **`TrackTable.zig`**: new `Scene` struct `{ name_span: sjon.Ast.Span, start_tick,
    dur_ticks : Tick }` and a `scenes: []const Scene = &.{}` table slice (document order);
    a `scene: u16` field on `Track` (the owning scene index); `pub const NO_SCENE: u16 =
    maxInt(u16)` sentinel for top-level tracks (comptime-asserted `>= MAX_SCENES`, so it
    can never alias a real index). Header invariant list + the `//!` doc updated.
  - **`Compile.zig`**: extracted the per-track body of `buildTracks` into a reusable
    `buildTrackForm(ta, transport, idx, offset, scene, …) Error!bool` — offset added to
    every key tick, `scene` recorded on the `Track`; returns `false` only when a key-cap
    stops the whole walk (the track cap stays a caller-side pre-check). `buildKey` gained
    an `offset` param and folds the scene start in via `std.math.add` (overflow →
    `tick_overflow`; offset 0 is a provable no-op, so the top-level tick path is
    byte-identical). `validateScenes` became `buildScenes`: same three shape checks, but a
    sound scene now records its window in `scenes` and walks its child `(track …)` forms
    through `buildTrackForm` with `offset = scene.start_tick`.

  **Design frozen (carry-forward for Phase 3/4):** (a) **write order** — top-level tracks
  build first (`buildTracks`), then scenes in document order (`buildScenes`), so a later
  scene's track lands after an earlier one's; that's the handoff order Phase 3's window
  gate + Phase 5's corpus rely on (last-listed active scene wins by write order). (b)
  **`name_span` is the `:name` symbol's span** (combined coords, like `track_spans`), so
  Phase 4's `SceneRec` carries `{start_tick, dur_ticks, name_span}` and the editor slices
  the name from source — no name bytes in the blob. (c) Phase 2 does NOT yet gate eval on
  the window — a scened track evaluates unconditionally (its keys just sit at absolute
  ticks); the window gate + `scene-beat`/`scene-phase` env are Phase 3. (d) No scene
  `:dur`-positivity check yet — an empty `[at, at)` window is harmless (never active); add
  it with Phase 3 if the eval gate wants it. Gate: `zig build test` ✓, `zig build corpus`
  ✓ (13/13 byte-identical — no existing case has scenes, offset-0 add is identity),
  `zig build audit-diagnostics` ✓ (26/26), `zig build wasm` ✓ (still compiles; ABI
  untouched — Phase 4). No JS/TS touched.

- **Phase 3 — eval semantics (done, 2026-07-14).** RED first: three Zig tests in
  `Eval.zig` — a scened track that writes one tick before its window (len 1, want 0), a
  `:expr scene-beat` scored track that fails to compile (`scene-beat` unbound → the
  `compileScore` helper's `r.ok()` assert trips), and a loop wrap where the pre-window tick
  still writes. All three failed as intended; green after the edits.
  - **`Eval.zig`**: a window gate at the top of the track loop — a `Track.scene != NO_SCENE`
    track is skipped (write OMITTED, like an expr-NaN) unless the WRAPPED tick `t` is in
    `[start, start+dur)`, so an overlapping later scene hands the target off by write order
    and loop end-behavior re-enters scenes. The owning `Scene` is also passed to
    `ExprTrack.evalAt` for the scened expr env.
  - **`ExprTrack.zig`**: `evalAt`/`bindTime` gained a `scene: ?TrackTable.Scene` param that
    binds two child-scope names — `scene-beat` = `beatOf(tick − start)` (beats since the
    window opened) and `scene-phase` = `(tick − start) / dur` in f64 (0..1 through it, a
    fresh eval-time division like the lerp `u`; a non-positive/degenerate window reports 0
    rather than dividing). Both join `reserved_names` (a control can no longer shadow them);
    `MAX_BINDINGS` 8→10. `emitValue` passes `null` (clock lanes are never scene-local).
  - **`Compile.zig`**: `buildScenes` now guards the window end with a checked
    `std.math.add(start, dur)` (overflow → `tick_overflow`), so the eval-time `start + dur`
    compare can never overflow. `buildTrackForm`/`dryRunExpr` thread the owning `Scene`
    through; a scened expr track **dry-runs at its scene start** (`scene-beat`/`scene-phase`
    at 0, and a real in-window tick) rather than at t = 0, so a `(/ 1 beat)` sound over the
    window is not spuriously rejected for a beat-0 it never sees, and a top-level
    `scene-beat` reference is still caught as `UnknownBinding` (→ `expr_eval_failed`).

  **Design frozen (carry-forward for Phase 4/5):** (a) **`scene-beat`/`scene-phase` are
  reserved env names** (now in `ExprTrack.reserved_names`) bound only inside a scene, exactly
  like `dur` in a bounded score — a top-level reference is an `expr_eval_failed` diagnostic.
  (b) **`scene-phase` is a new eval-time f64 division** — deterministic (IEEE, like `beatOf`
  /`phaseOf`/lerp), NOT the seconds↔ticks `mul+floor` seam; Phase 5's corpus must pin its
  exact bytes. (c) The **window-end `tick_overflow` guard** joins buildKey's fold as a
  determinism seam; a non-positive `:dur` stays lenient (never-active window, phase 0) — no
  new diagnostic, so the code set stays 26. (d) The window gate uses the WRAPPED tick, so
  loop wrap re-enters scenes; the compile dry-run tick for a scened expr track is its scene
  start. Gate: `zig build test` ✓, `zig build corpus` ✓ (13/13 byte-identical — no scene
  case exists yet; the change is compile+eval only), `zig build audit-diagnostics` ✓
  (26/26 — no new codes), `zig build wasm` ✓, `zig build fuzz` ✓ (the new hot-path add/sub
  never panic). No JS/TS touched (ABI is Phase 4).

- **Phase 4 — ABI + npm meta (done, 2026-07-14).** RED first: two Zig tests in `Abi.zig`
  referencing `SCENES_SECTION_ID`/`SCENE_REC_LEN`/`META_SECTION_HEADER_LEN` before they
  existed (`zig build test` failed to compile — `use of undeclared identifier
  'SCENES_SECTION_ID'`), plus two npm tests reading `driver.meta.scenes` (undefined →
  assertion fail). Green after the edits. This is the **first consumer of the 'PACM'
  section-framing convention** (§ above): the convention text is now transcribed verbatim
  into the `Abi.zig` `//!` header (the format's doc of record), alongside the encoder.
  - **`src/Abi.zig`**: `MetaSceneRec` extern struct `{ start_tick i64, dur_ticks i64,
    name_span_start u32, name_span_end u32 }` = 24 B, with a `comptime @sizeOf` pin and an
    `@offsetOf(name_span_start) == 16` spot-check (mirrors `MetaTrackRec`). New pub consts
    `META_SECTION_HEADER_LEN = 8`, `SCENES_SECTION_ID = 0x4e454353` (`'SCEN'` LE),
    `SCENE_REC_LEN = 24`. `metaEncodedLen` adds `8 + 4 + n·24` **only when `scenes.len >
    0`**; `encodeMeta` appends the `'SCEN'` TLV frame (`[id][payload_len][count][rec×n]`)
    after the last control, name via `userSpan` (like every other meta span). Omit-when-
    empty keeps a no-scenes blob byte-identical to a pre-Phase-4 one.
  - **`src/wasm_entry.zig`**: the `META_CAP` comptime bound now includes a full `'SCEN'`
    section (`+ 8 + 4 + MAX_SCENES·24`); 192 KiB still has ample headroom.
  - **`npm/pacer/src/index.js`**: a post-controls `while (off < len)` TLV walk — read
    `id`/`payload_len`, decode `'SCEN'`, **always** `off += 8 + payload_len` (unknown ids
    skip by length). `meta.scenes` = `[{ name, startTick, durTicks, nameSpan }]`, `[]` when
    none. A new `#docBytes` field (the reload's UTF-8 doc) is the slice source for scene
    names — spans are USER coordinates, matching those bytes exactly.
  - **`npm/pacer/src/types.js`**: `MetaScene` typedef + `scenes` on `Meta`.

  **Design frozen (carry-forward for Phase 5 / plan 11):** (a) **`'SCEN'` = 0x4e454353 is
  now claimed** in the section stream — 11 Phase 3 (ease programs) must pick a distinct 4-CC
  (`'EASE'`) and the encoder emits scenes BEFORE ease-programs (fixed documented order,
  though decoders dispatch by id and must not rely on order). (b) **Scene names ride as
  spans, not inline bytes** — the glue slices from `#docBytes`, so any consumer producing a
  scene `name` needs the score source (the editor already has it). (c) The unknown-id
  tolerance is the convention's whole point (rule §3): a `while (off < len)` walk that always
  advances by `8 + payload_len` skips sections it predates without a throw — pinned by a Zig
  test that walks a synthetic `[unknown 'ZZZZ' frame][real 'SCEN' frame]` stream and still
  finds the scene. Gate: `zig build verify` ✓ (native test + corpus **13/13 byte-identical**
  — omit-when-empty holds; + npm **45/45** wasm parity), `zig build audit-diagnostics` ✓
  (26/26 — no new codes), npm `lint`/`typecheck` ✓. Corpus `scenes-basic` (Phase 5) is the
  first case to exercise the `'SCEN'` bytes end-to-end.
