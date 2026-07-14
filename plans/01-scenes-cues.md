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
(append phase completions here)
