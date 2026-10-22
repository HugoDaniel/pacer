# Raw measurement data — 2026-10-22 (plan 06 Group C)

Companion raw data for `docs/binary-perf-20261022.md`. Environment record:
`environment.tsv`. All paths are repo-relative; the measurements ran on
OpenBSD `obs` (pacer `d2605e7`, SJON `c9a90d85`).

## Size (C2)

- `sizes.tsv` — every measured file: raw / gzip9 / brotli11.
- `groups.tsv` — JS glue closures and the published package file set.
- `scores.tsv` — the real Meridian `score.sjon` vs `score.pacb` pair.
- `meridian-program.tsv` — Meridian export totals with `musicPath`
  excluded, plus the pacer-local program totals (no music exists there).
- `c2-provenance.tsv` — method and ablation provenance.
- `fixtures/ablations/pacer-rt-pattern-free.wasm` — rebuilt from pacer
  `aac3eda` (P2 trend) with the current toolchain/SJON; pattern capability
  absent; **incomplete/trend-only**.
- `fixtures/ablations/pacer-rt-ablate-pacm.wasm` — HEAD `f7fa639` with only
  `Pacm.decode` and `Pacb.verifyRouting` stubbed (same recipe/cache).

## Load (C3)

- `load-samples.tsv` — 50 cold + 50 warm samples per path per score,
  interleaved. `load-summary.tsv` — median, MAD, p10, p90, min, max.
- `c3-provenance.tsv`.

## Eval and memory (C4/C5)

- `meridian-minimal.{text,binary}.frames.tsv` and
  `all-features.{text,binary}.frames.tsv` — 100,000 rows each:
  `frame, t_seconds, ns, allocs, frees, bytes, frame_len`.
  `ns` is `rdtsc` delta converted with the run's calibrated TSC rate
  (`*.meta.tsv`).
- `*.summary.tsv` — p50/p95/p99/max, MAD, mean, alloc_frames, total_allocs.
- `*.memory.tsv` — cold/warm load, 1,000 steady frames, and the
  `DecodedScore` ownership-copy row (production `Pacb.decode` with the
  counting GPA).
- `*.wasm-eval.tsv` / `*.wasm-eval-raw.tsv` — supplementary real-shipped
  WASM batch timing (1,000-frame batches; the binding C4 instrument is the
  native harness).
- Fixtures: `fixtures/all-features.pacb`, `fixtures/meridian-minimal.pacb`,
  `fixtures/meridian.score.{sjon,pacb}`, and the minimal score source.

## Reproduction commands (on obs)

```sh
PACER_PERF_FIXTURES=docs/perf-data-20261022/fixtures \
  node tools/measure_load.mjs docs/perf-data-20261022

zig build perf-measure -Doptimize=ReleaseFast -- \
  --score meridian-minimal \
  --doc tools/testdata/perf/meridian-minimal.score.sjon \
  --pacb docs/perf-data-20261022/fixtures/meridian-minimal.pacb \
  --target beat --target heroPos:2 --target heroTurn --target heroTint \
  --out /tmp/c4 --frames 100000
```

The size script takes the ablation artifacts as its optional arguments; see
`c2-provenance.tsv`.
