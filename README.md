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

## Layout

| Path | What |
|---|---|
| `src/` | the Zig driver — compile, eval, easing, tick math, WASM entry + boundary blobs |
| `schema/pacer.sjon` | the score schema (embedded, validates on wasm32-freestanding) |
| `corpus/` | golden determinism cases — `doc.sjon` + `times.sjon` + generated `expected.sjon` |
| `npm/pacer/` | the ESM JS glue around `pacer.wasm` (published package) |
| `examples/` | a browser demo (live editor → canvas + audio) |
| `tools/` | the diagnostic-coverage audit |

## Quickstart

pacer builds next to a sibling **SJON** checkout — clone it as `../SJON`
(unpublished, consumed by path, like pngine). Then:

```sh
zig build verify   # Zig tests + native golden corpus + node/wasm parity walk
```

Other verbs: `zig build fuzz` (never-panic harnesses), `zig build
audit-diagnostics` (every diagnostic code is tested), `zig build corpus --
--update` (regenerate goldens, then review the diff). See
[`CLAUDE.md`](./CLAUDE.md) for the full conventions.

Run the browser demo (serve from the repo root so the paths resolve):

```sh
zig build wasm
python3 -m http.server   # then open /examples/
```

## Using it from JS

The driver ships as an npm package — see
[`npm/pacer/README.md`](./npm/pacer/README.md) for install, the wasm-bytes
handshake, and the `Pacer` API.

## License

[CC0 1.0 Universal](./npm/pacer/LICENSE) — a public-domain dedication. Do
whatever you like with it, no attribution required.
