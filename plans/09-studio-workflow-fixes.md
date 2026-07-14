# 09 — Studio workflow fixes (meter, UTF-8 spans, checkpoints)

**Repo:** studio (editor + dashboard)
**Wire impact:** none
**Gates:** studio editor test verb (+ dashboard tests for Phase 3 if it touches `src/`)

Three independent fixes surfaced by the demo workflow. Each phase stands alone — run
them in any order, compact between.

## Phase 1 — timeline honors the score's meter (RED first)

Why: `Timeline.svelte` hardcodes `BEATS_PER_BAR = 4` (flagged in-code as a future
setting) while the score declares `(transport :meter […])` and `'PACM'` carries it.
Load: `studio/editor/src/lib/timeline/Timeline.svelte`, the meta consumption site
(`preview.ts` `transportBpmOf`/`loopBeatsOf` region), `App.svelte` only where timeline
props are bound.
Reds: unit/component test — a 3/4 score renders bar ticks every 3 beats; no score →
falls back to 4; meter change on reload updates the ruler.
Green: thread `meter` from `pacer.meta.transport` through the armed-score callback into
the timeline props; delete the constant.
Gate: editor tests.

## Phase 2 — UTF-8 byte spans → editor coordinates (RED first)

Why: pacer diagnostic/meta spans are UTF-8 **byte** offsets; they only equal JS string
indices while the score is ASCII (noted in `pacer/npm/pacer/src/index.js`). One
non-ASCII comment (`; côr`) shifts every CodeMirror squiggle and control span after it.
Load: `studio/editor/src/lib/preview/preview.ts` (`onScoreDiagnostics` path),
`ScorePane.svelte` (diagnostic → CodeMirror mapping), any other span consumer (grep
`span` in `lib/score`/`ScorePane`).
Reds: `lib/score/byte-index.test.ts` — mapping util `byteToCharIndex(text)` on ASCII
(identity), 2-byte, 3-byte, emoji (surrogate-pair) cases; an integration red: a score
with a non-ASCII comment before a bad track yields a diagnostic that highlights the
actual offending token in ScorePane.
Green: `lib/score/byte-index.ts` (build a cumulative offset index once per text
version, O(1) lookups) and route every span consumer through it. If plan 07 already
built this util, this phase is just the diagnostics wiring + integration red.
Gate: editor tests.

## Phase 3 — named score/document checkpoints (RED first)

Why: the demo directory is manual version control —
`impulse.PRE-TUNNEL-2026-07-10.sjon`, `live.score.CAMARADAS-2026-07-09.sjon`, ten
more. The studio already persists an NDJSON action log (score lives there as
`SET_SCORE` nodes; `src/lib/seed-log.ts`), so checkpoints are log bookmarks, not new
storage.
Load first (investigation, keep it tight): `schema/studio-state.sjon` (action
vocabulary + transitions), `editor/src/lib/state/state-interpret.ts` (how actions are
declared/applied), `src/lib/seed-log.ts`, however the log is replayed/branched (grep
`log` in `src/lib/editor-bridge.ts`).
Design: a `CHECKPOINT` action carrying `{name}` — a marker node; "restore" replays the
log up to a marker into the current state as a new `SET_SOURCE`/`SET_SCORE` pair (no
history rewrite — restoring is itself an action, so it's undoable and the log stays
append-only).
Reds: state-interpret test — dispatching `CHECKPOINT` appends the marker and leaves
AppState unchanged; a `listCheckpoints(log)` helper returns names+positions; restore
produces actions whose applied state equals the state at the marker (source + score
fields compared).
Green: schema action + helpers + a minimal UI (name field + list in the editor chrome;
match existing panel conventions).
Gate: editor tests + manual smoke (checkpoint → edit → restore).

## Progress log
