# 06 — `emitValue` switches on the enum; the subset claim becomes a comptime pin

**Repo:** pacer
**Wire impact:** none (bit-identical values — pinned by test AND corpus)
**Gates:** `zig build verify`, npm gate
**Size:** small — one function, one comptime block, one test.

## Why

`ExprTrack.emitValue` (`ExprTrack.zig:242-249`) builds the full 10-binding time env,
string-scans it for one name, and hits `unreachable` on a miss. The anti-drift
rationale ("no formula is re-derived here") overshoots: `bindTime`'s formulas are
already one-line calls into `TimeMap` (`beatOf`, `barOf`, `phaseOf`, `bpmAt`,
`secondsFromTick`) — a switch on `EmitName` calling those SAME methods is equally
drift-proof, total by construction (no `unreachable`), and doesn't build nine
bindings to read one. And the guarantee the `unreachable` leans on — every `EmitName`
is a `bindTime` name — is prose, in a file that comptime-pins its other
binding-count invariants (`ExprTrack.zig:96-102`).

## Design

- `emitValue` becomes an exhaustive switch:
  `.beat => map.beatOf(tick)`, `.bar => map.barOf(tick)`,
  `.phase => map.phaseOf(tick)`, `.bpm => map.bpmAt(tick)`,
  `.t => map.secondsFromTick(tick)` — verbatim the expressions `bindTime` binds
  (same callee, same argument, same op order ⇒ same bits). The doc comment keeps the
  bit-identity claim but re-grounds it: both callers reach the same `TimeMap`
  methods; drift now requires `bindTime` to abandon those methods, which the
  equivalence test below would catch.
- The existing comptime block gains the subset pin: `inline for` over
  `@typeInfo(TrackTable.EmitName).@"enum".fields`, asserting each `@tagName` appears
  in `reserved_names`. Appending a future `EmitName` variant without reserving its
  name becomes a build break, not a prose promise.
- `Eval.zig`'s emit-lane comment ("bit-identical to a scalar `:expr` track") stands —
  it's about the shared `@floatCast`, unchanged.

## Phases

### Phase 1 — equivalence red, then the switch (RED first)
Load: `src/ExprTrack.zig` (`emitValue`, `bindTime`, the comptime block),
`src/Eval.zig` (the existing `:emit [bpm]`-vs-expr bit-equality test as template).
Reds: extend the Eval-level equivalence test to sweep ALL five `EmitName`s against
their `:expr` twins bit-exactly, at several ticks including a tempo-map boundary and
a negative tick — written and green BEFORE the switch lands (this red guards the
refactor rather than preceding a behavior change: it must stay green across it; note
the inversion in the log). Add the comptime subset pin and confirm it passes; sanity-
check it fires by temporarily misspelling one reserved name (throwaway, not
committed).
Green: replace the scan with the switch; delete the dead `MAX_BINDINGS` buffer from
`emitValue`.
Gate: `zig build verify` — corpus byte-identical (any diff means the switch is NOT
the same formula: stop and investigate, do not regen), npm gate.

## Progress log

- **2026-07-20 — Phase 1 complete.** Inverted red as planned: the Eval-level
  twin sweep ("emit lanes: every EmitName matches its :expr twin bit-exactly")
  covers all five names at the origin, both sides of a 4b tempo boundary, an
  off-grid late tick, and a negative tick — green BEFORE the switch and green
  across it. Comptime subset pin added (every `EmitName` ∈ `reserved_names`);
  throwaway misspell check confirmed it breaks the build. `emitValue` is now
  the exhaustive switch on the same `TimeMap` methods; the `MAX_BINDINGS`
  buffer and the `unreachable` are gone. Gates: `zig build verify` — corpus
  25/25 byte-identical (the switch IS the same formula), npm gate (81 pass).
