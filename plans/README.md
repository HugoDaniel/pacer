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

Execution order, wave milestones, and the current "what's next" pointer are
maintained in [00-strategy.md](00-strategy.md) — the "Depends on" column above only
records hard dependencies.
