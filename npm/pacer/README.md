# pacer

JS glue for **pacer.wasm** — a deterministic animation driver conducted by an
[SJON](https://git.hugodaniel.com/hugo/SJON) score.

The driver is a pure function of time: write a score plus your target registries
in, call `eval(seconds)` per frame, read packed `(target, value)` writes back. It
never reads a clock, owns no loop, and never touches the GPU or audio graph.
Same document + same time ⇒ byte-identical writes, in the browser and natively.

ESM-only. Ships JavaScript source + generated `.d.ts` types + `pacer.wasm`
(the score-text driver) and `pacer-rt.wasm` (the playback runtime).

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

## Playback runtime

`pacer/rt` ships `PacerRt`: the same evaluator without the compiler. Pack a
score offline with `pacer pack`, ship the resulting `.pacb` bytes, and load
them against the matching host registries. **The npm package does not include
the `pacer` CLI binary**; build it from the repo source with `zig build cli`
(Zig 0.16.0 and sibling SJON 1.5.0+ — see `docs/cli.md` in the repo).

```js
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { perfClock } from 'pacer/clock';
import { PacerRt } from 'pacer/rt';

const wasm = await readFile(fileURLToPath(import.meta.resolve('pacer/pacer-rt.wasm')));
const pacb = await readFile('score.pacb');
const player = await PacerRt.load(wasm, pacb);

const clock = perfClock();
const entries = player.eval(clock()); // same 'PACW' entries as Pacer
```

There is **no `reload(text)`** — the runtime has no parser. `load(pacbBytes)`
is the only load verb, and a refused load is transactional: the old score and
its held control/BPM state stay live, so inspect `status` / `reason` for the
load outcome instead of dropping playback.

Binary metadata preserves the `'PACM'` spans, and scene names ride the
blob's `'SNAM'` section — they decode exactly, no source text needed.
A blob without `'SNAM'` (pre-SNAM cartridges) falls back to the source
slice each `nameSpan` anchors, so its names are `''`. Declared-only
target names are `null` because `'DECL'` carries registry/ncomp, never
names. Route those writes by `registry`.

## Exports

| Import | Provides |
|---|---|
| `pacer` | `Pacer` — `load`, `reload`, `eval` / `evalTicks` / `evalBytes`, `meta`, `setControl` / `clearControl` / `registerControl`, `setBpm`, `exprFailures` |
| `pacer/rt` | `PacerRt` — `load` (packed `.pacb` only), `eval` / `evalTicks` / `evalBytes`, `meta`, controls, `setBpm`, `exprFailures`, `status` / `reason` |
| `pacer/route` | `toUniforms`, `routeWrites` — split write entries across registries |
| `pacer/clock` | `perfClock`, `masterClock` — sample the master clock (audio masters when playing) |
| `pacer/audio` | `clockOnlyHost` (alias `sointuHost`), `paramRegistry`, `applyParams` — the `AudioTargetHost` boundary |
| `pacer/host-check` | `checkAudioTargetHost` — the host conformance kit, for consumers' test suites |
| `pacer/pacer.wasm` | the score-text driver binary asset |
| `pacer/pacer-rt.wasm` | the playback runtime binary asset |

## The audio engine contract

pacer knows **registries, params, and one clock — never engines.** An audio
host is exactly three methods (`pacer/audio`'s `AudioTargetHost`):

```
params()   → [{ name, ncomp?, min?, max?, default? }]   // the animatable surface
setParam(name, value)                                    // total: never throws
clock()    → null | { seconds, playing }                 // null = someone else masters
```

There is no `timeline()`, no engine metadata, no capability negotiation:
**tempo and timeline truth travel as score text** — `(transport …)` /
`(tempo …)` forms, generated skeletons — never as a runtime host query.
Capability differences surface through `params()` content alone: an engine
exposes what it honestly controls, a score is engine-relative by construction
(its registry-1 targets resolve against whatever the active host declares;
unresolved names are the ordinary `unknown_target` diagnostic).

`checkAudioTargetHost(host, { expectClock }) → findings[]` (`pacer/host-check`)
is the executable statement of that contract — pure, never throws, empty array
= conformant. Run it inside your host's own test suite.

One contract, three delivery footprints:

1. **Prerendered wasm-song** — a self-rendering synth binary (KB-scale);
   clock-only.
2. **Module + live engine** — real params + a clock; the param surface is the
   score's registry 1.
3. **PCM bounce** — rendered audio (a WAV, an `<audio>` element); clock-only,
   zero engine risk — how a demo ships bit-pinned sound.

Modes 1 and 3 are `clockOnlyHost(player)`: any `currentTime`/`playing` surface
becomes a conformant host with an empty registry. It was published as
`sointuHost` (the first such player); both names stay exported.

### Host matrix

| Host | `params()` | `clock()` | Master | Where |
|---|---|---|---|---|
| `clockOnlyHost` (alias `sointuHost`) | empty — the asset is pre-rendered (Sointu `pNGa` song, batida/audzio bounce PCM) | player time | audio | `pacer/audio` (shipped) |
| `chiptuneHost` | volume/tempo/pitch (`ch<N>.*` blocked upstream) | null | rAF (studio) | pngine studio (shipped) |
| `batidaHost` | `gain`, `ch<N>.gain/mute`, `separation` — no tempo/pitch by batida's timeline-invariance rule | frames/rate | audio | batida glue (planned) |
| audzio graph | every AudioParam in the loaded `(audio-graph …)` | context time | audio | future (audzio set) |

## Develop

This package is the JS half of the [pacer](https://git.hugodaniel.com/hugo/pacer)
repo; `pacer.wasm` is built from the Zig sources by Zig **0.16.0** with a
sibling SJON **1.5.0 or newer** checkout at `../SJON` (the 0.1.0 release pin
is `v1.5.0`, revision `97e12f39d9e63d028aa9b124660cc4cfed4cc726`).

```sh
git clone https://git.hugodaniel.com/hugo/SJON.git ../SJON
git -C ../SJON checkout 97e12f39d9e63d028aa9b124660cc4cfed4cc726
npm ci             # JS dev dependencies
npm run build      # zig build wasm + wasm-rt → copy both in → emit .d.ts (types/)
npm run typecheck  # tsc --noEmit over the JSDoc-typed source
npm run lint       # biome check src test browser (lint + format, read-only)
npm run format     # biome check --write src test browser (apply fixes)
npm test           # node --test (rebuilds the wasm first); incl. corpus parity
```

### G5 browser-proof fixture (`browser/`)

A diagnostic Operate/Read page that proves a served PNG bundle →
pngine's public `payloadsOf` → a source-free `PacerRt`, passively
verifying every fetched byte against a digest manifest. The served
root is an isolated, gitignored webroot — never this package's tree.

```sh
npm run g5:prepare   # author + pack the fixtures via the fresh CLIs and
                     # build .agent/artifacts/g5-web (needs zig + the
                     # sibling pngine CLI — runs on the wave host)
npm run g5:serve     # serve the prepared webroot on http://127.0.0.1:8046/
                     # (flags: --port N --root DIR --host H)
npm run g5:test      # node --test over browser/g5/*-spec.mjs (server +
                     # builder specs; builder legs need the wave host)
npm run test:browser # playwright via the sibling pngine install
                     # (browser/g5/bundle-names.spec.js)
```

`browser/g5/expected.json` is the hand-authored oracle (names, ticks,
supplied-time writes); nothing in the fixture is sampled from a run.
The G5 node specs are named `*-spec.mjs` so `npm test`'s autodiscovery
and playwright's default testMatch never pick them up.

`npm publish` rebuilds `pacer.wasm` fresh and runs the full gate before it
packs: `prepublishOnly` runs `lint` + `typecheck` + `test`, then `prepack` runs
`build` (so the published `pacer.wasm` is always freshly compiled from source).
`publishConfig.registry` targets the self-hosted Gitea registry, so a bare
`npm publish` from `npm/pacer/` lands in the right place.

## License

[CC0 1.0 Universal](./LICENSE) — a public-domain dedication. Do whatever you
like with it, no attribution required.
