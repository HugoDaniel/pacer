// Lane extraction shared by the routing helpers: one write entry's value
// as a host wants it — a bare number for a scalar target, else a plain
// Array of its live lanes.

/** @typedef {import('./types.js').WriteEntry} WriteEntry */

/**
 * @param {Pick<WriteEntry, 'ncomp' | 'value'>} entry
 * @returns {number | number[]}
 */
export function laneValue(entry) {
  // Lane 0 is always present in the fixed 4-lane buffer; `?? 0` is for
  // noUncheckedIndexedAccess only and never fires at runtime.
  return entry.ncomp === 1
    ? (entry.value[0] ?? 0)
    : Array.from(entry.value.subarray(0, entry.ncomp));
}
