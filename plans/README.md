# pacer growth plans

**Start at [00-strategy.md](00-strategy.md)** — the rollout order, status board, and
"what's next" pointer live there; this file holds the shared conventions and the
plan index.

Plans distilled from the impulsos/camaradas post-mortem: the shipped score was three
tracks (one the identity `(track :target beat :expr beat)`) while ~400 beats of
choreography lived in WGSL as `const B_* : f32` knobs. These plans move the timing
structure (sections, events, envelopes) into the score and give the studio a visual
surface for it — without ever pulling per-pixel work out of WGSL.

## Execution discipline (applies to every plan)

- **TDD reds first.** Every phase starts by writing failing tests, runs them to see
  the red, then implements to green. No implementation before its red exists.
- **One phase per context window.** Each phase lists exactly the files to load.
  After a phase's gate passes: append a short entry to the plan's `## Progress log`,
  commit (house style `type(scope): summary — detail`), then compact. Never carry a
  previous phase's file contents into the next — the plan file + progress log is the
  only carry-forward. Target well under 100k tokens per phase.
- **Wire surfaces are append-only** (`'PACT'`/`'PACD'`/`'PACM'`/`'PACW'`,
  `Compile.Code`, `Easing.Op`, `drv_*`). New enum variants/records/exports are
  appended; contract changes bump `drv_abiVersion`.
- **Failures are diagnostics, not errors.** New `Compile.Code` variants are appended
  to the u16 enum and each gets a by-name test (`zig build audit-diagnostics` gate).
- **Every score-language feature lands with a golden corpus case.** Regenerate via
  `zig build corpus -- --update` and review the diff; never hand-edit goldens.

## Gates

| Surface | Gate |
|---|---|
| pacer core | `zig build verify` (+ `zig build audit-diagnostics` when diags change) |
| pacer npm | `cd npm/pacer && npm run lint && npm run typecheck && npm test` |
| studio editor | check `~/Dev/pngine/studio/editor/package.json` scripts; run its test verb |
| wgslender | its own `zig build` test verbs (check `~/Dev/wgslender/CLAUDE.md`) |

## The plans

| # | Plan | Repo(s) | Depends on |
|---|---|---|---|
| 00 | [strategy](00-strategy.md) — rollout waves, status board, decision log | — | — |
| 01 | [scenes-cues](01-scenes-cues.md) — `(scene …)` named sections, scene-local time | pacer | — |
| 02 | [trigger-lanes](02-trigger-lanes.md) — `(trigger …)` beat/event lanes | pacer | ideally 01 |
| 03 | [pattern-tracks](03-pattern-tracks.md) — `:pattern` via SJON PatternQuery | pacer, SJON | — |
| 04 | [transport-lanes](04-transport-lanes.md) — `(transport :emit …)` built-in clock lanes | pacer | — |
| 05 | [array-targets](05-array-targets.md) — array uniform fields as targets | pacer npm, studio, pngine | — |
| 06 | [tracker-import](06-tracker-import.md) — .it module → score skeleton | studio | 01, 02 help |
| 07 | [timeline-editor](07-timeline-editor.md) — visual keys/curves on 'PACM' anchors | studio | — |
| 08 | [knob-lift](08-knob-lift.md) — WGSL const → uniform + `(control …)` | wgslender, studio | — |
| 09 | [studio-workflow-fixes](09-studio-workflow-fixes.md) — meter, UTF-8 spans, checkpoints | studio | — |
| 10 | [audio-bus](10-audio-bus.md) — registry 1 wired to libopenmpt ctls | studio, pacer npm | — |
| 11 | [hardening-1.0](11-hardening-1.0.md) — corpus pins, compose targets, easing wire | pacer | — |
| 12 | [sjon-alignment](12-sjon-alignment.md) — preloaded schema, schema vocabulary, LSP, examples | pacer | — |
| 13 | [sjon-union-arms](13-sjon-union-arms.md) — a disjoint union should report the arm, not the union | SJON (ask), pacer | 12 |
| 14 | [cli](14-cli.md) — a native binary: score IR + eval-at-t as JSON, knobs as `--set` | pacer | — |
| 15 | [release-0.1.0](15-release-0.1.0.md) — release preparation, gates, package checks and pre-publication review | pacer | pinned SJON / pngine inputs |

Execution order, wave milestones, and the current "what's next" pointer are
maintained in [00-strategy.md](00-strategy.md) — the "Depends on" column above only
records hard dependencies.

Post-1.0 follow-on: the **demo-stack wave** lives in [`it/`](it/README.md)
(created 2026-07-19, from the batida re-adaptation in `~/llm/plans/it/`) —
tempo-map transport, the engine-agnostic audio-host contract, exact tracker
import, audio-bus v2. It inherits this file's execution discipline; its own
strategy board is `it/00-strategy.md`.

Quality follow-on: the **elegance wave** lives in [`elegance/`](elegance/README.md)
(created 2026-07-20, from the elegance/purity review) — seven plans closing the
review's findings, two of them (writes-cap, meta-cap-pin) release-relevant before
the 0.2.0 tag. It inherits this file's execution discipline; its own ordering and
status board are in `elegance/README.md`.

Playback follow-on: the **binary wave** lives in [`binary/`](binary/README.md)
(created 2026-10-18, planning only — execution not started) — the `'PACB'`
compiled-score format, a playback-only `pacer-rt.wasm` with no compiler in its
import closure, byte-level text-vs-binary parity, and a measured (not promised)
size/perf story with the decision left to the user. Its SJON prerequisite is a
pacer-local handoff, unfiled. It inherits this file's execution discipline; its
strategy board is `binary/00-strategy.md`.
