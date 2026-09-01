# 14 — A native CLI: score IR and eval-at-t as JSON

**Repos:** pacer
**Wire impact:** none — `Abi` gains DECODERS (reading halves of blobs it already
writes); no format, enum, or export moves. The CLI's own JSON is explicitly NOT a
wire surface.
**Gates:** `zig build verify` every phase; Phase 1's real gate is a ZERO-byte
corpus diff.

## Why

pacer ships no native binary. `build.zig`'s only `addInstallArtifact` is
`pacer.wasm`, and `npm/pacer/package.json` declares no `bin`. So every way to ask
pacer a question goes through a host — a browser (`examples/index.html` + the npm
glue) or `src/corpus_runner.zig`, a native exe that is never installed and whose
argv is `<corpus-dir> [--update]`, answering only "does this whole directory
still match its goldens?".

There is no way to point at one score and ask *what did the compiler make of
this?* or *what does this write at t = 3.5 s with the sway knob at 0.2?* without
writing a host. Everything needed has shipped — `Abi.encodeMeta` already
serializes the IR, `Eval.evalSeconds` already returns a frame, `Eval.setControl`
already implements the override (plan 08 settled the knob vocabulary), and
compose-mode `(target …)` means a score compiles with zero host registries. This
is a front end, not new driver capability.

## Design

Three verbs sharing one load path:

```
pacer ir    <score.sjon|-> [--target …]
pacer eval  <score.sjon|-> [--target …] [--set …] (--at S… | --from S --to S --fps N)
pacer check <score.sjon|-> [--target …] [--json]
```

- `--target NAME[:ncomp[:registry]]`, repeatable. Flat order IS the `target_id`
  space, as in a `times.sjon`. ncomp defaults 1, registry 0. Zero targets is the
  default and works for compose-mode scores (`corpus/target-declared`). No
  non-decreasing-registry rule — that is a corpus-harness constraint the JS
  regrouping needs, not a driver one.
- `--set <id-or-slot>=<v>[,<v>…]`, repeatable, applied once after load. A bare
  integer key is a slot index, anything else a `(control :id …)` name —
  unambiguous because `control-id` is a SJON symbol. `eval` only: `ir` reports the
  document IR, which a live override does not change.
- `-` reads stdin; the file label becomes `<stdin>`.

### Render from MEMORY, not from the blobs

`corpus_runner.renderMeta` encodes via `Abi` then decodes field by field, so the
golden sits ON the wire format. That ritual is right for the corpus, whose whole
job is proving `'PACM'` byte-identical native and wasm. It is the WRONG ritual
for the CLI, because `'PACM'` is lossy relative to the in-memory result and the
lost parts are exactly what an `ir` dump promises:

- **No emit lanes at all.** `TrackTable.Transport.emit` has no `'PACM'`
  representation, so a score with `(transport :emit [beat bar])` would render
  NOTHING about it. Verified: `Abi.zig` has no `emit` anywhere.
- **No target names** — only `target_id`. `corpus_runner` already breaks out of
  the blob for these, resolving through `result.targets`.
- **No scene names** — a span only.
- **No expr / pattern source text** — the track record is a `source` byte 0..3.
- **No merged-join origins.** `CompileResult.targets` is a native-side view that
  preserves host indices then appends compose-mode declarations, so `origin:
  host|declared` is computable natively and unavailable on the wire.
- **Codes as ordinals, not names.** `'PACD'` carries `Compile.Code`'s u16; the
  CLI wants `@tagName` beside it, which only the in-memory enum has.

So `ir`, `check` and `eval` all render from `CompileResult` / `TrackTable` /
`Writes.Entry` directly. The CLI is native-only and makes no parity claim, so
round-tripping through a wasm-boundary format to produce native-only output
would be ritual, not proof.

The one thing that ritual DID buy is the diagnostic merge order — `encodeDiags`
writes every SJON diagnostic first, then every pacer code. Rendering from memory
re-spells that, so pin it with a counterfactual test rather than a decoder: on a
score tripping both, the rendered array's `(producer, code_id, span.start)`
triples must match the blob's positionally.

### The one core change: `Eval.Evaluator.last_tick`

`evalSeconds` wraps SECONDS first for a mapped score, then converts; `evalTicks`
then wraps again in TICKS (`@mod(t, dur)`). Either way the tick the writes came
from is `evalTicks`'s post-wrap value, which is NOT `map.tickFromSeconds(seconds)`
— they diverge on every looping score past its `:dur`. A CLI printing a frame's
tick therefore cannot recompute it, and must not re-spell the wrap (a pinned
determinism seam).

So `Evaluator` gains `last_tick: Tick = 0` beside `expr_failures`, assigned in
`evalTicks` after the wrap, documented in the same voice ("a debugging probe, not
semantics"). Additive, no wire impact, no behaviour change. **Its gate is that
every corpus golden stays byte-identical.**

### Channels and exit codes

SJON's table (`SJON/src/cli/Cli.zig:69`), not pngine's 0..6 — three verbs do not
need six codes:

| Code | Meaning |
|---|---|
| 0 | ok |
| 1 | the score has errors |
| 2 | usage error |
| 3 | internal error (I/O, OOM) |

`ir`/`eval` are DATA verbs: stdout is JSON only, diagnostics to stderr, zero
stdout bytes on error. `check` is a REPORT verb: its report goes to stdout (human
by default, `--json` for the envelope). `main` collapses escapes to 3, and a
failed stdout flush overrides whatever `run` returned.

### Files

`src/cli/`, a separate module root importing the PUBLIC `pacer` module (not
relative-path sources like `corpus_runner`), so the CLI also tests that the
published surface suffices.

| File | Owns |
|---|---|
| `src/cli/main.zig` | Thin entry: stdio, argv, env snapshot, outermost catch. Nothing behavioural. |
| `src/cli/Cli.zig` | `Action` union, pure `parseArgs`, `run(gpa, io, args, stdout, stderr, env) Error!u8`, the three runners. |
| `src/cli/Render.zig` | PURE `fn(w: *Io.Writer, …) !void` writers: the JSON envelopes, the human diagnostic line, `indexToLineCol`. |
| `src/cli/Cli_tests.zig` | In-process e2e driving `Cli.run` with `Writer.Allocating`. |

The `main`/`Cli` split is SJON's, so tests cover the code path the binary runs.
The pure-writer / thin-wrapper split is pngine's CONTRIBUTING §11c and is
MANDATORY: under `zig build` fd 1 carries the test-runner protocol, so a function
a test calls must never write to stdout — the failure mode is `zig build test`
hanging at 0% CPU with no diagnostic.

### Facts that constrain it

- `sjon.Pattern.MAX_TICK = 1 << 53` — the JS exact-integer boundary, so every
  tick emits as a plain JSON number. The npm glue's BigInt problem does not
  reappear natively.
- Zig 0.16's `std.json.Stringify` prints f64 shortest-round-trip, so decimal is
  lossless. The corpus's hex bit-patterns exist because `sjon fmt` rewrites hex
  LITERALS — a score-text problem, not a JSON one.
- Spans are raw u32 byte offsets. SJON's `indexToLineCol` lives in
  `SJON/src/cli/`, outside the `sjon` module — pacer must write its own.
- `sjon.CappedRead.readFileZ` IS exported and yields the `[:0]u8` `Driver.init`
  needs. Reuse it.
- `CompileResult.targets` aliases caller memory for host names; argv outlives the
  compile, so `--target` names borrow from argv.
- A frame aliases the evaluator's reused buffer — render before the next eval.
- Write values are truncated to `ncomp` lanes in the JSON — `ncomp` sits beside
  them so nothing is hidden, and it makes `--set pan=0.25,0.5` and
  `"value":[0.25,0.5]` the same spelling in both directions.
- `std.fmt.parseFloat` ACCEPTS `"nan"` and `"inf"`, so `--set` must reject
  non-finite lanes in the parser (a typo, not a score property) rather than
  leaning on `setControl`'s bool.
- `eval` with neither `--at` nor a sweep is a usage error, not a default of 0:
  adding a default later is additive, removing one is breaking.
- Sweep times are `from + i/fps` computed from `i`, never accumulated, so a long
  sweep does not drift. Explicit `--at`s come first in argv order, then the
  sweep; no sorting, no dedup — the frames array indexes 1:1 with what was asked.
- CLI tests CANNOT ride `src/root.zig`'s `test {}` block: these files
  `@import("pacer")`, which inside the core test binary resolves to a second,
  distinct module instance. Hence a separate `addTest` rooted at `src/cli/Cli.zig`,
  whose own `test {}` plays root.zig's role one level down.
- `std.json.Stringify` prints a non-finite f64 as bare `nan`/`inf` (invalid
  JSON). pacer never lets one into a write, so the only door is argv: reject
  non-finite `--at`/`--from`/`--to`/`--set` at parse time.

## Phases

### Phase 1 — `Abi.decodeMeta` / `decodeDiags`, corpus renders through them
Load: `src/Abi.zig`, `src/corpus_runner.zig`.
Gate: `zig build verify` with a ZERO-byte corpus diff.

### Phase 2 — CLI skeleton + `check`
Load: `src/cli/*` (new), `build.zig`, `SJON/src/cli/main.zig` for the entry shape.
New: `main.zig`, `Cli.zig`, `Args.zig`, `Json.zig`, `Source.zig`, `Diags.zig`.
Reds: `Json` escaping / invalid-UTF-8 → U+FFFD / non-finite → `null`; `LineIndex`
(ASCII, multi-byte columns, offset inside a sequence, CRLF, EOF, past-EOF, empty,
invalid lead); `Args` verb dispatch, `-` as positional not flag, `--target`
grammar and the `Compile.MAX_TARGETS` cap; the `encodeDiags` merge-order pin; end
to end over `corpus/diag-controls/doc.sjon` → exit 1 with five diagnostics, and a
clean score → exit 0, `diagnostics: []`, empty stderr.
Build wiring: a NAMED `cli` step, not `b.installArtifact` — nothing in this build
attaches to the default install step, so a bare `zig build` stays a no-op and
should keep doing so. Plus a `run` step forwarding `b.args`, and the separate CLI
test artifact hung on `test_step`.

### Phase 3 — `ir`
Load: `src/TrackTable.zig`, `src/TimeMap.zig`, `src/Easing.zig` (`Op`/`Stage`/
`Program`), `src/Compile.zig` (`Target` + the `CompileResult.targets` doc).
New: `src/cli/Ir.zig`.
Reds: keys + easing variety; `:expr` / `:pattern` / `(trigger …)` with their
SOURCE TEXT asserted via the track span; scenes + a `(tempo …)` map +
`(transport :emit …)` + a compose-mode `(target …)` asserting `origin: declared`.

### Phase 4 — `eval`, `--set`, sampling, and the `last_tick` probe
Load: `src/Eval.zig`, `src/Writes.zig`, `src/TrackTable.zig` (`Control`),
`src/cli/Args.zig` + `Cli.zig`.
New: `src/cli/Frames.zig`; `src/Eval.zig` gains `last_tick` — the ONLY file
outside `src/cli/` this plan touches.
Reds: the probe on a mapped looping score past `:dur` reports the WRAPPED tick
(this red lives in `Eval.zig`'s own tests); sweep count/endpoints/caps/partial
flags; `--set` grammar, name-vs-slot, unknown id, out-of-range slot, non-finite
rejected at parse; a two-sample test proving the frame-aliasing rule is respected
(frames must STREAM — never collect, or every frame shows the last one's writes);
an out-of-range time → `out_of_range: true` at exit 0; `--set` rejected by `ir`.
Gate: `zig build verify`, and every corpus golden byte-identical after the probe.

### Phase 5 — the binary golden and the docs
Load: `tools/score_docs.sh` (the shape to copy), `build.zig`, `CLAUDE.md`,
`README.md`.
New: `tools/cli_golden.sh` + `src/cli/testdata/{starter.ir,starter.eval,
controls.check}.json`; `docs/cli.md`.
The goldens live under `src/cli/testdata/`, NOT `corpus/` — that directory's
contract is native-vs-wasm byte equality and the CLI makes no such claim. Same
check-by-default / `--update`-to-write shape as `score_docs.sh`, check leg on
`verify`, update leg on a `cli-golden` verb. `examples/starter.score.sjon` is the
fixture: keys, expr, pattern, trigger, scene, tempo map, control, three easing
combinators, two registries.
Docs: a `zig build cli` row in CLAUDE.md's verb table, one sentence under
Wire-stable surfaces naming the CLI JSON as deliberately OUTSIDE the set (one
producer, no second decoder — so it is versioned via `"format": N`, not frozen),
and a README row.

## Progress log

### Phase 1 — `Abi.decodeMeta` / `decodeDiags` — DONE 2026-09-01

**Deliverable — the reading halves of the two encode-only blobs** (`src/Abi.zig`),
symmetric with the `encodeTargets`/`decodeTargets` and `Writes.encode`/`decode`
pairs already there. `decodeMeta(blob) ?MetaView` and `decodeDiags(blob) ?DiagView`,
plus the decoded record types `MetaTrack` / `MetaKey` / `MetaControl` / `MetaScene`
/ `MetaTempoSeg` / `DiagRecord` and the three wire enums `TrackSourceKind` /
`DiagSource` / `DiagSeverity`.

**Both decoders are TOTAL** — every defect returns null rather than trapping,
matching `decodeTargets`, because a blob is host glue's output. Validation happens
ONCE at decode (lengths, magic, version, every enum byte, key ranges inside the key
stream, each section's exact payload accounting, no repeated section id, no
trailing bytes); the accessors are therefore assert-based, not fallible. Every
returned slice — a diagnostic message, a control id — ALIASES the blob.

**Enum bytes are validated at decode, not at access**, because the accessors return
real enum values (`Easing.Op`, `TrackTable.ControlType`, `TrackSourceKind`): an
unvalidated byte would be an invalid enum, i.e. UB, rather than a null. That is why
`decodeMeta` walks all 8×4 op slots of every `'EASE'` program. Zeroed slots decode
cleanly because `Op.linear == 0`, matching `Program.zero_stage`.

**An unknown section id is still skipped by length** — the TLV tolerance guarantee
is under test (`decodeMeta: an unknown section id is skipped by length`), and an
ABSENT section reads as an EMPTY one (`sceneCount() == 0`), which is the encoder's
own omit-when-count-is-zero equivalence.

**`corpus_runner` now renders through them.** `renderMeta` / `renderEasePrograms` /
`renderDiags` lost ~205 lines of inline byte-walking; `renderLanes` and `renderRail`
now take `[4]f32` / `?[4]f32` instead of raw byte slices, and the section order is
stated explicitly (`'SCEN'`, `'EASE'`, `'TMPO'`) rather than emerging from the walk
— which is the encoder's fixed order restated as code. `easeOpName` and
`controlTypeName` are gone: `@tagName` over the decoded enums gives the same
spellings the goldens pin.

**Zig 0.16 note:** `std.meta.intToEnum` no longer exists; the checked conversion is
`std.enums.fromInt(E, x) ?E`.

**Gate: `zig build verify` green with a ZERO-byte corpus diff** — 37 cases
byte-identical, no golden touched. That diff being empty IS the proof the decoders
match the encoder, which is why this phase came before any CLI code. It also makes
`encodeMeta` round-trip testable in Zig for the first time (previously it was only
proven through golden text).

**CORRECTION, same day, before Phase 2 started.** This phase was planned partly on
the premise that the CLI would otherwise be a THIRD hand-rolled `'PACM'` decoder.
That premise is FALSE and the plan's design section now says the opposite: the CLI
renders from memory, because `'PACM'` carries no emit lanes, no target names, no
scene names, no expr/pattern source text, no join origins, and codes as ordinals
rather than names. So neither decoder gets a CLI consumer.

The phase is kept anyway, on the two justifications that survive independently:
`corpus_runner` shed ~205 lines of inline byte-walking, and `encodeMeta` became
round-trip testable in Zig for the first time (it was previously provable only
through golden text). `decodeMeta`/`decodeDiags` are also a fair public surface for
any host reading a blob back. Recorded rather than quietly dropped, because a
progress log that only lists the reasons that worked out is not a log.

**Carry-forward for Phase 2:** nothing from this phase is on the CLI's path. Read
the IR from `driver.result` — `table.tracks` / `.keys` / `.controls` / `.scenes` /
`.programs` / `.transport` — and diagnostics from `result.diagnostics` plus
`result.validated.result.diagnostics`, in that order (the merge `encodeDiags`
performs, pinned by a counterfactual test rather than by decoding).

### Phase 2 — CLI skeleton + `check` — DONE 2026-09-01

**Deliverable — `zig build cli` produces `zig-out/bin/pacer`**, with `check`
working end to end: human report by default, `--json` envelope, `-` for stdin,
`--target NAME[:ncomp[:registry]]` repeatable, exit 0/1/2/3.

Six files under `src/cli/`: `main.zig` (process wiring only — writers built
BEFORE argv so an OOM in `toSlice` still reports; a failed stdout flush overrides
whatever `run` returned), `Cli.zig` (the test seam: `run(gpa, io, argv, out, err)`,
`Exit`, usage text, the shared load path), `Args.zig` (pure — returns an `Action`,
never prints), `Json.zig` (scalar emitters only), `Source.zig` (input + `LineIndex`),
`Diags.zig` (the shared diagnostics array + `check`'s two renderings).

**Build wiring:** a NAMED `cli` step plus `run`, never `b.installArtifact` —
nothing in this build attaches to the default install step, so a bare `zig build`
stays a no-op and now demonstrably keeps doing so. The CLI tests are a SECOND test
artifact rooted at `src/cli/Cli.zig`, because `src/root.zig`'s discovery block
cannot reach files that `@import("pacer")` — inside the core test binary that
resolves to a second, distinct module instance. `Cli.zig`'s own `test {}` plays
root.zig's role one level down. Hung on `test_step`, so it rides `verify` and runs
in parallel with the core binary.

**The merge pin came out differently than planned, and better.** The plan called
for a counterfactual test on a score tripping BOTH producers at once. No such
score exists: `Compile.compile` runs the builder only `if (!v.hasErrors())`
(`src/Compile.zig:353`), so a document failing SJON validation never reaches
pacer's own checks — every corpus `diag-*` case is all-sjon or all-pacer, never
mixed. The fixture was rewritten as three tests: the walk matches the `'PACD'`
blob record-for-record on a pacer-only score AND on a sjon-only score, plus an
explicit pin on the structural reason they cannot mix. The day that changes, the
third test is the one that says so.

**Two Zig 0.16 notes.** `std.Io.Writer.Allocating` is the whole in-process test
harness — `invoke(argv)` returns `(code, stdout, stderr)` with no subprocess, run
under `std.testing.allocator`, which is ALSO the leak gate: `std.process.Init`'s
allocator explicitly does not affect the return code, so pngine's exit-99 dance
would buy nothing here. And `{d}` on an f32 must not be widened to f64 first —
`0.1` as f32 widened prints `0.10000000149011612`, so `Json.number32` takes the
f32 directly.

**Gate: `zig build verify` green** (253 Zig tests incl. 34 new CLI ones, 37 corpus
cases unchanged, npm parity, score-docs current). Smoke-verified: compose-mode
score with zero flags exits 0, `corpus/diag-controls --target tint:3` reproduces
exactly the five pinned diagnostics with names beside ordinals, stdin reports
`<stdin>`, and a usage error writes zero bytes to stdout.

**Carry-forward for Phase 3 (`ir`):** add `.ir` to `Args.Verb` and a branch to
`runCommand`'s switch; everything else is in place. Read the IR from
`driver.result.table.?` and `driver.result.targets`. `Json.lanes(v, ncomp)` already
truncates. `Source.LineIndex.at(offset)` gives 1-based line/col with codepoint
columns. The envelope preamble (`pacer`/`command`/`source`/`ok`/`diagnostics`) is
spelled in `Diags.renderJson` — Phase 3 should lift it into a shared helper rather
than copy it.
