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

### Render from the blobs, not the table

`corpus_runner.renderMeta` already encodes via `Abi` then decodes field by field,
so the golden sits ON the wire format. SJON does the same for `eval
--format=json`. The CLI follows — but rather than hand-rolling a *second* Zig
decoder (there is already one inline in the runner and one in JS), the reading
halves go into `Abi` itself, symmetric with `encodeTargets`/`decodeTargets` and
`Writes.encode`/`decode`.

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
- `std.json.Stringify` prints a non-finite f64 as bare `nan`/`inf` (invalid
  JSON). pacer never lets one into a write, so the only door is argv: reject
  non-finite `--at`/`--from`/`--to`/`--set` at parse time.

## Phases

### Phase 1 — `Abi.decodeMeta` / `decodeDiags`, corpus renders through them
Load: `src/Abi.zig`, `src/corpus_runner.zig`.
Gate: `zig build verify` with a ZERO-byte corpus diff.

### Phase 2 — CLI skeleton + `check`
Load: `src/cli/*` (new), `build.zig`, `SJON/src/cli/main.zig` for the entry shape.
Reds: `invoke(&.{"pacer","check",fixture})` → `(code, stdout, stderr)`; unknown
flag → 2; missing positional → 2; a clean corpus score → 0; `corpus/diag-controls`
→ 1 with five diagnostics; `--json` parses. Table tests for `indexToLineCol`
(UTF-8 included) and `--target` parsing.
Build wiring: a NAMED `cli` step, not `b.installArtifact` — bare `zig build`
installs nothing today and that property holds. Plus a `run` step forwarding
`b.args`, and a `cli_tests` artifact `test` and `verify` depend on.

### Phase 3 — `ir`
Load: `src/cli/Cli.zig`, `src/cli/Render.zig`, `src/Abi.zig` (MetaView),
`npm/pacer/src/types.js` for field names.

### Phase 4 — `eval`, `--set`, sampling
Load: `src/cli/Cli.zig`, `src/cli/Render.zig`, `src/Eval.zig` (control API).

### Phase 5 — docs
`docs/cli.md` (hand-written — no schema to render from), the verb in CLAUDE.md's
build-verb table, a README layout row, and the explicit "CLI JSON is not a wire
surface" note in CLAUDE.md's wire-stable section.

## Progress log
