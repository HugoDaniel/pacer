# pacer × it — the demo-stack wave

**Start at [00-strategy.md](00-strategy.md)** — waves, status board, decision log,
"what's next" pointer. This file holds the scope and the plan index.

Post-1.0 follow-on set, created 2026-07-19. The batida plan set
(`~/llm/plans/it/`, repo `~/Dev/batida` once created) re-adapted itself around
pacer as the demo conductor: batida derives an **exact** musical time map from
`.it` modules (TimeMap: tempo segments, per-row grid, note onsets), emits pacer
score skeletons (`export-score`), and implements pacer's `AudioTargetHost` with
real per-channel params. That surfaced pacer-side work this set owns:

1. pacer's transport is **constant-BPM** — modules with tempo maps (Txx) can
   only export second-unit positions today (filed in it 09's risks). → plan 01.
2. The audio boundary should stay **engine-agnostic** as real engines multiply
   (chiptune3/libopenmpt today; batida, audzio-graph, Sointu tomorrow) → plan 02.
3. The studio's `.it` importer (../06-tracker-import.md) **approximates** timing
   (initial tempo/speed, Axx/Txx warnings) — exact data can replace the math
   without pacer ever learning what a tracker is → plan 03.
4. The studio audio bus (../10-audio-bus.md) is capped by libopenmpt's blocked
   ext-interactive API (`audio.ch<N>.*` deferred) and a vendored worklet patch —
   a second engine behind the same contract removes the cap → plan 04.

## The audio-agnostic principle (applies to every plan here)

pacer knows **registries, params, and one clock — never engines.**

- Tempo/timeline truth travels as **score text** (generated skeletons, `(tempo …)`
  forms), never as a runtime host query. Hosts stay three methods:
  `params() / setParam() / clock()` (`npm/pacer/src/audio.js`).
- Engine-specific glue lives host-side (studio, batida npm, …); skeleton
  generation lives engine-side. pacer core contains zero tracker, zero
  WebAudio, zero engine vocabulary.
- A score is engine-relative by construction: targets resolve against whatever
  the active host's `params()` declares; unresolved targets are the existing
  `unknown_target` diagnostic. Engines with different capabilities (chiptune's
  tempo/pitch factors vs batida's per-channel gains) simply expose different
  registries — the `;;`-commented template-block discipline (../10, Phase 3)
  handles portability.

## Execution discipline

Inherited whole from [`../README.md`](../README.md): TDD reds first · one phase
per context window with a progress-log entry + commit per phase · wire surfaces
(`'PACT'`/`'PACD'`/`'PACM'`/`'PACW'`, `Compile.Code`, `Easing.Op`, `drv_*`)
append-only · failures are diagnostics with spans, each `Compile.Code` audited
by name · every score-language feature lands with a golden corpus case
(`zig build corpus -- --update`, review the diff, never hand-edit).

Gates: pacer core `zig build verify` (+ `audit-diagnostics` when codes change);
npm `cd npm/pacer && npm run lint && npm run typecheck && npm test`; studio
editor its own test verb (`~/Dev/pngine/studio/editor/`); batida artifacts are
**external gates** — a plan phase that needs one states the batida milestone it
waits on (it 10's ladder: T2 = player+timeline, P40 = batida.wasm).

## The plans

| # | Plan | Repo(s) | Depends on |
|---|---|---|---|
| 00 | [strategy](00-strategy.md) — waves, status, decisions | — | — |
| 01 | [tempo-map](01-tempo-map.md) — `(tempo …)` segments; piecewise seconds↔ticks | pacer | — |
| 02 | [engine-contract](02-engine-contract.md) — host conformance kit + capability matrix | pacer npm | — |
| 03 | [exact-import](03-exact-import.md) — timing providers behind the studio import dialog | studio editor | 01 shipped in studio wasm; batida T2 for the exact provider |
| 04 | [audio-bus-v2](04-audio-bus-v2.md) — engine-agnostic studio audio engines; per-channel bus | studio editor | 02; batida P40 |

Cross-repo context of record: `~/llm/plans/it/` (batida set — esp. 06 TimeMap,
07 param surface, 09 demo composition) and `~/llm/plans/audzio/` (the future
`(audio-graph …)` engine). This set never blocks on them for Wave A (see 00).
