// Write-buffer routing — split one eval's entries across the host's
// ordered registries by each entry's `registry` index. Registry 0 is
// conventionally the visual bus (pngine uniforms), registry 1 audio.

/**
 * Entries of one registry as a pngine-style uniforms object:
 * `{ [name]: number | number[] }` — scalar for ncomp 1, array
 * otherwise. Allocates; for per-frame zero-allocation paths iterate
 * the entries directly.
 */
export function toUniforms(entries, registry = 0) {
  const uniforms = {};
  for (const e of entries) {
    if (e.registry !== registry) continue;
    uniforms[e.name] = e.ncomp === 1 ? e.value[0] : Array.from(e.value.subarray(0, e.ncomp));
  }
  return uniforms;
}

/**
 * Group entries by registry index: `groups[registry]` is an array of
 * `{ name, ncomp, value }` borrowing the (reused!) entry objects.
 */
export function routeWrites(entries, registryCount) {
  const groups = Array.from({ length: registryCount }, () => []);
  for (const e of entries) {
    if (e.registry < registryCount) groups[e.registry].push(e);
  }
  return groups;
}
