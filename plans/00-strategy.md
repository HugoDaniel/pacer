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
| 0 | 11 P1–P2 corpus pins | ☐ |
| 0 | 03 P0 pattern spike | ☐ |
| 0 | studio refresh + `:emit` template | ☐ |
| 1 | 'PACM' framing decision | ☐ |
| 1 | 01 scenes-cues | ☐ |
| 1 | 02 trigger-lanes | ☐ |
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

→ **11 easing-controls-corpus, Phase 1 + 2** (easing + controls/expr-env corpus pins —
no design risk; deepens the determinism gate before bigger features ride on it). Open
`plans/11-*.md`, execute its next phase RED-first, gate `zig build verify`. Then Wave 0
continues: 03 Phase 0 (PatternQuery wasm32 spike, verdict → Decision log), then the
studio refresh (which also lands 04's deferred `:emit [beat]` template switch).

04 transport-lanes is **DONE** (all 3 phases landed 2026-07-14) — schema/validation,
bit-exact eval, and the `transport-emit` golden. See 04's progress log; the studio
`:emit [beat]` migration is deferred to the Wave 0 studio-refresh step.

## Decision log

- 2026-07-13 — Strategy written. Open decisions parked: 'PACM' section framing
  (Wave 1 gate); PatternQuery wasm32 feasibility (Wave 0 spike); array-write delivery
  option a/b (05 Phase 0); scene out-of-window semantics recommended as write-omitted
  (01, confirm at its Phase 1 design freeze).
- 2026-07-14 — 04 transport-lanes complete. Cross-plan note: `(transport :emit …)`
  lanes are pinned in the corpus via `(eval …)` write buffers only, NOT the `'PACM'`
  meta blob — emit added no wire surface. Any later plan that wants emit lanes echoed in
  meta must append a meta section (append-only) and bump nothing else. The studio
  `demoscene.score.sjon` → `:emit [beat]` switch is a Wave 0 studio-refresh item, gated
  on the studio's `pacer.wasm` carrying emit eval.
