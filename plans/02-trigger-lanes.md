# 02 — Trigger / event lanes

**Repo:** pacer
**Wire impact:** appends `Compile.Code` variants; **no** `'PACW'` change (triggers write
ordinary entries to host-registered targets)
**Gates:** `zig build verify`, `zig build audit-diagnostics`, npm gate

## Why

The demo hand-rolls the same event idioms in five WGSL modules: per-beat pulse
`pow(1.0 - fract(beat), 4.0)`, backbeat gate `f32(i32(floor(beat)) & 1)`, "beats since
the tap" `fract((beat - 1.5) / 4.0) * 4.0`. A `(trigger …)` form emits those as lanes
so the shader reads a value instead of re-deriving clock math.

## Design (freeze in Phase 1)

```
(trigger :target snare :every 2b :offset 1b)          ; periodic
(trigger :target drop  :at [160b 220b 256b])          ; explicit hits
```

- Events are exact integer ticks: `offset + k·every` (periodic) or the sorted `:at`
  list. `:every` must be > 0 ticks; positions use existing time-pos units.
- At eval tick T the trigger finds the last event ≤ T (none yet → write omitted) and
  writes lanes **in this fixed order, truncated to the target's registry ncomp**:
  1. `phase` — 0..1 progress from that event to the next (explicit-list last event or
     one-shot: seconds-based decay is host business; phase holds 1.0)
  2. `count` — 0-based event index as f32
  3. `gate` — 1.0 on the exact event tick, else 0.0 (structural, like key landing)
  4. `beats-since` — beats elapsed since the event
  So an ncomp-1 target gets just `phase`; ncomp-4 gets all four.
- Phase/beats-since derive from tick deltas through the one documented f64 seam —
  specify the op order in the plan's Phase 3 test names so the golden pins it.
- Loop wrap: event schedule is defined on the unwrapped local timeline (wrap first,
  then resolve), matching track semantics.
- Trigger is a third kind of table row: reuse `Track` with a new `source` variant
  (internal representation, not wire). Counts against `MAX_TRACKS`.
- Scened triggers (if plan 01 landed): positions scene-relative, active only in-window.
- New diagnostics (append): `trigger_invalid` (missing/duplicate source, `:every` ≤ 0,
  empty/unsorted `:at`), `trigger_target_unknown` NOT added — reuse `unknown_target`.

## Phases

### Phase 1 — schema + validation (RED first)
Load: `schema/pacer.sjon`, `src/Compile.zig` (Code enum + validate stage), an existing
diagnostic test as pattern.
Reds: `(trigger)` with no `:every` and no `:at` → `trigger_invalid`; both →
`trigger_invalid`; `:every 0b` → `trigger_invalid`; unknown target → `unknown_target`;
valid periodic + valid list compile clean.
Green: schema form + appended `trigger_invalid`; validation only.
Gate: `zig build test`, `zig build audit-diagnostics`.

### Phase 2 — compile (RED first)
Load: `src/Compile.zig` (track walk), `src/TrackTable.zig`.
Reds: compiled table holds the trigger row with resolved tick schedule (periodic params
or an owned sorted tick slice), correct target/registry/ncomp join; schedule ticks past
2^53 → `tick_overflow`; trigger + 255 tracks → `track_cap_exceeded`.
Green: `Track.source` gains the trigger variant; arena-owned tick list.
Gate: `zig build test`.

### Phase 3 — eval (RED first)
Load: `src/Eval.zig`, `src/TimeMap.zig` (seconds seam reference).
Reds: point-sample tests — before first event: no write; on the exact event tick:
gate=1, phase=0, count=k; mid-interval: gate=0, phase in (0,1), beats-since exact;
after the last `:at` event: phase=1 held; ncomp truncation (ncomp-1 target gets phase
only, lanes above ncomp zeroed in the entry); loop wrap resets count per local
timeline; f64→f32 truncation only at emission.
Green: eval arm for the trigger source; binary-search or cached-cursor event lookup
(reuse the last-segment cache idea for O(1) near-monotonic sampling).
Gate: `zig build test`.

### Phase 4 — corpus + parity + docs
Load: `corpus/expr-control/` as template.
Work: new case `trigger-basic` (periodic ncomp-4, explicit-list ncomp-1, wrap, exact
event ticks in `times.sjon`); `zig build corpus -- --update` + diff review; npm needs
no code change (entries are ordinary writes) but add one `npm/pacer` test asserting a
trigger write flows through `toUniforms`; update `CLAUDE.md` surface table if needed.
Gate: `zig build verify` + npm gate.

## Progress log

### Phase 1 — schema + validation (done, 2026-07-14)

**RED first.** Appended `trigger_invalid` (= **26**) to `Compile.Code` (so the tests
compile), then wrote five tests and ran `zig build test` → 4 fail + 1 crash: with no
schema `trigger` form, `(trigger …)` is an unknown head, so SJON rejects the doc and
*no* pacer diagnostic is emitted (`findDiag(.trigger_invalid)` is null, the valid case
never reaches `ok()`). Green after the schema form + a `validateTriggers` stage.

**Design frozen.** `(trigger :target T :every Nb :offset Mb)` (periodic) XOR
`(trigger :target T :at [P …])` (explicit hits). Both `:every` and `:at` are
**schema-optional**, so every trigger-shape defect routes through the pacer
`trigger_invalid` code (with a span), not a bare SJON missing-key error — the scene
discipline. Rules validated in Phase 1:
- **Source XOR** — neither or both → `trigger_invalid` (span on the form).
- **`:every` > 0 ticks** — a non-positive interval → `trigger_invalid` (span on the
  `:every` value). Overflow is `tick_overflow` via `posToTick`.
- **`:at` non-empty + strictly ascending in TICK order** — empty, descending, or a
  tie → `trigger_invalid` (span on the list). NOTE this DIFFERS from tracks, which
  *sort* their keys; triggers *reject* unsorted `:at` (so `[1bar 2b]`, descending once
  converted, is rejected). Overflow of any element is `tick_overflow`.
- **Unknown target reuses `unknown_target`** — no trigger-specific target code (per
  the design). `:offset` is unvalidated in Phase 1 (any tick; ignored without
  `:every`); it resolves in Phase 2.

**Validation-only.** A well-formed trigger emits nothing and builds *no* table row yet
(Phase 2) — it just passes the diag gate, so a `(transport …)` + valid triggers with no
tracks compiles clean (`ok()`, 0 diagnostics). Any trigger defect nulls the whole table
via the existing `build()` diag-count gate.

**Schema.** Added the `trigger` top-level form + a `time-pos-list` value-kind (a
`(vector-shape :element time-pos)` with **no** min-len, so an empty `:at` reaches pacer
rather than tripping a schema type error). Header comment now lists `trigger`.

**Carry-forward for Phase 2 (compile).** (1) **Scened triggers are DEFERRED to Phase
2**: the `scene` form's `:positional track-section` still allows only `track` heads, so
a `(trigger …)` inside a `(scene …)` is currently a schema error. Phase 2 widens that
positional AND walks scene-child triggers scene-relative (reusing the scene start offset
+ `tick_overflow` fold from `buildTrackForm`), so the schema widening and the compile
walk land together. `validateTriggers` walks the top-level forest only for now. (2) The
Phase 2 table row reuses `Track` with a new `source` variant (periodic params or an
arena-owned sorted tick slice) + `Track.scene` for the owning window.

**Gate.** `zig build test` exit 0 (5 new trigger tests green); `zig build
audit-diagnostics` **27/27** (`trigger_invalid` referenced by name); `zig build verify`
green — native corpus **14/14 byte-identical** (the schema addition shifted no golden;
user coords are manifest-independent) + wasm parity **46/46**. No wire surface beyond the
appended `Compile.Code` variant; `'PACT'`/`'PACD'`/`'PACM'`/`'PACW'` bytes unmoved.

### Phase 2 — compile into the table (done, 2026-07-14)

**RED first.** Added the structural scaffolding so the test file compiles — a `.trigger`
variant on `TrackTable.Source` (carrying a new `TrackTable.Trigger` union) plus the
`.trigger` arms the exhaustive switches now demand (`Eval` no-op, `Abi` meta encode,
`corpus_runner` render) — then wrote six Phase 2 tests and ran `zig build test` → **4 fail
+ 2 crash**: with `validateTriggers` still validation-only, a valid trigger builds no row
(the direct `tracks[0]` accesses index an empty table → crash; the row-count/scene/cap
tests fail their expects). Green after replacing `validateTriggers`/`validateAtList` with
row-building `buildTriggers` / `buildTriggerForm` / `buildAtList`, widening the `scene`
positional, and walking scene-child triggers.

**The table row.** A trigger is a third `Track` row kind — same target/registry/ncomp/scene
join, no keys. `Source` gained a `.trigger` variant holding a `TrackTable.Trigger`:
- `periodic { every: Tick, offset: Tick }` — the interval (> 0) and the ABSOLUTE phase
  (scene start folded into `:offset`); the schedule is unbounded, so eval will divide
  rather than materialize it.
- `at: []const Tick` — an arena-owned, strictly-ascending, ≥ 1-element slice; `buildAtList`
  folds the scene start into each position and rejects empty/tie/descending (in tick order)
  as `trigger_invalid`. The uniform offset add preserves order, so the ascending check is
  equivalent before or after the fold. This union is INTERNAL — it never crosses the wire.

**Scened triggers (the Phase 1 carry-forward).** The `scene` `:positional` value-kind was
renamed `track-section` → `scene-section` and its head-set widened to `[track trigger]`, so
`(scene … (trigger …))` validates. `buildScenes`' child loop now dispatches `track` →
`buildTrackForm` and `trigger` → `buildTriggerForm` (both count against `MAX_TRACKS`,
cap checked in the caller). A scened trigger folds the scene start into every `:at` tick and
into the periodic `:offset` with a checked add — overflow raises `tick_overflow` (span on
the offending position / offset), exactly like `buildKey`'s scene-relative fold. Top-level
triggers keep offset 0 (the fold can never overflow, matching `buildKey`).

**`:offset` resolved.** Defaults to 0, converted via `posToTick`, and consulted ONLY in the
periodic branch (ignored with `:at`, as Phase 1 promised). A trigger past the cap fires
`track_cap_exceeded`; `:every` ≤ 0 and the source XOR stay `trigger_invalid` (unchanged from
Phase 1, now inside `buildTriggerForm`).

**Wire.** `'PACM'` `MetaTrackRec.source` gained value **2 = trigger** (append-only after
`0 keys` / `1 expr`; key range 0/0, `META_VERSION` unbumped) — the `Abi` header + struct
comment and the `corpus_runner` source→name switch (`2 => "trigger"`) were updated to match.
No `'PACW'` change (a trigger's writes are ordinary entries, landing in Phase 3). No corpus
case has a trigger yet, so nothing shifted.

**Carry-forward for Phase 3 (eval).** `Eval`'s track loop has a `.trigger => {}` no-op arm
(a trigger writes nothing yet) — that is where the lane sampling lands: at wrapped tick T,
find the last event ≤ T (periodic: `floor((T − offset) / every)` with events ≥ 0; explicit:
binary-search / cached cursor over the `at` slice), then write (phase, count, gate,
beats-since) truncated to ncomp — before the first event OMIT the write; the last explicit
event holds phase 1.0. `has_expr` correctly ignores `.trigger` (no scratch needed). The
scene-window gate already brackets trigger rows (Phase 1/2 scened triggers carry the index).

**Gate.** `zig build test` exit 0 (6 new Phase 2 trigger tests green); `zig build
audit-diagnostics` **27/27** (no new code — cap/overflow/unknown-target/trigger_invalid all
reused); `zig build verify` green — native corpus **14/14 byte-identical** + wasm parity
**46/46**; `zig build corpus` 14/14. No wire bytes moved for the existing corpus.

### Phase 3 — eval (done, 2026-07-14)

**RED first.** With the `.trigger => {}` no-op still in `Eval` (Phase 2 carry-forward), added
five Phase 3 tests and ran `zig build test` → **4 failed**: every value-expecting probe got
an omitted (len-0) write. Green after replacing the no-op with an `evalTrigger` arm. (The
two omit-only checks and the byte-identical determinism test passed under the no-op — a
trigger that writes nothing is still deterministic — so they guard the seam rather than
drive it.)

**The eval arm.** `evalTrigger(map, track, sched, t, cache)` samples the schedule at the
already-wrapped, already-scene-gated tick `t` and returns `?Writes.Entry` (`null` before the
first event → the write is OMITTED, like an expr-NaN or an out-of-window scene, so *whether*
a trigger writes at time t is a pure function of t):
- **periodic** — `k = @divFloor(t − offset, every)`; `k < 0` ⇒ omit; else `event = offset +
  k·every`, and the schedule is unbounded so `span = every` (always a next event). One
  integer floor-division, no materialized schedule.
- **explicit `:at`** — `t < at[0]` ⇒ omit; else the last `at[k] ≤ t` via the SAME
  near-monotonic cursor cache keyframes use (`seg_cache[i]`, restart-on-backwards-seek), then
  `span = at[k+1] − at[k]`, or `0` for the last event.

**The four lanes** (frozen order, truncated to the target's `ncomp` — lanes above `ncomp`
stay zeroed in the entry, exactly like a key track's unused components):
1. `phase` — `(t − event)/span` ∈ [0,1); `span == 0` (last explicit event) holds **1.0**.
2. `count` — the 0-based event index `k` as f32.
3. `gate` — **1.0** exactly on the event tick (`t − event == 0`), else 0.0 — structural, like
   a key landing on its own value.
4. `beats-since` — `(t − event)/ppb`, i.e. `map.beatOf(t − event)`.

Each lane is an i64 tick delta narrowed to f32 ONLY here at emission; `phase` and
`beats-since` are each one f64 division in the documented op order (`f64(delta) / f64(span)`
and `beatOf`), so the golden pins byte-for-byte. **Loop wrap** needs no special handling: the
caller wraps `t` before the switch, so `count`/`gate`/`phase` reset per local timeline for
free (tested: 9b under a 2-bar loop reads `count 0` / `gate 1`, not the unwrapped `k=4`).
**Scened triggers** reuse the caller's window gate + the Phase 2 absolute-tick fold, so
`evalTrigger` is scene-agnostic (tested: a scene at 4b with `:offset 1b` first fires at 5b,
falls silent at the 12b window end).

**No wire / no diagnostics.** Eval-only: no `Compile.Code`, no `'PAC*'` byte moved, no corpus
case yet (Phase 4). The module header gained a "Trigger tracks:" sentence beside the keyframe
/ expr descriptions.

**Gate.** `zig build test` exit 0 (5 new Phase 3 trigger tests green); `zig build verify`
green — native corpus **14/14 byte-identical** + wasm parity **46/46**; `zig build
audit-diagnostics` **27/27** (unchanged — Phase 3 adds no code).

**Carry-forward for Phase 4 (corpus + parity + docs).** New corpus case `trigger-basic`:
a periodic ncomp-4 target + an explicit-list ncomp-1 target, with `times.sjon` hitting a
pre-first-event tick (omitted write), exact event ticks (gate 1), a mid-interval, a
held-last-event, and a loop wrap. `zig build corpus -- --update` then REVIEW the diff (this
is the first golden to carry `source == 2` / a `"trigger"` meta row and trigger writes).
npm needs no driver code (trigger writes are ordinary `'PACW'` entries) but add one
`npm/pacer` test asserting a trigger write flows through `toUniforms`, and decode `source ==
2` in the meta mirror if the JS names track sources. Update `CLAUDE.md`'s surface table only
if a row is now inaccurate.

### Phase 4 — corpus + parity + docs (done, 2026-07-14)

**RED first.** Added `corpus/trigger-basic/{doc,times}.sjon` with no `expected.sjon` and ran
`zig build corpus` → **1 failed** (`trigger-basic: cannot read expected.sjon` — the case is
wired into the gate but has no golden). Green after `zig build corpus -- --update` generated the
golden; then the wasm-parity half went RED (`corpus parity: trigger-basic`) because the JS meta
mirror named the trigger source `expr`, fixed below.

**The case.** `trigger-basic` is a 2-bar 120 bpm 4/4 loop with two top-level triggers:
`(trigger :target pulse :every 1b :offset 1b)` into an **ncomp-4** target (all four lanes) and
`(trigger :target hit :at [2b 5b 7b])` into an **ncomp-1** target (phase only, on registry 1 — a
trigger write carries its bus flag). The nine `times` walk the whole frozen contract and I checked
every write by hand against the golden before trusting it:
- **beat 0** — both before their first event → **empty write buffer** (pre-first omit).
- **beat 1 / 2 / 3 / 5** — pulse on its exact event tick → `gate 1`, `phase 0`, `count` = k
  (0/1/2/4); **beat 2 / 5** hit exact → phase 0 (first-of-list has a real `span`, not the held
  1.0).
- **beat 1.5** — pulse mid → `phase 0.5`, `gate 0`, `beats-since 0.5`; **beat 3** hit mid →
  `phase 1/3` = `3EAAAAAB` (non-dyadic, pins the f64→f32 seam).
- **beat 7.5** — hit **holds its last `:at` event at phase 1.0** (span 0); pulse mid k=6.
- **beat 8 (= :dur)** — wraps to tick 0 → both omit again (empty buffer).
- **beat 9** — wraps to 1b → pulse fires with `count 0`, **not** the unwrapped k=8 (loop wrap
  resets the count on the local timeline).

It is the FIRST golden with `:source trigger` meta rows (both with key range 0/0 — no `mkey`
children).

**Parity fix (the only code this phase).** The npm meta mirror decoded the source byte with a
binary `dv.getUint8(off+4) === 0 ? 'keys' : 'expr'`, so byte **2** wrongly read as `expr`. Replaced
it with a `TRACK_SOURCES = ['keys','expr','trigger']` lookup (mirroring the existing `CONTROL_TYPES`
idiom) indexed by the byte, and widened `MetaTrack.source` in `types.js` (and the internal
`rawTracks` JSDoc) to `'keys' | 'expr' | 'trigger'`. No driver/routing change — a trigger's writes
are ordinary `'PACW'` entries. Added one `driver.test.js` test asserting the meta names both
sources `trigger`, that triggers carry no keys, that a pre-first-event eval omits the lane, and
that a periodic ncomp-4 write flows through `toUniforms` as `[0,0,1,0]` (phase/count/gate/beats)
with the ncomp-1 hit landing phase-only on the audio bus.

**Docs.** `CLAUDE.md`'s wire-surface table was already accurate — triggers ride the existing
`'PACW'`/`'PACM'` surfaces and the `source == 2` byte landed in Phase 2 (append-only within
`'PACM'`), so no row moved; no edit needed.

**Gate.** `zig build verify` green — native corpus **15/15 byte-identical** (the 14 prior goldens
regenerated unchanged; only `trigger-basic` is new) + wasm parity **48/48** (46 prior + the
`trigger-basic` parity case + the new `toUniforms` test); `zig build audit-diagnostics` **27/27**
(no new code); npm `lint` + `typecheck` + `test` all clean. **02 trigger-lanes is COMPLETE** — the
board box is ticked and the strategy pointer advances to studio refresh + impulsos benchmark #1.
