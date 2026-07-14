# 10 — Audio bus: wire registry 1

**Repos:** studio editor (primary); pacer npm (only if the host contract needs a tweak)
**Wire impact:** none (registry 1 already exists in the design; `pacer/audio` ships)
**Gates:** studio editor test verb; npm gate if `npm/pacer` changes

## Why

pacer's whole audio boundary — `AudioTargetHost`, `sointuHost`, `paramRegistry`,
`applyParams` (`pacer/npm/pacer/src/audio.js`) — is dead code in the studio:
`armPacer` passes only `[registries]` (visual bus) with a comment calling audio "a
future layer". The studio's real audio engine is chiptune3/libopenmpt, which *does*
have a live control surface (global volume/tempo/pitch ctls, per-channel volume/mute).
Wiring it makes a score conduct both picture and sound, and turns registry 1 from
aspiration into a tested surface.

## Design (verify in Phase 0)

- v1 target list (all libopenmpt-native, no audio DSP work):
  `audio.volume` (global gain), `audio.tempo` (tempo factor ctl), `audio.pitch`
  (pitch factor ctl), `audio.ch<N>.volume`, `audio.ch<N>.mute` (N from the loaded
  module's channel count).
- The worklet boundary makes application async — fine: pacer stays the pure function,
  the host applies writes best-effort per frame (that's already `applyParams`'s
  contract). Determinism claims cover the writes, not the speaker.
- Keep `sointuHost` untouched; add a sibling `chiptuneHost` in the **studio** (it
  depends on the studio's audio driver, not on pacer).
- Failure mode when no module is loaded: registry 1 is empty → tracks targeting audio
  names surface pacer's `unknown_target` diagnostic, which is exactly right.

## Phases

### Phase 0 — worklet control surface investigation (RED first)
Load: `studio/editor/src/lib/audio/audio-driver.ts` (+ the chiptune3 worklet's message
handling — find where postMessage commands are consumed).
Reds: a characterization test against the driver with a mocked worklet port: what
control messages exist today (volume? seek?), asserting current shape.
Output: record here which of the v1 target list is reachable through existing
messages vs. needs new worklet message types (libopenmpt exposes
`module.ctl_set`/`set_channel_volume` — extending the worklet message switch is
expected).
Gate: editor tests.

### Phase 1 — chiptuneHost (RED first)
Load: `pacer/npm/pacer/src/audio.js` (the `AudioTargetHost` contract + `applyParams`),
`audio-driver.ts` interface only.
Reds: `lib/audio/chiptune-host.test.ts` — `paramRegistry(chiptuneHost(driver))` yields
the v1 names with correct ncomp (all 1); `applyParams(entries, host, 1)` calls the
driver with the right control messages; unknown target ids are ignored; no module
loaded → empty registry.
Green: `lib/audio/chiptune-host.ts` (+ any new worklet messages from Phase 0, each
with a driver-level test).
Gate: editor tests.

### Phase 2 — arm both buses + per-frame apply (RED first)
Load: `studio/editor/src/lib/preview/preview.ts` (`armPacer`, `renderFrame`,
`uniformsAt`) and the playback loop's audio linkage (`PlaybackAudioSink` region).
Reds: preview test — `Pacer.load` receives `[visualRegistry, audioRegistry]`; a score
track targeting `audio.volume` produces registry-1 writes that reach the host each
frame while registry-0 writes still reach `toUniforms`; re-arm on module load/unload
(audio registry changes → pacer reload with fresh registries, generation token holds).
Green: build the audio registry in `armPacer`; split writes with `routeWrites` (or
`applyParams` directly) in the frame path.
Gate: editor tests (the real-wasm `score-uniforms.test.js` harness is the right home
for one end-to-end red).

### Phase 3 — template + docs
Work: extend a template score with a musical use (e.g. duck `audio.ch3.volume` under
a scene, or a filter-sweep-like pitch ride); note in the studio docs that registry 1
is now live; file the Sointu-host variant as a future pngine-side follow-up in this
log.
Gate: editor tests + manual smoke with audible result.

## Progress log
