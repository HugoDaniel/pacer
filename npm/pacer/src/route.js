// Write-buffer routing — split one eval's entries across the host's
// ordered registries by each entry's `registry` index. Registry 0 is
// conventionally the visual bus (pngine uniforms), registry 1 audio.

/** @typedef {import('./types.js').WriteEntry} WriteEntry */

/**
 * Entries of one registry as a pngine-style uniforms object:
 * `{ [name]: number | number[] }` — scalar for ncomp 1, array
 * otherwise. Allocates; for per-frame zero-allocation paths iterate
 * the entries directly.
 *
 * @param {ReadonlyArray<WriteEntry>} entries
 * @param {number} [registry=0] Bus index to fold (defaults to the visual bus).
 * @returns {Record<string, number | number[]>}
 */
export function toUniforms(entries, registry = 0) {
  /** @type {Record<string, number | number[]>} */
  const uniforms = {};
  for (const e of entries) {
    if (e.registry !== registry) continue;
    // `value` is a fixed 4-lane Float32Array, so lane 0 is always present;
    // `?? 0` only satisfies noUncheckedIndexedAccess (and matches the
    // trailing-lane-is-0 contract) — it never fires at runtime.
    uniforms[e.name] = e.ncomp === 1 ? e.value[0] ?? 0 : Array.from(e.value.subarray(0, e.ncomp));
  }
  return uniforms;
}

/**
 * Group entries by registry index: `groups[registry]` is an array of
 * `{ name, ncomp, value }` borrowing the (reused!) entry objects.
 *
 * @param {ReadonlyArray<WriteEntry>} entries
 * @param {number} registryCount Number of buses (the length of `groups`).
 * @returns {WriteEntry[][]}
 */
export function routeWrites(entries, registryCount) {
  const groups = Array.from({ length: registryCount }, () => /** @type {WriteEntry[]} */ ([]));
  for (const e of entries) {
    const group = groups[e.registry];
    if (group !== undefined) group.push(e);
  }
  return groups;
}
