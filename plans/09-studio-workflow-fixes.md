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

### Phase 1 pre-flight (2026-07-15) — plan reconciled with the refactored studio

Grounded Phase 1 against the live editor before implementing; the plan text (written
2026-07-13) is stale on file paths — the timeline moved from `Timeline.svelte` to `.ts`
modules under `pngine/studio/editor/src/lib/timeline/`. Findings that make Phase 1 narrower
than written:
- **The strip is already parameterized.** `timeline-strip.ts:378` takes `beatsPerBar = 4` as
  a DEFAULT param (not a hardcoded constant), and `timeline-strip.test.js:390` already tests
  `respects custom beatsPerBar`. So there is no constant to delete — the bar math already
  honors a passed-in meter.
- **The real work is threading.** `preview.ts` `onScoreArmed?.({ loopBeats, bpm })`
  (lines ~188/203) is the armed-score callback; the driver exposes the meter as
  `pacer.meta.transport.beatsPerBar` (npm `types.js:77`). Phase 1 = add `beatsPerBar` to that
  callback payload and route it into the strip caller, so the score's `(transport :meter …)`
  overrides the default 4. `transportBpmOf`/`loopBeatsOf` at `preview.ts:156`+ are the sibling
  helpers to copy for a `beatsPerBarOf`.
- **RED lands in** `src/lib/timeline/*.test.js`; gate = `node --test 'src/lib/**/*.test.js'`.
  Integration red: a 3/4 score renders bar ticks every 3 beats end-to-end; no score → 4;
  meter change on reload updates the ruler.

### Phase 1 DONE (2026-07-15) — timeline honors the score's meter — pngine `962698a`

RED→GREEN, exactly as the pre-flight scoped it (threading only, no constant to un-hardcode
in the strip — it was already parameterized).
- **RED** (`src/lib/timeline/timeline-strip.test.js`): a new `bpmRulerCadence` block —
  4/4 → bar every 4 beats, **3/4 → bar ticks every 3 beats** (1.5s @ 120), 7/8, the 4/4
  default, and degenerate fallbacks (meter < 1 / non-finite → 4, bpm ≤ 0 → 120). Ran red
  (no such export), then green.
- **GREEN pure**: `bpmRulerCadence(bpm, beatsPerBar)` in `timeline-strip.ts` returns the
  `{tickStepSec, minorSubdivisions}` pair (a bar every `beatsPerBar` beats, one dot/beat),
  guards mirroring `formatBeats`.
- **GREEN thread**: `beatsPerBarOf(p)` in `preview.ts` (sibling to `transportBpmOf`) reads
  `pacer.meta.transport.beatsPerBar`; the `onScoreArmed` payload carries `beatsPerBar` →
  `App.svelte` `beatsPerBar` state (`?? 4` when no score) → `Timeline` prop → the cadence
  helper + both `formatBeats` calls. `Timeline.svelte`'s hardcoded `BEATS_PER_BAR = 4`
  constant is deleted; the 4/4 default now lives in the prop default + the two fallbacks.
- **Gate**: editor tests **1532/1532** (+6), `tsc` + `svelte-check` **0 errors**, biome clean.
- Behavior nuance: the old bpm-mode `tickStepSec` used `Math.max(1, bpm)` (→ a 240s tick at
  bpm 0); `bpmRulerCadence` falls back to 120 there instead, matching `formatBeats`. No
  regression for any real (positive) bpm; strictly saner at the degenerate edge.

Phases 2 (UTF-8 byte spans) and 3 (named checkpoints) remain — independent, compact between.

### Phase 2 DONE (2026-07-15) — UTF-8 byte spans → editor coordinates — pngine `52210b5`

RED→GREEN. pacer diagnostic/meta spans are UTF-8 byte offsets (documented in
`pacer/npm/pacer/src/index.js`); CodeMirror indexes by UTF-16 code unit, so one non-ASCII
byte before a span shifts every later coordinate.
- **RED** (`studio/editor/src/lib/score/byte-index.test.js`, `.js` to match the `*.test.js`
  runner glob — the plan's `.test.ts` was loose): `byteToCharIndex` on ASCII (identity), 2-byte
  (é), 3-byte (€), 4-byte emoji (surrogate pair → 2 UTF-16 units), mid-code-point round-down, and
  out-of-range clamp; plus the integration red — a `; côr\noops` score where pacer's byte span
  `[7,11)` slices `'ops'` on the JS string, remapped to char `[6,10)` it slices `'oops'`. Ran red
  (`ERR_MODULE_NOT_FOUND`), then green. +10 tests (1532 → 1542).
- **GREEN pure** (`lib/score/byte-index.ts`): `byteToCharIndex(text)` builds a dense per-byte →
  char table once (O(1) lookups; multi-byte offsets round down to the code-point start, out-of-range
  clamps to `[0, length]`); `remapScoreDiagnostics(text, diags)` maps `{start,end}` byte spans →
  char, returning fresh records (no mutation). Generic over `<T extends ByteSpan>` so meta spans can
  reuse it.
- **GREEN route**: `preview.ts` runs both armed-score `onScoreDiagnostics` emits through
  `remapScoreDiagnostics(score, …)`, so `ScoreDiagnostic.start/end` now carry EDITOR (UTF-16 char)
  coordinates; the type + option doc comments flipped from "byte offset" to editor coordinates.
- **Scope call**: ScorePane's v1 is a compact TEXT summary (its own comment defers rich highlighting
  to a later phase) and the existing CM `updateDiagnostics` is line/column-based — so no new squiggle
  UI was built; the fix is correct coordinates at the `preview.ts` choke point, proven purely by the
  integration test. Meta spans (control `valueSpan`, scene `nameSpan`) have no editor
  coordinate-consumer yet, so they were left byte-valued — remap them where 07 first positions them.
- **Gate**: editor tests **1542/1542** (+10), `tsc` + `svelte-check` **0 errors** (5 pre-existing
  App.svelte warnings, untouched), biome clean.
- The util is the dependency 07 (timeline-editor) wants — recorded in `00-strategy.md`'s Decision
  log so 07 reuses it. Phase 3 (named checkpoints) remains — independent; compact here.

### Phase 3 pre-flight → DONE (2026-07-15) — already shipped as the Versions / Checkpoint feature

Grounded Phase 3 against the live editor before writing a line — and, exactly like Phase 1's
pre-flight, the plan text (written 2026-07-13) predates the studio's current state. Phase 3's whole
deliverable — **named checkpoints** (a name field + list in the editor chrome, restore, replacing the
`impulse.PRE-TUNNEL-2026-07-10.sjon`-style manual file-copy workflow) — is **already built, live, and
gated** as the **Versions / Checkpoint** feature. Building the plan's literal `CHECKPOINT` action +
`listCheckpoints` helper would DUPLICATE it and regress (it would forfeit the integrations below).

The plan's design maps one-to-one onto shipping code — but the marker is a tree **save-tag**, not a
separate marker node, which is strictly better (it pins the node against compaction and rides the
auto-checkpoint / branch-tip / deep-link / dashboard-pill machinery):
- **`CHECKPOINT {name}` → `SAVE_VERSION {label}`** (`schema/studio-state.sjon:359`). Dispatching it
  appends a node and tags the cursor: `tagNode(tree, tree.cursor, { label })`
  (`editor/src/App.svelte:766-767`). The transition only clears `dirty` — AppState *content* (source +
  score) is unchanged, exactly the plan's "appends the marker and leaves AppState unchanged".
- **name field + list → `VersionsPanel.svelte`.** "+ Checkpoint" reveals an inline name input
  (`placeholder="Name (optional), ↵"`, `VersionsPanel.svelte:162-182`) that commits
  `onCheckpoint(label)` → `makeCheckpoint` → `SAVE_VERSION`; the list (`versionsView`,
  `editor/src/lib/ui/versions-view.ts`) renders checkpoints newest-first as `v3 · my label`, marks the
  current one, and offers restore / rename / copy-deep-link / branch-tips. Mounted at
  `Toolbar.svelte:238`, wired in `App.svelte` (`makeCheckpoint`/`gotoVersion`/`renameVersion`/`toggleVersions`).
- **`listCheckpoints(log)` → `listSaveTags(tree)` / `listSaveTagsFromNdjson(serialized)`**
  (`action-tree.ts:730,750`) returns `{nodeId, version, label, ts, kind}[]` = names (`label`) +
  positions (`nodeId`).
- **restore (append-only, undoable) → `replayTo(nodeId)`** (`App.svelte:793`). It replays the log to
  the tagged node — rebuilding source AND score — then moves the cursor; the next edit branches
  naturally (nothing lost, no history rewrite). This IS the plan's "replay the log up to a marker into
  the current state … no history rewrite".

Every RED Phase 3 lists is already GREEN under shipping tests: tag-appends-marker /
content-unchanged (`state.test.js`, `action-tree.test.js`), `listSaveTags` names+positions
(`action-tree.test.js`), and restore-replay reconstructs **source + score**
(`src/lib/seed-log.test.js:21` — `buildSeedLog round-trips source + score through the action log`,
via the same `pathTo`+`reduce` path `replayTo` uses; plus `history.test.js`). `save-btn.test.js`
covers the `checkpointState` control (disabled when the cursor already sits on a version).

Closed as **satisfied by existing work** — no code written (writing the duplicate would be a
regression). The feature's tests were already green in the Phase 2 gate run (1542/1542); nothing new
to gate. **09 is complete** (all three phases done); Wave 2 continues with **07 (timeline-editor)**,
which reuses `byte-index.ts` (Phase 2's util). If the manual-versioning pain persists in practice, a
FOLLOW-UP would be adoption/discoverability of the existing panel — not a second checkpoint system.
