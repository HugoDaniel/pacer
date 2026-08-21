# pacer — Project Conventions

pacer is a Zig 0.16 deterministic animation / parameter driver: an SJON score
compiles to a flat tick-grid `TrackTable`, and a per-frame evaluator turns one
f64 seconds value into a packed `(target, value)` write buffer. It never reads a
clock, owns no loop, and never touches the GPU or audio graph — it is a pure
function of time. Same document + same f64 time ⇒ byte-identical writes, native
and wasm32. This file captures the conventions the codebase already follows so
commits don't drift from them.

pacer sits in a constellation: it consumes **SJON** (the score language +
validator + expr / trig kernels, a sibling path dependency), and feeds
**pngine** (visual uniforms, registry 0) and an audio engine such as **Sointu**
(params, registry 1). The npm package under `npm/pacer` is the JS glue around
`pacer.wasm`. pacer is pre-1.0; the wire formats and the diagnostic codes are
the intended-stable surfaces, gated by the golden corpus + `zig build verify`.

## Allocators

Every public entry point takes `gpa: std.mem.Allocator` and returns an owned
struct with arena-backed `.deinit()`; the struct never retains the caller's GPA.
Bind with `var`, `defer .deinit()`:

```zig
var schema = try Schema.load(gpa);          // once per host
defer schema.deinit();
var result = try Compile.compile(gpa, &schema, source, targets);
defer result.deinit();
```

The long-form memory model lives in `src/root.zig`'s `//!` header — read it once.
It mirrors SJON's (see SJON `src/root.zig`).

## Error sets

Every module exports an explicit `pub const Error = error{ … }`. Compile /
validate FAILURES are not errors — they are `Diagnostic`s on a successfully
returned result (collection over abort, the SJON discipline). Runtime errors
split three ways: resource exhaustion (`Compile.Error`'s `OutOfMemory`,
`Abi`/`Writes`' `BufferTooSmall`), host-clock guards (`TimeMap.Error`'s
`TickOverflow`/`NonFiniteTime`, re-exported as `Eval.Error` — `drv_eval` maps
them to an empty frame), and build-input domains (`Easing.Error`,
`ExprTrack.Error`, `PatternTrack.Error` — diagnostics at compile, counted
omissions at eval). Never assert on user input — those return diagnostics with
spans.

## Wire-stable surfaces — append-only

Four packed little-endian blobs cross the `pacer.wasm` boundary; two enums and
the `drv_*` export set ride with them. All are append-only: never reorder,
retype, or remove a field / variant / export — bump `drv_abiVersion` if the
contract itself must change.

Version policy: appending rides a minor release; any blob `VERSION` /
`drv_abiVersion` bump (or a section 4-CC reuse) is a breaking release — a
major once 1.0 tags, a 0.x minor until then.

| Surface | Where | Direction |
|---|---|---|
| `'PACT'` targets in | `Abi.encodeTargets` / `decodeTargets` | host → driver |
| `'PACD'` diagnostics out | `Abi.encodeDiags` | driver → host |
| `'PACM'` score metadata (+ TLV section stream) out | `Abi.encodeMeta` | driver → host |
| `'PACW'` writes out (20-byte entries) | `Writes.encode` / `decode` | driver → host |
| `Compile.Code` (u16) | `src/Compile.zig` | rides in `'PACD'` |
| `Easing.Op` (u8) | `src/Easing.zig` | rides in `'PACM'` `'EASE'` |
| `drv_*` exports | `src/wasm_entry.zig` | the JS ABI |

The npm glue (`npm/pacer/src/index.js`) mirrors every blob with one `DataView`
pass and casts the exports to the `PacerExports` typedef (`npm/pacer/src/types.js`)
— keep both sides in lockstep.

`'PACM'` closes with an append-only TLV **section stream** — zero or more
`[id u32][payload_len u32][payload]` frames after the last control, walked to
end-of-buffer with unknown ids skipped by length (so an old decoder tolerates a
new section). The sections are `'SCEN'` (scenes) then `'EASE'` (deduped easing
programs + per-key refs), emitted in that fixed order. Section 4-CCs are wire-stable
too: never reuse one, never bump `META_VERSION` for a new section — a breaking
change to a section's own layout mints a fresh id. Convention of record:
`src/Abi.zig`'s header and `plans/01-scenes-cues.md`.

## Determinism seams

The byte-identical claim rests on a handful of pinned seams — touch them only
with a corpus regen and a diff review:

- **One `mul + floor` per conversion** — seconds↔ticks goes through the single
  documented f64 seam in `TimeMap`; everything else is exact integer tick math on
  the `PPC = 720720` grid (divides 1..16 exactly). Overflow is a `tick_overflow`
  diagnostic, never a wrap. Under a `(tempo …)` map the same mul+floor runs
  against the active segment's origin, over a cumulative segment table built in
  one documented op order (`start_sec_{i+1} = start_sec_i + Δtick/tps_i`, never
  reassociated); a ≤1-segment map takes the constant code path VERBATIM — the
  degenerate pin that keeps every pre-map score bit-identical.
- **Seconds-domain wrap for mapped scores** — `:end loop`/`hold` under a tempo
  map wrap host seconds first (IEEE-exact `@mod`/`@min` in `TimeMap.loopSeconds`
  / `holdSeconds`, `loop_secs` computed once at compile), THEN convert once —
  tick-wrapping would replay loop iteration 2 at the final segment's tempo.
  Constant scores keep the historical tick-domain wrap in `Eval` bit-for-bit;
  `evalTicks` always wraps ticks (they are musical positions — correct in both
  worlds).
- **Fixed-count bezier bisection** — `Easing` solves cubic-bezier with a fixed
  iteration count (no epsilon early-exit), so the result is bit-identical.
- **Pinned `sjon.trig` kernels** — sin / cos / exp / pow route through SJON's
  deterministic kernels, not libm.
- **Single f64→f32 truncation at emission** — evaluation is f64; the one
  narrowing to f32 happens at write-buffer encode. The value must FIT: the
  narrowing kinds carry `(repr-shape :type f32)` in `schema/pacer.sjon`, so an
  out-of-range literal is refused at compile with a span rather than encoded as
  ±inf. Range-only — precision loss is the accepted step, magnitude is not.
- **Structural landing** — key ticks select segments structurally, so a key
  value lands bit-exactly on its authored f32.
- **NaN rejection at the expr boundary** — a non-finite expr result omits that
  track's write for the frame (counted in `drv_exprFailures`); a NaN never
  reaches the buffer.
- **Number syntax is SJON's** — pacer parses no literals; the lexer owns them,
  `0x` hex integers included (SJON 1.2.0). A meaning change there is a meaning
  change in the score language, inherited without a line of pacer code, so it
  rides a corpus pin (`hex-literals`) like every other value path.

## The CompileResult borrow-whole rule

`Eval.Evaluator` borrows a `CompileResult` WHOLE — table + validated tree +
schema (expr tracks re-read the tree every frame). The rule is structure, not
discipline: `Driver` (`src/Driver.zig`) owns the pair — in-place `init` (the
pointer receiver IS the placement contract), evaluator armed iff the compile
was clean, `deinit` encoding the teardown order once. Hold the pair through
`Driver`; construct a raw pair only where you can uphold placement /
no-reassign / teardown-order yourself (Eval's own tests do, on never-moved
stack locals). `drv_load` validates its arguments BEFORE `unload`, so a bad
call is a no-op (the live table survives).

One ring further out sits `Schema` (`src/Schema.zig`) — the preloaded score
manifest, whose arenas the result's plugins alias. The full nesting is
`Schema ⊃ CompileResult ⊃ Evaluator`, torn down inside-out. A `Schema` is a
HOST-level object: build one, above every `Driver`, and deinit it last
(`wasm_entry` keeps one for the instance's life, the corpus runner one for the
whole walk). `Driver` records the borrowed pointer so the outer ring is visible
on the struct rather than only in prose.

## The golden corpus

`corpus/<case>/{doc.sjon, times.sjon, expected.sjon}` is the determinism gate.
`src/corpus_runner.zig` (native) is the AUTHORITY: it renders the canonical
golden text, and `npm/pacer/test/corpus.test.js` re-derives the SAME text from
`pacer.wasm` output. Native-green + wasm-green ⇒ byte-identical `'PACW'` /
`'PACD'` / `'PACM'` for every pinned (score, time, directive). The golden pins
the `(meta …)` block and the control / tempo directive echoes too. Regenerate
with `zig build corpus -- --update` and REVIEW the diff — never hand-edit a
golden. The runner's `//!` header is the format's documentation of record.

## Build verbs

| Command | Purpose |
|---|---|
| `zig build test` | All inline Zig tests (root.zig forces submodule discovery) |
| `zig build wasm` | Build `pacer.wasm` (freestanding, ReleaseSmall) |
| `zig build corpus` | Native golden gate; `-- --update` regenerates |
| `zig build verify` | test + native corpus + `node --test` (wasm parity) — the whole gate |
| `zig build fuzz` | Never-panic fuzz harnesses (separate from `verify`) |
| `zig build audit-diagnostics` | Every `Compile.Code` variant is tested by name |

## npm package

`npm/pacer` is ESM-only JS glue: JSDoc-typed source + tsc-generated `.d.ts`, on a
strict TS 2026 baseline (`noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`,
…), linted + formatted by Biome. Gate before touching it:

```sh
cd npm/pacer && npm run lint && npm run typecheck && npm test
```

`npm test` rebuilds `pacer.wasm` first (the `pretest` hook) so the parity walk
runs against fresh bytes. `npm publish` runs the full gate then rebuilds the wasm
(`prepublishOnly` + `prepack`) and lands in the self-hosted Gitea registry. The
package version is spelled by hand in three places — `package.json`,
`build.zig.zon`, `src/root.zig` — and a lockstep test in `test/exports.test.js`
fails loudly if they drift.

## The ../SJON path dependency

pacer builds ONLY next to a sibling SJON checkout (`build.zig.zon` points at
`../SJON`). This is intentional — SJON is unpublished, consumed by path like
pngine. pacer imports it with `.@"plugin-exec" = false` (no libwasmtime; it needs
only the parser / validator / Expr / Pattern / trig surface). The score schema
(`schema/pacer.sjon`) is `@embedFile`'d via the `pacer_schema` build import, so
validation works on wasm32-freestanding with no filesystem.

It is **preloaded**, not prepended: `Schema.load` compiles the manifest once
through `sjon.Host.preloadSchema`, and every `validate` hands the bundle back
via `HostOptions.preloaded`. The document is therefore parsed on its own and
every diagnostic / metadata span is a SCORE coordinate by construction —
pacer translates no spans anywhere. (It used to prepend the manifest text to
each score and subtract the prefix; SJON's `Host.zig` header names that
pattern as the one preload replaces.)

## Roadmap

All roadmapped score forms have landed — `(scene …)` windows and compose-mode
`(target …)` declarations closed the last omissions (the `schema/pacer.sjon`
header notes none remaining). Compose-mode targets **merge** with the host
registries at compile: host indices are preserved, a declared name the host
also provides is host-authoritative (arity must agree, else
`target_arity_mismatch`), and a declared-only name is appended to the join under
its `:registry` — so a score compiles, corpus-tests, and lints with no host at
all. Declared names never cross the wire (`'PACT'`/`'PACM'` unchanged); a
consumer reads them from source, and `CompileResult.targets` surfaces the merged
join natively. Wave 4 is closed (hardening P1–P5, the 1.0 review, and the
tag prereqs — see `plans/00-strategy.md`); what remains before 1.0 are release
calls, not open plan items: publishing 0.2.0 and cutting the tag itself.

Alongside that, `plans/12-sjon-alignment.md` realigns pacer with SJON 1.1/1.2+.
Wave A (preload — the schema is loaded once per host, spans are score
coordinates by construction) and Wave B (schema vocabulary) are CLOSED: the
manifest now carries the score language's `:default`s (read back through
`sjon.EffectiveView`, so a default has one spelling), its source counts
(`(exclusive-group …)` on `(track …)` / `(trigger …)`), its dependency
(`trigger :offset :requires [every]`), its f32 ranges (`(repr-shape …)`), its
widget-shaped keys (`(control …)` discriminated on `:type`), and slot-local
`key` / `stage` bodies. Every rule moved into the schema deleted the pacer
branch it subsumed — pacer voids the table on any SJON error, so a subsumed
branch is dead code, not a second line of defence. Waves C (tooling: an LSP
project file, a schema'd corpus harness, generated score-language docs) and D
(examples) remain open. No wire surface moved in either wave.

## Code style

Follows SJON's: `//!` module headers describing role + invariants; `///` on
public APIs with ownership / lifetime notes; `comptime { std.debug.assert(@sizeOf(T)
== …); }` layout pins as build breaks; `std.debug.assert` for internal invariants
(never on user input); Zig 0.16 containers (`var list: std.ArrayList(T) = .empty;
try list.append(gpa, x);`). Commits: one logical change each, in the house style
`type(scope): summary — detail`.
