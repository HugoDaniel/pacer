# 02 — The engine contract (audio-agnostic hosts)

**Repo:** pacer npm (kit + docs); no pacer core change
**Wire impact:** none ('PAC*' untouched); npm surface appends only — the
`pacer/host-check` subpath export and a `clockOnlyHost` named export in
`pacer/audio` (`sointuHost` kept as an alias) — minor-release surface,
accumulate-till-publish
**Gates:** npm gate
**Size:** small — two phases.

## Why

Registry 1 is about to have real plurality: chiptune3/libopenmpt (shipped,
../10), batida (planned, `~/llm/plans/it/07` + 09), the audzio graph (future —
registry 1 = every AudioParam of an `(audio-graph …)`, the general case), and
Sointu (filed follow-up, clock-only). The `AudioTargetHost` contract
(`npm/pacer/src/audio.js`: `params() / setParam() / clock()`) is already
engine-agnostic; what's missing is (a) an executable statement of what a
correct host IS — today each host re-invents its pins (../10 Phase 1 tested
chiptuneHost by hand) — and (b) one written capability matrix so the next host
is written against the contract, not against the studio's incidental shape.

## Design (freeze in Phase 1)

- **The contract stays three methods.** No `timeline()`, no engine metadata,
  no capability negotiation: tempo/timeline truth travels as score text
  (plan 01; strategy decision 2026-07-19), and capability differences surface
  through `params()` content alone. A host that adds methods is fine; pacer
  never calls them.
- **`checkAudioTargetHost(host, opts) → findings[]`** — a pure conformance
  kit in `npm/pacer/src/host-check.js`, exported as `pacer/host-check`,
  usable inside any consumer's test suite (studio today, batida npm later).
  Findings are `{code, message}` records, empty array = conformant. Checks:
  - `params()` returns an array of well-formed specs: non-empty unique `name`
    strings, `ncomp` (default 1) an integer 1..4, `min`/`max`/`default`
    finite-when-present and arity-consistent, `min ≤ default ≤ max`.
  - **Totality**: `setParam` must not throw on an unknown name, a stale name
    (registry re-arm race, ../10 Phase 1's pin), or a non-finite value —
    pacer NaN-rejects upstream, but the host stays total anyway.
  - `clock()` returns `null` or `{seconds: finite, playing: boolean}`; if
    `opts.expectClock`, null is a finding (the demo-stack topology requires
    an audio-master clock — audio.js's locked `masterClock` design).
  - Idempotence probe: two `params()` calls agree (registry fingerprinting in
    the studio depends on a stable surface between arms).
- **`clockOnlyHost` is the canonical name for the prerendered pattern.**
  `sointuHost` adapts a player surface (`currentTime`/`playing`) into the
  clock-only host — but the pattern is engine-neutral: a Sointu `pNGa` song
  (pngine's shipped `SointuExports`/`createAudioPlayer` pipeline), a
  batida/audzio native **bounce**, any `<audio>`-element wrapper. Rename by
  append: `audio.js` exports `clockOnlyHost` as canonical, `sointuHost` stays
  a same-function alias (published names never break; JSDoc points forward).
  Prerendered is a **delivery mode, not legacy** — it is how a demo ships
  bit-pinned audio with zero engine risk (the batida set pins the native
  bounce as the exact artifact and calls browser-live best-effort, it 08/09).
- **The matrix** (documented in `npm/pacer/README.md`, cited by hosts):

  | Host | `params()` | `clock()` | Master | Where |
  |---|---|---|---|---|
  | clockOnlyHost (alias `sointuHost`) | empty — the asset is pre-rendered (Sointu `pNGa` song, batida/audzio bounce PCM) | player time | audio | `pacer/audio` (shipped; canonical name lands Phase 1) |
  | chiptuneHost | volume/tempo/pitch (`ch<N>.*` blocked upstream) | null | rAF (studio) | pngine studio (shipped, ../10) |
  | batidaHost | `gain`, `ch<N>.gain/mute`, `separation` — no tempo/pitch by batida's timeline-invariance rule (it 07) | frames/rate | audio | batida glue (planned, batida T2+) |
  | audzio graph | every AudioParam in the loaded `(audio-graph …)` | context time | audio | future (audzio set) |

## Phases

### Phase 1 — host-check kit (RED first)
Load: `npm/pacer/src/audio.js`, one existing npm test as pattern.
Reds (`npm/pacer/test/host-check.test.js`): a minimal conformant fake → `[]`;
each defect class above → exactly its finding code (bad ncomp, duplicate name,
throwing setParam, non-finite default, clock shape, expectClock vs null); the
kit never throws on a hostile host (methods missing/throwing → findings, not
exceptions); `clockOnlyHost === sointuHost` (the alias pin) and
`clockOnlyHost(fakePlayer)` passes the kit with `expectClock: true`.
Green: `host-check.js` + the `pacer/host-check` export in `package.json`
(exports map append; triple-pin untouched — accumulate-till-publish,
../00-strategy 2026-07-15); the `clockOnlyHost` canonical export + alias in
`audio.js` with the forwarding JSDoc.
Gate: npm gate.

### Phase 2 — matrix + docs + downstream adoption note (RED first)
Load: `npm/pacer/README.md`, `npm/pacer/src/types.js`.
Reds: a docs-presence test is overkill — instead one red pinning that
`chiptuneHost` (imported from the studio? no — cross-repo) … scope honestly:
the only testable artifact here is the kit's own JSDoc/type surface; write the
lockstep red (`test/exports.test.js` pattern) for the new export path.
Green: README audio section rewritten around the matrix + the "three methods,
text for tempo truth" doctrine + the delivery-mode ladder (prerendered
wasm-song / live engine / PCM bounce — one contract, three footprints);
`types.js` gains the `HostFinding` typedef.
Follow-up filed in the progress log (not done here, cross-repo): the studio's
`chiptune-host.test.ts` adds one `checkAudioTargetHost` red on its next
touch; batida's host lands with the kit in its own suite from day one.
Gate: npm gate.

## Progress log

(empty — plan not started)
