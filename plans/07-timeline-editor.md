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
