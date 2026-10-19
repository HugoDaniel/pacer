// pacer — the canonical 'PACT' encoder leaf (02 T3.1).
//
// Extracted verbatim from index.js's load path so the playback
// runtime's glue (rt.js) encodes the IDENTICAL target-registry bytes:
// registry identity is the exact canonical blob (00 decision 3), so
// there is one encoder, shared — never two spellings that can drift.
// Zero behavior change: this is a pure move of `encodeTargets`.

const PACT_MAGIC = 0x54434150;
/** Mirror of `Abi.MAX_TARGETS` — the flat registry join's ceiling. */
const MAX_TARGETS = 1024;

const encoder = new TextEncoder();

/**
 * Encode the flattened target list as a 'PACT' blob.
 * @param {ReadonlyArray<import('./types.js').FlatTarget>} flat
 * @returns {Uint8Array}
 */
export function encodeTargets(flat) {
  if (flat.length > MAX_TARGETS) {
    throw new Error(`pacer: ${flat.length} targets exceed the ${MAX_TARGETS}-target limit`);
  }
  // Pair each target with its UTF-8 name up front so the write loop
  // never re-correlates two arrays by index.
  const encoded = flat.map((target) => ({ target, name: encoder.encode(target.name) }));
  let len = 8;
  for (const { name } of encoded) len += 4 + name.length;
  const blob = new Uint8Array(len);
  const dv = new DataView(blob.buffer);
  dv.setUint32(0, PACT_MAGIC, true);
  dv.setUint32(4, flat.length, true);
  let pos = 8;
  for (const { target, name } of encoded) {
    if (target.ncomp < 1 || target.ncomp > 4) {
      throw new Error(`pacer: target ${target.name} has ncomp ${target.ncomp}`);
    }
    // The name length rides a u16 on the wire; keep it in 1..65535 so it
    // neither wraps the field nor encodes an unnamed target.
    if (name.length < 1 || name.length > 65535) {
      throw new Error(
        `pacer: target ${target.name} name is ${name.length} UTF-8 bytes (need 1..65535)`,
      );
    }
    // The registry index rides a u8; a 257th registry would wrap into
    // bus 0 and mislabel every write it emits.
    if (target.registry > 255) {
      throw new Error(`pacer: target ${target.name} sits in registry ${target.registry} (max 255)`);
    }
    blob[pos] = target.ncomp;
    blob[pos + 1] = target.registry;
    dv.setUint16(pos + 2, name.length, true);
    pos += 4;
    blob.set(name, pos);
    pos += name.length;
  }
  return blob;
}
