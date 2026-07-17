// Write-buffer routing — split one eval's entries across the host's
// ordered registries by each entry's `registry` index. Registry 0 is
// conventionally the visual bus (pngine uniforms), registry 1 audio.

import { laneValue } from './lane.js';

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
    // A compose-mode declared-only target has no host name (null), so it
    // can't key a by-name uniforms map — the host routes it by registry
    // through routeWrites instead. Skip it here.
    if (e.name === null) continue;
    uniforms[e.name] = laneValue(e);
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
