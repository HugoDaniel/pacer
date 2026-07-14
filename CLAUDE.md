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
var result = try Compile.compile(gpa, source, targets);
defer result.deinit();
```

The long-form memory model lives in `src/root.zig`'s `//!` header — read it once.
It mirrors SJON's (see SJON `src/root.zig`).

## Error sets

Every module exports an explicit `pub const Error = error{ … }`. Compile /
validate FAILURES are not errors — they are `Diagnostic`s on a successfully
returned result (collection over abort, the SJON discipline). `Compile.Error`,
`Abi.Error`, `Writes.Error`, and `Easing.Error` are the only unions; the only
runtime errors are resource exhaustion (`OutOfMemory`, `BufferTooSmall`). Never
assert on user input — those return diagnostics with spans.

## Wire-stable surfaces — append-only

Four packed little-endian blobs cross the `pacer.wasm` boundary; two enums and
the `drv_*` export set ride with them. All are append-only: never reorder,
retype, or remove a field / variant / export — bump `drv_abiVersion` if the
contract itself must change.

| Surface | Where | Direction |
|---|---|---|
| `'PACT'` targets in | `Abi.encodeTargets` / `decodeTargets` | host → driver |
| `'PACD'` diagnostics out | `Abi.encodeDiags` | driver → host |
| `'PACM'` score metadata (+ TLV section stream) out | `Abi.encodeMeta` | driver → host |
| `'PACW'` writes out (20-byte entries) | `Writes.encode` / `decode` | driver → host |
| `Compile.Code` (u16) | `src/Compile.zig` | rides in `'PACD'` |
| `Easing.Op` (u8) | `src/Easing.zig` | program table (future wire) |
| `drv_*` exports | `src/wasm_entry.zig` | the JS ABI |

The npm glue (`npm/pacer/src/index.js`) mirrors every blob with one `DataView`
pass and casts the exports to the `PacerExports` typedef (`npm/pacer/src/types.js`)
— keep both sides in lockstep.

`'PACM'` closes with an append-only TLV **section stream** — zero or more
`[id u32][payload_len u32][payload]` frames after the last control, walked to
end-of-buffer with unknown ids skipped by length (so an old decoder tolerates a
new section). The first section is `'SCEN'` (scenes). Section 4-CCs are wire-stable
too: never reuse one, never bump `META_VERSION` for a new section — a breaking
change to a section's own layout mints a fresh id. Convention of record:
`src/Abi.zig`'s header and `plans/01-scenes-cues.md`.

## Determinism seams

The byte-identical claim rests on a handful of pinned seams — touch them only
with a corpus regen and a diff review:

- **One `mul + floor` per conversion** — seconds↔ticks goes through the single
  documented f64 seam in `TimeMap`; everything else is exact integer tick math on
  the `PPC = 720720` grid (divides 1..16 exactly). Overflow is a `tick_overflow`
  diagnostic, never a wrap.
- **Fixed-count bezier bisection** — `Easing` solves cubic-bezier with a fixed
  iteration count (no epsilon early-exit), so the result is bit-identical.
- **Pinned `sjon.trig` kernels** — sin / cos / exp / pow route through SJON's
  deterministic kernels, not libm.
- **Single f64→f32 truncation at emission** — evaluation is f64; the one
  narrowing to f32 happens at write-buffer encode.
- **Structural landing** — key ticks select segments structurally, so a key
  value lands bit-exactly on its authored f32.
- **NaN rejection at the expr boundary** — a non-finite expr result omits that
  track's write for the frame (counted in `drv_exprFailures`); a NaN never
  reaches the buffer.

## The CompileResult borrow-whole rule

`Eval.Evaluator` borrows a `CompileResult` WHOLE — table + validated tree +
schema (expr tracks re-read the tree every frame). So: build the evaluator from a
STORED (not temporary) result; tear the evaluator down BEFORE the result; never
reassign a live result. Both rules are confined to `wasm_entry.zig`'s
`unload` / `drv_load` and the corpus runner. `drv_load` validates its arguments
BEFORE `unload`, so a bad call is a no-op (the live table survives).

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

## Roadmap

Deliberate omissions landing with later build-order steps (see the header of
`schema/pacer.sjon`): `(scene …)` / cue lists, and compose-mode `(target …)`
declarations.

## Code style

Follows SJON's: `//!` module headers describing role + invariants; `///` on
public APIs with ownership / lifetime notes; `comptime { std.debug.assert(@sizeOf(T)
== …); }` layout pins as build breaks; `std.debug.assert` for internal invariants
(never on user input); Zig 0.16 containers (`var list: std.ArrayList(T) = .empty;
try list.append(gpa, x);`). Commits: one logical change each, in the house style
`type(scope): summary — detail`.
