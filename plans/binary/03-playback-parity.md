# binary 03 — playback parity: one score, two load paths, identical bytes

**Repos:** pacer
**Wire impact:** none (test architecture only).
**Gates:** new `zig build parity` (proposed; created by P1) joins the wave's
gate set; `zig build verify`; npm gate for the wasm leg.
**Created 2026-10-18; not started.**

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
