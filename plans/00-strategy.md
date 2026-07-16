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
| 1 | studio refresh + benchmark #1 | ☑ |
| 2 | 09 workflow fixes | ☑ |
| 2 | 07 timeline editor P1–P5 | ☑ |
| 2 | 05 array targets · ALL phases ✓ (dotted lanes in the demoscene, smoke green 2026-07-16) | ☑ |
| 2 | benchmark #2 · A/B CONFIRMED 2026-07-16 | ☑ |
| 3 | 06 tracker import · P0 ✓ (.it reader, 2026-07-16) | ☐ |
| 3 | 10 audio bus | ☐ |
| 3 | 03 pattern tracks P1–P4 | ☐ |
| 4 | 08 knob lift | ☐ |
| 4 | 11 P3–P5 | ☐ |
| 4 | 1.0 review | ☐ |

## What's next

→ **Wave 3 · 06 tracker-import in flight — Phase 0 done (pure-TS `.it` reader, pngine
`4f5e061`, 2026-07-16); Phase 1 (timing model: rows→beats, order-pos→beat, Txx/Axx warnings)
is next**, then P2 score emission and P3 studio UI. Byte-layout notes + the realism findings
live in 06's Progress log — the demo module swings its groove with 1024 alternating A8/A4
set-speed rows (beat pairs stay on-grid, odd rows drift), so Phase 1's Axx warning is a real
case, not hypothetical. After 06: 10 audio-bus, then 03 pattern tracks P1–P4.

**Benchmark #2 is CLOSED — A/B CONFIRMED 2026-07-16.** The user eyeballed beats 148–204 in the
studio against the pre-rewrite build: the dots choreography is identical (icon strobe from 162,
wipe 184, contract 186→188, letters + tally from 190, full-flash 199, fist 200 + red dot), with
the `dots-choreo` scene block, both trigger rows, and the two vec4 key lanes on the Motion
timeline. Measurement, residue, and the (since-fixed) pngine `(group, binding)` dedup gotcha are
in the 2026-07-16 benchmark #2 Decision-log entry; the demo files are snapshotted as
`*.PRE-PACERBENCH2-2026-07-16.sjon`.

**05 array-targets is COMPLETE.** The manual studio smoke
went GREEN 2026-07-16 (pngine journal §255; 05's Progress log has the detail): a fresh
Demoscene-seeded draft on `:4321` against the rebuilt §253 compiler wasm, verified at the worker
`draw` seam (Worker.postMessage patch) — `env` ships as ONE coalesced 8-float write, the cool
grade key `[0.85 0.95 1.25 0.4]` verbatim at t=0.5, the warm `[1.2 1.0 0.75 0.55]` landed by
beat 14, the trigger's count lane matching the beat number exactly and the phase lane sawtoothing
at precisely one 170 BPM beat (0.353 s) — plus all three eyeball items: per-beat flash + warming
grade animate in the preview and filmstrip, and the Motion timeline shows both `env.*` lanes
(`env.0` vec4 key curves, `env.1` trigger row). All Phase 3 code was already in
(pngine `72d49f8`): the demoscene template drives a **bare `env: array<vec4f, 2>` post binding**
through the DOTTED element targets, real-wasm test pinning the bit-exact vec4 landing and the
coalesced write. Benchmark #2 closed Wave 2 (2026-07-16); Waves 3 (06 → 10 → 03) and 4 remain.

**07 timeline-editor is COMPLETE** (all 5 phases, 2026-07-15) — the visual timeline ships end-to-end.
Phase 1 (**anchors lib, pngine `5be6884`**) → `lib/score/anchors.ts`: `scoreAnchors(meta, source)`
→ the view model, `refineKeySpans` splitting each key's single form span into `:at`/`:value` field
spans + lifting `:ease`; Phase 2 (**write-back lib, pngine `2dd0e63`**) → `lib/score/span-edit.ts`:
`retimeKey`/`revalueKey`/`applyEdits` splice a batch back into the score right-to-left through those
field spans, byte→char mapped ONCE at the splice (09's `byte-index.ts`), then the caller
`pacer.reload`s for fresh spans; Phase 3 (**sampling lib, pngine `c766b4b`**) →
`lib/score/curve-sample.ts`: `sampleTrackCurve` probes the loaded pacer per tick column (one shared
pacer — eval is a pure function of time); Phase 4 (**ScoreTimeline strip, pngine `fdfcc9a`**) →
`lib/timeline/score-timeline.ts` (pure model + drag reducer) + `components/ScoreTimeline.svelte`
(dumb shell) behind a Motion-tab text⇄timeline toggle: drag a key → beat-snapped retime + lane-0
revalue **BATCHED into one `SET_SCORE`** (atomic undo/log), a bare click → `FOCUS_SPAN` jumps to the
span in ScorePane; Phase 5 (**polish, pngine `7510db8`**) → scenes lane (`timelineScenes` → named
click-to-focus blocks), vec-key lane display (`ys[]` per component, visual only), and the pure tested
`curveLanePath`. **Control pins were DEFERRED** — the meta's `MetaControl` is a timeless knob (no
tick), so it has no x on a time axis; a controls panel is a separate, non-timeline concern for
whatever plan first needs live controls (see 07's Phase 5 log + the Decision-log entry below).

**09 studio-workflow-fixes is COMPLETE** (all three phases, 2026-07-15) — board box ticked.
Phase 1 (timeline honors the score's meter, pngine `962698a`), Phase 2 (UTF-8 byte spans → editor
char offsets, pngine `52210b5`), and **Phase 3 — reconciled: named checkpoints ALREADY SHIP** as
the studio's **Versions / Checkpoint** feature (a "+ Checkpoint" name field + list + restore in
`VersionsPanel.svelte`, backed by `SAVE_VERSION`/`tagNode`/`listSaveTags`/`replayTo`; every RED the
plan specified is already green under `versions-view`/`save-btn`/`action-tree`/`seed-log`/`history`
tests). Building the plan's literal `CHECKPOINT` action + `listCheckpoints` would have DUPLICATED
and regressed it — so no code was written (see 09's Progress log for the full file:line map). This
is the Phase-1 situation repeated: the plan (2026-07-13) predated the studio's current state.

**Wave 1 is COMPLETE** — item 8 (studio refresh + benchmark #1) closed 2026-07-15; the user's
studio A/B of the tunnel rewrite was **indistinguishable** (drop burst at beat 160 + decay,
beat-driven scene selection — all unchanged), confirming the score-driven `motion.spin` drop lane
and `:emit [beat]` route end-to-end. Studio refresh + triple-pin + the benchmark measurement/residue
are in the 2026-07-15 Decision-log entries below; the cleanest future trigger wins (dots/word
steppers → `count` lane) are the benchmark #2 target.

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
- 2026-07-15 — **Wave 1 item 8, part 1/2 (studio refresh) DONE + triple-pin decided.** Rebuilt
  `pacer.wasm` clean at HEAD and synced via `npm run build:wasm-copy`; the studio chain
  (`pngine/studio/public/pacer.wasm` → `pngine/studio/editor/public/pacer.wasm` →
  `pacer/npm/pacer/pacer.wasm`, all symlinks) now converges on one hash. **Non-obvious gotcha
  worth pinning: the prior studio copy was STALE** — the npm `pretest` hook rebuilds `zig-out/`
  only, and the npm tests load `zig-out/bin/pacer.wasm` DIRECTLY (`corpus.test.js`/`driver.test.js`
  line ~15/25), so the green npm gate never touches the studio's copy. The copy step
  (`build:wasm-copy`, run explicitly) is the ONLY thing that refreshes the studio. Editor
  real-wasm suite 1526/1526 green on the fresh bytes. **Triple-pin: no bump** — 0.1.0 has stood
  since `85582e3` (first publishable package) through all of Wave 0/1 including scenes (which also
  grew the surface); the convention is accumulate-then-bump-at-publish. The next `npm publish`
  should go 0.1.0 → 0.2.0, covering `:emit`, `Meta.scenes`/`MetaScene`, and `MetaTrack.source:
  'trigger'`. No pacer code changed (wasm is gitignored; no version bump).
- 2026-07-15 — **Benchmark #1 (impulsos tunnel) — rewrite applied + pacer-validated; A/B pending.**
  The North-Star ritual on the tunnel section (fs3, beats 148–200) of `~/Dev/2026_impulse/`
  (`impulse.sjon` is the live doc; `project.sjon` predates the tunnel; the repo is NOT git —
  snapshotted by hand as `*.PRE-PACERBENCH-2026-07-15.sjon`). **Measurement (the steering signal):
  the score owns timeline landmarks + envelopes cleanly; the tunnel's per-beat/per-cell texture is
  residue that correctly stays in WGSL.** Two clean migrations applied: (1) the identity
  `(track :target beat :expr beat)` → `:emit [beat]` on transport (same value, one fewer track;
  `motion.beat` already exists so it resolves — unlike the Wave-0 demoscene which first needed the
  field); (2) the drop's WHOLE time-envelope — `dt = beat-160; dropBurst = step(0,dt)*exp(-2*dt)`
  — moved to ONE expr track on the otherwise-unused, already-routed `motion.spin` field (fs3 now
  reads `let dropBurst = motion.spin;`). **Durable cross-plan facts:** (a) SJON's Expr DOES expose
  `pow`/`step`/`min`/`max`/`clamp`/`fract`/`if` (the demo's "the score expr can't fract/pow"
  comment was simply wrong — empirically probed against `pacer.wasm`); only `exp` is absent, spell
  it `(pow 2.718281828459045 x)`; `step(edge,x)` matches WGSL arg order. (b) The expr reproduces
  the WGSL envelope to f32 precision (Δ ≤ 4e-6, exactly 1.0 at beat 160, exactly 0 before) —
  validated by loading the actual edited file through `pacer.wasm`, `ok:true`, 0 exprFailures.
  **Residue (stays WGSL, by nature not gap):** `pow(1-fract(beat),k)` pulse shaping (k=4/3/2),
  `floor(beat)&1` backbeat PARITY (a sustained half-beat mask — the trigger event model of
  onsets+held-lanes cannot express it), `offbeat=abs(sin(π·beat+…))` continuous oscillator, and
  `hash21(tCell)` per-cell dot selection. **Buffer-plumbing cost surfaced:** migrating MORE lanes
  (buildRamp/calm envelopes) needs widening `motion` (its `struct Motion` is copied in 6 modules)
  or a second buffer — deferred; the single free `spin` field held exactly one lane, so this
  rewrite needed zero buffer surgery. **Cleanest FUTURE trigger wins are elsewhere in this demo:**
  the dots/word steppers `floor((beat-B_SHAPES)/1)` / `floor((beat-B_WORD)/1)` ("one icon/letter
  per beat") map directly to a trigger `count` lane — the natural benchmark #2 target once the
  timeline editor (07) makes authoring them cheap. **A/B CONFIRMED 2026-07-15**: the user's studio
  A/B of the tunnel was indistinguishable (drop burst + decay at beat 160, beat-driven scene
  selection — unchanged), which also confirms the score `spin` write routes end-to-end through the
  studio to `motion.spin` (the one link the headless pacer.wasm validation couldn't cover). Item-8
  board box ticked → Wave 1 COMPLETE; Wave 2 (09 studio-workflow-fixes) is next.
- 2026-07-15 — **09 Phase 2 (UTF-8 byte spans → editor coordinates) DONE — pngine `52210b5`.**
  Cross-plan fact for **07 (timeline-editor)**: the byte→char mapper now EXISTS at
  `pngine/studio/editor/src/lib/score/byte-index.ts` — `byteToCharIndex(text)` (dense per-byte
  table, O(1) lookups; multi-byte offsets round down to the code-point start, out-of-range clamps
  to `[0, length]`) + `remapScoreDiagnostics(text, diags)` (pure, returns fresh records). 07 must
  REUSE it for any span→editor mapping, not rebuild. The seam: pacer diagnostic/meta spans are
  UTF-8 byte offsets (per `pacer/npm/pacer/src/index.js`), CodeMirror indexes by UTF-16 code unit,
  so a non-ASCII byte before a span shifts every later coordinate. Routed the two armed-score
  `onScoreDiagnostics` emits in `preview.ts` through the remap, so `ScoreDiagnostic.start/end` now
  carry EDITOR (char) coordinates, not bytes — the type's doc comment was flipped to match. No
  pacer wire surface touched; this is a studio-internal consumer of an already-stable byte contract.
  Meta spans (control `valueSpan`, scene `nameSpan`) have no editor coordinate-consumer yet, so
  they were left as-is — remap them at the point 07 first uses them as positions.
- 2026-07-15 — **09 Phase 3 (named checkpoints) reconciled → NO CODE; plan 09 COMPLETE.** Like
  Phase 1's pre-flight, the plan text (2026-07-13) predated the studio: named checkpoints already
  ship as the **Versions / Checkpoint** feature, so building the literal `CHECKPOINT` action +
  `listCheckpoints` would duplicate and *regress* it (forfeiting compaction-pinning, auto-checkpoint
  recovery, branch-tip discovery, `?at=` deep-links, dashboard pills). The one-to-one map (all live +
  gated): `CHECKPOINT {name}` → `SAVE_VERSION {label}` (`schema/studio-state.sjon:359`) tagging the
  cursor (`App.svelte:766`); name-field + list → `VersionsPanel.svelte` (+ Checkpoint input at
  :162, `versionsView`) mounted at `Toolbar.svelte:238`; `listCheckpoints` → `listSaveTags` /
  `listSaveTagsFromNdjson` (`action-tree.ts:730,750`, names=`label` + positions=`nodeId`);
  append-only restore → `replayTo(nodeId)` (`App.svelte:793`) replaying the log to the tagged node
  (rebuilds source **and** score, cursor moves, next edit branches). Restore-reconstructs-score is
  pinned by `src/lib/seed-log.test.js:21`. **Cross-plan bearing:** the action log is a persistent
  **tree** (`action-tree.ts`), not the flat NDJSON the plan assumed — checkpoints are tree
  **save-tags** on nodes; any later plan touching versioning/history builds on `tagNode`/`replayTo`,
  not a new marker vocabulary. No pacer or pngine code changed this step (docs only); the feature's
  tests were already green in the Phase 2 gate (1542/1542).
- 2026-07-15 — **07 Phase 1 (anchors lib) DONE — pngine `5be6884`.** `lib/score/anchors.ts` turns
  `pacer.meta` into the timeline view model. **Cross-plan fact discovered (governs 07 Phases 2–5):
  a keyframe is ONE byte span with NO ease.** pacer's `MetaKey` = `{ at, value[4], span }` where
  `span` covers the whole `(key …)` form (confirmed against `Abi.zig`'s `encodeMeta` test), and
  ease lives only in the compiled table. So the timeline's `:at`/`:value` field spans and the
  `:ease` symbol come from anchors REFINING the form span (`refineKeySpans`, a byte-space
  keyword-order-free tokenizer that treats `[…]` vec values as one token), NOT from meta — Phase 2's
  `retimeKey`/`revalueKey` splice through `atSpan`/`valueSpan`. anchors EMIT byte spans (pacer's
  native coordinate); byte→char happens ONCE at the write-back splice via `byteToCharIndex` (09
  Phase 2). The demoscene's comment em-dashes (6-byte drift) proved the discipline in-test. Two
  hygiene notes for later: (a) the studio's installed `pacer` `.d.ts` is a stale pnpm file-copy
  (`Meta` lacks `scenes`; `source` lacks `'trigger'`) — anchors type their meta input STRUCTURALLY
  to stay robust to it; refreshing that `.d.ts` is an unrelated task. (b) the plan wrote the test as
  `.test.ts`, but the runner globs `.test.js` only — RED files must be `.test.js`. Gate: 7 new tests
  (incl. a real `pacer.wasm` × demoscene load), full editor suite 1549/1549, typecheck 0 errors.
- 2026-07-15 — **07 Phase 2 (write-back lib) DONE — pngine `2dd0e63`.** `lib/score/span-edit.ts` is
  the timeline's text-splice layer: `retimeKey`/`revalueKey` build a `SpanEdit {span, text}` from a
  key's `atSpan`/`valueSpan`, `applyEdits(source, edits)` splices a batch back. **Cross-plan fact:
  this is now the canonical "edit score text through a pacer span" primitive** — any later plan that
  writes score text (11 Phase 3 ease programs, 05 array-target authoring) should reuse `applyEdits`,
  not reinvent splicing. Its three invariants: (1) **byte→char maps ONCE, at the splice**, via 09's
  `byteToCharIndex` against the ORIGINAL source — the single seam from pacer byte space to editor
  char space (proven by a `; é\n(key …)` drift test); (2) **a batch applies RIGHT-TO-LEFT** (sort
  descending by start) so a splice never shifts a not-yet-applied lower offset — order-independent,
  and overlaps THROW rather than corrupt; (3) **span-edit mutates no pacer state** — it is pure text,
  the caller owns `reload`, so the score text stays the sole document authority. v1 retime snaps to
  WHOLE beats: `retimeKey` emits `Nb` (exact tick via pacer's `floor(beats·180180)`), and a
  non-beat-aligned tick THROWS rather than truncate (sub-beat is v2); `revalueKey` emits
  `String(value)` (shortest f64 round-trip → same f32 for an f32-exact drag value). The determinism
  property is proven end-to-end against real wasm: a +1b retime and a 0.5 revalue reload with
  `evalBytes` 'PACW' writes byte-identical at unaffected times and genuinely changed inside the
  reshaped segment. Gate: 14 new tests, full editor suite 1563/1563, typecheck + svelte-check 0
  errors, lint clean. Pointer → Phase 3 (curve sampling; the interleaved-eval RED decides the
  second-Pacer-instance question).
- 2026-07-15 — **07 timeline-editor COMPLETE (Phase 5 polish) — pngine `7510db8`; plan 07 DONE.**
  Two grounded items shipped RED-first as pure `score-timeline.ts` additions (+7 tests → editor
  suite **1596/1596**): **scenes lane** (`timelineScenes` → `{name, x, width, nameSpan}` blocks;
  click focuses `nameSpan` via the same FOCUS_SPAN path a key click uses) and **vec-key display**
  (`TimelineKeyView.ys[]`, one y per component, visual only — lane 0 stays the sole drag lane, per
  Phase 4's "show lanes, edit later"). The shell's curve path-building was lifted into the pure,
  tested `curveLanePath(curve, lane, layout)`, leaving the `.svelte` purely render + pointer
  routing. **Cross-plan decision: the third listed item, "control pins," is DEFERRED — controls do
  not belong on the time strip.** `MetaControl` is a **timeless knob** (`{index, id, targetId, name,
  registry, ncomp, type, value, min, max, valueSpan}` — no tick), so it has no x on a time axis;
  and nothing in the studio consumes controls yet (no `(control …)` fixture, no controls UI). A
  controls *panel* (knobs bound to expr-env `id`s, committing through `valueSpan` via Phase 2's
  `applyEdits` — the commit-to-text pattern 07's "Why" cited) is a separate, non-timeline concern
  that belongs to whatever plan first needs live controls; it must NOT be bolted onto the timeline
  strip. No pacer wire surface touched (07 is entirely studio-side).
- 2026-07-15 — **05 array-targets Phase 0 DONE — pngine `1095d61`; the a/b delivery decision is
  settled as (b).** Extracted `buildRegistries` into a pure `lib/preview/registries.ts` (behavior-
  preserving) and pinned the array/matrix drop-baseline with 7 characterization tests (editor suite
  **1603/1603**). **Decision: option (b), studio-side coalescing — no pngine worker change.** The
  write seam (`gpu.js` `setUniform` → `writeBuffer(buffer, offset, uniformToTypedArray(value, type,
  size))`) already accepts a **whole-array JS value** and truncates to the field's byte `size`, so
  the studio can drive `array<f32,N>` by writing the whole field at its reflected offset. Pacer's
  per-element writes (`env[3]=0.5`) land in `toUniforms` as name-keyed entries that match no
  reflection field (dropped today); Phase 2 will **coalesce them at `uniformsAt`** (the single funnel
  feeding live frames + the thumbnail strip) into one `env` array per frame with **holes holding the
  previous value**. The reflection carries `{type, size, bufferId, offset}` but **no stride and no
  array type** — the studio derives layout from the WGSL rule (uniform-space arrays stride **16
  B/element**; `array<f32,16>` = 256 B = 64 f32 slots, element `i` at float `i·4`; element count =
  `size/16`), so pngine's reflection schema is never grown. Option (a) (`name[i]` in the worker) is
  deferred unless (b) proves insufficient. No pacer wire surface touched (05 is host-side only).
- 2026-07-15 — **05 array-targets Phase 1 (registry expansion + `dropped` warning) DONE — pngine
  `ea22401`.** `buildRegistries` now returns `{ targets, dropped }`: array fields expand into element
  targets (`array<f32,16>` → `env[0]`..`env[15]` ncomp 1; `array<vec4f,4>` → 4 targets ncomp 4;
  `count = size/16`), matrices/odd sizes go to `dropped` (surfaced via `console.warn` in preview.ts,
  gated non-empty — a uniform-layout fact has no score-text span so it can't ride `onScoreDiagnostics`).
  **Two cross-plan facts.** (1) **The studio now reads pngine's wire-stable `UT_*` uniform-type enum
  (gpu.js) from the reflection**, via a local `LANES_BY_TYPE` map — a NEW coupling to that enum (F32/I32/
  U32→1, VEC2*→2, VEC3*→3, VEC4*→4; matrices 6/7 + unknowns → dropped). If pngine ever adds a uniform
  type, that map must learn it (else the field drops, not crashes — safe default). (2) **The discriminator
  is `type`, forced because `array<f32,4>` and `mat4x4f` are BOTH `size:64`** — size alone can't split
  them. To keep real vec2/3/4 fields regression-proof, the plain-field path is the ORIGINAL size-only rule
  (`size/4 ∈ 1..4`) with NO type dependency; `type` is consulted ONLY for wider fields. Degenerate
  size-16 single-element arrays (`array<f32,1>` vs `vec4f`) both resolve to one 4-lane target — accepted,
  not special-cased. Editor suite **1606/1606**. No pacer wire surface touched (05 is host-side only);
  Phase 2 is the write-delivery coalescing at `uniformsAt`.
- 2026-07-15 — **05 array-targets Phase 2 (write delivery — studio-side coalescing) DONE — pngine
  `930d3f4`.** New pure `coalesce.ts` (`makeUniformCoalescer`) folds pacer's per-element array writes
  into one whole flat-float array per base, confirming **delivery option (b) is sufficient — no pngine
  worker/core change** (Phase 0's prediction holds). **Three cross-plan facts.** (1) **The coalesced
  value's layout is byte-locked to pngine's `uniformToTypedArray` (gpu.js):** every WGSL
  uniform-address-space array element strides to **16 B = 4 floats**, so element `i` lane `j` lands at
  flat index `i·4+j` and the whole value is `count·4` floats (`array<f32,16>` → 64 floats w/ 3 pad each;
  `array<vec4f,4>` → 16 tight). Any future change to how pngine packs uniform-array bytes must move this
  fold in lockstep. (2) **"Holes hold last value" is stateful sample-and-hold, and that collides with
  `uniformsAt` purity** (thumbnail must equal playhead at a given time). Resolved by scoping coalescer
  state PER CALL-SITE, not inside `uniformsAt`: the live playhead keeps a persistent coalescer (mirrors
  the GPU buffer across frames), the thumbnail strip a per-batch throwaway (ascending, self-consistent,
  can't contaminate the playhead). For a fully-keyframed array (no holes — the Phase 3 case) both paths
  are identical; the divergence exists only for sparse/trigger lanes, where scrubbing backward does NOT
  replay history (accepted preview limitation). (3) **`buildRegistries` now also returns the `arrays`
  plan (`{base,count,lanes}`), built in the SAME walk as the targets** — consistency by construction, so
  the coalescing plan can never disagree with the expanded target set. Zero-overhead default: no array
  ⇒ `liveCoalescer = null` ⇒ raw passthrough (the demoscene default is untouched). Editor suite
  **1614/1614**. No pacer wire surface touched. Phase 3 is the demoscene `env: array<f32,8>` example +
  real-wasm integration test.
- 2026-07-15 — **05 array-targets Phase 3 verification → BLOCKED; the host-side premise is
  contradicted by real pngine reflection. User chose to PAUSE & re-plan (no code written).** Before
  authoring the demoscene example I compiled real probe shaders through pngine's actual pipeline
  (`zig build run -- compile`) and dumped the PNGB uniform table the studio worker truly receives
  (`gpu.js parseUniformTable`, forwarded verbatim by `worker-core.js handleGetUniforms`). **Three
  ground-truth facts that break Phases 1–2's model:** (1) a struct-member array (`bands:
  array<vec4f,2>`) reflects as `{ type: 255 (unknown), size: 32 }` — pngine's
  `UniformType.fromWgslType` (`src/bytecode/uniform_table.zig`) has **no `array<…>` case**, and the
  flattener (`Emitter.zig flattenFields`) recurses only into nested *structs*, so an array is a leaf
  stamped `unknown`, **discarding the element type + count** that wgslender's reflection JSON *does*
  carry (`"type":"array<vec4f, 2>"`). (2) a **bare** array binding (`var<uniform> env:
  array<vec4f,2>`, not inside a struct) reflects as **nothing at all** — absent from the table. (3)
  `array<f32,N>` in a uniform **fails to compile**: pngine's validator emits *"uniform var 'env'
  contains array with element stride 4 (uniform requires a multiple of 16)"* — so the plan's headline
  `env: array<f32,16>` → 16 scalar lanes is physically impossible; the only efficient uniform array is
  `array<vec4f,N>` (lanes in 4s). **Consequence:** `buildRegistries` keys array expansion off a real
  vec/f32 `type` tag (`LANES_BY_TYPE`), but real pngine tags every array `255` → `LANES_BY_TYPE[255]`
  undefined → **dropped**. Phases 0–2 are unit-green only because their fixtures fed `type: 5` for
  arrays — a value pngine never produces. The feature does not connect to real reflection. **This
  invalidates the Phase-0 delivery framing too:** option (b) coalescing was never the blocker — the
  blocker is upstream, that the reflection carries no array info to expand from (from `{255, size}`
  alone the studio cannot recover `array<vec4f,2>` vs `array<vec2f,4>` vs a mystery type). **Options
  recorded for the re-plan (user to pick before resuming): (A)** host-side vec4 convention —
  `unknown(255) + size%16==0 ⇒ array<vec4f, size/16>`, `base[i]` ncomp-4 targets, **no pngine change**,
  but vec4-grouped lanes only + rewrite P1–P2 fixtures to `type:255`; **(B)** extend pngine's reflector
  to carry array element-type + count through the PNGB uniform-table field encoding (a **wire-stable
  pngine change** — contradicts "Wire impact: none"; spans pngine Zig + `gpu.js` + studio); **(C)**
  drop uniform arrays as the mechanism — widen a struct with more scalar fields, or a storage-buffer
  path (different write seam). **Nothing was committed as code** — Phases 0–2's pngine commits stand;
  this is a docs-only pause. Probe shaders lived in `/tmp` only (neither repo tree touched). Board:
  `05 · P3 BLOCKED`, benchmark #2 blocked on it, What's next points at the decision.
- 2026-07-16 — **05 UNBLOCKED: the user implemented Option (B) in pngine; validated end-to-end,
  P3 ready to resume.** pngine `2b659bf`/`21215a2`/`9c5456f`/`9519e03` + journal §253: the PNGB
  uniform-table field record's always-zero pad byte 9 now carries `elem_count` (u8, **append-only**
  — old payloads carry 0 there, old readers skip the byte, `elemCount 0` = not-an-array, so both
  directions stay compatible with no new enum values and no record growth); an array leaf's `type`
  byte holds the **ELEMENT's** UT_* tag; element type + count come from wgslender's structured
  TypeInfo (aliases and const-expression counts resolve); **bare** uniform bindings (`var<uniform>
  env: array<vec4f,2>`, previously absent — also bare vec4f/f32) reflect as one leaf named after
  the var (runtime-sized storage arrays stay unreflected); `parseUniformTable` returns `elemCount`
  and `handleGetUniforms` forwards it. **Validation (2026-07-16, real bytes, same probe method that
  found the block):** `bands: array<vec4f,2>` (struct member) → `{type: 5 (VEC4F), size: 32,
  elemCount: 2}` (was `{255, 32}`); bare `env: array<vec4f,2>` → same shape, named (was ABSENT);
  `array<f32,8>` uniform → still correctly rejected (WGSL stride rule — a language limit, §253
  records scalar-lane arrays as storage-only). Real `parseUniformTable` output fed through the REAL
  `buildRegistries`: both probes expand into `[i]` ncomp-4 targets + a matching `arrays` plan,
  `dropped: []` — **the P1–P2 studio code works against real reflection with ZERO changes** (its
  `type: 5` fixtures turned out to model exactly what Option (B) now emits). Gates: pngine
  `test-reflect`/`test-bytecode`/`test-sjon`/`test-descriptor-encoder` green; editor **1614/1614**,
  tsc 0, biome clean, svelte-check 0 err. **Cross-plan facts:** (1) 05's "Wire impact: none" header
  is superseded — Option (B) was a deliberate append-only pngine wire change, the user's call. (2)
  The studio still derives `count = size/16` and its `UniformReflection` type omits `elemCount` —
  correct today (every legal uniform array element strides to 16 B, so `size/16 === elemCount`),
  but P3 should consume `elemCount` as authoritative (also future-proofs >16-B elements, which
  currently drop via `LANES_BY_TYPE`). (3) P3's example must be `array<vec4f, N>` — lanes in 4s.
  Board: `05 · P3 READY`; benchmark #2 unblocked behind it; What's next → resume P3.
- 2026-07-16 — **05 Phase 3 studio re-base DONE (pngine `419226b`, journal §254); element targets
  renamed `base.N` (DOTTED) — the `[i]` spelling was unauthorable.** Resuming P3 surfaced a second
  reachability gap, one seam past the reflection block: a score literally cannot name `bands[1]` —
  `:target` is `target-name :underlying symbol` and `[` opens a vector in SJON, so `bands[1]` lexes
  as symbol + vector (schema error) and the string form is rejected (probed live on the real pacer
  wasm; the 2026-07-16 validation missed it because it fed registry names into `buildRegistries`
  without ever authoring a track). **Cross-plan facts:** (1) ⭐ **The score-facing element-target
  naming contract is `base.N`** (`bands.1`, nested `fx.bands.1`) — `.` is in SJON's symbol-body
  charset and is pngine's own nested-struct separator; a WGSL identifier is never all-digits, so a
  trailing `.N` is unambiguous. All 05 docs/examples/templates must use it; no pacer surface changed
  (`target-name` stays an unconstrained symbol). (2) **The Phase-2 "always 16 B = 4 floats"
  byte-lock is superseded: stride is now per-field** (`size/elemCount`, carried as `strideFloats`
  in the `arrays` plan; `elemCount` consumed as the authoritative count and the array
  DISCRIMINATOR, replacing the size/type heuristic). Consequence: tight STORAGE arrays reflect and
  expand — `var<storage> lanes: array<f32,8>` → 8 scalar targets through the SAME
  reflection + `setUniform` seam (`uniformToTypedArray` truncates flat floats to the field's byte
  size regardless of address space), so the retired `array<f32,N>` scalar-lane headline returns via
  storage. (3) A pre-§253 reflection (no `elemCount`) degrades wide fields to `dropped`
  (console-visible), never crashes — the studio tolerates a stale pngine runtime. Real-wasm
  integration test `array-targets.test.js` chains authored score → `eval` → `toUniforms` →
  coalescer → whole-field writes (holes sample-held). Editor **1626/1626** (+12), tsc 0, biome
  clean, svelte-check 0 err. Board: 05 → example+smoke left; benchmark #2 next behind it.
- 2026-07-16 — **05 Phase 3 example DONE (pngine `72d49f8`): the demoscene template drives a bare
  `env: array<vec4f, 2>` post binding via dotted lanes; only the manual smoke remains.** `env.0` =
  keyframed vec4 color grade (cool→warm on the chroma window), `env.1` = `(trigger :every 1b)` —
  its phase lane shapes a quartic per-beat flash, so the flagship template now composes **02
  triggers × 05 array lanes**; the binding lives in stage 4 only (the four `Motion` struct
  declarations untouched — the zero-churn pitch, and the shipped exerciser of the §253
  bare-binding reflection path). Scoreless-template invariant kept: all-zero `env` renders the
  static noise scene (grade amount 0; flash a constant imperceptible lift). **Cross-plan facts:**
  (1) **the demoscene score is load-bearing fixture for FIVE editor suites** (`score-uniforms`,
  `anchors`, `span-edit`, `curve-sample`, `score-timeline`) — any future template edit that adds a
  score target must extend those suites' modeled registries or every load fails `unknown_target`
  (this ripple was 11 red tests until caught); `score-uniforms` now derives its registries through
  the REAL `buildRegistries` so it can't drift again, and anchors' track list pins 5 rows incl. a
  `'trigger'` source row (first template exercise of 02's meta source in the timeline path). (2)
  Template vec4 keyframes land BIT-EXACTLY on `Math.fround` of the authored literals (structural
  landing holds through the whole studio chain) — pinned in the new template test alongside the
  dyadic-exact trigger lanes and the coalesced 8-float `env` write. Compiled-doc reflection
  verified to match the modeled wire byte-for-byte (`env {type:5, size:32, elemCount:2}`,
  `dropped: []`). Editor **1627/1627**, tsc 0, biome clean (touched scope; whole-tree biome
  already red at HEAD, pre-existing), svelte-check 0 err. Board: 05 → manual smoke left → tick →
  benchmark #2.
- 2026-07-16 — **Benchmark #2 (impulsos dots choreography) — rewrite applied + parity-validated;
  A/B pending.** The North-Star ritual, round 2, on the dots-grid choreography (beats 149–204,
  the `dots` module of `~/Dev/2026_impulse/impulse.sjon`; snapshots
  `*.PRE-PACERBENCH2-2026-07-16.sjon`). **Measurement: TEN beat knobs left WGSL for the score**
  (`B_SHAPES`/`SHAPE_BEATS`/`B_REFRESH`/`REFRESH_LEN`/`B_CONTRACT`/`CONTRACT_LEN`/`B_WORD`/
  `WORD_BEATS`/`B_FULL`/`B_FIST`) through ONE `array<vec4f,4>` binding driven as dotted lanes —
  exactly the 05×02 composition the wave was built for: `denv.0`/`denv.1` are per-beat
  `(trigger …)`s whose **count lane IS the old `floor((beat-B)/1)` stepper** (`:offset` is a true
  start delay — event k = offset + k·every, write omitted before the first event, so the buffer's
  initial zeros cover pre-history); `denv.2` keys the four crossfade mixes — **`:ease smoothstep`
  is the WGSL builtin's exact curve**, so the migrated smoothsteps are shape-identical, not
  approximated; `denv.3` keys the global ramps (birth, wipe front with its 1.25 clamp, contraction,
  word progress). Parity gate (scratchpad `bench2_parity.mjs`, the corpus-style red→green for a
  non-git demo repo): pngine CLI compile → real `parseUniformTable` → real `buildRegistries` →
  real `pacer.wasm` `evalTicks` → `toUniforms` → real coalescer, 1401 tick samples over beats
  140–210 vs the ORIGINAL WGSL formulas — **steppers exact, everything else worst Δ 1.06e-6**
  (f32 truncation), event gates structural, pre-event holes omitted. **Cross-plan facts:** (1)
  ⭐ **pngine's `populateUniformTable` deduped by `(group, binding)` across ALL modules** and joined
  buffers through one global map — in a multi-pipeline doc with per-pipeline `(layout auto)`, a
  score-driven binding had to claim a doc-globally-unique slot or it SILENTLY vanished from the
  reflection (no diagnostic; `denv` at `(0,2)` disappeared behind cs1's `pngineU`/fs3's `gA` and
  landed at `(0,4)`). **FIXED upstream 2026-07-16** (pngine `e2dc4bd` per-pipeline join +
  `b2319a4` collision/drop warnings); re-verified from this side — the binding-4 workaround was
  reverted (`denv` back at its natural `(0,2)`, table attributes every field to the right buffer,
  parity gate ALL GREEN, worst Δ unchanged at 1.06e-6). (2) **Lane rest-value ambiguity**: a key lane that rests at 0
  half-lights any consumer whose window straddles 0 (the tally's char-0 pop read `smoothstep(-0.15,
  0.15, wordProg)` = 0.5 at rest) — the idiom is REST OUTSIDE THE WINDOW with a slope-matched
  anchor key (`-1` rest, `189.85b → -0.15` anchor, then slope 1/beat); triggers dodge this by
  design via the pre-first-event omit. (3) **A childless `(scene …)` is legal** and lands in
  `'SCEN'`/the timeline — a pure named-section annotation (`dots-choreo` @ 148b/72b). **Residue
  (stays WGSL, steering signal):** (a) a periodic trigger has no event-count cap, so "hold the
  last icon/letter" keeps a shader `clamp(count, 0, N-1)` — a `:count N` limiter on `(trigger …)`
  would let the score own the hold (N stays a data fact); (b) vec4 element key tracks COUPLE the
  four lanes (every key names all lanes) — fine for non-overlapping crossfades, awkward for
  independent envelopes; per-lane element targets (`denv.2.x`) don't exist; (c) per-dot stagger
  (the grow-out snaps, tally column offsets, hash dance) is inherently per-instance and stays WGSL
  — but its CLOCK moved to a shared lane: *the score owns the clock, WGSL keeps per-instance
  shape*; (d) the disabled `B_DOTS`/`B_BG` knobs and the grow-out `B_SPLIT`/`B_VERT`/`B_HORZ`
  (per-dot staggered) were deliberately left. No pacer or pngine code changed — demo-side only.
  **A/B CONFIRMED 2026-07-16** — the user eyeballed beats 148–204 in the studio: the choreography
  is identical. Board box ticked; **Wave 2 COMPLETE** (09 → 07 → 05 → benchmark #2).
- 2026-07-16 — 06 Phase 0 complete (pngine `4f5e061`): pure-TS `.it` reader
  (`studio/editor/src/lib/score/it-reader.ts`), fixture-pinned reds + realism check
  against the real module. **Cross-plan fact for 06 Phase 1 / any trigger emission:**
  `impulse-04.it` sets speed per-row (1024 Axx commands, alternating A8/A4 swing) —
  a naive rows→beats at the initial speed 6 is only PAIRWISE correct: even rows (the
  beat quarters) land on-grid, odd rows land late by the swing. Onset beats emitted
  for triggers should either quantize to the even-row grid or model the per-row
  speed ledger; the Phase-1 warning must fire here (Txx is absent — the BPM itself
  never moves, so `(transport :bpm 125)` stays honest).
