# 11 — Hardening toward 1.0

**Repo:** pacer
**Wire impact:** Phase 3 appends to `'PACM'`; Phase 4 lands roadmapped compose-mode
`(target …)`; the rest is corpus/test coverage only
**Gates:** `zig build verify`, `zig build audit-diagnostics`, npm gate

## Why

The determinism gate is pacer's moat, but the corpus (8 cases) under-pins the surface:
most named easing primitives, `xy`/`color` controls, the `bpm`/`dur`/`cycle` expr env,
and several diagnostics have Zig unit tests yet no golden — meaning wasm parity isn't
proven for them. Two roadmapped wire items also remain: compose-mode `(target …)`
declarations and serializing the easing program table ("future wire" in `CLAUDE.md`).
Phases here are independent; run them as warm-ups between larger plans.

## Phase 1 — pin every easing primitive (RED first)

Load: `corpus/ease-composed/` as template, `src/Easing.zig` (the primitive list only).
Reds: new case `ease-primitives` — one track per named ease (all 18: linear, hold,
smoothstep, in/out/in-out × quad/cubic/quart/sine/expo), plus standalone
`(cubic-bezier …)` and both `(steps :jump start|end)` variants; times sampling
segment interiors + exact key ticks. The red is the runner failing on the missing
golden.
Green: `zig build corpus -- --update`, review the diff against hand-computed spot
values (at least one interior value per family verified by hand in the review notes).
Gate: `zig build verify` (native + wasm parity).

## Phase 2 — pin controls fully + the expr env (RED first)

Load: `corpus/controls-live/` and `corpus/expr-control/` as templates,
`src/ExprTrack.zig` (env table only).
Reds: extend/add cases — `xy` and `color` control types with `:min`/`:max` echoed
through `'PACM'` (meta golden), vector control set/clear over the wasm boundary; an
expr case binding `bpm`, `dur`, `cycle` (and `dur` absent when transport has no
`:dur` — expect the compile diagnostic path pinned).
Green: regen + review.
Gate: `zig build verify`.

## Phase 3 — easing program table into `'PACM'` (RED first)

Why: `Easing.Op` is already wire-stable ("future wire", ops params already f32), but
programs never serialize — an external editor (plan 07) can't render authored curves
without re-parsing ease specs itself.
Load: `src/Abi.zig` (meta encode + extern-record pattern), `src/Easing.zig`
(`Program` layout), `npm/pacer/src/index.js` meta decode + `types.js`.
Reds: Zig Abi test round-tripping a programs section (op stream + stage weights per
program, tracks referencing program indices); npm test decoding `meta.easePrograms`
and tolerating old blobs without the section.
Green: append the section after existing ones (same framing decision as plan 01
Phase 4 — coordinate if both land); comptime size pins on any new extern record.
Gate: `zig build verify` + npm gate; extend one corpus case so the golden pins the
`(meta …)` echo of programs.

## Phase 4 — compose-mode `(target …)` declarations (RED first)

Why: roadmapped in the schema header. Today targets exist only if the host registers
them, so a score is meaningless standalone; declared targets let a score compile (and
be corpus-tested, shared, and linted) without a host, then bind by name at load.
Design decision to freeze first: declared targets **merge** with host registries
(host wins on conflict? or diagnostic on mismatch — recommend: matching declaration
is fine, arity mismatch → `target_arity_mismatch`, extra declared-only targets get
writes with a synthetic registry — decide and record).
Load: `schema/pacer.sjon`, `src/Compile.zig` (target join), `src/Abi.zig`
(`decodeTargets` — declared targets must NOT change `'PACT'`; they only add to the
in-memory join).
Reds: schema/validation tests (`(target :name motionX :arity 1 :registry 0)` form;
duplicates → new appended code `target_decl_invalid`); compile tests for each merge
rule; a corpus case compiled with an EMPTY host registry proving standalone scores
golden-stably.
Green: implement; append the diagnostic code.
Gate: `zig build verify`, `zig build audit-diagnostics`, npm gate (npm `registries`
option becomes optional — typedef update).

## Phase 5 — diagnostic goldens (RED first)

Load: `corpus/diag-validation/` + `corpus/diag-tick-overflow/` as templates,
`src/Compile.zig` Code enum for the list.
Reds: a `diag-compile` case exercising the untested-by-golden codes
(`target_arity_mismatch`, `track_source_conflict`, ease-cap/weights/params families,
`control_*`) — one doc per code or one doc with several, whichever the runner's
format prefers; the golden pins code numbers + spans forever (that's the point:
diagnostic codes are a stable surface).
Green: regen + review.
Gate: `zig build verify`.

## Progress log

- **Phase 1 — pin every easing primitive (done, 2026-07-14).** New golden case
  `corpus/ease-primitives/` (modelled on `ease-composed/`): 21 tracks, one per
  easing primitive — all 18 named eases (`linear`, `hold`, `smoothstep`, in/out/in-out
  × quad/cubic/quart/sine/expo), a standalone `(cubic-bezier :p [0.42 0 0.58 1])`, and
  both `(steps :n 2 :jump end|start)` variants. Every key runs `0 → 1` over one bar
  (`0b..4b` = 2.0 s at 120 bpm), so each write value **is** `e(u)` directly and the
  golden reads as a table of easing outputs. Five sample times pin `u = 0, 0.25, 0.5,
  0.75, 1`: `u=0`/`u=1` are exact key ticks (structural landing → bit-exact `0` / `1`
  for all 21, `hold` and `steps` included), `0.25/0.5/0.75` sample interiors. `steps`
  use `:n 2` so the `0.25/0.75` interior samples fall inside a tread and separate
  end-jump from start-jump (`u=0.25`: end `0` vs start `0.5`; `u=0.75`: end `0.5` vs
  start `1.0`). The red was the runner failing on the missing golden (`cannot read
  expected.sjon: FileNotFound`, 10 cases 1 failed); `-- --update` generated it.
  **Review (hand-verified spot values):** polynomial families (linear/quad/cubic/
  quart/smoothstep/steps) match hand math to full f32 precision — the whole `u=0.5`
  column is an exact table (every `in-out-*` and the symmetric bezier land exactly
  `3F000000`=0.5; `in-quad` 0.25, `out-cubic` 0.875, `out-quart` 0.9375, …). Trig/expo
  families (`sine`, `expo`) match the pinned `sjon.trig` `sin64`/`cos64`/`pow64`
  kernels — e.g. `in-sine(0.25)`=`3D9BE50C`≈0.07612 (π/8), `in-expo(0.25)`=`3BB504F3`
  ≈0.0055243 (2⁻⁷·⁵); the `out-sine`/`out-expo` mid-range values sit ~1e-5 from libm,
  which is the deterministic kernel's own output (the same kernels `ease-composed`'s
  spring already pins) — the golden pins the kernel, not libm, by design. Regen
  touched only this case; the 9 pre-existing goldens stayed byte-identical. Gate:
  `zig build verify` ✓ (native corpus 10/10 + wasm parity `node --test` 40/40). No JS/TS
  touched, so no npm lint/typecheck needed this phase.
