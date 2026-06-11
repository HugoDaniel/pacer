// Master-clock sampling — the locked topology: "the frame (slowest
// clock) samples the audio (fastest clock)". Audio masters when
// playing; the performance clock carries the rest. The driver itself
// never reads a clock — these helpers produce the one f64 the host
// passes to `Pacer.eval` each RAF.

/**
 * Monotonic seconds from the performance clock, rebased to 0 at
 * creation.
 */
export function perfClock(now = () => performance.now() / 1000) {
  const t0 = now();
  return () => now() - t0;
}

/**
 * Sample the master clock: the audio host's transport when it reports
 * playing, the fallback otherwise.
 *
 * @param {{ clock(): { seconds: number, playing: boolean } | null } | null} audioHost
 *   The AudioTargetHost surface (pngine's Sointu player already
 *   satisfies it). May be null for visual-only use.
 * @param {() => number} fallback - typically `perfClock()`.
 */
export function masterClock(audioHost, fallback = perfClock()) {
  return () => {
    const c = audioHost?.clock?.();
    return c && c.playing ? c.seconds : fallback();
  };
}
