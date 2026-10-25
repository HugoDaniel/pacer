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
- **Playback runtime** (`@mr_hugo/pacer/rt`, `pacer-rt.wasm`). `PacerRt` evaluates a
  precompiled `'PACB'` cartridge with no parser or compiler compiled in. It
  exposes the same write frames, controls, BPM and metadata surface, plus
  transactional `load` status (`status` / `reason`).
- **Offline packing.** The native `pacer` CLI's `pack` verb compiles a score
  and its target registries into a `.pacb` file for `PacerRt`. The CLI also
  provides `check`, `ir` and `eval`.
- **Routing, clock and audio glue.** `@mr_hugo/pacer/route` splits write entries across
  visual (registry 0) and audio (registry 1) buses; `@mr_hugo/pacer/clock` samples a
  host master clock; `@mr_hugo/pacer/audio` provides the `AudioTargetHost` boundary and
  `clockOnlyHost` (alias `sointuHost`); `@mr_hugo/pacer/host-check` is the executable
  host conformance kit.
- **Both wasm assets.** `@mr_hugo/pacer/pacer.wasm` (text driver) and
  `@mr_hugo/pacer/pacer-rt.wasm` (playback runtime) are published as package subpaths.
- **Score language.** Keyframe tracks with composable easing, `:expr` tracks,
  `:pattern` tracks, trigger lanes, scenes, controls, transport emit lanes,
  tempo segments and compose-mode target declarations. See
  `docs/score-language.md` in the repository.

### Install

The package publishes publicly to npm as `@mr_hugo/pacer`. The unscoped name
`pacer` is already taken on npmjs, so the scope keeps this package distinct:

```sh
npm install @mr_hugo/pacer@0.1.0
```

The package is ESM-only and requires Node >= 20 or a browser with WebAssembly
support. It ships JavaScript source, generated `.d.ts` declarations and the
two wasm binaries. `Pacer.load` never fetches wasm for you: resolve the
`@mr_hugo/pacer/pacer.wasm` / `@mr_hugo/pacer/pacer-rt.wasm` subpaths and pass the bytes or a
compiled `WebAssembly.Module`.

### Building the CLI from source

`npm install @mr_hugo/pacer` does **not** install the native `pacer` CLI. The source
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
At preparation time, the release registry probe returned no published `0.1.0` or `0.2.0` package.
