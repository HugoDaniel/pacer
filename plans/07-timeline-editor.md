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
