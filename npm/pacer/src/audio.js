// The audio boundary — the `AudioTargetHost` contract pacer drives
// and masters from, plus an adapter for the host that predates it.
// The engine behind the interface is interchangeable: pngine's Sointu
// player satisfies the clock today with zero params; a real audio
// engine adds a live param surface — the driver never knows which.
//
// Topology (locked): audio masters when playing. Each frame samples
// `host.clock()` through `masterClock` (clock.js), passes one f64 to
// `Pacer.eval`, and routes the audio-bus write entries back through
// `applyParams`. The driver stays a pure function of time — it never
// reads a clock and never owns the loop.

/**
 * @typedef {{ seconds: number, playing: boolean }} AudioClock
 * @typedef {{ name: string, min?: number, max?: number, default?: number, ncomp?: number }} AudioParamSpec
 * @typedef {{
 *   params(): AudioParamSpec[],
 *   setParam(name: string, value: number | number[]): void,
 *   clock(): AudioClock | null,
 * }} AudioTargetHost
 */

/**
 * Adapt a Sointu-style player (pngine `createAudioPlayer`'s surface:
 * `currentTime` / `playing` getters) into an AudioTargetHost. The
 * song is pre-rendered, so the param surface is empty and `setParam`
 * is accepted-and-ignored; the value of the adapter is the clock —
 * the locked topology works end-to-end before a real audio engine
 * exists.
 *
 * @param {{ currentTime: number, playing: boolean }} player
 * @returns {AudioTargetHost}
 */
export function sointuHost(player) {
  return {
    params: () => [],
    setParam: () => {},
    clock: () => ({ seconds: player.currentTime, playing: player.playing }),
  };
}

/**
 * A host's param surface as a Pacer registry — pass as `registries[1]`
 * so the score may target every declared param. Adding a param to the
 * engine makes it keyframable with zero driver changes, the same
 * dynamism as pngine's uniform reflection table.
 *
 * @param {AudioTargetHost} host
 * @returns {Array<{name: string, ncomp: number}>}
 */
export function paramRegistry(host) {
  return host.params().map((p) => ({ name: p.name, ncomp: p.ncomp ?? 1 }));
}

/**
 * Route one eval's audio-bus entries into the host: scalar for ncomp
 * 1, array otherwise (mirrors `toUniforms`). Call per frame after
 * `Pacer.eval`; entries of other registries are skipped.
 *
 * @param {Array<{name: string, registry: number, ncomp: number, value: Float32Array}>} entries
 * @param {AudioTargetHost} host
 * @param {number} registry - the audio bus index (conventionally 1).
 */
export function applyParams(entries, host, registry = 1) {
  for (const e of entries) {
    if (e.registry !== registry) continue;
    // Lane 0 is always present in the fixed 4-lane buffer; `?? 0` is for
    // noUncheckedIndexedAccess only and never fires at runtime.
    host.setParam(
      e.name,
      e.ncomp === 1 ? (e.value[0] ?? 0) : Array.from(e.value.subarray(0, e.ncomp)),
    );
  }
}
