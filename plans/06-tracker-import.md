# 06 — Tracker-module import (.it → score skeleton)

**Repo:** studio editor (new pure lib + UI); no pacer core change
**Wire impact:** none
**Gates:** studio editor test verb

## Why

`impulse-04.it` contains every note event of the demo's music, yet the drop/breakdown
bar positions were hand-computed into WGSL comments and constants ("full drop bar 41.1
(160), breakdown bar 56.1 (220)"). An importer that reads the module and emits a score
skeleton — transport, scene anchors, triggers from note onsets — removes the
transcription step entirely.

## Design (freeze in Phase 0)

- **Parse in pure TS**, not through libopenmpt: the chiptune3 build lives in an
  AudioWorklet and is awkward in unit tests, while the .it format is documented and
  the subset needed (order list, patterns, rows, note/instrument/channel per cell,
  initial tempo/speed) is small. Deterministic and Node-testable. Scope v1 to `.it`
  (the demo's format); `.xm/.mod` later behind the same interface.
- Output is SJON **text** (the score is a text surface — plan 07's write-back also
  works on text):
  - `(transport :bpm <initial tempo> :meter [4 4] :dur <orderLen·rowsPerBar/rowsPerBeat>b :end loop)`
  - one comment line per order-list entry: `; bar N — pattern P` (the scene anchors a
    human then names),
  - optionally, per selected channel: `(trigger :target <name> :at [<onset beats>b …])`
    (needs plan 02 in the shipped pacer.wasm; until then emit the list as a comment).
- Beat math: rows→beats via speed (ticks/row) and tempo, standard IT timing; ignore
  tempo-change effects in v1 but **detect and warn** when Txx/Axx commands exist so the
  user knows the grid drifts.
- Fixture: a tiny hand-built .it (a few patterns) committed to the repo; use
  `~/Dev/2026_impulse/impulse-04.it` locally as a realism check, not as a committed
  fixture.

## Phases

### Phase 0 — format spike + module skeleton (RED first)
Load: nothing from the studio beyond its test config; the IT format spec (fetch
offline knowledge; record byte-layout notes in this file).
Reds: `editor/src/lib/score/it-reader.test.ts` against a fixture built by a tiny
in-test byte writer: parses header (song name, initial tempo/speed, order list),
pattern count, and unpacks one pattern's rows to `{row, channel, note, instrument}`.
Green: `it-reader.ts` — pure function `parseIt(bytes): ItModule`.
Gate: editor tests.
Carry-forward: byte-layout notes + fixture-builder location.

### Phase 1 — timing model (RED first)
Load: `it-reader.ts` (interface only), this plan.
Reds: `it-timing.test.ts` — rows→beats for given speed/tempo (4 rows/beat at speed 6
baseline, the demo's "4 rows/beat, 16 rows/bar" as a named case); order-list position →
absolute beat; presence of Txx/Axx anywhere → `warnings` entry.
Green: `it-timing.ts` — `beatOf(orderPos, row)`, `songBeats()`, `warnings`.
Gate: editor tests.

### Phase 2 — score emission (RED first)
Load: `it-reader.ts`/`it-timing.ts` interfaces, one real score as the style reference
(`studio/public/shaders/demoscene.score.sjon`).
Reds: `score-emit.test.ts` — golden-text: fixture module + channel selection `{4: 'kick'}`
→ exact SJON text (transport line, order-boundary comments, trigger form or comment
per channel); output reloads clean through the real pacer wasm (reuse the
`score-uniforms.test.js` loading harness for one integration red).
Green: `score-emit.ts`.
Gate: editor tests.

### Phase 3 — studio UI
Load: `ScorePane.svelte`, the Motion tab wiring in `EditorTabs.svelte`/`App.svelte`
(only the mount points), state actions in `schema/studio-state.sjon` if a new action is
needed.
Reds: component/unit test — file-input → parse → channel checklist → "insert skeleton"
dispatches the score-set action with emitted text appended/replacing.
Green: minimal import dialog on the Motion tab; warnings displayed.
Gate: editor tests + manual smoke with `impulse-04.it`.

## Progress log
