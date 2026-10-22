# Perf measurement fixtures (plan 06 Group C)

`meridian-minimal.score.sjon` is the C4/C5 Meridian-shape representative
(keys + expr + controls + three named scenes on a hold transport). Pack it
against the flat join used by the harness and examples/player:

```sh
zig build run -- pack tools/testdata/perf/meridian-minimal.score.sjon \
  --target beat --target heroPos:2 --target heroTurn --target heroTint \
  --out .agent/control/cache-c/fixtures/meridian-minimal.pacb
```

The all-features representative is `corpus/all-features/doc.sjon`, packed
against the `times.sjon` join in flat order:

```sh
zig build run -- pack corpus/all-features/doc.sjon \
  --target beat --target bpm --target radius --target blend --target pat \
  --target grid --target hit --target level --target sweep --target dropx \
  --target pulse:4 --out .agent/control/cache-c/fixtures/all-features.pacb
```

The measurement scripts accept `PACER_PERF_FIXTURES=<dir>` for the PACB
pair. `tools/measure_size.mjs` reports the real Meridian export score pair
(`animader/animader/.agent/releases/meridian/assets/score.sjon`, packed with
`beat, scene, heroPos:2, heroTurn, heroTint:3`).
