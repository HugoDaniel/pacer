# Raw measurement data — 2026-10-22 (plan 06 Group C)

Companion raw data for `docs/binary-perf-20261022.md`. Environment record:
`environment.tsv`. All paths are repo-relative; the measurements ran on
OpenBSD `obs`. C2/C3 ran on pacer `d2605e7`; the C4/C5 rows below come from
the parity-enforced harness at pacer `7a20d0b` (SJON `c9a90d85`). The
harness compares every text/binary frame hash and length after both timed
sweeps and aborts before writing any TSV on divergence.

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
  `frame, t_seconds, ns, allocs, frees, bytes, frame_len, fnv1a64`.
  `ns` is `rdtsc` delta converted with the run's calibrated TSC rate
  (`*.meta.tsv`). `fnv1a64` is the per-frame FNV-1a hash of the emitted
  `'PACW'` bytes — the frame-parity evidence column; `frame_len` is its
  companion. The harness enforces equality on both before writing.
- `meridian-keys-only.{text,binary}.frames.tsv` — the supplementary
  attribution control (same shape, no expr track; see
  `keys-only-provenance.tsv`). These are **not** binding C4 rows.
- `*.summary.tsv` — p50/p95/p99/max, MAD, mean, alloc_frames, total_allocs.
- `*.memory.tsv` — cold/warm load, 1,000 steady frames, and the
  `DecodedScore` ownership-copy row (production `Pacb.decode` with the
  counting GPA).
- `*.wasm-eval.tsv` / `*.wasm-eval-raw.tsv` — supplementary real-shipped
  WASM batch timing (1,000-frame batches; the binding C4 instrument is the
  native harness).
- Fixtures: `fixtures/all-features.pacb`, `fixtures/meridian-minimal.pacb`,
  `fixtures/meridian-keys-only.pacb`, `fixtures/meridian.score.{sjon,pacb}`,
  and the minimal score sources.

## Reproduction commands (on obs)

```sh
PACER_PERF_FIXTURES=docs/perf-data-20261022/fixtures \
  node tools/measure_load.mjs docs/perf-data-20261022

# C4/C5 binding rows (parity enforced before any TSV is written)
zig build perf-measure -Doptimize=ReleaseFast -- \
  --score meridian-minimal \
  --doc tools/testdata/perf/meridian-minimal.score.sjon \
  --pacb docs/perf-data-20261022/fixtures/meridian-minimal.pacb \
  --target beat --target heroPos:2 --target heroTurn --target heroTint \
  --out .agent/control/cache-c4 --frames 100000

zig build perf-measure -Doptimize=ReleaseFast -- \
  --score all-features \
  --doc corpus/all-features/doc.sjon \
  --pacb docs/perf-data-20261022/fixtures/all-features.pacb \
  --target beat --target bpm --target radius --target blend --target pat \
  --target grid --target hit --target level --target sweep --target dropx \
  --target pulse:4 --out .agent/control/cache-c4 --frames 100000

# Supplementary attribution control (not a binding C4 row)
zig build perf-measure -Doptimize=ReleaseFast -- \
  --score meridian-keys-only \
  --doc tools/testdata/perf/meridian-keys-only.score.sjon \
  --pacb docs/perf-data-20261022/fixtures/meridian-keys-only.pacb \
  --target beat --target heroPos:2 --target heroTurn --target heroTint \
  --out .agent/control/cache-c4 --frames 100000
```

The size script takes the ablation artifacts as its optional arguments; see
`c2-provenance.tsv`.
