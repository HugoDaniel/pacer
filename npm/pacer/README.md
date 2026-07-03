# pacer

JS glue for **pacer.wasm** — a deterministic animation driver conducted by an
[SJON](https://git.hugodaniel.com/hugo/SJON) score.

The driver is a pure function of time: write a score plus your target registries
in, call `eval(seconds)` per frame, read packed `(target, value)` writes back. It
never reads a clock, owns no loop, and never touches the GPU or audio graph.
Same document + same time ⇒ byte-identical writes, in the browser and natively.

ESM-only. Ships JavaScript source + generated `.d.ts` types + `pacer.wasm`.

## Install

`pacer` publishes to a self-hosted registry, and it's unscoped (no per-scope
route), so point npm at the registry for this install:

```sh
npm install pacer --registry=https://git.hugodaniel.com/api/packages/hugo/npm/
```

Or persist it in a project `.npmrc`:

```ini
registry=https://git.hugodaniel.com/api/packages/hugo/npm/
```

## You supply the wasm bytes

The package ships `pacer.wasm`, but the driver never fetches it for you — you
pass the bytes (or a compiled `WebAssembly.Module`) to `Pacer.load`. Resolve the
shipped binary via the `pacer/pacer.wasm` subpath:

```js
// Browser (bundler) — import the asset URL, then fetch it. Use your
// bundler's URL suffix/loader: Vite/webpack `?url`, esbuild `file`, …
import wasmUrl from 'pacer/pacer.wasm?url';
const wasm = await fetch(wasmUrl).then((r) => r.arrayBuffer());
```

```js
// Node — resolve the subpath to a file path, then read the bytes:
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
const wasm = await readFile(fileURLToPath(import.meta.resolve('pacer/pacer.wasm')));
```

Without a bundler, a browser can't resolve the bare `pacer/pacer.wasm`
specifier at runtime — `new URL('pacer/pacer.wasm', import.meta.url)` is a
*relative-URL* resolution against your module's URL, **not** package
resolution, so it points at the wrong place. Map the specifier through an
import map, or hand `Pacer.load` an explicit URL you control.

## Usage

```js
import { Pacer } from 'pacer';
import { perfClock } from 'pacer/clock';
import { toUniforms } from 'pacer/route';

const score = `(transport :bpm 120)
(track :target radius (key :at 0b :value 0) (key :at 4b :value 1))`;

const pacer = await Pacer.load(wasm, score, {
  registries: [
    [{ name: 'radius', ncomp: 1 }], // registry 0 — visual bus
    [],                             // registry 1 — audio bus
  ],
});
if (!pacer.ok) console.error(pacer.diagnostics);

const clock = perfClock();
(function frame() {
  const entries = pacer.eval(clock());
  if (entries) {
    const uniforms = toUniforms(entries, 0); // { radius: 0.5 }
    // → hand uniforms to pngine / your renderer
  }
  requestAnimationFrame(frame);
})();
```

## Exports

| Import | Provides |
|---|---|
| `pacer` | `Pacer` — `load`, `reload`, `eval` / `evalTicks` / `evalBytes`, `meta`, `setControl` / `clearControl` / `registerControl`, `setBpm`, `exprFailures` |
| `pacer/route` | `toUniforms`, `routeWrites` — split write entries across registries |
| `pacer/clock` | `perfClock`, `masterClock` — sample the master clock (audio masters when playing) |
| `pacer/audio` | `sointuHost`, `paramRegistry`, `applyParams` — the `AudioTargetHost` boundary |
| `pacer/pacer.wasm` | the driver binary asset |

## Develop

This package is the JS half of the [pacer](https://git.hugodaniel.com/hugo/pacer)
repo; `pacer.wasm` is built from the Zig sources by Zig 0.16.

```sh
npm run build      # zig build wasm → copy in → emit .d.ts (types/)
npm run typecheck  # tsc --noEmit over the JSDoc-typed source
npm run lint       # biome check src test (lint + format, read-only)
npm run format     # biome check --write src test (apply fixes)
npm test           # node --test (rebuilds the wasm first); incl. corpus parity
```

`npm publish` rebuilds `pacer.wasm` fresh and runs the full gate before it
packs: `prepublishOnly` runs `lint` + `typecheck` + `test`, then `prepack` runs
`build` (so the published `pacer.wasm` is always freshly compiled from source).
`publishConfig.registry` targets the self-hosted Gitea registry, so a bare
`npm publish` from `npm/pacer/` lands in the right place.

## License

[CC0 1.0 Universal](./LICENSE) — a public-domain dedication. Do whatever you
like with it, no attribution required.
