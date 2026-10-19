# binary 03 — playback parity: one score, two load paths, identical bytes

**Repos:** pacer
**Wire impact:** none (test architecture only).
**Gates:** new `zig build parity` (proposed; created by P1) joins the wave's
gate set; `zig build verify`; npm gate for the wasm leg.
**Created 2026-10-18; IN PROGRESS 2026-10-19 — T1–T5a task-complete
(private native composition proof; shared corpus parser; native parity
runner/classifier; three ordinary text-first anchors; portable native
text lifecycle proof). P1 COMPLETE (measured totals in the progress
log); P2 PARTIAL — 3 of 5 anchors (tempo-82bpm, clock-nonmonotonic,
scene-seek) are landed; P2–P3 acceptance remains open (reload/registry
anchors, lifecycle grammar and negatives are next — T5b). The two owner
questions remain unanswered, binary02 P3 is not accepted, and no phase
checkbox is claimed.**

## Why

The determinism claim extends to the new path: same score + same f64 time ⇒
byte-identical writes whether the score arrived as text through `drv_load`
or as `'PACB'` through `prt_load`. The existing goldens are the independent
anchor — authored against the text path, they must be *reproduced*, never
re-fit (`src/corpus_runner.zig:1-60`; the corpus's hex-bit-pattern
convention pins f64/f32 exactly). Nothing here weakens that: new anchor
cases are authored and goldened on the TEXT path first (they join the
corpus under `zig build corpus -- --update`, diff reviewed), and only then
does the binary leg replay them.

## Design

**The runner classifies algorithmically, never by name** (review I3 + the
inventory correction): `src/parity_runner.zig` (its own exe root beside
`corpus_runner` — nothing imports it, no dependency cycle) enumerates
`corpus/<case>/` sorted (the corpus runner's own discipline,
`src/corpus_runner.zig:149-155`), reads each golden's `(load :ok …)` line,
and FAILS the whole run on any case it cannot place in exactly one class:

- **clean non-pattern** — pack `doc.sjon` with the case's `times.sjon`
  target join, load BOTH ways (`Driver` for text, `Pacb.decode` +
  `EvalCore` for binary), replay `times.sjon` verbatim — every script form
  (`set-control`/`clear-control`/`set-bpm`/`register-control` included, so
  held controls and dynamic slots are exercised on both paths) — and diff:
  every frame's `Writes.encode` bytes, the load statuses, and the `'PACM'`
  bytes (text-load `Abi.encodeMeta` vs the embedded section). Mismatches
  print case, script index, and first diverging byte. Dated count (method,
  not a constant): 21 cases at HEAD `5f28aaa`, symlinked `examples-*`
  included.
- **clean pattern** — same, deferred to P4 (the SJON prerequisite); the
  runner knows the class and reports it as *skipped-pending*, never
  silently passed or omitted. Dated count: 2 (`pattern-basic`,
  `pattern-env`).
- **load-failing** — the text load fails; `PacbEncode` must REFUSE (pack
  requires `result.ok()`); assert the refusal, and that no `.pacb` bytes
  are produced (no pack on diagnostic fixtures). Dated count: 14 — the 13
  `diag-*` cases plus `pattern-budget` (its pattern dry-run exceeds the
  frame budget at load — a name-prefix classifier would miscount it).

`zig build parity` runs it; there is no `--update` — nothing regenerates,
only fixes. The runner consumes the public `pacer` module plus
`PacbEncode`/`Pacb` (exported by 01) — the packer and the player in one
process is the point: it is the text-vs-binary A/B.

**New corpus anchor cases** (text-path goldens, each reviewed on regen):
- `tempo-82bpm` — 82 BPM rational beats across the mul+floor seam with
  `:meter [4 4]` pinned in the case (the tps arithmetic is meter-dependent:
  82 × 180180 / 60 = 246,246 exact at 4/4);
- `clock-nonmonotonic` — `times.sjon` with decreasing/revisited host times
  (the seg-cache is a hint, never semantics);
- `scene-seek` — seeks landing inside/outside overlapping scene windows
  mid-frame, plus loop re-entry (`scenes-basic` pins one leg already);
- `reload-atomicity` — harness extension, scripted second loads with
  **per-path truth** (review I2): text leg — a bad-call load is a no-op and
  frames resume byte-identically, a diagnostics load leaves nothing loaded
  (`eval` answers 0) exactly as `src/wasm_entry.zig:207, 219-221` behaves;
  binary leg — EVERY refusal keeps the prior score and its control state,
  frames resume byte-identically, and the input zone is overwritten BEFORE
  the refused load to prove ownership (02 P2's invariant, replayed here at
  corpus level);
- `registry-mismatch` — binary leg only: load with a perturbed `'PACT'` —
  both a structural change AND a same-shaped name swap — expect status 1 +
  `registry_mismatch`, no writes change for the still-live score.

**Negative suites** (binary leg; 01's mutation classes end-to-end at the
load boundary): every-prefix truncation of a small PACB, forged
magic/version/required-features, directory overlap/overrun/reorder/gap,
count overflows, NaN/±inf fields, easing domain violations, payload
zero/multi-root/trailing-slack/corrupt-bytes, non-canonical presence
(degenerate section present, required section absent), PACM structural
garbage and PACM↔PACB incoherence (track/control registry lies, count
mismatches, `'EASE'`/`'TMPO'` divergence — 01's reader classes, each
status 1 + `meta_incoherent` where semantic), registry identity
mismatch — each an explicit expectation, never a crash;
plus 01's decode fuzz harness under `zig build fuzz`.

**No all-features gate before the prerequisite** (parent ruling): no
phase here (or in 02) treats an expr+pattern+controls+scenes+tempo all-features
case as a gate until the SJON prerequisite resolves — 04's full-capability
measurement and the pattern legs wait on the same fork. The all-features
score is authored when P4 lands, goldened text-side, then replayed.

**wasm leg** (`npm/pacer/test/rt-corpus.test.js`): the corpus renderer
replays the same cases through `pacer-rt.wasm` (the `corpus.test.js`
pattern against `zig-out/bin/pacer-rt.wasm`); packed inputs produced by
`pacer pack` in a pretest step — output locations: fixtures under
`npm/pacer/test/fixtures/` (gitignored, pretest-built), committed byte
goldens only under `tools/testdata/pacb/`.

## Phases

| Phase | Deliverable | Gate |
|---|---|---|
| P1 | `parity_runner` + classification over the corpus as it exists | `zig build parity` green (skips reported, failures red); `zig build verify` |
| P2 | the five anchor cases golden on the text path | `zig build corpus -- --update` diff reviewed; `zig build verify` |
| P3 | binary leg replays anchors + the negative suite; fuzz joined | `zig build parity`; `zig build fuzz` |
| P4 | wasm leg + pattern legs (post-prerequisite) | npm `lint && typecheck && test`; `zig build verify` |

## Progress log

_(created 2026-10-18; entries appended per phase)_

- **2026-10-19 — T1 COMPLETE (task only; P1 remains open).** Private
  native composition preflight, no parser extraction: `src/rt_entry.zig`
  gains the internal-only `NativeHarness` alias namespace and ordered
  native `reset`; `src/native_rt_bridge.zig` is the separately compiled
  `b.addObject` root that takes every alias address and defines only
  `pacer_native_rt_reset`; `src/NativeRt.zig` is the std-only `prt_*`
  extern facade with comptime ABI pins; `src/native_composition_probe.zig`
  is a real public-`pacer` consumer executable plus its separate named
  test root, attached to `native-composition`, `test`, and `verify`.
  Both modes compile/link/run the actual object: public schema +
  stationary Driver → public preflight/encode/PACT → real `prt_load` →
  seconds/tick frames byte-equal to the public driver → complete
  PACW/PACM → version-corrupt reload refused status 1/reason 1 with the
  live score, frames and metadata preserved → idempotent cleanup to zero
  eval/meta → fresh successful load. Controls, BPM and registration's u32
  sentinel are exercised; no native pointer passes through `u32`.
  RED: `error: no step named 'native-composition'`, then a missing
  `src/native_rt_bridge.zig` FileNotFound. GREEN: `native-composition`
  8/8 steps (probe exe + 1 test); `test` 525/525 (410 root + 89 CLI + 15
  tool/audit + 1 probe); `verify` 411/411 Zig, corpus 38/0, node 104/104;
  `audit-rt-imports` 10/10 with the frozen 17 `prt_*` + memory export
  set. No public root export, wire/version, wasm export or load/
  materializer change. P1–P3 acceptance, the parity runner, anchors and
  loader negatives remain open. Evidence:
  `.agent/control/binary03-t1-report.md`.
- **2026-10-19 — T2 COMPLETE (task only; P1 remains open).** Extracted the
  existing harness parser unchanged into the named std/SJON-only leaf
  `src/CorpusHarness.zig`: neutral public `Target`/`Step`/`Harness`,
  `manifest_src`, a frozen `MAX_TARGETS` (equality-pinned to
  `Abi.MAX_TARGETS` by a source-owning root test), `parse` over any holder
  with the existing `.preloaded` field, and `targetsAs` field copying.
  `src/corpus_runner.zig` now loads its harness manifest from the leaf,
  converts neutral targets to `Compile.Target` before `Driver.init` in the
  per-case arena, and keeps its canonical renderer untouched. The old
  `root.zig` runner-discovery import is gone; the moved parser tests run in
  their own explicit test root (6 tests) attached to `test` and `verify`,
  with a separate anonymous corpus-manifest import. Grammar, target
  order/defaults, width checks, pattern diagnostics and zero-host-target
  cases are unchanged. RED: missing `src/CorpusHarness.zig` FileNotFound.
  GREEN: `test` 528/528 (407 root + 6 harness + 89 CLI + 10 audit-tool + 15
  artifact-tool + 1 probe); `corpus` 38/0; `verify` 26/26 with 414/414 Zig
  and node 104/104; `native-composition` 8/8; `audit-rt-imports` 10/10 with
  the frozen 17 `prt_*` + memory. `corpus/`, `src/cli/testdata/` and
  `tools/testdata/pacb/` are byte-identical to `dd57196`. No schema, JS,
  wasm export, wire/version or public-root export change. P1–P3 acceptance,
  the parity runner, anchors and loader negatives remain open. Evidence:
  `.agent/control/binary03-t2-report.md`.
- **2026-10-19 — T3 COMPLETE; P1 CLOSED (task/gate only; P2–P3 open).**
  `src/parity_runner.zig` is a public-`pacer` consumer over the named
  `corpus_harness` leaf, linked to T1's separately compiled runtime object
  through the std-only `NativeRt` facade (no runtime/source import). It
  enumerates the corpus sorted, reads bounded doc/times/expected files
  (symlinked docs followed), requires ONE initial `(load :ok …)` golden
  record (later reload records are never the initial classification),
  compiles through a stationary public `Driver`, and assigns every case
  exactly once from the compile outcome plus compiled track source TAGS:
  clean non-pattern, clean pattern, or load-failing.
  - clean non-pattern: pack from the ORIGINAL host join, load through the
    real `prt_load`, compare fresh `Abi.encodeMeta` == embedded `'PACM'` ==
    the runtime copy, then replay every current script form and compare the
    complete `'PACW'` blob plus control/BPM/registration acceptance and the
    expr-failure counter. Mismatches name case, step, surface, lengths, and
    the first differing byte (or end-of-buffer).
  - clean pattern: `skipped-pending-SJON`; the existing
    `pack_patterns_unsupported` preflight refusal is asserted and `encode`
    is never called.
  - load-failing: compile refusal asserted; neither pack API is called, so
    no `'PACB'` bytes exist.
  `src/ParityTests.zig` is a separate test root (8 named tests + the
  discovery block) covering the initial/later/duplicate/malformed/unknown
  golden records, clean/dirty pattern and disagreement classification, the
  diagnostic pack guard, the pattern preflight guard, and a real production
  frame mutated on a copy (named first-byte mismatch) then restored.
  Measured on the current 38-case corpus: **19 clean non-pattern replayed,
  4 clean pattern skipped-pending-SJON (examples-starter, pattern-basic,
  pattern-env, rig-studio — skips are not passes), 15 load-failing
  compile-refused with no PACB, 0 failed**. RED: no `parity` step, then the
  missing parity source (FileNotFound). GREEN: `parity` 8/8 steps;
  `test` 537/537 (407 root + 6 harness + 89 CLI + 1 probe + 9 parity + 10
  audit-tool + 15 artifact-tool); `verify` 28/28 steps with 423/423 Zig
  tests, corpus 38/0, node 104/104; `audit-rt-imports` 10/10 with the
  frozen 17 `prt_*` + memory. `zig build parity -- --update` is rejected.
  No corpus/golden, fixture, schema, JS, wire/version, public-root export,
  wasm export or production-load change. Evidence:
  `.agent/control/binary03-t3-report.md`.
- **2026-10-19 — T4 PARTIAL: three ordinary text-first anchors (P2
  remains OPEN).** Authored only `corpus/tempo-82bpm`,
  `corpus/clock-nonmonotonic` and `corpus/scene-seek` (doc + harness),
  text-first. `tempo-82bpm` pins 82 bpm 4/4 at tps 246246 ticks/s and
  samples the f64 nearest 30/41 s and 90/41 s plus each representable
  neighbour and one tick past, against key landings at 1b/3b and the
  emitted `beat` lane. `clock-nonmonotonic` runs forward, backward,
  repeated and negative clocks through a 120→60 bpm map (segment 1 at
  tick 360360 = 1.0 s, loop_secs 7.0 s exactly) with an explicit
  `:at [1b 3b 5b 7b]` trigger; repeated 0.5 s before and after the seeks
  reproduces the same frame bytes. `scene-seek` overlaps intro/seek/tail
  on one `level` target, binds `scene-phase`/`scene-beat`, starts the
  seek scene at 2b (nonzero origin), samples each exclusive end and the
  inactive gaps [5,6) s / [7,8) s, and seeks backward across the 8 s loop
  wrap and re-entry.
  RED: check-only `corpus` saw the three new directories with
  `FileNotFound` for `expected.sjon` (41 cases, 3 failed). `zig build
  corpus --update` then regenerated all 41; the 38 pre-existing goldens
  were byte-identical before/after (git object hashes; no pre-existing
  corpus file changed vs `b08b403` — the only corpus diff is the three
  additions) and only the three new directories appeared.
  All new golden frames were checked against an independent Python
  oracle reproducing the documented `TimeMap` op order, key interpolation
  and `f32` emission (`binary03-t4-oracle.log` / `binary03-t4-verify.log`):
  exact ticks, f64 sample bits and f32 lane bits all match; repeated
  frames/writes match. GREEN: `corpus` 41/0; `parity` 41 cases = 22 clean
  non-pattern replayed (+3), 4 clean pattern skipped-pending-SJON (not
  passes), 15 load-failing compile-refused, 0 failed; `test` 537/537;
  `verify` 28/28 with 423/423 Zig, corpus 41/0, node 107/107;
  `audit-rt-imports` 10/10 with the frozen 17 `prt_*` + memory. A
  separate LOW producer-ABI guard commit pins the actual
  `Rt.NativeHarness` alias types in the separately compiled bridge
  (temporary `prt_loadError` return-type perturbation produced the exact
  guard error and was restored byte-identically; `native-composition`
  and audit re-ran green). **P2 is NOT complete:** only 3 of the 5
  anchors have landed; `reload-atomicity`, `registry-mismatch` and the
  lifecycle grammar/JS leg remain T5 work. No owner decision, SJON
  permission, pattern acceptance or metadata claim changed. Evidence:
  `.agent/control/binary03-t4-report.md`.
- **2026-10-19 — T5a COMPLETE (task only; P2 remains OPEN).** Portable
  native text entry and the real `drv_*` lifecycle proof, no grammar,
  schema, renderer, JS or anchor change. `src/wasm_entry.zig` now takes
  `std.heap.page_allocator` (on wasm32 the same WasmAllocator dispatch;
  no load-algorithm change), exposes an object-local `NativeHarness` alias
  namespace over every production `drv_*`, and adds `reset` with the
  ordered teardown: existing `unload()` (Driver/evaluator first), then
  `schema.deinit()` + `schema = null`, then `diags_len = 0` last.
  `src/native_text_bridge.zig` is the separately compiled native-only
  `b.addObject` root; it takes every alias address at comptime, rejects
  wasm targets, pins all producer ABI types against the std-only
  `src/NativeText.zig` C facade (`callconv(.c)`, real native pointers),
  and defines only `pacer_native_text_reset`. `build.zig` gives that
  object the target-matched SJON module and only the anonymous
  `pacer_schema`; it imports no public `pacer`, corpus manifest, plugin
  stub or wasmtime link. The composition probe links public `pacer` +
  both private objects and its shared main/test assertion now runs the
  actual text load: clean `drv_load` 0 with control/BPM and copied
  PACW/PACM/PACD (`decodeDiags` count 0) → over-cap `docCap()+1` call 2
  with frames/meta/diags preserved → fixed diagnostic source status 1
  with a decoded non-empty PACD and zero eval/meta → cleanup from the
  diagnostic session → fresh load → cleanup from a live clean score,
  repeated cleanup, fresh load after teardown → final zero surface. Both
  native resets are deferred before any load; the public Driver stays the
  stationary PACM/frame oracle. RED: missing `src/NativeText.zig`
  FileNotFound in both executable and test compile modes. The producer
  guard was demonstrated separately by a bounded temporary
  `NativeHarness.load` signature perturbation, which produced the exact
  `native_text_bridge: drv_load producer ABI drift` error and was restored
  byte-identically (`src/wasm_entry.zig` sha256
  `eae854d5f7c678a14fb2c6d60be0cb1bed1b7d531e047f53fe40083e13349329`
  before/after). GREEN post-commit `0f59936`: `native-composition` 10/10
  steps + 1/1 test; `test` 23/23 steps, 537/537; `verify` 30/30 steps
  with 423/423 Zig, corpus 41/0, node 107/107; `audit-rt-imports` 10/10
  on the frozen 17 `prt_*` + memory; `parity` 8/8 steps, 41 cases = 22
  clean non-pattern replayed, 4 skipped-pending-SJON, 15 load-failing,
  0 failed. Both wasm artifacts are byte-identical to the pre-change
  build (`pacer.wasm` 666873 B / `97dc08e4…22f2ffc`; `pacer-rt.wasm`
  172255 B / `caddd6fd…134751dd3`) and their explicit export sets are
  unchanged (19 and 18 entries; no `pacer_native_*` export).
  `tools/smoke_rt.mjs` PASS. `corpus/`, `src/cli/testdata/` and
  `tools/testdata/pacb/` are byte-identical to `a491078`; fmt/diff-check
  clean. **P2 is NOT complete:** only 3 of the 5 anchors have landed and
  T5b's lifecycle grammar/JS leg remains; P3 is not accepted and the two
  owner questions remain unanswered. Evidence:
  `.agent/control/binary03-t5a-report.md`.
