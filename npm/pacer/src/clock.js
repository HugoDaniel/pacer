// Master-clock sampling — the locked topology: "the frame (slowest
// clock) samples the audio (fastest clock)". Audio masters when
// playing; the performance clock carries the rest. The driver itself
// never reads a clock — these helpers produce the one f64 the host
// passes to `Pacer.eval` each RAF.

/**
 * Monotonic seconds from the performance clock, rebased to 0 at
 * creation.
 *
 * @param {() => number} [now] Seconds source; defaults to `performance.now()`.
 * @returns {() => number} Reads elapsed seconds since creation.
 */
export function perfClock(now = () => performance.now() / 1000) {
  const t0 = now();
  return () => now() - t0;
}

/**
 * Sample the master clock: the audio host's transport when it reports
 * playing, the fallback otherwise — with a continuous handoff. While
 * audio plays, its position IS score time (authoritative: starting
 * playback snaps score time to the song position, by design). When it
 * stops, the fallback carries on rebased to the last mastered second,
 * so a pause never jumps the visuals.
 *
 * @param {{ clock(): { seconds: number, playing: boolean } | null } | null} audioHost
 *   The AudioTargetHost surface (audio.js; pngine's Sointu player
 *   fits via `sointuHost`). May be null for visual-only use.
 * @param {() => number} fallback - typically `perfClock()`.
 * @returns {() => number} Samples the master clock in seconds per call.
 */
export function masterClock(audioHost, fallback = perfClock()) {
  let mastered = false; // audio was authoritative on the last sample
  let last = 0; // last mastered seconds — the handoff point
  let offset = 0; // rebases the fallback after a handoff
  return () => {
    const c = audioHost?.clock?.();
    if (c?.playing) {
      mastered = true;
      last = c.seconds;
      return last;
    }
    if (mastered) {
      mastered = false;
      offset = last - fallback();
    }
    return fallback() + offset;
  };
}
