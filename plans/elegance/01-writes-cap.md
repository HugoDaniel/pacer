# 01 — `WRITES_CAP` covers the true full house (emit lanes included)

**Repo:** pacer
**Wire impact:** none (zone sizes are not wire-visible; the JS glue reads ptr+len)
**Gates:** `zig build verify`, npm gate
**Size:** small — one constant, one shared home, two comptime ties.

## Why

`wasm_entry.zig:76` sizes the writes zone as
`Writes.encodedLen(MAX_TRACKS + MAX_CONTROLS + MAX_DYNAMIC_CONTROLS)` — 384 entries —
with the comment "sized for a full house". But `Evaluator.init` (`Eval.zig:152-155`)
correctly budgets `transport.emit.len` **in addition**: a maximal score (256 track
rows + all 5 emit lanes + 64 document controls + 64 held dynamic slots) produces 389
entries. `Writes.encode` then returns `BufferTooSmall` and the
`catch unreachable` in `drv_eval` / `drv_evalTicks` (`wasm_entry.zig:241,253`) fires —
which in the ReleaseSmall wasm build is UB, not a trap.

Root cause, and the real fix: the two sums (evaluator entry-buffer sizing and the
wasm zone cap) are hand-mirrored with no comptime tie, in a codebase whose default
enforcement for exactly this class is a comptime pin.

## Design

One constant, one home, derived not spelled:

- `Eval.zig` grows `pub const MAX_FRAME_ENTRIES`, computed from the caps it already
  owns: `emit_max + TrackTable.MAX_TRACKS + TrackTable.MAX_CONTROLS +
  MAX_DYNAMIC_CONTROLS`, where `emit_max =
  @typeInfo(TrackTable.EmitName).@"enum".fields.len` — the lane ceiling is the enum's
  field count (duplicates are rejected at compile), so appending a future `EmitName`
  variant grows the constant automatically.
- `Evaluator.init` asserts its per-table sizing against the ceiling:
  `emit.len <= emit_max` (internal invariant — compile enforced uniqueness) and the
  allocated entry count `<= MAX_FRAME_ENTRIES`.
- `wasm_entry.zig`: `WRITES_CAP = Writes.encodedLen(Eval.MAX_FRAME_ENTRIES)`. The
  `catch unreachable` comments update to cite the shared constant — the claim becomes
  true by construction instead of by hand-arithmetic.

No behavior change for any non-pathological score; the zone grows by 100 bytes.

## Phases

### Phase 1 — the red is a build break (RED first)
Load: `src/wasm_entry.zig` (zones + comptime block), `src/Eval.zig` (init sizing),
`src/TrackTable.zig` (caps + `EmitName`), `src/Writes.zig` (`encodedLen`).
Red: add the comptime tie to `wasm_entry.zig`'s existing comptime block first —
`WRITES_CAP >= Writes.encodedLen(<true full house incl. emit_max>)` — and run
`zig build wasm`: it must FAIL against the current 384-entry cap. That failure is the
finding, reproduced as a pin.
Green: introduce `Eval.MAX_FRAME_ENTRIES` (derived as above), redefine
`WRITES_CAP = Writes.encodedLen(Eval.MAX_FRAME_ENTRIES)`, drop the now-redundant
standalone assert (the definition subsumes it), add the two `Evaluator.init` asserts,
update the `catch unreachable` comments.
Gate: `zig build verify` (corpus must be byte-identical — nothing semantic moved),
npm gate (`pretest` rebuilds the wasm; parity walk re-runs against the new bytes).

## Progress log

- **2026-07-20 — Phase 1 complete.** Red first: the comptime tie
  (`WRITES_CAP >= encodedLen(emit_max + tracks + controls + dynamic)`) failed
  `zig build wasm` against the 384-entry cap exactly as predicted. Green:
  `Eval.MAX_FRAME_ENTRIES` derived from the caps (emit ceiling =
  `EmitName` field count), `WRITES_CAP = Writes.encodedLen(Eval.MAX_FRAME_ENTRIES)`
  (subsumes the red assert, which was then dropped), two `Evaluator.init` asserts
  (`emit.len <= emit_max`, `entry_count <= MAX_FRAME_ENTRIES`), `catch unreachable`
  comments now cite the shared constant. Zone grew 384→389 entries (+100 bytes).
  Gate: `zig build verify` byte-identical corpus (25 cases), npm gate green (81).
