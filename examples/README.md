# examples

Four files, two of which are pacer scores.

| File | What it is |
|---|---|
| `starter.score.sjon` | The score `index.html` loads into its editor — a tour of the language: keyframes with every easing combinator, an `:expr` track behind a pinned `(control …)`, a `:pattern` track, two `(trigger …)` lanes, a `(tempo …)` change and a `(scene …)` window. |
| `demoscene.score.sjon` | The flagship: 100 bars at 128 bpm driving the four `motion` uniform fields of `impulsos_camaradas.sjon` — `sceneMix`, `spin`, `chromaAmt`, and `beat` through `:emit`. |
| `impulsos_camaradas.sjon` | **A pngine document, not a pacer score.** pngine owns it; it lives here so the score next to it has something to read. It builds the SDF pipeline, the halftone dot layer and the cube-canvas grid, and takes all of its motion from the `motion` buffer. |
| `index.html` | The browser demo. |

Both scores are written in **compose mode** — they declare their own targets
with `(target …)`, or (in the starter's case) target the demo page's
registries — so each one compiles, evaluates and lints standalone. Both are
pinned by the golden corpus: `corpus/examples-demoscene/doc.sjon` and
`corpus/examples-starter/doc.sjon` are symlinks to the files above, so the
example that ships is the example the gate compiles. Editing one and running
`zig build verify` tells you immediately if it stopped compiling; regenerate
its golden with `zig build corpus -- --update` and review the diff.

`sjon-project.sjon` at the repo root points `sjon-lsp` at `schema/pacer.sjon`,
so both scores get diagnostics, hover and completion in an editor with no
`(use-plugin …)` line of their own.

## Running the demo

`index.html` fetches `pacer.wasm` and the starter score over HTTP, so serve it
from the repo root rather than opening the file directly:

```sh
zig build wasm
python3 -m http.server        # then open http://localhost:8000/examples/
```

Edit the score in the left pane: it recompiles ~150 ms after you stop typing,
diagnostics appear underneath with spans into your own text, and the last good
table keeps animating while the text is broken. Drag the `sway-amt` slider for
a live `drv_setControl` override and press *clear* to hand authority back to
the document. *play music* starts a click track that is **rendered from the
score** — the page walks `t` and watches the `click` trigger's count lane — so
retiming the transport, or editing the `(tempo …)` line, retimes the music with
the picture, and the audio transport takes over as the master clock.

`impulsos_camaradas.sjon` does not run here — it needs pngine, which loads the
document, binds `demoscene.score.sjon`'s writes into the `motion` buffer, and
renders the pipeline.

## Running the examples from the CLI

The browser demo is one entry point; the cookbook is the other, with pinned output for every case.

### The cookbook

`examples/cookbook/` holds 26 teaching cases. Each case has `score.sjon`, `case.json`, `notes.md` and a generated `expected.json`; `examples/cookbook/README.md` is the language guide and case index, and `examples/cookbook/run.mjs` is the runner.

### Prerequisites

- Zig 0.16 (verified 0.16.0) and Node 20+ (verified 22.23.2).
- Here the native Zig binaries are OpenBSD, so commands go through `obs sh -c 'cd /home/agent/worktrees/animader-init/pacer && ulimit -c 0 && <command>'`. On a native host, drop the wrapper.
- Build the CLI and both wasm artifacts:

  ```sh
  obs sh -c 'cd /home/agent/worktrees/animader-init/pacer && ulimit -c 0 && zig build cli wasm wasm-rt'
  ```

  Verified tail: `Build Summary: 11/11 steps succeeded`. This writes `zig-out/bin/pacer`, `zig-out/bin/pacer.wasm` and `zig-out/bin/pacer-rt.wasm`; it does not copy them into `npm/pacer/`. The Node load reads `npm/pacer/pacer-rt.wasm`, so copy once:

  ```sh
  cd npm/pacer && npm run build:wasm-copy && npm run build:wasm-rt-copy
  ```

- `zig build` is the full gate: `Build Summary: 1/1 steps succeeded` cached.

### Run the whole cookbook

```sh
obs sh -c 'cd /home/agent/worktrees/animader-init/pacer && ulimit -c 0 && node examples/cookbook/run.mjs'
obs sh -c 'cd /home/agent/worktrees/animader-init/pacer && ulimit -c 0 && node examples/cookbook/run.mjs --case keys-scalar'
obs sh -c 'cd /home/agent/worktrees/animader-init/pacer && ulimit -c 0 && node examples/cookbook/run.mjs --json'
obs sh -c 'cd /home/agent/worktrees/animader-init/pacer && ulimit -c 0 && node examples/cookbook/run.mjs --update'
obs sh -c 'cd /home/agent/worktrees/animader-init/pacer && ulimit -c 0 && node examples/cookbook/run.mjs --no-build'
```

Real output:

```text
26/26 cases match
1/1 cases match
0 case(s) updated, 26 unchanged
```

`--json` printed a 26-element array and exited 0, with every `"ok"` true. Exit 0 means every case matched (`N/N cases match`). `--update` is the only way to change `expected.json`; with no drift it prints `0 case(s) updated, 26 unchanged`. Run one invocation at a time: they share `.zig-cache/cookbook`.

### One case by hand: `keys-scalar`

One host registry (`radius`, ncomp 1), two keys, default linear ease.

```sh
obs sh -c 'cd /home/agent/worktrees/animader-init/pacer && ulimit -c 0 && ./zig-out/bin/pacer check examples/cookbook/cases/keys-scalar/score.sjon --target radius'
obs sh -c 'cd /home/agent/worktrees/animader-init/pacer && ulimit -c 0 && ./zig-out/bin/pacer eval examples/cookbook/cases/keys-scalar/score.sjon --target radius --at 0 --at 1 --at 3'
obs sh -c 'cd /home/agent/worktrees/animader-init/pacer && ulimit -c 0 && ./zig-out/bin/pacer pack examples/cookbook/cases/keys-scalar/score.sjon --target radius --out /tmp/keys-scalar.pacb'
obs sh -c 'cd /home/agent/worktrees/animader-init/pacer && ulimit -c 0 && ./zig-out/bin/pacer ir examples/cookbook/cases/keys-scalar/score.sjon --target radius'
```

Real output excerpts (`frames[].writes[].value` for eval):

```text
examples/cookbook/cases/keys-scalar/score.sjon: no diagnostics
"value":[0.2]  "value":[0.5]  "value":[0.8]
"pack":{"out":"/tmp/keys-scalar.pacb","bytes":386,"sections":5,"targets":{"host":1,"declared":0},"pacm_bytes":128}
"transport":{"bpm":120,"beats_per_bar":4,...,"ticks_per_beat":180180,...},"scenes":[]
```

`--at` is repeatable with one value per flag; `--at 0 1 3` is a usage error (exit 2). A sweep uses `--from`, `--to` and `--fps` together; `--from 0 --to 3 --fps 1` gives t=0,1,2,3, endpoint included.

### Load the packed score in Node

From the repository root in the same `obs` shell:

```js
import { readFileSync } from "node:fs";
import { PacerRt } from "./npm/pacer/src/rt.js";
const rt = await PacerRt.load(
  readFileSync("npm/pacer/pacer-rt.wasm"),
  readFileSync("/tmp/keys-scalar.pacb"),
  { registries: [[{ name: "radius", ncomp: 1 }]] },
);
console.log("ok", rt.ok, "status", rt.status, "reason", rt.reason);
console.log(rt.eval(1));
```

```text
ok true status 0 reason 0
[ { name: 'radius', targetId: 0, registry: 0, ncomp: 1,
    value: Float32Array(4) [ 0.5, 0, 0, 0 ] } ]
```

`registries` is an array of registries, each an array of `{name, ncomp}`; the flat index is the `target_id` space. A flat list throws `TypeError: targets.map is not a function`.

### Troubleshooting

Without `--target`, `check` exits 1:

```text
examples/cookbook/cases/keys-scalar/score.sjon:6:16: error: unknown_target: unknown target `radius` -- not in any host registry
1 error, 0 warnings
```

The tool prints an em dash before `not`; it is written `--` here for ASCII.

`--at 0 1 3` exits 2 with:

```text
pacer: unexpected extra argument `1`
```

A silent `zig build` is cached: re-run it with `--summary all` and read `Build Summary: N/M steps succeeded` (cached run: `1/1`). Do not delete `.zig-cache` unless the summary names a stale step.

On the workspace host `sha256sum` reads stdin only, so a file argument hashes empty input. Pipe the bytes:

```text
$ sha256sum zig-out/bin/pacer
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
$ sha256sum < zig-out/bin/pacer
46de4d48a33ac76fb5445906f0558f43572d4e5ad6d33e0f108b699aff611e7b
```
