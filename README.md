# pacer

A deterministic animation / parameter driver conducted by an
[SJON](https://git.hugodaniel.com/hugo/SJON) score.

Write a score plus your target registries in, call `eval(seconds)` per frame,
read packed `(target, value)` writes back. The driver is a pure function of
time: it never reads a clock, owns no loop, and never touches the GPU or audio
graph. **Same document + same f64 time ⇒ byte-identical writes, in the browser
and natively** — a claim the golden corpus enforces on both sides of the WASM
boundary.

The pipeline: SJON score → Zig compile (targets joined, positions converted to
`i64` ticks on the `PPC = 720720` grid, easing programs flattened + deduped) →
flat `TrackTable` → per-frame evaluator → packed `'PACW'` write buffer. Visual
targets route by name into pngine uniforms (registry 0), audio targets into an
engine's param registry (registry 1).

The score language (all of it validated with spans by the embedded schema —
and documented, form by form, in
[`docs/score-language.md`](./docs/score-language.md), rendered from that same
schema):
keyframe tracks with composable easing (`seq`/`chain` combinators, springs,
bezier, steps), `:expr` tracks evaluated each frame against a bound time env
(`t`/`beat`/`bar`/`phase`/…), `:pattern` tracks driven by SJON's pattern
engine (1 cycle = 1 bar on the shared grid), `(trigger …)` event lanes
(phase/count/gate/beats-since), `(scene …)` windows with scene-local time,
`(control …)` pins that write every frame and feed expressions
(live-overridable from the host), `(transport :emit …)` built-in clock lanes,
`(tempo …)` segments — a piecewise tempo map moving only the seconds↔ticks
projection (b/bar positions stay exact ticks; the `bpm` env/emit lane becomes a
step function; mapped scores loop/hold in wall-clock seconds) — and
compose-mode `(target …)` declarations so a score compiles with no host
registries at all.

## Layout

| Path | What |
|---|---|
| `src/` | the Zig driver — compile, eval, easing, tick math, WASM entry + boundary blobs |
| `src/cli/` | the native `pacer` binary — score IR, eval-at-t, and `pack` to `'PACB'` as JSON-first |
| `schema/pacer.sjon` | the score schema (embedded, validates on wasm32-freestanding) |
| `schema/pacer-corpus.sjon` | the corpus harness schema (embedded; validates every `times.sjon`) |
| `sjon-project.sjon` | the workspace project file — what `sjon-lsp` reads to give scores editor support |
| `corpus/` | golden determinism cases — `doc.sjon` + `times.sjon` + generated `expected.sjon` |
| `npm/pacer/` | the ESM JS glue around `pacer.wasm` (published package) |
| `examples/` | a browser demo (live editor → canvas + audio) |
| `docs/score-language.md` | GENERATED score-language reference (`zig build score-docs`) |
| `docs/cli.md` | the CLI reference (`pacer ir` / `eval` / `check`) |
| `tools/` | the diagnostic-coverage audit, the score-docs renderer, the CLI goldens |

## Quickstart

pacer builds next to a sibling **SJON** checkout — clone it as `../SJON`
(unpublished, consumed by path, like pngine). Then:

```sh
zig build verify   # Zig tests + native golden corpus + node/wasm parity walk
```

Other verbs: `zig build fuzz` (never-panic harnesses), `zig build
audit-diagnostics` (every diagnostic code is tested), `zig build corpus --
--update` (regenerate goldens, then review the diff), `zig build score-docs`
(re-render the score-language reference). See [`CLAUDE.md`](./CLAUDE.md) for
the full conventions.

Run the browser demo (serve from the repo root so the paths resolve):

```sh
zig build wasm
python3 -m http.server   # then open /examples/
```

## Asking a score a question

```sh
zig build cli   # → zig-out/bin/pacer

pacer check score.sjon              # diagnostics, with line/col
pacer ir    score.sjon | jq         # the compiled IR as JSON
pacer eval  score.sjon --at 3.5     # the write frame at t, as JSON
pacer eval  score.sjon --at 3.5 --set sway-amt=0.2   # …with a knob held
```

A score that declares its own targets with `(target …)` needs no flags at all;
one written against host registries takes them as `--target NAME[:ncomp[:registry]]`,
in the flat order that IS the `target_id` space. Full reference:
[`docs/cli.md`](./docs/cli.md).

## Editing scores

Scores get diagnostics, hover, completion and did-you-mean from SJON's
language server. `sjon-project.sjon` at the repo root is what points it at
`schema/pacer.sjon`, so the vocabulary is live for every `corpus/*/doc.sjon`
and every example with no `(use-plugin …)` line in the score. Build the server
out of the sibling checkout (`cd ../SJON && zig build lsp`), put
`../SJON/zig-out/bin` on your `PATH`, and follow your editor's block in
[SJON's tooling guide](../SJON/docs/TOOLING.md) — the server attaches to
`*.sjon` and finds the project file on its own.

## Using it from JS

The driver ships as an npm package — see
[`npm/pacer/README.md`](./npm/pacer/README.md) for install, the wasm-bytes
handshake, and the `Pacer` API.

## Versioning

The wire surfaces — the four `'PAC*'` blobs, the `Compile.Code` and
`Easing.Op` enums, and the `drv_*` export set — are **append-only**. Additive
growth (a new TLV section, trailing field, enum variant, or export) ships in a
minor release; bumping any blob `VERSION`, `drv_abiVersion`, or reusing a
section 4-CC is a breaking release — a major once 1.0 is tagged, a 0.x minor
until then (the SemVer pre-1.0 convention). The golden corpus + `zig build
verify` gate both kinds.

## License

[CC0 1.0 Universal](./LICENSE) — a public-domain dedication. Do
whatever you like with it, no attribution required.
