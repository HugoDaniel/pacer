# 04 — Audio bus v2 (engine-agnostic engines, per-channel params)

**Repo:** studio editor (primary); pacer npm only if the kit (02) surfaces a
contract gap
**Wire impact:** none
**Gates:** studio editor test verb; npm gate if `npm/pacer` changes
**Size:** Wave B — all phases gated on batida P40 (`batida.wasm` renderer).

## Why

../10-audio-bus.md wired registry 1 and hit the ceiling the same day:
`audio.ch<N>.volume/mute` are **unreachable** through the shipped libopenmpt
build (ext-interactive function pointers locked inside the wasm table), the
worklet ships a vendored crash patch (upstream ctl stack leak, report still
pending), and the engine is a black box to the determinism story. batida's
whole design (deterministic renderer, mixer-side param table `gain` /
`ch<N>.gain` / `ch<N>.mute` / `separation`, audio-master clock — it 07/09) is
the unblocked engine. The studio should host BOTH behind one seam — the score
never knows which engine plays, only which targets resolved.

## Design (verify in Phase 0)

- **`AudioEngine`** — a studio-side interface (this is NOT a pacer contract;
  pacer sees only the host): `{ load(bytes), play/pause/stop, seek(seconds),
  hasTrack(), host(): AudioTargetHost }`. `chiptuneEngine` adapts the existing
  `AudioDriver` + `chiptuneHost` verbatim; `batidaEngine` wraps batida.wasm in
  an AudioWorklet (batida P40's own worklet glue — the studio consumes, never
  forks it) with `batidaHost` over the wasm's param exports + frame-counter
  clock.
- **Conformance from day one**: both hosts run 02's `checkAudioTargetHost` in
  their suites (`expectClock: true` for batida).
- **Clock master flip**: chiptune keeps `clock() → null` (rAF masters — the
  ../10 topology note). When the active engine provides a clock, the preview's
  playback loop samples it through `masterClock` (`pacer/audio`'s locked
  design) instead of rAF time — the strategy's parked UX decision lands in
  Phase 2 with a pin: scrubbing while paused evals at the scrub time on both
  masters (pure function of t — nothing else is acceptable).
- **Registry churn is solved**: `refreshAudioRegistry`'s fingerprint re-arm
  (../10 Phase 2) already handles "param surface changed"; an engine SWITCH is
  just a bigger fingerprint change. Per-channel names appear dynamically from
  `params()` (channel count is per-module) — the exact dynamism `paramRegistry`
  was built for.
- **Score portability** stays the `;;`-template discipline (../10 Phase 3): the
  template ships a commented chiptune block (`audio.pitch` ride — factors
  batida deliberately lacks, it 07's timeline-invariance rule) and a commented
  batida block (a `ch<N>.gain` duck under a scene); a live `audio.*` target on
  the wrong engine is the correct `unknown_target` diagnostic.
- **A `prerenderedEngine` is a trivial third engine** if the studio ever
  wants bounce playback: `createAudioPlayer` (pngine) behind the
  `AudioEngine` seam, `host() = clockOnlyHost(player)` (02), empty registry.
  Noted for the seam's sake, not planned — no phase depends on it.
- **Vendored-patch retirement** is explicitly NOT this plan: the chiptune
  worklet patch + leak test stay until upstream fixes (report pending,
  ../00-strategy); batida becoming default merely demotes them to legacy.

## Phases

### Phase 0 — engine seam + chiptune adapter (RED first)
Load: `lib/audio/audio-driver.ts` + `chiptune-host.ts` (interfaces), the
track-state flip sites in `App.svelte` (mount points only).
Reds: `audio-engine.test.js` — `chiptuneEngine(driver)` satisfies the
interface by characterization (play/pause/load delegate; `host()` === the
existing chiptuneHost; kit findings empty); engine selection is pure state
with exactly one active engine.
Green: `lib/audio/audio-engine.ts` + the chiptune adapter; App wiring moved
behind it (no behavior change — the ../10 pins all stay green untouched).
Gate: editor tests.

### Phase 1 — batidaEngine (BLOCKED: batida P40)
Load: batida's published worklet/wasm glue doc at that time (it 09/P40).
Reds: with a stub worklet port (the FakeNode idiom from ../10 Phase 0):
`load` posts module bytes; `host().params()` reflects the loaded module's
channel count (`ch0.gain … chN.gain`, mutes, `gain`, `separation`, ncomp 1);
no module → empty registry (the load-heals-the-score flow); kit conformant
incl. clock; unknown/stale setParam total.
Green: `lib/audio/batida-engine.ts` + `batida-host.ts`.
Gate: editor tests (+ one real-wasm smoke when the asset exists — logged, not
CI-gated until batida ships stable bytes).
 
### Phase 2 — arm, route, clock flip (RED first)
Load: `lib/preview/preview.ts` (`armPacer`, `renderFrame`, the
`PlaybackAudioSink` region), `pacer/audio` `masterClock`.
Reds: engine switch re-arms with the new registry (fingerprint flips) and the
generation token holds mid-switch; registry-1 writes reach the ACTIVE engine
only; with batida active the frame loop samples `masterClock(host.clock())`
and a paused scrub still evals at scrub-t (both masters, pinned end to end in
the `score-uniforms.test.js` harness).
Green: preview plumbing; engine switch UI action (title-menu row next to the
existing "Load audio track…" loader).
Gate: editor tests.

### Phase 3 — template + the engine ritual (RED first)
Reds: rot pins for BOTH `;;` blocks (each strips-and-loads against its
engine's registry on the real wasm, the ../10 Phase 3 idiom); the duck lane
drives `ch<N>.gain` through applyParams with clamps honored.
Green: template blocks + docs (`agent-bridge.md` registry-1 section updated:
engines, matrix pointer, the "wrong-engine target fails the load" trap).
Gate: editor tests + the strategy's **engine ritual** (manual, user's ears +
eyes, logged here).

## Progress log

(empty — plan not started)
