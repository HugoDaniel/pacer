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
  **Phase 0 verdict (2026-07-16): `audio.ch<N>.*` is DEFERRED** — the shipped
  libopenmpt build cannot invoke the ext-interactive interface from JS (see the
  log). v1 ships `audio.volume` / `audio.tempo` / `audio.pitch`.
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

### Phase 0 — worklet control surface investigation (done, 2026-07-16)

**Characterization landed** (pngine `7b54680`): a new "worklet port vocabulary"
suite in `studio/editor/src/lib/audio/audio-driver.test.js` (the FakeNode mock
now records `port.posted`). Seven pins, green on first run against the real
driver: boot posts exactly one `config` (`{repeatCount: -1, stereoSeparation:
100, interpolationFilter: 0}`); `play` carries a standalone ArrayBuffer copy of
the held bytes (start at 0 posts no seek; a mid-timeline start follows with
`setPos`); pause/resume map to `pause`/`unpause` (the worklet keeps position);
replacing a live track posts `stop` first; `setVolume` never crosses the port
(main-thread GainNode); and the complete outbound vocabulary is
`config play setPos pause unpause stop`. Gate: editor tests 1663/1663 (+7),
biome clean.

**Reachability of the v1 target list** (chiptune3 0.8.7; the studio serves the
worklet via the `public/chiptune → node_modules/chiptune3` symlink, so the
worklet files are upstream-owned, not a repo copy):

| target | verdict | how |
|---|---|---|
| `audio.volume` | reachable TODAY | `driver.setVolume` → main-thread GainNode; no worklet message involved |
| `audio.tempo` | worklet-ready, driver gap | the worklet switch already handles `setTempo` → `openmpt_module_ctl_set('play.tempo_factor', v)`; nothing in the studio posts it — Phase 1 adds a driver method. **No worklet change needed.** |
| `audio.pitch` | worklet-ready, driver gap | same via `setPitch` → `play.pitch_factor` |
| `audio.ch<N>.volume` / `.mute` | **NOT reachable — deferred** | no message at either end (upstream's `toggleMute` case is commented out). The emscripten build DOES export the ext API (`_openmpt_module_ext_create_from_memory` / `_ext_get_interface` / `_ext_get_module` / `_ext_destroy`, id strings `interactive`/`2`/`3` present) — but `openmpt_module_ext_interface_interactive` is a struct of C function pointers, and the build keeps the indirect table closure-only (`__indirect_function_table = wasmTable = wasmExports["tf"]`; `Module` exports no `wasmTable`, `getWasmTableEntry`, or `dynCall_*`). JS cannot call the pointers. Fix requires rebuilding libopenmpt with wider `EXPORTED_RUNTIME_METHODS` (or upstream chiptune3 work) — out of scope for this plan; filed as follow-up alongside the Sointu host. |

The plan's expectation "extending the worklet message switch is expected" came
out BETTER than expected for v1: tempo and pitch need no worklet change at all
(good — the worklet is upstream's file), and the one thing that would have
required forking it (per-channel control) is blocked below the worklet anyway.
Phase 1's chiptuneHost therefore targets exactly `audio.volume`, `audio.tempo`,
`audio.pitch` — ncomp 1 each — with the driver growing `setTempo` / `setPitch`
methods that post the existing messages.

### Phase 1 — chiptuneHost (done, 2026-07-16)

**Landed** (pngine `0f3c2a6`, reds first): the driver grew `setTempo` /
`setPitch` — posting the worklet's existing ctl messages verbatim, no worklet
change — plus `hasTrack()` so the host can answer "no module → empty
registry". `lib/audio/chiptune-host.ts` implements `AudioTargetHost` over a
minimal `ChiptuneControls` slice (tests substitute a recorder; `AudioDriver`
satisfies it structurally). The pins run pacer's REAL `paramRegistry` /
`applyParams` (via the `pacer/audio` export, already resolvable in the editor)
so the whole write-entry→`laneValue`→`setParam`→driver route is covered.
Gate: editor tests 1675/1675 (+12), tsc clean, biome clean.

Decisions baked into the host (each pinned):

- **Clamp to declared [min, max] in `setParam`** — `paramRegistry` carries
  only `{name, ncomp}`, so pacer never clamps; a keyframe passing through 0
  must not hand libopenmpt a zero tempo factor. Volume [0, 1]; factors
  [0.25, 4] (the musically sane window). The specs carry `min`/`max`/
  `default` (all defaults 1) — the future 08 knob-lift surface.
- **`setTempo`/`setPitch` do NOT persist across boot** (unlike `setVolume`,
  the one-shot UI control): the audio bus re-applies its writes every frame,
  so a fresh module is corrected by the next eval — holding would only add a
  stale-value replay path. Pinned as "no replay on boot".
- **`clock()` returns null** — the studio's rAF playback loop is the time
  master (the driver is slaved via `PlaybackAudioSink`); the host offering no
  clock keeps that topology honest.
- Unknown param names no-op (a stale-registry write after re-arm must not
  throw); non-finite values are dropped (pacer's NaN rejection already
  guarantees this upstream — the host stays total anyway).
- The phase-0 vocabulary pin was consciously widened to
  `config play setPos pause unpause setTempo setPitch stop`.

Phase 2 wires `armPacer` to pass `[visualRegistry, audioRegistry]` and routes
registry-1 writes through `applyParams(entries, chiptuneHost(driver), 1)` per
frame, re-arming on track load/unload (`hasTrack` flips → registries change).

### Phase 2 — arm both buses + per-frame apply (done, 2026-07-16)

**Landed** (pngine `712ab92`, reds first): `initPreview` gained an `audioHost`
option (an `AudioTargetHost`, null = empty bus). `armPacer` samples
`paramRegistry(audioHost)` at arm time and loads
`[visualRegistry, audioRegistry]`; the arm key widened to a registry
fingerprint — visual reflection key + audio params JSON — so EITHER side
changing (shader reload / track load-unload) forces the fresh-load path.
`renderFrame` splits ONE `pacer.eval` across the buses: registry 0 →
`toUniforms` → coalescer → `draw.uniforms` (unchanged), registry 1 →
`applyParams(writes, audioHost, 1)`. App.svelte creates the driver BEFORE the
preview and passes `chiptuneHost(driver)`; `preview.refreshAudioRegistry()` is
called at all five track-state flip sites (picker load, IndexedDB restore,
player boot, player replace, clear). Gate: editor tests 1682/1682 (+7:
6 preview pins + 1 end-to-end), tsc clean, biome clean.

Decisions baked in (each pinned):

- **Audio applies on LIVE frames only** — `renderFrame` is the single seam
  that touches the host; the thumbnail prefetch and curve sampler eval out of
  playback order and stay visual-only (`uniformsAt` is registry-0 by
  contract now, documented). Paused re-renders DO apply — arming or
  scrubbing while paused brings the audio params to the playhead's score
  state, same as visuals (pinned: the arm-time paused re-render applies the
  score's opening `audio.volume`).
- **`refreshAudioRegistry` is a keyed no-op** — it recomputes the fingerprint
  and skips the re-arm when the param surface is unchanged (a same-surface
  track replace must not invalidate the thumbnail strip). When an arm is
  in flight (`pacer` still null), it re-arms anyway: the generation token
  supersedes the stale load — the plan's "generation token holds".
- **No track → whole-score diagnostic, nothing drives** — pinned end to end:
  with an empty registry 1 a score targeting `audio.volume` fails its load
  (`unknown_target`, pacer.ok false), so neither bus runs until a track
  loads and the refresh re-arms (the load "heals" the score).
- The planned end-to-end red in `score-uniforms.test.js` (real wasm × real
  `chiptuneHost` × recording driver, clamping included) came up GREEN
  immediately — the pacer-side chain was already whole after Phase 1; the
  gap was purely preview plumbing. Kept as the integration pin.

**Phase 3 consideration:** the demo player's warm-up path (`playerWarmup`
mutes via `setVolume(0)` until GO) can be overridden by a score-driven
`audio.volume` on any paused re-render during the countdown — per-frame
re-apply is the bus's contract. If the Phase 3 template keyframes
`audio.volume`, either start it at 1 (warm-up mute holds unless a re-render
fires) or prefer `audio.tempo`/`audio.pitch` for the musical use.

### Phase 3 — template + docs + audible smoke (done, 2026-07-16) — PLAN CLOSED

**Template + docs landed** (pngine `3d83e82`, reds first): the demoscene
score ships an `audio.pitch` ride — flat (0.94) under the noise intro,
bending to true pitch as the cube lands (the chroma window's timing; not
`audio.volume`, honoring the Phase 2 warm-up watch-out). It ships COMMENTED
with a distinctive `;;` marker: the studio boots the template trackless,
where a live `audio.*` target fails the WHOLE load (`unknown_target`) —
dead visuals at first paint. Rot protection pins in
`score-uniforms.test.js`: one asserts the `;;` block exists and the shipped
score loads against the visual registry alone; the other programmatically
strips the marker, loads `[visual, paramRegistry(chiptuneHost)]` on the
real wasm, and drives the ride through `applyParams` (flat f32-exact at
beat 0, mid-bend in (0.94, 1) at beat 12, exactly 1 from beat 16, registry
0 untouched). `agent-bridge.md` documents registry 1 as live, including the
agent trap: patching an `audio.*` track into a trackless project kills the
whole score — ship such tracks commented, the template block is the model.

**The audible smoke FAILED — and caught a real crash** (fixed in pngine
`b31a896`, reds first). Silence despite every unit pin green. Node probes
against the shipped libopenmpt build: the ctl works standalone, but driving
the REAL worklet class dies after ~1.1k messages with the user's exact
console (`getWasmTableEntry` TypeError → OOB cascade → "invalid pitch
factor" from garbage parses). Root cause UPSTREAM (chiptune3@0.8.7, still
latest): the `setPitch`/`setTempo` cases call `asciiToStack` twice per
message with no stackSave/stackRestore — ~56 B of emscripten stack leaked
per ctl, exhausting the 64 KB stack in ~19 s of per-frame drive, after
which the wasm instance is permanently corrupt (playback keeps running —
the failure is silent). Fix, two parts, each pinned:

- **`public/chiptune` is now a VENDORED dir** (revising the Phase 0 "never
  fork the worklet" stance — a crash is the documented reason):
  `chiptune3.worklet.js` carries one marked `PNGINE PATCH` (stack
  save/restore around the two ctl cases); `libopenmpt.worklet.js` stays a
  symlink into node_modules (the 2 MB blob remains upstream-owned).
  `chiptune-worklet-leak.test.js` spams 3000 ramping ctl messages through
  the SERVED worklet's real handler (a `buildIt` module from the plan 06
  fixture): upstream dies ~1.1k, the patch survives — and the same test
  decides whether a future chiptune3 upgrade may restore the symlink.
  `chiptune-worklet.bundle.js` rebuilt from the patched source (demo.zip
  carries the fix).
- **The driver dedupes `setTempo`/`setPitch`**: a held value posts once; a
  play START clears the cache (the worklet's `play` recreates the module,
  resetting both factors engine-side) while an unpause keeps deduping.

**Smoke re-run: CONFIRMED AUDIBLE** (2026-07-16, user's ears, `.it` module
through the title-menu loader — note the loader lives in the TITLE menu,
"Load audio track…", not an audio panel). Gates: editor 1687/1687 (+5 over
Phase 2), tsc clean, biome clean.

**Follow-ups filed:**
- **Sointu host** (pngine-side, future): a `sointuHost` sibling of
  `chiptuneHost` when the studio grows a Sointu engine — the
  `AudioTargetHost` contract + `refreshAudioRegistry` flow is
  engine-agnostic; only the param table and driver slice change.
- **Upstream report** to DrSnuggles/chiptune3 (the ctl stack leak +
  suggested patch) — pending.
- `audio.ch<N>.*` stays deferred (Phase 0 log: ext-interactive unreachable).
