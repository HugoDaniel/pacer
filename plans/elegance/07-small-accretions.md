# 07 — Small accretions: ordinals, probe docs, decode alignment, push helper

**Repo:** pacer (+ npm glue docs)
**Wire impact:** none (the frozen `drv_exprFailures` name STAYS — docs align to it)
**Gates:** `zig build verify`, npm gate
**Size:** small — four independent one-sitting items, one phase.

## Why

Four leftovers from the review, none worth a plan alone, all worth not carrying into
1.0. Common thread: prose and helpers that drifted while the pinned surfaces stayed
true.

## Design

**(a) Stale ordinals.** Triggers are "a third `Track` row" at `Compile.zig:966` but
"a fourth row kind" at `TrackTable.zig:134` — one predates pattern tracks. Fix by
REMOVING the ordinals, not correcting them ("a trigger row" / "a trigger row kind
reusing this struct"): a count that can't be stated can't rot. Grep both files for
other source-kind ordinals while there.

**(b) `exprFailures` probe docs.** The counter outgrew its name — it counts pattern
omissions too (`Eval.zig:129-137` describes this fully; the export name is
wire-frozen, the documented cost of append-only, and stays). Two stale descriptions
align to the Zig truth: `npm/pacer/src/index.js:471-473` ("non-finite result" — it's
any runtime failure, exprs AND patterns) and `wasm_entry.zig`'s `drv_exprFailures`
doc ("expr-track evaluations" — widen to match `Eval.expr_failures`'s own text,
which is the description of record; say so there).

**(c) `Writes.decode` alignment.** `decode(src: []const u8)` safety-panics on an
unaligned slice via `@alignCast` while its sibling `decodeTargets` is total on any
bytes. Returning null on misalignment would make the result depend on the buffer's
ADDRESS (same bytes, different answer — an impurity worse than the panic). Instead,
lift the requirement into the signature: `decode(src: []align(4) const u8)` — the
obligation becomes a compile-time fact at every call site. Update callers (module
tests already use `align(4)` buffers; check `src/fuzz.zig`'s decode harness — its
arbitrary input must land in an aligned buffer, which is a copy it should already be
doing) and note in the doc why null-on-misalignment was rejected.

**(d) Eval push helper.** `evalTicks` hand-rolls `self.entries[n] = …; n += 1` at
SEVEN sites, all in its own body (the emit-lane loop, the four `track.source` arms,
the document-control loop, the dynamic-control loop — the track helpers return
entries; the pushes happen at their call sites). One private
`fn push(self: *Evaluator, n: *usize, entry: Writes.Entry) void` folds them; write
order is untouched (the corpus pins it — emit → tracks → controls, in-order
consumers depend on it).

## Phases

### Phase 1 — all four, in order (a) → (d)
Load: `src/TrackTable.zig`, `src/Compile.zig` (the two comments only),
`src/Eval.zig`, `src/wasm_entry.zig` (probe doc), `src/Writes.zig`, `src/fuzz.zig`
(decode harness), `npm/pacer/src/index.js` (JSDoc only).
Work: (a) and (b) are comment/JSDoc edits — no reds possible; (c)'s red: the type
system itself (an unaligned call site stops compiling — confirm `fuzz.zig` still
builds and its harness still feeds arbitrary BYTES, just from aligned storage);
(d) is a pure refactor under continuously-green tests, corpus byte-identical.
Gate: `zig build verify` (empty corpus diff), `zig build fuzz` (the decode harness
moved), npm gate (`npm run lint && npm run typecheck && npm test` — JSDoc edits are
inside tsc's checked surface).

## Progress log

(empty)
