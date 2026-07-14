# 00 — Rollout strategy

The living guide for this effort. At the start of a session: read this file, pick the
top unchecked item in **What's next**, open only that plan file, and execute its next
phase under the discipline in `README.md`. When a phase or plan completes, update the
status board and What's next here — this file is the memory between sessions; keep it
current and keep it short.

## North star

**The impulsos benchmark.** The demo (`~/Dev/2026_impulse/`, score `live.score.sjon`)
shipped with a 3-track score and ~60 `const B_*` beat knobs in WGSL. The measure of
every wave below is: *how much of that WGSL timing could move into the score without
changing the rendered frames?* The concrete acceptance ritual, run at the end of each
wave that touches the score language:

1. Pick one section of the demo (the tunnel, beats 148–200, is the richest: a window,
   a build ramp, a drop burst, backbeat flashes, per-beat lurch).
2. Rewrite its timing as score forms (scene + tracks + triggers), lifting the shader
   to read lanes instead of deriving from `beat`.
3. Eyeball A/B in the studio at the section's beats; the goal is indistinguishable
   motion with visibly less WGSL clock math.

Record each ritual's outcome (what expressed cleanly, what still needed WGSL) in the
Decision log — that residue is the roadmap's steering signal.

## Ordering rationale

Three constraints drive the order:

- **The wire decisions come first.** Plans 01 (scenes → `'PACM'`) and 11 Phase 3
  (ease programs → `'PACM'`) both append meta sections; whichever runs first freezes
  the section-framing/tolerance convention. Decide it once, early, deliberately —
  not as a side effect of whichever plan happens to land first.
- **Prove the loop on the smallest plan.** 04 (transport lanes) exercises the whole
  pipeline — schema, diags, eval, corpus regen, npm parity, studio wasm refresh — in
  one small plan. Any friction in the TDD/corpus workflow surfaces there cheaply.
- **Ship value to the studio between core waves.** A score feature is invisible until
  the studio's `pacer.wasm` is rebuilt and a template uses it. Every core wave ends
  with a studio refresh step; studio-side plans interleave so the tool visibly
  improves while core work proceeds.

De-risking: 03 (patterns) carries the only real feasibility unknown (SJON
PatternQuery under wasm32-freestanding, `plugin-exec=false`). Its Phase 0 spike is
scheduled early — as a spike only — so the answer can reshape later waves without
blocking anything.

## Waves

### Wave 0 — prove the loop (small, sequential)
1. **04 transport-lanes** — all phases. First real feature, smallest surface.
2. **11 Phase 1 + 2** (easing + controls/expr-env corpus pins) — no design risk,
   deepens the determinism gate before bigger features ride on it.
3. **03 Phase 0 only** — the PatternQuery feasibility spike. Record the verdict in
   the Decision log; do not continue into 03's later phases yet.
4. **Studio refresh**: rebuild `pacer.wasm`, copy into the studio's `public/` +
   `editor/public/`, switch `demoscene.score.sjon` to `:emit [beat]`, run the
   editor's real-wasm tests (`score-uniforms.test.js`).

### Wave 1 — the score owns time (the core of the whole effort)
5. **'PACM' framing decision** — before 01 Phase 4: settle how appended meta sections
   are framed and how old/new decoders tolerate each other. Write it into 01, 11
   Phase 3, and the Decision log.
6. **01 scenes-cues** — all phases.
7. **02 trigger-lanes** — all phases (scened triggers included, since 01 landed).
8. **Studio refresh + impulsos benchmark #1** (the tunnel section, scenes + triggers).

### Wave 2 — the studio catches up
9. **09 studio-workflow-fixes** — all three phases (cheap; Phase 2's byte-index util
   is a dependency 07 wants).
10. **07 timeline-editor** — Phases 1–4 (Phase 5 polish can trail).
11. **05 array-targets** — all phases. With scenes/triggers/lanes + a timeline, the
    "many envelopes without WGSL churn" workflow is real.
12. **Impulsos benchmark #2** — redo the ritual using the timeline editor and array
    lanes; the measure now includes authoring speed, not just expressiveness.

### Wave 3 — music in, sound out
13. **06 tracker-import** — emits real `(trigger …)` forms now that 02 is in the
    studio's wasm.
14. **10 audio-bus** — registry 1 live over libopenmpt ctls.
15. **03 pattern-tracks** — Phases 1–4, informed by the Wave 0 spike verdict.

### Wave 4 — synergy and 1.0 posture
16. **08 knob-lift** — the wgslender/studio bridge; most cross-repo, least urgent.
17. **11 Phase 3** (ease programs in `'PACM'` — 07's curves can then drop sampling if
    it's a win), **Phase 4** (compose-mode targets — standalone scores), **Phase 5**
    (diagnostic goldens).
18. **Version/1.0 review** — surfaces stable through four waves of goldens; decide
    what a 1.0 tag needs beyond this.

## Standing checklists

**After any pacer core phase that changes behavior:** `zig build verify` green;
`audit-diagnostics` if codes changed; goldens regenerated via `-- --update` with the
diff reviewed and the review noted in the plan's progress log.

**Studio refresh (end of each core wave):** rebuild wasm (`zig build wasm`); update
the copies the studio loads (`studio/public/pacer.wasm`, `editor/public/` — confirm
whether a script syncs these before copying by hand); bump-check the npm triple-pin
(`package.json` / `build.zig.zon` / `src/root.zig`) if the npm surface changed; run
the editor's real-wasm tests; update templates to use new forms where they simplify.

**When a plan finishes:** tick it below, move the What's next pointer, and append one
line to the Decision log if the plan changed any cross-plan assumption.

## Status board

| Wave | Item | Status |
|---|---|---|
| 0 | 04 transport-lanes | ☑ |
| 0 | 11 P1–P2 corpus pins | ☑ |
| 0 | 03 P0 pattern spike | ☑ |
| 0 | studio refresh + `:emit` template | ☑ |
| 1 | 'PACM' framing decision | ☑ |
| 1 | 01 scenes-cues | ☑ |
| 1 | 02 trigger-lanes | ☑ |
| 1 | studio refresh + benchmark #1 | ☐ |
| 2 | 09 workflow fixes | ☐ |
| 2 | 07 timeline editor P1–P4 | ☐ |
| 2 | 05 array targets | ☐ |
| 2 | benchmark #2 | ☐ |
| 3 | 06 tracker import | ☐ |
| 3 | 10 audio bus | ☐ |
| 3 | 03 pattern tracks P1–P4 | ☐ |
| 4 | 08 knob lift | ☐ |
| 4 | 11 P3–P5 | ☐ |
| 4 | 1.0 review | ☐ |

## What's next

→ **Wave 1: studio refresh + impulsos benchmark #1** is next (strategy Wave 1 item 8) — 02
trigger-lanes is COMPLETE (all 4 phases, 2026-07-14, see below), board box ticked. This is a
studio / cross-repo step, not a pacer-core phase, so there is no single plan file: work from
Wave 1 item 8 + the "Studio refresh" standing checklist + the impulsos notes
(`examples/impulsos_camaradas.sjon`). The refresh: rebuild `pacer.wasm`, sync the copies the
studio/editor load, run the editor's real-wasm tests, and **bump-check the npm triple-pin —
the npm surface grew this wave** (`MetaTrack.source` now admits `'trigger'`; a new `TRACK_SOURCES`
mirror), so decide whether that warrants a version bump before the next publish. Then rewrite the
impulsos tunnel section as score forms — scenes (01) + triggers (02) — lifting the per-beat pulse
/ backbeat-gate / beats-since WGSL idioms `02` was built to replace, and measure expressiveness
against the hand-rolled original (benchmark #1). Wave 2 (09 → 07 → 05 → benchmark #2) follows.

**02 trigger-lanes is COMPLETE** (all 4 phases, 2026-07-14). A `(trigger …)` form emits event
lanes off the tick grid — `periodic { every, offset }` (`:every N :offset M`) XOR an explicit
strictly-ascending `:at` list — as a third `Track` row kind (internal `Source.trigger` /
`TrackTable.Trigger`, never wire; counts against `MAX_TRACKS`; scene-relative under a `(scene …)`,
start folded into every tick at compile). At the already-wrapped, already-scene-gated tick `t`,
`Eval.evalTrigger` finds the last event ≤ t and writes four lanes in FROZEN order truncated to the
target's ncomp — `phase` `(t−event)/span` ∈ [0,1) (last explicit event holds 1.0 unconditionally),
`count` (event index f32), `gate` (1.0 only on the exact tick, structural), `beats-since`
(`map.beatOf(t−event)`); **before the first event the write is OMITTED** (a pure function of t),
and **loop wrap resets count/gate/phase for free** (the caller wraps t first). Wire: one
`Compile.Code` variant `trigger_invalid` = **26** (in `'PACD'`) and `'PACM'` `MetaTrackRec.source`
value **2 = trigger** (both append-only; `META_VERSION` unbumped, no `'PACW'` change — a trigger's
writes are ordinary entries). The `trigger-basic` golden pins the whole contract byte-for-byte
(pre-first omit, exact-tick gate 1, mid-interval phase, held-last-event 1.0, loop-wrap count
reset) — the FIRST golden with a `"trigger"` meta row; the npm meta mirror decodes `source == 2`
via a `TRACK_SOURCES` table and a `toUniforms` test flows a trigger write through the routing
helper. Gate: `zig build verify` (corpus **15/15** byte-identical, wasm **48/48**) +
`audit-diagnostics` 27/27 + npm lint/typecheck/test. Per-phase detail lives in 02's progress log;
durable cross-plan facts in the Decision log below.

**01 scenes-cues is COMPLETE** (all 5 phases, 2026-07-14). `(scene :name X :at Nb :dur Mb
(track …))` is a named window on the transport tick grid: scenes may overlap, child tracks
resolve scene-relative (start folded into key ticks at compile), a scened track writes only
inside `[start, start+dur)` (else the write is OMITTED, so a later active scene hands the target
off by write order), and scened expr tracks bind `scene-beat`/`scene-phase` (reserved env names;
`scene-phase` is a new eval-time f64 division). Wire: three `Compile.Code` variants
(`scene_invalid`=23, `scene_duplicate_name`=24, `scene_cap_exceeded`=25, in `'PACD'`); `'PACM'`
gained a post-controls `'SCEN'` TLV section — the FIRST consumer of the section-framing
convention (`META_VERSION` unbumped; omit-when-empty keeps old blobs byte-stable). `MAX_SCENES =
64`, `NO_SCENE = maxInt(u16)`. The `scenes-basic` corpus case pins the handoff (two `level`
writes, drop last), the scene-phase/scene-beat bytes, the empty-buffer-when-inactive case, and
loop-wrap re-entry (native == wasm, corpus 14/14 + npm 46/46). Per-phase detail lives in 01's
progress log; durable cross-plan facts in the Decision log below. Board box `01 scenes-cues`
ticked.

The **'PACM' framing decision** (the design gate before 01 Phase 4) is **DONE**
(2026-07-14): a TLV section stream after the controls array, walked to end-of-buffer,
no `META_VERSION` bump — canonical spec frozen in `plans/01-scenes-cues.md` ("The
`'PACM'` section-framing convention"), referenced from 11 Phase 3, recorded in the
Decision log below. No code changed (the first consumer is 01 Phase 4); grounded on
reading both wire sides (`Abi.zig` `encodeMeta`, `index.js` `get meta`) + `drv_metaLen`.

Wave 0 is **COMPLETE** (2026-07-14). The studio refresh: rebuilt `pacer.wasm`
(`a0a6edd4`, carries 04's emit eval) and synced it via `npm run build:wasm-copy` (the
studio's `public/pacer.wasm` → `editor/public/pacer.wasm` → `npm/pacer/pacer.wasm` are
symlinks, so that one copy is the sync; it is gitignored, so no pacer commit). Editor
real-wasm tests green (`score-uniforms.test.js` + full suite 1526/1526). The
`:emit [beat]` migration did NOT fit the demoscene as plan 04 assumed — its `motion`
buffer had no `beat` field and no identity `beat` track (that idiom lives in the impulse
benchmark score). Per the user's choice, the demoscene shader gained a `beat` uniform
(reclaiming the struct's `_pad` slot, buffer still 16 B) so the flagship template now
demonstrates `:emit`; committed in **pngine** (`46f492b`), not pacer. The impulse
`live.score.sjon` identity-track → `:emit [beat]` swap remains for Wave 1's benchmark
ritual. See 04's progress log for the corrected follow-up.

03 P0 pattern spike is **DONE** (2026-07-14) — **VERDICT: FEASIBLE**, no SJON change.
SJON's `Pattern`/`PatternQuery` is already re-exported to path consumers and its
`queryTree` closure compiles clean under wasm32-freestanding (`plugin-exec = false`),
proven by a temporary `_ = &sjon.PatternQuery.queryTree;` probe in `wasm_entry.zig` that
built green then was removed. A kept native test in `src/root.zig` queries `[bd hh sn cp]`
and asserts the fastcat's four haps on exact quarter-bar ticks. Code-size delta with the
probe was +2 B (the engine's deps — `Expr`/`Schema`/`Ast`/`Pattern` — are already linked
by pacer). See 03's progress log for the full verdict and the Phase-1 design bearing.
Board box `03 P0 pattern spike` is ticked; Phases 1–4 stay in Wave 3.

11 P1–P2 is **DONE** (2026-07-14) — Phase 1's `ease-primitives` golden pins all 18 named
eases + `cubic-bezier` + both `steps` jumps across `u = 0…1`; Phase 2's three cases pin
`xy`/`color` controls with vector `:min`/`:max` through `'PACM'`, vector control
set/clear over the boundary (`controls-vector`), the `bpm`/`dur`/`cycle` expr env
(`expr-env`), and the `dur`-absent `expr_eval_failed` diagnostic (`diag-dur-unbound`).
See 11's progress log. Board box `11 P1–P2` is ticked; Phases 3–5 land in Wave 4.

04 transport-lanes is **DONE** (all 3 phases landed 2026-07-14) — schema/validation,
bit-exact eval, and the `transport-emit` golden. See 04's progress log; the studio
`:emit [beat]` migration is deferred to the Wave 0 studio-refresh step.

## Decision log

- 2026-07-13 — Strategy written. Open decisions parked: 'PACM' section framing
  (Wave 1 gate); PatternQuery wasm32 feasibility (Wave 0 spike); array-write delivery
  option a/b (05 Phase 0); scene out-of-window semantics recommended as write-omitted
  (01, confirm at its Phase 1 design freeze).
- 2026-07-14 — 03 Phase 0 spike complete. **PatternQuery is feasible under
  wasm32-freestanding with `plugin-exec = false`** (verdict grounded in a green
  `zig build wasm` with `queryTree` referenced; probe removed after). Two cross-plan
  facts for Wave 3's 03 Phases 1–4: (1) **cycle↔bar is identity** — `Pattern.PPC` is
  pacer's per-bar tick count, so freeze "1 cycle = 1 bar" at no cost; (2) **env-merge is
  the real open decision** — PatternQuery binds `cycle`/`tick`/`seed` per hap, which
  *collide by name* with pacer's expr env (`cycle`/`tick`); recommend pattern-local names
  shadow inside a hap value. The hap-selection point-sample rule is untouched (still the
  plan's recommendation to freeze in 03 Phase 1). No wire surface moved.
- 2026-07-14 — 04 transport-lanes complete. Cross-plan note: `(transport :emit …)`
  lanes are pinned in the corpus via `(eval …)` write buffers only, NOT the `'PACM'`
  meta blob — emit added no wire surface. Any later plan that wants emit lanes echoed in
  meta must append a meta section (append-only) and bump nothing else. The studio
  `demoscene.score.sjon` → `:emit [beat]` switch is a Wave 0 studio-refresh item, gated
  on the studio's `pacer.wasm` carrying emit eval.
- 2026-07-14 — **'PACM' section-framing decided (Wave 1 gate).** Appended `'PACM'`
  sections use a **TLV stream after the controls array, walked to end-of-buffer, with NO
  `META_VERSION` bump.** Each section: `[section_id u32 LE][payload_len u32 LE][payload]`;
  the decoder loops `while (off < len)` past the last control, decoding known 4-CC ids
  and skipping unknown ones by `payload_len`. Chose this over version-gated skip because
  (a) today's shipped JS `get meta` already returns after the last control with no
  `off === len` check, so it ignores trailing sections with no throw — new-wasm/old-glue
  is tolerant for free; (b) `drv_metaLen` (`wasm_entry.zig:205`) returns the exact
  encoded length, so the EOF walk terminates precisely (no padding to misread as
  `id = 0`); (c) the strict `version !== 1` throw stays a real corruption check because
  we never bump for a section — a breaking change to a section's *own* layout mints a new
  id (`'SCE2'`) instead. Rejected version-gating: a bump hard-throws old decoders and
  can't express "knows scenes but not ease-programs." Canonical spec lives in
  `plans/01-scenes-cues.md`; 01 Phase 4 (`'SCEN'`) is the first consumer and transcribes
  it into the `Abi.zig` `//!` header; 11 Phase 3 (`'EASE'`) is the second (emitted after
  `'SCEN'`, fixed order). Sections omit-when-empty so no-scenes / no-program blobs stay
  byte-identical to today's. No code changed this step — decision + written convention only.
- 2026-07-14 — 01 scenes-cues Phase 1 complete (schema + validation). Wire-stable
  carry-forward: three append-only `Compile.Code` variants — `scene_invalid` = **23**,
  `scene_duplicate_name` = **24**, `scene_cap_exceeded` = **25** (these ride in `'PACD'`;
  never renumber). Design frozen: `(scene …)`'s `:name`/`:at`/`:dur` are schema-**optional**
  by deliberate choice, so a missing one surfaces as the pacer `scene_invalid` code with a
  span — NOT a bare SJON missing-key error. Rationale: schema-required keys would set
  `hasErrors()` and skip the whole pacer `build()`, leaving no pacer diagnostic; routing
  presence through pacer keeps one wire-stable code per scene-shape defect (the
  `transport_invalid`/`control_invalid` family). `MAX_SCENES = 64`. No `'PACM'`/`'PACT'`
  surface moved — the scenes meta section (`'SCEN'`) is Phase 4, per the framing convention
  above. Scene→table compilation and eval (windows, `scene-beat`/`scene-phase`) are Phases
  2–3 and unstarted.
- 2026-07-14 — 01 scenes-cues Phase 2 complete (compile into the table). Two cross-plan
  assumptions frozen for Phases 3–5. (1) **Scene write order** = top-level tracks first
  (`buildTracks`), then scenes in document order (`buildScenes`); a later scene's track
  lands after an earlier one's, so the eval window gate (Phase 3) + the corpus handoff case
  (Phase 5) can rely on "last-listed active scene wins by write order." (2) **`Scene.name_span`
  is the `:name` symbol's span** (COMBINED coords, like `track_spans`), so Phase 4's `SceneRec`
  = `{start_tick, dur_ticks, name_span}` and the editor slices the name from source — no name
  bytes in `'SCEN'`. Runtime shape (no wire surface yet): `Track.scene: u16` with
  `NO_SCENE = maxInt(u16)`; a `Scene` = `{name_span, start_tick i64, dur_ticks i64}`. Scene
  start folds into key ticks at compile via checked `std.math.add` (overflow → `tick_overflow`);
  eval is deliberately NOT window-gated yet (Phase 3). No `'PACM'`/`'PACD'`/`'PACT'`/`'PACW'`
  bytes moved — corpus stayed 13/13 byte-identical.
- 2026-07-14 — 01 scenes-cues Phase 3 complete (eval semantics). Two cross-plan facts.
  (1) **`scene-beat` and `scene-phase` are now reserved env names** (`ExprTrack.reserved_names`,
  `MAX_BINDINGS` 8→10) — a control can no longer be named either, and any plan adding new
  env bindings (02 trigger-lanes, 03 pattern-tracks) must not collide. Bound only inside a
  scene, like `dur` in a bounded score; a top-level reference is `expr_eval_failed`.
  (2) **`scene-phase` adds a NEW eval-time f64 division** (`(tick − start)/dur`) — a
  determinism seam in the same class as the lerp `u` / `beatOf` / `phaseOf` (IEEE-pinned,
  native == wasm32), NOT the seconds↔ticks `mul+floor` seam; Phase 5's corpus must pin its
  exact bytes. The window end `start + dur` is guarded at compile (checked add → `tick_overflow`)
  so the eval gate never overflows; a non-positive `:dur` stays a lenient never-active window
  (phase 0, no new diagnostic — code set stays 26). No `'PACM'`/`'PACD'`/`'PACT'`/`'PACW'`
  bytes moved — corpus stayed 13/13 byte-identical (no scene case yet; it lands in Phase 5).
- 2026-07-14 — 01 scenes-cues Phase 4 complete (ABI + npm meta). The **'PACM' section-framing
  convention is now REALIZED** — `'PACM'` grew a post-controls TLV section stream, with the
  convention transcribed into the `Abi.zig` `//!` header (the format's doc of record). Two
  cross-plan facts. (1) **`'SCEN'` = 0x4e454353 is a claimed section id.** 11 Phase 3 (ease
  programs) must mint a distinct 4-CC (`'EASE'`); the encoder emits sections in a fixed order
  (scenes before ease-programs), though decoders dispatch by id and MUST NOT rely on order or
  presence. Adding a section never bumps `META_VERSION` (stays 1); omit-when-count-0 keeps
  older blobs byte-stable (corpus stayed 13/13). (2) **The npm glue now retains the reload's
  UTF-8 doc bytes** (`#docBytes`) to slice scene names from spans — the pattern any future
  span-only meta record (no inline bytes) reuses. `'PACT'`/`'PACD'`/`'PACW'` untouched; the
  `'PACM'` addition is append-only, no `META_VERSION` bump. Corpus `scenes-basic` (Phase 5)
  is the first case to exercise the `'SCEN'` bytes end-to-end (native == wasm).
- 2026-07-14 — 01 scenes-cues Phase 5 complete → **plan 01 DONE.** Cross-plan facts. (1) The
  golden `(meta …)` echo now renders a `(mscene :name N :at T :dur D :name-span [S E])` line per
  scene, produced by BOTH the native runner (`corpus_runner.zig` `renderMeta`, walking the
  post-controls TLV stream + slicing the name from `doc`) and the JS parity renderer
  (`corpus.test.js`, from `driver.meta.scenes`) — so the corpus now gates the `'SCEN'` bytes
  end-to-end. **Any later plan appending a `'PACM'` section (11 Phase 3, `'EASE'`) must extend
  BOTH `renderMeta`s** to keep the golden gating that section. The renderer walks unknown ids by
  length, exercising the convention's tolerance. (2) `'SCEN'` did NOT earn a CLAUDE.md wire-table
  row — it is a section inside `'PACM'`, not a fifth blob; the four-blobs framing stands, with the
  `'PACM'` row annotated "(+ TLV section stream)" and a paragraph noting section 4-CCs are
  wire-stable and never bump `META_VERSION`. The `schema/pacer.sjon` header now lists `scene` and
  drops it from the omissions note (compose-mode `(target …)` remains the only listed omission).
  No new wire surface beyond Phase 4's `'SCEN'`; goldens other than `scenes-basic` stayed
  byte-identical (user coords are manifest-independent, so the schema-comment edit moved nothing).
- 2026-07-14 — Wave 0 complete (studio refresh). Two cross-plan facts. (1) **The studio
  loads pacer.wasm by symlink** — `studio/public/pacer.wasm` → `editor/public/pacer.wasm`
  → `pacer/npm/pacer/pacer.wasm`; the canonical sync is `npm run build:wasm-copy` (the
  npm `pretest` hook rebuilds only `zig-out/`, so it does NOT refresh the studio — run
  the copy step explicitly). The npm copy is gitignored: a studio refresh produces no
  pacer commit. (2) **04's `:emit [beat]` follow-up was mis-targeted at the demoscene.**
  The identity-track idiom `(track :target beat :expr beat)` + a `motion.beat` uniform
  live in the impulse benchmark score (`~/Dev/2026_impulse/live.score.sjon`), NOT the
  demoscene, whose `motion` buffer is `{sceneMix, spin, chromaAmt, _pad}`. Adding
  `:emit [beat]` there was proven to break the load (`unknown_target`, code 0). Resolution
  (user's choice): give the demoscene shader a real `beat` field (reclaiming `_pad`; buffer
  stays 16 B) so the flagship template demonstrates `:emit` — committed in **pngine**
  (`46f492b`: shader + score + `score-uniforms.test.js`), leaving pacer untouched. The
  impulse-score identity-track → `:emit [beat]` swap moves to Wave 1's benchmark ritual.
  Verified empirically: wgslender reflection lists all struct members (so `beat` registers
  in the real studio at offset 12), editor suite 1526/1526 green. Render output is
  unchanged (the shader can read `motion.beat` but doesn't yet).
- 2026-07-14 — 02 trigger-lanes Phase 1 complete (schema + validation). Wire-stable
  carry-forward: one append-only `Compile.Code` variant — `trigger_invalid` = **26** (rides in
  `'PACD'`; never renumber). Design frozen for Phases 2–4: `(trigger …)`'s source is `:every`
  (periodic, phased by optional `:offset`) XOR an explicit `:at` list; both keys are
  schema-**optional** by deliberate choice so every shape defect surfaces as `trigger_invalid`
  with a span (the scene discipline), and an unknown target reuses `unknown_target` (NO
  trigger-specific target code, per the plan's design note). Two rules that differ from tracks
  and matter downstream: (1) a trigger **rejects** an unsorted/duplicate/descending `:at`
  (checked in TICK order, so `[1bar 2b]` is rejected) rather than sorting it — the Phase 2
  compiled slice is therefore already ascending and needs no sort; (2) `:every` must be > 0
  ticks (0/negative → `trigger_invalid`; overflow → `tick_overflow`). Phase 1 is validation-only
  (no table row), so a valid trigger compiles clean with 0 diagnostics. **Scened triggers are
  deferred to Phase 2**: the `scene` `:positional track-section` still allows only `track` heads,
  so Phase 2 both widens that positional and walks scene-child triggers scene-relative (reusing
  `buildTrackForm`'s scene-start offset + `tick_overflow` fold). No `'PACT'`/`'PACM'`/`'PACW'`
  surface moved — corpus stayed 14/14 byte-identical (user coords are manifest-independent, so
  the new schema form shifted nothing). `scene-beat`/`scene-phase` remain the only reserved env
  names; triggers add none in Phase 1 (lane values are plain writes, not env bindings).
- 2026-07-14 — 02 trigger-lanes Phase 2 complete (compile into the table). Wire-stable
  carry-forward: `'PACM'` `MetaTrackRec.source` gained value **2 = trigger** (append-only after
  `0 keys` / `1 expr`; never renumber, never bump `META_VERSION`) — a trigger meta row carries
  key range 0/0, no `'PACW'` change. No corpus case has a trigger yet, so nothing shifted (corpus
  14/14 byte-identical). The trigger schedule is an INTERNAL `TrackTable.Trigger` union
  (`periodic {every, offset}` XOR arena-owned ascending `at: []Tick`) reached through a new
  `Source.trigger` variant — never crosses the wire, so adding it is not a wire event. The `scene`
  positional widened (`track-section` → `scene-section`, head-set `[track trigger]`); scene-child
  triggers fold the scene start into each `:at` tick and the periodic `:offset` with a checked add
  (overflow → `tick_overflow`), so a scened trigger's ticks are absolute exactly like a scened
  track's keys. A trigger counts against `MAX_TRACKS`. `Eval` carries a `.trigger => {}` no-op
  (writes nothing) until Phase 3 lands the lane sampling.
- 2026-07-14 — 02 trigger-lanes Phase 3 complete (eval). No wire surface (eval-only): no
  `Compile.Code`, no `'PAC*'` byte moved, corpus 14/14 byte-identical, audit 27/27. The durable
  contract the Phase 4 golden + downstream WGSL consumers pin: at the already-wrapped,
  already-scene-gated tick `t`, a trigger writes four lanes in FROZEN order truncated to the
  target's ncomp — [0] `phase` = `(t−event)/span` ∈ [0,1), [1] `count` = event index (f32), [2]
  `gate` = 1.0 ONLY on the exact event tick else 0.0 (structural), [3] `beats-since` =
  `map.beatOf(t−event)`. Three subtleties that are now behavior, not just intent: (1) **before the
  first event the write is OMITTED** (`null` entry, like an expr-NaN), so whether a trigger writes
  at t is a pure function of t; (2) **the last explicit `:at` event holds `phase` 1.0
  unconditionally** — even AT its exact tick (there is no next event to divide toward), so gate=1
  and phase=1 coincide there; a periodic schedule is unbounded and never hits this (span =
  `every`); (3) **loop wrap resets count/gate/phase for free** because the caller wraps `t` before
  the arm. `phase`/`beats-since` are each ONE f64 division in the documented op order, f32 only at
  emission. `evalTrigger` is scene-agnostic (reuses the caller's window gate + the Phase 2
  absolute-tick fold) and reuses the keyframe `seg_cache` slot as the `:at` cursor.
- 2026-07-14 — **02 trigger-lanes COMPLETE** (Phase 4: corpus + parity + docs). No new wire
  surface (Phase 4 pins existing bytes): the `trigger-basic` golden — a periodic ncomp-4 target
  (all four lanes) + an explicit-list ncomp-1 target (phase only), over a 2-bar 120 bpm loop —
  pins the frozen contract byte-for-byte across native == wasm (corpus 15/15, wasm 48/48): a
  pre-first-event omit (also at the loop-wrap-to-0), exact-tick gate 1, a mid-interval phase
  (incl. non-dyadic 1/3), the held-last-event phase 1.0, and a loop wrap where `count` resets to
  0 (not the unwrapped k=8). It is the FIRST golden to carry a `source == 2` / `"trigger"` meta
  row. Cross-boundary fact for **06 tracker-import** (emits `(trigger …)`) and **07
  timeline-editor** (reads `meta.tracks`): the npm glue now names the source byte via a
  `TRACK_SOURCES = ['keys','expr','trigger']` table (was a binary `0 ? 'keys' : 'expr'` that
  mis-named byte 2), and `MetaTrack.source` in `types.js` admits `'trigger'`. Trigger writes are
  ordinary `'PACW'` entries, so `route.js`/`toUniforms` needed no code change (a test pins one
  trigger write flowing through). The npm surface grew (a new source name), so the triple-pin
  version bump is a studio-refresh decision, deferred to Wave 1 item 8. `CLAUDE.md`'s wire-surface
  table was already accurate (no row moved).
