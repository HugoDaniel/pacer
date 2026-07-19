# 00 — Strategy (demo-stack wave)

Session protocol, same as ../00-strategy.md: read this file, pick the top
unchecked item in **What's next**, open only that plan file, execute its next
phase under [`README.md`](README.md)'s discipline, then update the board and
this pointer.

## North star

**A tempo-honest, engine-swappable studio.** Two acceptance rituals:

1. **The tempo ritual** — a module with real tempo changes (synthetic Txx
   fixture; impulse-04.it has none) imports to a score whose beat anchors stay
   musically true across the change, with zero drift warnings; the same score
   evals bit-identically native/wasm (golden).
2. **The engine ritual** — the same demo project plays through two audio
   engines (chiptune3 today, batida when its wasm lands) by flipping one
   engine selection; the score's registry-1 targets resolve per engine, the
   per-channel duck lane works on batida, and pacer core is untouched.

## Ordering rationale

- **01 first** — it is the only pacer-core plan (wire + determinism seams move);
  everything downstream (exact import emitting `(tempo …)`, studio refresh)
  waits on its golden. It also reuses the whole proven loop (schema → diags →
  eval → 'PACM' → corpus → npm parity) from the shipped waves.
- **02 is cheap and unblocking** — the conformance kit + matrix freeze the
  contract batida's host will be written against (batida side, it 07/09),
  before that code exists anywhere.
- **03/04 split by dependency** — their provider/engine abstractions and
  characterization tests land now (Wave A) against the existing TS importer and
  chiptune driver; the batida-backed halves (Wave B) wait on external gates
  (batida T2 data, batida P40 wasm) without blocking anything.

## Waves

### Wave A — no batida needed
1. **01 tempo-map** — all phases (core, wire, goldens, seams doc).
2. **02 engine-contract** — both phases.
3. **03 exact-import Phases 0–2** — provider abstraction over the existing TS
   importer + shared emitter over `TimingData` + skeleton-file provider.
4. **Studio refresh** — rebuild `pacer.wasm`, `npm run build:wasm-copy`, AND
   re-link the glue (`pnpm install --prefer-offline` in `studio/`) — the
   hard-link rule from ../00-strategy (2026-07-17); editor real-wasm tests.
   Then the **tempo ritual** on a synthetic Txx fixture.

### Wave B — batida-gated
5. **03 Phases 3–4** — the exact provider (needs batida T2's timeline data
   surface) + the verify/diff UX + capacity pins.
6. **04 audio-bus-v2** — all phases (needs batida P40's wasm renderer).
7. **The engine ritual** + template refresh; file the audzio-graph host as the
   follow-on (it becomes the general case: registry 1 = every AudioParam of an
   `(audio-graph …)`, batida a node inside — `~/llm/plans/audzio/`).

## Status board

| Wave | Item | Status |
|---|---|---|
| A | 01 tempo-map | ☑ 2026-07-19 |
| A | 02 engine-contract | ☑ 2026-07-19 |
| A | 03 exact-import P0–P2 | ☐ |
| A | studio refresh + tempo ritual | ☐ |
| B | 03 exact-import P3–P4 (gate: batida T2) | ☐ |
| B | 04 audio-bus-v2 (gate: batida P40) | ☐ |
| B | engine ritual + template | ☐ |

## What's next

→ **Open [03-exact-import.md](03-exact-import.md), run Phase 0** (freeze
`TimingData`, characterize the approx path) — studio editor repo. 01 and
02 landed whole (01: 5 phases, corpus 25 cases, 'TMPO' on the wire;
02: host-check kit + matrix, npm 81 green). Wave B gates are external (batida milestones,
tracked in `~/llm/plans/it/10-demos-and-milestones.md`).

## Decision log

- 2026-07-19 — Set created from the batida re-adaptation (`~/llm/plans/it/`,
  same date). Decisions frozen at creation, each owned by its plan doc:
  (1) **tempo truth travels as score text**, never as a runtime host query —
  hosts stay `params/setParam/clock` (README principle; 02 documents it).
  (2) **`(tempo …)` positions are b/bar only** — an `s` position would need the
  map being defined (01's design; `s` stays legal everywhere else and resolves
  through the finished map). (3) **Timing providers supply data, the studio
  emitter stays the one text generator** (03) — engines never format score
  text; the skeleton-file provider is the engine-agnostic escape hatch.
  (4) **Engines expose what they honestly control**: batida's host excludes
  tempo/pitch factors by batida's own timeline-invariance rule (it 07);
  chiptune keeps exposing them; scores are engine-relative via registries (04).
- 2026-07-19 — Open decisions parked: `:at`-list / key caps under 1000+-onset
  imported triggers (03 Phase 4 measures against the real wasm before any core
  cap moves — a cap raise is wire-free but corpus-relevant); whether 'TMPO'
  should also ride `drv_meta`'s JS surface beyond the section decode (01
  Phase 4 decides when the studio timeline asks for it); clock-master flip UX
  in the studio preview when an engine provides `clock()` (04 Phase 2).
- 2026-07-19 — **The prerendered ("sointu-ish") path is kept and generalized,
  not superseded.** Assessed against pngine's shipped pipeline: the
  `SointuExports` ABI (whole song rendered at instantiation; `m/s/l/t`
  exports), the `pNGa` PNG chunk (`--audio`), `createAudioPlayer`, and
  `sointuHost`. It is the footprint extreme of the same two seams this set
  standardizes on (AudioTargetHost + masterClock); the delivery ladder is
  (a) synth wasm in `pNGa` — KB-scale, clock-only; (b) module + live engine —
  params + clock (plan 04); (c) PCM bounce — clock-only, zero engine risk,
  and the browser vehicle for batida's bit-pinned native bounce. Plan 02
  renames by append (`clockOnlyHost` canonical, `sointuHost` alias).
  **Parked idea, batida-side, not planned here:** batida emitting the Sointu
  ABI — a self-rendering song wasm (module + engine, renders the whole song
  at instantiation, exposes `m/s/l/t`) that drops into the existing `pNGa`
  chunk + mini.js player with zero pngine changes; wire stays module-sized,
  runtime cost ≈10 MB/min (int16 44.1 kHz stereo). If it ever matters it
  lands in the batida set (`~/llm/plans/it/`). Also noted, pngine-side and
  out of this set's scope: mini.js's `pNGa` path masters from the perf clock
  (`sr.start(0, tm)` — audio slaved to visuals, the size-play tradeoff),
  opposite of the studio topology; the fix if drift ever shows is sampling
  `ax.currentTime`.
- 2026-07-19 — **Cross-set implementation order pinned** (mirrored in the
  batida set, `~/llm/plans/it/10`): **pacer Wave A first** — 01's `(tempo …)`
  vocabulary is the one wire freeze every downstream producer targets, and
  Wave A upgrades the shipped studio stack with no new repos (the ordering
  held in practice: 01 ran P1–P4 the same day this was pinned). Then batida
  T0 → T1 → T2; **T2 is "first light"** for the new stack — the prerendered
  mode (bounce WAV + `clockOnlyHost` + exact `export-score` skeletons) ships
  a full demo with no P40/worklets. Then 03 P3–P4 (exact provider, gate:
  batida T2) → batida P40 → 04 (studio engine, per-channel bus, clock flip)
  → batida T3 (the long grind, deliberately AFTER the integration milestones
  so cross-repo flaws surface while cheap) → batida T4 (the demo-stack
  page). audzio interleaves freely through A2; its consumer moment is A3
  (batida `play` via cubeb); the `(audio-graph …)` node swap comes last.
  Critical path: pacer 01 → T0→T1→T2 → 03 P3 → P40 → 04 → T3 → T4.
