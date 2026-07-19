# 03 — Exact import (timing providers)

**Repo:** studio editor (`~/Dev/pngine/studio/editor/`); no pacer core change
**Wire impact:** none
**Gates:** studio editor test verb (real-wasm harness for integration reds)
**Size:** P0–P2 are Wave A; P3–P4 wait on batida T2 (external gate).

## Why

../06-tracker-import.md shipped the studio's `.it` → score-skeleton dialog on a
deliberate approximation: pure-TS parse, beats from the **initial** tempo/speed,
`warnings` when Axx/Txx exist (impulse-04.it carries 1024 Axx — the swing keeps
beat *pairs* honest while odd rows drift; real Txx modules get worse: the grid
is simply wrong). batida derives the exact map by running the actual timing
state machine (`Timeline.derive`, it 06) — tempo segments, true onset ticks,
true order-boundary beats. The studio should consume that **as data through an
engine-agnostic seam**, keeping the TS path as the always-available fallback —
the importer never becomes "the batida dialog".

## Design (freeze in Phase 0)

- **`TimingData`** — the neutral interchange every provider produces:
  `{ title, warnings[], tempoSegments: [{beat, bpm}], orders: [{index,
  pattern, startBeat}], channels: [{index, label, onsetBeats: number[],
  playedCount}], songBeats, meter? }`. Beats are the native currency (exact
  under a tempo map once beats are segment-aware); no seconds field — the
  emitter derives nothing engine-specific.
- **Providers** supply data, never text: `TimingProvider = { id, label,
  available(): boolean, analyze(bytes): TimingData | {error} }`.
  1. `approx-ts` — wraps the existing `it-reader/it-timing/it-import` libs
     verbatim (constant map ⇒ one tempo segment + today's warnings).
  2. `skeleton-file` — not a TimingProvider at all: a "load skeleton text"
     input that inserts an engine-emitted `.score.sjon` (e.g. batida
     `export-score`) directly, bypassing the emitter. The zero-coupling path:
     ANY engine with a CLI can feed the studio today.
  3. `batida-wasm` (Phase 3) — batida.wasm analyzing the same bytes; exact
     segments + onsets. The wasm's export shape is batida's to define (it
     P40); this plan owns only the adapter to `TimingData`.
- **One emitter.** `score-emit.ts` is refactored to consume `TimingData` (its
  golden text preserved for the approx provider) and grows tempo-map output:
  `tempoSegments.length > 1` ⇒ emit `(tempo :at Nb :bpm B)` lines after the
  transport (requires plan 01 in the studio's pacer.wasm — Wave A order
  guarantees it); onsets stay exact-nominal beats (the ../06 Phase 2
  deviation stands — never quantize); drift warnings become obsolete exactly
  when the provider is exact (they are TimingData content, not emitter
  logic).
- **Dialog** keeps its shape (checklist, census, insert); gains a provider
  selector (auto-prefers exact when `available()`) and, in Phase 4, an
  approx-vs-exact comparison line.

## Phases

### Phase 0 — freeze `TimingData` + characterize the current path (RED first)
Load: `lib/score/it-import.ts`, `it-timing.ts`, `score-emit.ts` (interfaces),
their tests' fixture helpers (`it-fixture.js`).
Reds: `timing-provider.test.js` — the approx provider over the shared fixture
produces a `TimingData` whose fields reproduce today's analysis (same census,
same warnings, one tempo segment at the initial bpm); type-shape pins.
Green: `lib/score/timing-provider.ts` (types + `approxProvider`), pure
adapters only — zero behavior change in the existing libs.
Gate: editor tests.

### Phase 1 — emitter over TimingData (RED first)
Load: `score-emit.ts` + its golden test.
Reds: existing golden text byte-identical when fed through
`TimingData` (the refactor is invisible for one-segment data); a two-segment
`TimingData` emits `(tempo …)` lines that load clean through the REAL studio
pacer.wasm (the `score-uniforms.test.js` harness idiom — this red is also the
studio-side proof of plan 01's wire).
Green: `emitScore(data, selection)` signature; dialog call-site updated.
Gate: editor tests.

### Phase 2 — skeleton-file path + provider selector (RED first)
Load: `ItImportDialog.svelte` mount points, the dialog's pure model.
Reds: model-level — selecting a provider routes `analyze`; a skeleton file
insert dispatches the same SET_SCORE action with the file text verbatim
(append/replace semantics identical to emitted text); unavailable providers
hidden.
Green: selector + file input in the dialog (dumb shell, decisions in the lib —
the house pure/edge split).
Gate: editor tests.

### Phase 3 — the exact provider (BLOCKED: batida T2 timeline surface)
Load: batida's published wasm/API doc at that time (it 06/09/P40).
Reds: adapter test over a batida-analyzed fixture — segments/onsets match
hand-computed truth for a Txx fixture the approx provider gets WRONG (the
plan's raison d'être, asserted); `available()` false when the wasm asset is
absent (studio still boots approx-only).
Green: `batidaProvider` adapter; auto-prefer wiring.
Gate: editor tests; realism check with impulse-04.it logged here (its 1024
Axx: exact onsets shift odd rows by the true 4-tick swing vs approx nominal).

### Phase 4 — verify UX + capacity pins (RED first)
Reds: dialog model exposes an approx-vs-exact delta summary (segment count,
max onset drift in beats, order-anchor drift) when both providers run; a
1392-onset trigger (impulse-04 ch 2's played census, ../06 Phase 3) loads
through the real wasm — pinning today's caps or motivating a measured,
wire-free core cap raise (strategy's parked decision; if raised, it happens
in the pacer repo with its own corpus note, not silently here).
Green: comparison line in the dialog; capacity findings logged.
Gate: editor tests.

## Progress log

- 2026-07-19 — **Phase 2 done — WAVE A SCOPE COMPLETE (P0–P2)**
  (skeleton-file path + provider selector, reds first; pngine a442310).
  Model: `analyzeWith(provider, bytes)` routes through the SELECTED
  provider (red pins the routing with a marker provider and the
  {error}→ok:false surface); `defaultProviders` is the auto-prefer
  roster (exact will be prepended in Wave B); `selectableProviders`
  hides unavailable ones (never disabled); `skeletonAction(text,
  current)` is the ONE insert semantics shared by `importAction`'s
  emitted text and a verbatim engine-emitted `.score.sjon` file.
  `ItAnalysis` now carries `timing: TimingData` (not `mod`) and the
  dialog summary is the provider's line (display gains "(.it)" — logged
  as the one deliberate text change). Dialog stays dumb: provider
  `<select>` rendered only when there's a choice, a "Load skeleton
  text…" input dispatching `skeletonAction` directly. P3–P4 wait on
  batida T2 (Wave B). Gate: editor tests 1720 ✓, tsc + svelte-check
  (0 errors) + biome clean.
- 2026-07-19 — **Phase 1 done** (emitter over TimingData, reds first;
  pngine 85f3661). `emitScore(data, selection)` reads everything from
  `TimingData`; the old golden text is byte-identical for one-segment
  data (pinned — the refactor is invisible for the approx provider);
  `tempoSegments.length > 1` ⇒ `(tempo :at Nb :bpm B)` lines after the
  transport, and the mapped skeleton loads clean through the REAL studio
  pacer.wasm with `meta.tempoMap` echoing `[{0,125},{8b·tpb,250}]` — the
  studio-side proof of plan 01's wire. `TimingData` grew a required
  provider-built `summary` (the `; imported from …` line) so "(.it)" /
  "rows/beat" vocabulary stays provider-side; `timingFromModule(mod)` is
  the exported pure core `approxProvider.analyze` delegates to;
  `importAction` routes through it. NOTE: the studio-refresh prereqs ran
  EARLY (this phase's real-wasm red needed them): `zig build wasm` +
  `npm run build:wasm-copy` in pacer, `pnpm install --prefer-offline` in
  studio/ — the tempo-map wasm + tempoMap-decoding glue are live in the
  editor now. Gate: editor tests 1713 ✓, tsc + biome clean. (freeze TimingData + characterize, reds
  first; pngine adcb47b). `lib/score/timing-provider.ts`: the frozen
  `TimingData` shape exactly as designed (beats native, no seconds
  field), `TimingProvider`/`TimingAnalysis`/`isTimingError`, and
  `approxProvider` (`id: 'approx-ts'`) wrapping it-reader/it-timing
  verbatim — zero behavior change to the wrapped libs. Reds characterize
  against `analyzeIt` (census) and `timingOf` (warnings verbatim) over
  real fixture BYTES (packed cells through `buildIt`, incl. the Axx
  warning case and the NOTE_MAX cut/off rule); bad bytes → `{error}`,
  never a throw. Gate: editor tests 1710 ✓ (+6), biome + tsc clean.
