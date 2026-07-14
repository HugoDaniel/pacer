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
