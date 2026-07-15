# 07 — Visual timeline editor on `'PACM'` anchors

**Repo:** studio editor; no pacer core change (the anchors already exist)
**Wire impact:** none
**Gates:** studio editor test verb

## Why

pacer's `'PACM'` blob already exposes key ticks and value byte-spans, described in
`pacer/npm/pacer/src/index.js` as "the editor's timeline anchors", and `(control …)`
already proved commit-to-text via spans. Nothing consumes them: `ScorePane.svelte`
says explicitly "the rich keyframe/curve timeline lands in a later phase; this is the
text surface." This plan is that later phase. The score text stays the document
authority — the timeline is a lens that edits the text through spans.

## Design

- Three layers, built bottom-up so each is unit-testable without Svelte:
  1. **anchors** — `pacer.meta` → view model `{tracks: [{name, keys: [{tick, value,
     ease, atSpan, valueSpan}]}], transport, scenes?}`,
  2. **write-back** — pure text splicing: `(scoreText, span, newText) → newScoreText`,
     batched for multi-key drags, followed by `pacer.reload` (the studio's existing
     score path re-arms and re-derives meta — new spans come back fresh; never reuse
     spans across an edit),
  3. **UI** — a `ScoreTimeline.svelte` strip: one row per track, keys as handles,
     drag-x = retime (snap to beat grid from transport meter), drag-y = revalue,
     click-through to the text span in `ScorePane`.
- Curve rendering needs no easing reimplementation: sample the loaded pacer instance
  (`eval` per pixel column is cheap and exact — same trick as thumbnails). Sampling
  must not disturb playback: check whether eval on the shared instance races the
  playback loop's `uniformsAt`; if so, sample via `evalTicks` between frames or a
  second Pacer instance loaded from the same text.
- v1 scope: retime + revalue scalar keys, beat snapping, visual only for vec keys
  (show lanes, edit later). No key add/delete in v1 (that's a text insertion, more
  grammar-sensitive — v2).

## Phases

### Phase 1 — anchors lib (RED first)
Load: `pacer/npm/pacer/src/index.js` (meta decode section) + `types.js`;
`studio/editor/src/lib/preview/score-duration.ts` (existing tick→seconds constants).
Reds: `lib/score/anchors.test.ts` — given a real `Pacer.load` of a fixture score
(reuse the real-wasm harness from `score-uniforms.test.js`): track rows with key
ticks/values/spans; transport bpm/meter/dur; spans point at the exact `:at`/`:value`
byte ranges (assert by slicing the source text).
Green: `lib/score/anchors.ts`.
Gate: editor tests.
Carry-forward: the exact meta field names/shapes discovered.

### Phase 2 — write-back lib (RED first)
Load: `anchors.ts` interface; nothing else.
Reds: `lib/score/span-edit.test.ts` — single-span splice; multi-edit batch applied
right-to-left so earlier spans stay valid; property test: retime a key by +1b, reload
through real wasm, re-derived anchor tick moved exactly one beat and all writes at
other times unchanged (`evalBytes` equality); revalue roundtrip likewise; UTF-8: spans
are byte offsets — route through the byte↔char mapping (plan 09 Phase 2 util; if 09
hasn't run, build the util here and 09 reuses it).
Green: `lib/score/span-edit.ts` — `retimeKey`, `revalueKey`, `applyEdits`.
Gate: editor tests.

### Phase 3 — sampling for curves (RED first)
Load: `preview.ts` (only the pacer instance ownership + thumbnailUniforms pattern).
Reds: `lib/score/curve-sample.test.ts` — N-column sample of a track over the loop
matches direct `eval` values; sampling while "playback" evals interleave produces
identical results (no shared-cursor corruption — this red decides the second-instance
question).
Green: `lib/score/curve-sample.ts` + record the instance decision here.
Gate: editor tests.

### Phase 4 — ScoreTimeline component (RED first)
Load: `Timeline.svelte` (strip conventions: playhead, BPM ruler), `ScorePane.svelte`
(mount + diagnostics conventions), state actions schema if a new action is needed
(edits should flow as the existing score-set action so undo/log semantics hold).
Reds: component tests — renders rows/keys from anchors; drag emits a batched edit →
dispatched score action; snap honors meter; key click focuses the span in ScorePane.
Green: `ScoreTimeline.svelte` behind a Motion-tab toggle (text ⇄ timeline).
Gate: editor tests + manual smoke.

### Phase 5 — polish pass
Scenes lane (if plan 01 landed: render scene windows as named blocks), control pins on
the strip, vec-key lane display. Each item: red first, small, independent.

## Progress log

### Phase 1 — anchors lib → DONE (2026-07-15, pngine `5be6884`)

`lib/score/anchors.ts` — `scoreAnchors(meta, source)` → the timeline view model,
plus the exported `refineKeySpans(bytes, formSpan)` refiner. RED-first: wrote
`anchors.test.js` (7 tests, `node --test`-globbed `.test.js` — NOT the plan's
`.test.ts`, which the runner would skip), watched it fail (`ERR_MODULE_NOT_FOUND`),
then greened it. Gate: 7/7 green, full editor suite **1549/1549**, `tsc` +
svelte-check **0 errors** (5 pre-existing `App.svelte` warnings), lint clean.

**Carry-forward — the exact `'PACM'` shapes discovered (this is the crux):**

- **A key is ONE span, and there is no ease in meta.** pacer's `MetaKey` = `{ at:
  bigint, value: number[4], span }` where `span` covers the WHOLE `(key …)` form
  (confirmed in `pacer/src/Abi.zig` `encodeMeta` test: the span slices `"(key :at
  4b :value 0.8)"`), and ease is baked into the compiled table, never surfaced.
  The timeline retimes (`:at`) and revalues (`:value`) independently and paints
  the curve, so the anchors layer REFINES the form span into `atSpan`/`valueSpan`
  and lifts the `:ease` symbol by tokenizing the form. This is the real work of
  Phase 1 — not a passthrough. Phase 2's `retimeKey`/`revalueKey` splice through
  these two field spans directly.
- **Spans are UTF-8 BYTE offsets.** anchors EMIT byte spans (pacer's native
  coordinate); the refiner tokenizes in byte space (ASCII delimiters never
  collide with multibyte continuation bytes ≥ 0x80). The demoscene's comment
  em-dashes (`—`, 3 bytes each, 6-byte drift) made this concrete — the test maps
  byte→char via `byteToCharIndex` (09 Phase 2's util) before slicing, which is
  exactly the Phase 2 consumption path. **Do not have anchors emit char spans**;
  the byte→char map happens once, at the write-back splice boundary.
- **View model shape (Phase 2/4 consume this):**
  `{ transport{ bpm, beatsPerBar, dur:bigint|null, end:'loop'|'hold', loopBeats },
     tracks[{ name, targetId, registry, ncomp, source:'keys'|'expr'|'trigger',
       formSpan, keys[{ tick:bigint, value:number[], ease:string|null,
       atSpan, valueSpan, formSpan }] }],
     scenes[{ name, startTick, durTicks, nameSpan }] }`.
  expr/trigger tracks carry `keys: []`. `loopBeats` reuses
  `preview/score-duration.ts`'s `scoreLoopBeats` (no duplicate `TICKS_PER_BEAT`).
- **The meta input is typed STRUCTURALLY, not imported from `pacer`.** The
  studio's installed `pacer` is a pnpm file-copy whose `.d.ts` is stale (`Meta`
  has no `scenes`; `MetaTrack.source` lacks `'trigger'`). anchors defines its own
  `AnchorMeta` interface for the fields it reads — the running meta is assignable
  to it whether or not the installed types have caught up, and the interface IS
  the documentation of the consumed surface. (Refreshing that `.d.ts` is a
  separate hygiene task, not on 07's path.)

### Phase 2 — write-back lib → DONE (2026-07-15, pngine `2dd0e63`)

`lib/score/span-edit.ts` — `retimeKey` / `revalueKey` build a `SpanEdit`
(`{span, text}`) from a key's `atSpan` / `valueSpan`; `applyEdits(source, edits)`
splices a batch back into the score text. RED-first: wrote `span-edit.test.js`
(14 tests), watched `ERR_MODULE_NOT_FOUND`, greened it. Gate: 14/14 green, full
editor suite **1563/1563**, `tsc` + svelte-check **0 errors**, lint clean.

**Carry-forward — the write-back contract Phase 3/4 build on:**

- **byte→char maps ONCE, at the splice.** anchors emit pacer's byte spans;
  `applyEdits` maps every edit's span to char offsets via `byteToCharIndex`
  (09's `byte-index.ts`) against the ORIGINAL source, then splices. This is the
  single seam where the timeline crosses byte space → editor char space —
  proven by a `; é\n(key …)` test where the `é` drifts byte off char by one.
- **A batch is applied RIGHT-TO-LEFT.** Overwriting one span shifts every later
  byte, so `applyEdits` sorts descending by start and splices highest-first —
  earlier (lower) offsets stay valid until spliced. Order-independent by
  construction; **overlapping edits throw** rather than silently corrupt.
- **v1 retime snaps to WHOLE beats.** `retimeKey` emits an integer-beat `Nb`
  token (`formatBeats`), which converts to an exact tick (pacer floors
  `beats·180180`), so it round-trips bit-exactly. A non-beat-aligned tick
  **throws** (`RangeError`) rather than truncate — the UI must snap first;
  sub-beat retiming is v2. `revalueKey` emits `String(value)` (shortest f64
  round-trip → same f32 for an f32-exact drag value); non-finite throws.
- **The determinism property is proven end-to-end.** The real-wasm reds retime
  the 12b sceneMix key to 13b and revalue the 8b key to 0.5, `pacer.reload` the
  spliced text, and assert (a) the re-derived anchor moved exactly one beat /
  the value round-tripped, and (b) the raw `evalBytes` 'PACW' writes at
  UNAFFECTED times are byte-identical while a time inside the reshaped segment
  genuinely differs (positive control — the edit is no no-op). This is the
  reload-for-fresh-spans loop Phase 4's drag handler will drive.
- **No pacer state is mutated.** span-edit is pure text; the caller owns the
  `reload`. So the lib stays unit-testable and the score text remains the sole
  document authority (the plan's Design invariant).

### Phase 3 — sampling for curves → DONE (2026-07-15, pngine `c766b4b`)

`lib/score/curve-sample.ts` — `sampleTrackCurve(pacer, name, ncomp, {fromTick,
toTick, columns})` reads a track's value across N tick columns into
`{ticks: bigint[], lanes: number[][]}` (one value row per lane), so the strip
paints pacer's ease curve without reimplementing any easing. RED-first: wrote
`curve-sample.test.js` (9 tests), watched `ERR_MODULE_NOT_FOUND`, greened it.
Gate: 9/9 green, full editor suite **1572/1572**, `tsc` + svelte-check **0
errors**, lint clean.

**The instance decision (the RED the plan said would settle it): ONE shared
pacer — no second instance.**

- **pacer eval is a pure function of time.** There is no retained cursor between
  calls — `evalTicks(t)` computes that tick's writes from scratch, and
  `evalBytes` even `.slice()`s a fresh copy. So the ONLY shared mutable state is
  the reused write buffer (index.js: *"the returned array and its entries are
  reused — copy if you must keep them"*).
- **The sampler copies each column out before the next eval.** It pulls the lane
  scalars into `lanes[l][i]` immediately, never retaining an entry reference. So
  a playback frame eval landing between two sampled columns cannot corrupt the
  sample. The real-wasm RED proves it: wrapping the instance so every sampled
  column is preceded by a playback `eval(sec(7b))` on the SAME pacer yields a
  `deepStrictEqual`-identical curve to the un-interleaved baseline. **This closes
  the Design note's "second Pacer instance?" question — Phase 4's drag/scrub loop
  and the curve sampler share the one loaded instance.**
- **Sampling is in the TICK domain, not seconds.** `evalTicks` makes the curve
  SHAPE a pure function of tick, independent of the editor's live tempo — a
  sampled curve survives a bpm nudge (only the strip's horizontal seconds scaling
  changes, which the strip owns). Column `i`'s tick is `fromTick + floor(i·span /
  (columns−1))` — exact BigInt integer math, so 33 columns over `[0, 32b]` land
  on the whole-beat grid `0b…32b`, matching a direct `evalTicks` per column.
- **`toTick` is INCLUSIVE and absent writes read as NaN.** Passing `loopTicks` as
  `toTick` samples the loop boundary, whose value wraps to the start
  (`eval(L) === eval(0)`) — the caller subtracts a tick for the pre-wrap frame.
  A column where the track wrote nothing (no entry, or a null/expr-NaN frame)
  holds `NaN` so a canvas polyline breaks into a gap rather than fabricating a
  point. Phase 4 draws lane `l` as a polyline over `(ticks[i], lanes[l][i])`.

### Phase 4 — ScoreTimeline component → DONE (2026-07-15, pngine `fdfcc9a`)

The strip ships. Two pieces, RED-first: `lib/timeline/score-timeline.ts` (pure
model + drag reducer, 17 tests incl. 2 real-wasm proofs) and
`components/ScoreTimeline.svelte` (the dumb shell) behind a Motion-stance
text⇄timeline toggle. Gate: 17/17 green, full editor suite **1589/1589**, `tsc`
+ svelte-check **0 errors** (5 pre-existing `App.svelte` warnings), Biome clean.

**Carry-forward — the decisions that shaped the wiring:**

- **The component's logic lives in a PURE lib, not the `.svelte`.** The editor
  has NO DOM test harness (glob is `src/lib/**/*.test.js`, no jsdom/vitest), so —
  exactly as `Timeline.svelte`'s scrub logic lives in `timeline-gesture.ts` — all
  of ScoreTimeline's real work is in `score-timeline.ts`: `timelineRows(anchors,
  layout)` (→ positioned rows), `tickToX`/`valueToY`, `snapTickToBeat`, and the
  `keyPointerDown/Move/Up` reducer. The `.svelte` is a thin shell (SVG render +
  pointer routing), covered by manual smoke only. This is the pattern for every
  future editor-component phase — put the logic in `lib/`, keep the shell dumb.
- **A drag is a text edit, via the existing `SET_SCORE` action.** The reducer
  builds the edit from Phase 2's `retimeKey`/`revalueKey` and `applyEdits`, then
  emits `{type:'DISPATCH', action:{type:'SET_SCORE', score}}` — the SAME action
  typing in ScorePane dispatches, so undo/log/replay semantics hold for free. A
  retime + a revalue on one key **batch into a single `SET_SCORE`** (both field
  splices atomic) — retime snaps to a whole beat (v1) so `retimeKey` never throws.
  A no-op drag (snapped back to origin) emits nothing.
- **Two effect kinds, mirroring `timeline-gesture`'s DISPATCH/SEEK split.**
  `DISPATCH SET_SCORE` is the committed/logged edit; **`FOCUS_SPAN` is
  imperative** — a bare click (no move past threshold) focuses the key's form
  span back in ScorePane, wired like `selectBpm` (App sets `motionView='text'`
  then rAF-defers `scorePane.focusSpan(span)`, which byte→char-maps the span for
  CodeMirror). Caret placement is UI, not a document mutation, so it is NOT an
  action.
- **The armed (meta, text) pair must travel together.** The timeline derives
  `scoreAnchors(armedMeta, armedScore)` from a pair captured together in
  `onScoreArmed` — NOT from live `appState.score`, which races ahead of the async
  re-arm after a drag. The drag also splices against `armedScore` (the text the
  spans index), so a stale span never refines against edited text. After a drag →
  `SET_SCORE` → reload, both refresh in the same `onScoreArmed`, closing the
  reload-for-fresh-spans loop Phase 2 proved deterministic.
- **The shared pacer is reused for sampling, not re-instantiated.** `preview.ts`
  exposes `scoreMeta()` and `sampleCurve()` on its handle; the component takes an
  injected `sampleCurve` callback (DI, like `Timeline`'s thumbnails) rather than
  reaching across the pacer-instance boundary. This is the Phase 3 decision cashed
  in: one instance, safe to sample while playback evals interleave.
- **The installed `pacer` `.d.ts` is now CURRENT.** The Phase 1 note flagged it
  stale (no `scenes`, no `'trigger'`); the pnpm copy was refreshed (2026-07-15),
  so `pacer.meta` is directly assignable to `anchors.ts`'s `AnchorMeta` — the
  preview seam needs no cast. (The structural `AnchorMeta`/`CurveSamplePacer`
  interfaces stay as the documentation of the consumed surface regardless.)
