# Elegance wave — closing the review findings

Distilled from the 2026-07-20 elegance/purity review of the whole codebase (Zig core
+ npm glue + corpus). The review's verdict: the codebase's claims are almost all
pinned by a build break, a golden, or a counterfactual test — and every finding below
is a place where a hand-mirrored sum or a prose contract escaped that discipline.
These plans bring each stray back under it.

Inherits [`plans/README.md`](../README.md)'s execution discipline verbatim: reds
first where a red is constructible, one phase per context window, wire surfaces
append-only, gates green before commit. **None of these plans touch a wire format**;
04 changes load *acceptance* (stricter), which is behavior, not wire.

## Ordering

Two plans are release-relevant, the rest are quality:

1. **[01-writes-cap](01-writes-cap.md)** — the one latent defect (full-house frame
   overflows the wasm writes zone → `catch unreachable`). Land before the 0.2.0 tag.
2. **[02-meta-cap-pin](02-meta-cap-pin.md)** — the `META_CAP` comptime bound stopped
   stating its worst case when `'TMPO'` landed. Pairs naturally with 01 (same file,
   same class); land together.
3. **[07-small-accretions](07-small-accretions.md)** — four one-sitting cleanups
   (stale ordinals, `exprFailures` docs, `Writes.decode` alignment, eval push helper).
4. **[06-emit-value-switch](06-emit-value-switch.md)** — mechanical, self-contained.
5. **[05-builder-rows](05-builder-rows.md)** — pure refactor, zero corpus diff.
6. **[04-pattern-dry-run-budget](04-pattern-dry-run-budget.md)** — semantic change
   (stricter loads); needs a corpus case and a decision recorded.
7. **[03-driver-pinning](03-driver-pinning.md)** — the design-heavy one (borrow-whole
   made structural). Do last; its Design section weighs two options and the choice
   should be made deliberately, not en passant.

## The plans

| # | Plan | Finding it closes | Size |
|---|---|---|---|
| 01 | [writes-cap](01-writes-cap.md) | `WRITES_CAP` omits emit lanes; `catch unreachable` rests on it | small |
| 02 | [meta-cap-pin](02-meta-cap-pin.md) | `META_CAP` comptime bound predates `'TMPO'` | small |
| 03 | [driver-pinning](03-driver-pinning.md) | borrow-whole contract is discipline, not structure | medium |
| 04 | [pattern-dry-run-budget](04-pattern-dry-run-budget.md) | dry-run (gpa) more permissive than frame path (fixed scratch) | medium |
| 05 | [builder-rows](05-builder-rows.md) | Builder threads parallel arrays by convention + post-hoc assert | small |
| 06 | [emit-value-switch](06-emit-value-switch.md) | `emitValue` string-scan + prose-only subset claim | small |
| 07 | [small-accretions](07-small-accretions.md) | stale ordinal, probe naming docs, decode alignment, push helper | small |

## Status board

- [x] 01 writes-cap
- [x] 02 meta-cap-pin
- [x] 07 small-accretions
- [x] 06 emit-value-switch
- [x] 05 builder-rows
- [ ] 04 pattern-dry-run-budget
- [ ] 03 driver-pinning
