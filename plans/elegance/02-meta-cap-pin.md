# 02 — `META_CAP`'s worst-case pin includes every section (and can't rot again)

**Repo:** pacer
**Wire impact:** none
**Gates:** `zig build verify`
**Size:** small — move one sum next to the format it bounds.

## Why

The comptime assert at `wasm_entry.zig:91-97` claims "Meta at the caps fits" and
enumerates header + tracks + keys + controls + `'SCEN'` + `'EASE'` — but no `'TMPO'`
term. The bound still holds numerically (≈266 KiB of enumerated worst case + ≈8.2 KiB
of TMPO at `MAX_TEMPO_SEGMENTS`, against the 320 KiB zone — ~53 KiB slack), and
`encodeMeta` degrades to an absent blob rather than a wrong one, so nothing is
broken. But the assert's entire job is to make that hand-arithmetic unnecessary, and
it silently stopped stating the worst case the moment the newest section landed —
proof the sum lives too far from the format it describes.

## Design

Colocate the worst-case sum with the format definition so adding a section forces the
author through it:

- `Abi.zig` grows `pub fn metaWorstCase(comptime id_allowance: usize) usize` — a
  comptime-callable sum over ALL records and ALL sections at their caps, term by term
  in wire order, ending with `'TMPO'`. The `id_allowance` parameter stays a caller
  policy (the format itself allows 64 KiB ids; the 256-byte allowance is
  `wasm_entry`'s zone-sizing choice, documented at the call site).
- `wasm_entry.zig`'s comptime block collapses to
  `std.debug.assert(META_CAP >= Abi.metaWorstCase(256));`.
- A comment on `metaWorstCase` states the convention: **a new TLV section must add
  its term here in the same commit that defines its records** — the function sits
  directly under the section-stream docs, so the next `'XXXX'` author is already in
  the right file.

No red is constructible: the current bound holds, so the corrected assert passes
immediately. This is a pin-strengthening, not a behavior fix — the "test" is that a
deliberately-wrong term (try it once, locally) breaks `zig build wasm`.

## Phases

### Phase 1 — move the sum home
Load: `src/Abi.zig` (constants + section docs), `src/wasm_entry.zig` (comptime
block).
Work: add `metaWorstCase` beneath the `META_EASE_PROGRAM_LEN` constants, one term per
line with the section 4-CC named in a trailing comment (the sum should read like the
wire spec above it); verify it fails the build when a term is doubled (throwaway
sanity check, not committed); replace the `wasm_entry` inline sum with the call;
note the per-section convention in both the function doc and the `'PACM'` header's
section-stream paragraph ("a new section adds its `metaWorstCase` term in the same
commit").
Gate: `zig build verify` (byte-identical corpus — nothing at runtime changed),
`zig build wasm`.

## Progress log

- **2026-07-20 — Phase 1 complete.** `Abi.metaWorstCase(id_allowance)` added
  beneath `META_EASE_PROGRAM_LEN`, one term per line in wire order ending with
  `'TMPO'`; the per-section convention noted in both the function doc and the
  section-stream header paragraph. `wasm_entry`'s inline sum collapsed to
  `assert(META_CAP >= Abi.metaWorstCase(256))` with the 256-byte allowance
  documented as zone policy. Throwaway sanity check ran: doubling the `'EASE'`
  term broke `zig build wasm`; restored, build green. Gate: `zig build verify`
  byte-identical corpus, `zig build wasm` clean.
