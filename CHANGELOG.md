# Changelog

## 0.1.0 — 2026-10-25

The first public release of Pacer: a deterministic animation and parameter
driver conducted by an SJON score.

### Shipped

- **Compiler and evaluator** (`pacer`). `Pacer.load` compiles score text
  against host target registries; `eval` / `evalTicks` / `evalBytes` sample
  the compiled score at host-supplied time. Controls, BPM overrides, metadata
  and expression failure counts are part of the same surface:
  `setControl` / `clearControl` / `registerControl`, `setBpm`, `meta`,
  `exprFailures`.
- **Playback runtime** (`pacer/rt`, `pacer-rt.wasm`). `PacerRt` evaluates a
  precompiled `'PACB'` cartridge with no parser or compiler compiled in. It
  exposes the same write frames, controls, BPM and metadata surface, plus
  transactional `load` status (`status` / `reason`).
- **Offline packing.** The native `pacer` CLI's `pack` verb compiles a score
  and its target registries into a `.pacb` file for `PacerRt`. The CLI also
  provides `check`, `ir` and `eval`.
- **Routing, clock and audio glue.** `pacer/route` splits write entries across
  visual (registry 0) and audio (registry 1) buses; `pacer/clock` samples a
  host master clock; `pacer/audio` provides the `AudioTargetHost` boundary and
  `clockOnlyHost` (alias `sointuHost`); `pacer/host-check` is the executable
  host conformance kit.
- **Both wasm assets.** `pacer/pacer.wasm` (text driver) and
  `pacer/pacer-rt.wasm` (playback runtime) are published as package subpaths.
- **Score language.** Keyframe tracks with composable easing, `:expr` tracks,
  `:pattern` tracks, trigger lanes, scenes, controls, transport emit lanes,
  tempo segments and compose-mode target declarations. See
  `docs/score-language.md` in the repository.

### Install

The package is unscoped and lives on the self-hosted registry, so name the
registry explicitly:

```sh
npm install pacer@0.1.0 --registry=https://git.hugodaniel.com/api/packages/hugo/npm/
```

Or persist it in a project `.npmrc`:

```ini
registry=https://git.hugodaniel.com/api/packages/hugo/npm/
```

The package is ESM-only and requires Node >= 20 or a browser with WebAssembly
support. It ships JavaScript source, generated `.d.ts` declarations and the
two wasm binaries. `Pacer.load` never fetches wasm for you: resolve the
`pacer/pacer.wasm` / `pacer/pacer-rt.wasm` subpaths and pass the bytes or a
compiled `WebAssembly.Module`.

### Building the CLI from source

`npm install pacer` does **not** install the native `pacer` CLI. The source
release lives at <https://github.com/HugoDaniel/pacer>. Build it from a Pacer
checkout with:

- Zig **0.16.0**
- sibling SJON **1.5.0 or newer** (release pin: `v1.5.0`, revision
  `97e12f39d9e63d028aa9b124660cc4cfed4cc726`)

```sh
git clone https://git.hugodaniel.com/hugo/SJON.git ../SJON
git -C ../SJON checkout 97e12f39d9e63d028aa9b124660cc4cfed4cc726
zig build cli          # → zig-out/bin/pacer
zig build verify       # Zig tests + golden corpus + node/wasm parity
```

Prebuilt native CLI downloads are not part of this release.

### Known limitations

- This is a 0.x release. The wire surfaces are append-only and gated, but the
  project makes no 1.0 stability claim.
- The published npm package contains no native binary and no CLI.
- The browser proof is headless Chromium through the sibling pngine checkout.
  Real Safari, real hidden-tab behaviour and PCM-content verification were not
  exercised in the recorded production-delivery evidence.
- Source builds need the sibling SJON checkout (1.5.0+). Browser/bundle gates
  additionally need the sibling pngine checkout and its Playwright install.
- The golden corpus and native/wasm parity prove deterministic writes, not
  rendering or audio output.

### Version note

The repository previously carried `0.2.0` version declarations. This release
moves the declarations, lockfile and package metadata to `0.1.0` together.
The release registry probe returned no published `0.1.0` or `0.2.0` package.
