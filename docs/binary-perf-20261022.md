# Pacer binary performance — 2026-10-22 (Group C, plans 04/06)

**Status: measurement complete; the C6 decision point is an escalation, not
a proceed.** The frozen plan-04 blocker classes were evaluated against the
committed trees below. Class (b) — a frame-path latency regression beyond
measured noise — **fires** on both representative scores in the native
harness, and the supplementary real-WASM check confirms it on the
Meridian-shape score. Group D is **not started**; no `size-check` ratchet
exists or was created.

Every number here was measured on the environment record in §C1. Raw data
lives beside this report in `docs/perf-data-20261022/`; that directory's
`README.md` names each file and the reproduction commands. Nothing is
carried over from an earlier report row.

- **pacer:** `4d46a5a63e15b5fb4555a35eb7dc0bfce102c616` (`agent/animader-init`)
- **Group C start:** `f7fa639` (Group B exited, P3 accepted at `bb0ba56`)
- **SJON:** `c9a90d85ad0f9306f7c085048118db15248b5e3b`
- **Measurement source tree:** C2/C3 on `d2605e7`; C4/C5 on `4d46a5a`.
  The only difference is the C4 per-frame FNV parity check, which does not
  touch the timed loop. Artifacts are unchanged by both commits.

## C1 — environment record

Source: `docs/perf-data-20261022/environment.tsv`.

| Field | Value |
|---|---|
| Date (UTC) | 2026-10-22, measurements 13:05–13:29 |
| OS | `OpenBSD obs-dev.home.arpa 7.9 GENERIC.MP#15 amd64` |
| Kernel | `OpenBSD 7.9 (GENERIC.MP) #15: Sun Sep 27 02:47:36 MDT 2026` |
| CPU | Intel Core Processor (Skylake), 8 CPUs |
| RAM | 25,745,616,896 B (24 GiB), 4096 B pages |
| Zig | 0.16.0 |
| Optimize — shipped wasm | `ReleaseSmall`, `wasm32-freestanding` |
| Optimize — native C4/C5 harness | `ReleaseFast` native objects + harness |
| Node | v22.23.2 |
| gzip | 1.3.2 (OpenBSD `/usr/bin/gzip`) |
| brotli | 1.2.0 |
| Idleness | load average 0.82–1.34 on 8 CPUs before/after; `vmstat` 97–99% idle; no concurrent heavy job; runs serialized foreground |
| Clock caveat | `clock_gettime`/`performance.now` cost ~19–26 µs per call on this host (measured); C4 uses a calibrated `rdtsc` instead |
| TSC calibration | 2,304,003,676 Hz (Meridian run) / 2,303,992,869 Hz (all-features run) |

`C1` is the environment record for **every** table below. No historical
size or timing row is reused.

## C2 — size columns (raw / gzip9 / brotli11)

Method: per-file `animader/animader/.agent/releases/meridian.size.json`
convention — raw bytes plus each file's own encoded length at gzip level 9
and brotli quality 11 (`node:zlib`), not an archive and not a wire
measurement. Raw: `sizes.tsv`, `groups.tsv`, `scores.tsv`,
`meridian-program.tsv`, `c2-provenance.tsv`.

### Artifacts

| File | Label | Raw | gzip9 | brotli11 |
|---|---|---:|---:|---:|
| `zig-out/bin/pacer.wasm` | full driver, current HEAD, re-measured | 668,852 | 241,544 | 196,534 |
| `zig-out/bin/pacer-rt.wasm` | **full capability, binding** | 189,506 | 73,618 | 62,930 |
| `pacer-rt-pattern-free.wasm` | P2 trend rebuild, pattern-free, **incomplete/trend-only** | 171,667 | 66,764 | 57,746 |
| `pacer-rt-ablate-pacm.wasm` | Pacm-reader ablation (same recipe) | 184,858 | 71,085 | 60,935 |

The pattern-free column is a rebuild of pacer `aac3eda` (the P2 trend
commit) with the current host toolchain and sibling SJON, not the
historical binary and not a capability toggle on HEAD. It is trend-only:
the binding full-capability artifact is 189,506 / 73,618 / 62,930.

### The `Pacm` reader as its own row (controlled ablation)

Two builds differing **only** in reader inclusion, same HEAD `f7fa639`,
same ReleaseSmall recipe, separate caches, baseline rebuilt to the exact
full artifact (`4e2f2100…`):

| Build | Raw | gzip9 | brotli11 |
|---|---:|---:|---:|
| baseline (`Pacm.decode` + `Pacb.verifyRouting` present) | 189,506 | 73,618 | 62,930 |
| ablated (both return `null`, same file/recipe) | 184,858 | 71,085 | 60,935 |
| **measured delta** | **4,648** | **2,533** | **1,995** |

This is the marginal linked cost in this build (DCE cascade included), not
a standalone module size. The ablation changes acceptance (a packed score
with a PACM cannot load without the reader), so the reader's **load-time**
share is not separately attributable by this method; it is inside the C3
binary cold/warm rows and is not subtracted from any total.

### JS glue as shipped

| Group | Files | Raw | gzip9 | brotli11 |
|---|---:|---:|---:|---:|
| `index.js` alone | 1 | 16,452 | 5,909 | 5,121 |
| `index.js` + shared `pact.js`/`meta.js` | 3 | 31,824 | 11,414 | 9,910 |
| `rt.js` alone | 1 | 15,911 | 5,788 | 5,009 |
| `rt.js` + shared `pact.js`/`meta.js` | 3 | 31,283 | 11,293 | 9,798 |
| player glue: `rt.js` + pact/meta/route/lane/clock/audio | 7 | 39,075 | 15,008 | 12,919 |
| all published JS sources | 10 | 75,327 | 27,544 | 23,718 |
| published package file set (JS + types + both wasm + docs) | 34 | 992,422 | 365,557 | 302,395 |

The published `npm/pacer/pacer-rt.wasm` is the fresh 189,506 B artifact
(refreshed by the verify/A5 copy hook). The published
`npm/pacer/pacer.wasm` is **stale**: 666,873 B /
`97dc08e4…1f2ffc`, versus the current build's 668,852 B /
`9736a41b…6e3258`. No gate refreshes the driver copy; this is recorded,
not treated as a blocker.

### Representative score pair — Meridian (PACM duplication named)

| File | Raw | gzip9 | brotli11 |
|---|---:|---:|---:|
| `meridian/assets/score.sjon` | 2,657 | 598 | 528 |
| `score.pacb` (this exact score, host join `beat,scene,heroPos:2,heroTurn,heroTint:3`) | 11,361 | 1,236 | 1,094 |
| `'PACM'` embedded verbatim in that PACB (pack report) | 5,651 | — | — |

PACB embeds the metadata blob verbatim; the text path encodes `'PACM'` at
runtime. The container's +8,704 raw bytes over the text therefore include
a 5,651-byte metadata copy the text asset does not carry. The comparison is
read knowingly, not as a pure payload delta.

### Program totals (music excluded — the `musicPath` scoping convention)

| Set | Raw | gzip9 | brotli11 |
|---|---:|---:|---:|
| Meridian export: all files (cited release report) | 7,691,004 | 2,286,174 | 884,141 |
| Meridian export: music (excluded) | 6,912,140 | 2,001,312 | 648,634 |
| **Meridian export: program total, music excluded** | **778,864** | **284,862** | **235,507** |
| pacer-local: `rt.wasm` + rt glue + `score.pacb` | 232,150 | 86,147 | 73,822 |
| pacer-local: `pacer.wasm` + text glue + `score.sjon` | 703,333 | 253,556 | 206,972 |

The Meridian row is the release's own `size.json` sums, cited not
recompressed; the pacer-local rows are per-file sums from `sizes.tsv` and
`groups.tsv`. No audio file exists in the pacer-local set.

## C3 — load performance (real shipped WASM; the reference)

Method: **real-shipped-WASM artifact measurement**. `zig-out/bin/pacer.wasm`
and `pacer-rt.wasm` (the exact artifacts above), Node v22, wasm Module
compiled once, cold = fresh `WebAssembly` instance + the load call, warm =
second load on the live instance; text is `drv_load(doc)` (compile
included), binary is `prt_load(pacb)`. N = 50 per cell, **interleaved** and
order-alternated to decorrelate drift. Values are ns; divide by 1,000 for
µs. Median ± MAD and p10/p90. Raw: `load-samples.tsv`, `load-summary.tsv`,
`c3-provenance.tsv`.

| Score | Kind | Path | Median ± MAD | p10 | p90 |
|---|---|---|---|---:|---:|
| all-features | cold | text | 6,262,793 ± 3,271,637 | 3,060,158 | 51,983,866 |
| all-features | cold | binary | 6,522,044 ± 4,487,992 | 1,686,803 | 27,353,975 |
| all-features | warm | text | 308,977 ± 25,981 | 281,041 | 441,954 |
| all-features | warm | binary | 108,952 ± 9,777 | 99,175 | 174,044 |
| Meridian-minimal | cold | text | 3,824,779 ± 1,227,527 | 2,471,817 | 7,961,888 |
| Meridian-minimal | cold | binary | 2,167,869 ± 1,645,736 | 462,907 | 50,477,812 |
| Meridian-minimal | warm | text | 265,117 ± 20,114 | 244,165 | 357,028 |
| Meridian-minimal | warm | binary | 81,016 ± 13,130 | 69,003 | 161,193 |

Warm reload is faster on the binary path on both scores (binary median
~2.8–3.3× lower than text). Cold includes `WebAssembly.instantiate`, whose
variance dominates the cell (MAD 46–69% of the median); the raw samples and
p10/p90 are committed rather than summarized away. The text path's compile
is inside `drv_load`, as the protocol requires.

## C4 — eval latency and allocations (native harness; binding C4 instrument)

Method: **native-harness** measurement. `zig build perf-measure
-Doptimize=ReleaseFast` links the same production objects as
`native-composition` (`drv_*` from `wasm_entry.zig`, `prt_*` from
`rt_entry.zig`) through the std-only facades and points their
comptime-native allocator seam at a counting GPA. Per-frame time is an
`rdtsc` delta converted with the run-start `CLOCK_MONOTONIC` calibration
(`*.meta.tsv`); allocations are counted by the GPA. Both paths receive the
identical deterministic 100,000-frame script: monotonic run (scene + loop
wrap), scene seeks, non-monotonic revisits, wrap/hold crossings. Every
frame's `'PACW'` bytes are FNV-1a hashed on both paths and compared before
the raw data is written.

### Meridian-shape minimal (keys + expr + controls + 3 scenes, hold)

| Path | p50 | p95 | p99 | max | MAD | mean | alloc frames | total allocs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| text (µs) | 0.492 | 0.543 | 1.048 | 276.610 | 0.014 | 0.520 | 0 | 0 |
| binary (µs) | 0.833 | 0.924 | 1.400 | 622.693 | 0.014 | 0.868 | 0 | 0 |

### All-features (expr + pattern + controls + scenes + tempo + emit + trigger)

| Path | p50 | p95 | p99 | max | MAD | mean | alloc frames | total allocs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| text (µs) | 2.418 | 2.681 | 3.687 | 720.639 | 0.041 | 2.585 | 0 | 0 |
| binary (µs) | 2.776 | 3.204 | 4.518 | 709.899 | 0.057 | 2.978 | 0 | 0 |

Raw 100,000-frame files and summaries:
`meridian-minimal.{text,binary}.frames.tsv`,
`all-features.{text,binary}.frames.tsv`, `*.summary.tsv`, `*.meta.tsv`.
`max` includes scheduler pauses; p50/p95/p99 and the raw distribution are
the comparison.

### Supplementary real-shipped-WASM batch timing (not the C4 instrument)

1,000-frame batches (the host clock call is ~20 µs, so a per-call timer
would be the instrument), 100 batches, same script. Raw:
`*.wasm-eval.tsv`, `*.wasm-eval-raw.tsv`.

| Score | Path | p50 (ns/frame) | MAD | p95 | p99 |
|---|---|---:|---:|---:|---:|
| Meridian-minimal | text-wasm | 3,050.101 | 255.899 | 13,869.889 | 42,127.887 |
| Meridian-minimal | binary-wasm | 3,783.154 | 244.724 | 6,709.776 | 8,278.129 |
| all-features | text-wasm | 14,456.834 | 866.869 | 23,978.972 | 38,536.936 |
| all-features | binary-wasm | 14,499.855 | 717.966 | 18,100.026 | 29,125.704 |

The Meridian WASM batch confirms a binary slowdown of ~733 ns/frame
(+24.0%, beyond MAD); the all-features batch medians overlap within MAD, so
it is not independent confirmation there.

### Allocations and determinism

Both paths: **0 allocations in 100,000 frames** on both scores
(`alloc_frames 0`, `total_allocs 0`). Frame-byte hashes compare **100,000 /
100,000 equal** on each score (the harness fails the run on any mismatch).
No frame-path allocation and no nondeterminism the text path lacks was
observed.

## C5 — memory (same native harness)

Method: **native-harness counting GPA**, production `drv_load`/`prt_load`
and frame path. `peak_bytes` is live requested bytes at the phase peak;
`total_alloc_bytes` includes transient allocations freed before return.
Steady-state rows are 1,000 frames after the load. The `DecodedScore`
ownership row calls the production `pacer.Pacb.decode` with the same
counting GPA: it is the decode arena's copies (payloads, `'PACM'`, control
ids, canonical `'PACT'` bytes), i.e. the 02 P2 B3 line item; `deinit` is the
one free.

### Meridian-minimal

| Row | Status | Allocs | Frees | Total alloc B | Peak B | Live after B |
|---|---:|---:|---:|---:|---:|---:|
| text cold load | 0 | 248 | 234 | 1,248,376 | 517,294 | 517,294 |
| text warm reload | 0 | 43 | 43 | 719,992 | 517,294 | 517,294 |
| binary cold load | 0 | 5 | 0 | 1,623,602 | 1,623,602 | 1,623,602 |
| binary warm reload | 0 | 5 | 5 | 1,623,602 | 3,247,204 | 1,623,602 |
| text steady frame ×1000 | 0 | 0 | 0 | 0 | 517,294 | 517,294 |
| binary steady frame ×1000 | 0 | 0 | 0 | 0 | 1,623,602 | 1,623,602 |
| **DecodedScore ownership copy** | 0 | 2 | 0 | 10,804 | 10,804 | 10,804 |
| DecodedScore after deinit | 0 | 2 | 2 | 10,804 | 10,804 | 0 |

### All-features

| Row | Status | Allocs | Frees | Total alloc B | Peak B | Live after B |
|---|---:|---:|---:|---:|---:|---:|
| text cold load | 0 | 261 | 245 | 3,514,318 | 1,732,786 | 1,732,786 |
| text warm reload | 0 | 56 | 56 | 2,985,934 | 1,732,786 | 1,732,786 |
| binary cold load | 0 | 7 | 0 | 8,294,480 | 8,294,480 | 8,294,480 |
| binary warm reload | 0 | 7 | 7 | 8,294,480 | 16,588,960 | 8,294,480 |
| text steady frame ×1000 | 0 | 0 | 0 | 0 | 1,732,786 | 1,732,786 |
| binary steady frame ×1000 | 0 | 0 | 0 | 0 | 8,294,480 | 8,294,480 |
| **DecodedScore ownership copy** | 0 | 3 | 0 | 21,472 | 21,472 | 21,472 |
| DecodedScore after deinit | 0 | 3 | 3 | 21,472 | 21,472 | 0 |

The all-features binary cold load's ~8.29 MB is the prepared pattern state
(one decode per pattern track plus the load-time dry-run scratch), not the
`DecodedScore` copy row (21,472 B). Warm binary peak is the transactional
old+new overlap (16,588,960 B). No steady-state frame allocates on either
path.

## C6 — blocker evaluation and decision point

The three pre-declared classes from `04:87-92`, verbatim:

**(a) any parity failure of any class.** **Does not fire.** The C4 harness
compared 100,000/100,000 frame hashes per score; the committed parity gate
is 24 clean non-pattern + 5 clean pattern replayed (binary leg) + 15
load-failing, **skipped 0**, 0 failed (see §Gates).

**(b) any frame-path allocation or latency REGRESSION beyond measured
noise (median ± MAD over N=50/100k frames, same machine).** **FIRES.**

- Meridian-minimal: text 492 ± 14 ns vs binary 833 ± 14 ns; **+341 ns
  (+69.3%)**. The median ± MAD intervals [478, 506] and [819, 847] are
  disjoint.
- All-features: text 2,418 ± 41 ns vs binary 2,776 ± 57 ns; **+358 ns
  (+14.8%)**. Intervals [2,377, 2,459] and [2,719, 2,833] are disjoint.
- No frame-path allocation was observed on either path (0/100,000 both).
- Supplementary real-WASM: Meridian +733 ns/frame (+24.0%), intervals
  [2,794, 3,306] and [3,538, 4,028] disjoint. All-features WASM medians
  overlap within MAD (no independent confirmation there).

**(c) a non-determinism the text path doesn't have.** **Does not fire.**
Both paths produced byte-identical frames at all 100,000 scripted times on
both scores (FNV-1a equality, enforced by the harness), and neither path
allocated on the frame path.

**Verdict.** Class (b) fires. Per the frozen plan: **stop, do not start
Group D, escalate with evidence.** This report does not carry the
2026-10-20 authorization into D; the parent/user decides whether to fix
the binary eval leaf (the constant ~340–360 ns/frame delta is consistent
with the binary expr/pattern leaf work on the measured scores) or to
accept it by an explicit ruling. No `zig build size-check` verb exists and
none was created; no numeric budget, ratchet or threshold was invented.

## C7 — pacer-local vertical smoke (04 P3)

Added under `examples/player/`:

- `index.html` — the page; fetches `./score.pacb` and
  `../../npm/pacer/pacer-rt.wasm`, loads through `PacerRt.load` with the
  exact pack-time flat join (`beat, heroPos:2, heroTurn, heroTint`), shows
  `eval(0)` before the clock, drives `eval(t)` from `perfClock()`, and
  routes writes through the unchanged `npm/pacer/src/route.js`.
- `player.mjs` — the host clock + render loop; `Restart` calls
  `driver.load(pacb)` (successful reload tears down held state) and
  re-applies the held `hero-speed` control.
- `score.pacb` / `score.sjon` — the committed fixture and its source.
- `check.mjs` — the no-browser proof: binary load, registry join, meta
  track names, control id, `eval(0)` values, a live control reaching the
  `heroTint` expression, and reload/reset/re-apply. Result:
  `C7 PASS: load=0 tracks=beat,heroPos,heroTurn,heroTint
  controls=hero-speed eval(0)=4 entries heroTint=0.5 scene-seek=0.7000`.
- `README.md` — the parent-runnable server command:
  `python3 -m http.server 8073 --directory .`, then
  `http://localhost:8073/examples/player/`.

**No browser result is claimed here.** The actual browser pass is the
parent's browser-tester's, against a parent-started server. There is no
repository gate dedicated to `examples/`; `node examples/player/check.mjs`
and the browser pass are the C7 evidence, and no gate was invented.

## Gates (committed source tree `4d46a5a`, cold caches)

OpenBSD `obs`, foreground, `ulimit -c 0 && ulimit -s 32768`, new cache
`.agent/control/cache-c-final-gates`:

```
zig build test verify cli-golden parity fuzz audit-rt-imports --summary all
```

**EXIT 0** — Build Summary **56/56 steps**, **1238/1238 tests** (847 native
+ 391 fuzz), node **182 pass / 0 fail / 0 skipped**, corpus **44/0**,
parity **24 non-pattern + 5 pattern replayed + 15 load-failing, skipped 0,
0 failed**, negatives **68 named + 3 bad-call + 3700 prefix + 4 positive =
3775 attempted / 81 names**, audit closure **12 pacer + 18 SJON** (16
linked, 2 comptime-excluded), `cli-golden` and `score-docs` current, tree
clean afterwards except the pre-existing untracked `zig-pkg/`. Log:
`.agent/control/prod-four-c-final-gates.log`.

npm gates in `npm/pacer`:

- `npm run typecheck` — exit 0 on obs.
- `npm test` — exit 0, **182/182, 0 failed, 0 skipped** on obs (pretest
  rebuilt the wasm and fixtures).
- `npm run lint` — the Biome CLI ships no OpenBSD binary (exit 1 on obs,
  platform message). Re-run with the pinned toolchain on Linux as the A5
  precedent: `npm exec --yes --package=@biomejs/biome@2.5.0 -- biome check
  src test tools browser playwright.config.js` — exit 0, **31 files
  checked**. No npm/pacer source was changed by Group C.

Logs: `prod-four-c-final-npm-obs.log`,
`prod-four-c-final-npm-lint-linux.log`.

Artifacts after the gate (python3 hashlib and openssl agree):
`zig-out/bin/pacer.wasm` 668,852 B
`9736a41b61e2fa4ae2e37388bd36d8953fcdd41feb465d5805125867706e3258`;
`zig-out/bin/pacer-rt.wasm` 189,506 B
`4e2f2100fecc1e7a4657261867a26993c1e3e98bc3a29c4a319fab730b792515`.
Both are unchanged by Group C; the wasm seam is comptime-dead.

## Honest limits

- **Native vs shipped.** C4/C5's binding instrument is the native
  `ReleaseFast` production composition, as IM-5 approves. It is not the
  wasm artifact. The supplementary real-WASM batch confirms the Meridian
  regression but not all-features; the report does not claim otherwise.
- **Load noise.** The C3 cold cell includes `WebAssembly.instantiate`,
  whose MAD is 46–69% of the median. Raw samples and p10/p90 are committed;
  cold medians should be read with that spread.
- **One machine, no isolation.** Single OpenBSD host, load average
  0.82–1.34, no CPU pinning or real-time scheduling. The per-frame p50/MAD
  intervals are the reproducible noise statement the plan asks for.
- **Clock.** The host's clock call is ~19–26 µs; C4 uses calibrated
  `rdtsc` (2.304 GHz, calibrated against `CLOCK_MONOTONIC` at run start),
  not the event-loop clock. The timer overhead is well below the measured
  330–360 ns delta but is not zero.
- **Pacm row.** The ablation measures linked bytes; it cannot load, so its
  load-time share is inside the binary C3 rows, not separately attributed.
- **Pattern-free column.** Rebuilt P2 source with the current toolchain,
  labeled incomplete/trend-only; the binding artifact is full capability.
- **Published driver copy.** `npm/pacer/pacer.wasm` is stale (666,873 B);
  only `pacer-rt.wasm` is refreshed by the current verify hook. Recorded,
  not repaired (out of Group C scope).
- **GitNexus.** No GitNexus MCP tools or runner are present in this
  session (no index/`run.cjs`; CLI `MODULE_NOT_FOUND`), so graph impact
  and `detect_changes` coverage is unavailable; source-level review and the
  gate suite stand in.
- **C7 browser.** Not run here; parent browser-tester owns it.

## What remains for D

D1–D4 remain unstarted. They are blocked by the class-(b) escalation in
this report, not by missing measurement: the binding artifact sizes, load
samples, eval distributions, allocations, memory rows and the pacer-local
page all exist. A parent/user ruling on the measured binary eval
regression is the next decision point; no D work began, no push/merge/
publish occurred, and no numeric ratchet was created.
