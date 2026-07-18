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
Framing: obey **the `'PACM'` section-framing convention frozen in plan 01** (TLV, walked
to end-of-buffer, no version bump; canonical spec in 01's Design, summarized in 00's
Decision log). This section's id is `'EASE'`; it is emitted AFTER `'SCEN'` if both are
present (fixed order per the convention), and omitted when there are 0 programs. If 01
has already landed, `get meta`'s post-controls TLV walk exists — just add an `'EASE'`
arm; if 11 P3 somehow lands first, it introduces the walk (same code either way).
Reds: Zig Abi test round-tripping a programs section (op stream + stage weights per
program, tracks referencing program indices); npm test decoding `meta.easePrograms`
and tolerating old blobs without the section (absent → `[]`).
Green: append the `'EASE'` section per the convention; comptime size pins on any new
extern record.
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

- **Phase 2 — pin controls fully + the expr env (done, 2026-07-14).** Three new,
  purely-additive golden cases (the 10 pre-existing goldens stayed byte-identical —
  `git diff --stat corpus/` empty, only the three new dirs untracked):
  - **`corpus/controls-vector/`** — the non-scalar control kinds. `pan` is a `:type xy`
    widget (ncomp 2, rails `:min [-1 -1]` / `:max [1 1]`); `tint` is a `:type color`
    widget (ncomp 3, rails `[0 0 0]` / `[1 1 1]`). Both echo `:type` + vector `:min`/`:max`
    through `'PACM'` (the meta golden's first non-`slider`, non-scalar `mcontrol` rows).
    Both target a registry-0 slot, so a **vector** `set-control` overrides every lane at
    once (pan → `[-0.5 0.5]`, tint → `[1 0 1]`) and `clear-control` reverts each to its
    document `:value` — pinning vector override/revert across the wasm boundary, all
    directives `:ok true`. **Review:** value lanes `[0.25 0.5]` = `3E800000 3F000000`,
    `[0.2 0.4 0.6]` = `3E4CCCCD 3ECCCCCD 3F19999A`; rails `-1` = `BF800000`, `1` = `3F800000`
    — all exact.
  - **`corpus/expr-env/`** — the time bindings `expr-control` doesn't already pin: `bpm`,
    `dur`, `cycle`. Transport `:dur 2bar` binds `dur` = 8 beats (`beatOf(1441440)`), so the
    meta echoes `:dur 1441440 :end hold` — the *hold* dur-meta path (controls-live pins
    the *loop* one). Four expr tracks isolate `bpm` (=120, `42F00000`, constant), `dur`
    (=8, `41000000`, constant), `cycle` (=0/0.5/1.0/1.5 over t=0/1/2/3 s inside `[0,2bar]`),
    and `mix = cycle·bpm/dur` (=0/7.5/15/22.5 = `40F00000`/`41700000`/`41B40000`) — every
    value exact and hand-verified.
  - **`corpus/diag-dur-unbound/`** — the `dur`-absent compile guard: referencing `dur`
    with no `:dur` on the transport is `UnknownBinding` at the shared load-time dry-run
    (`ExprTrack.evalAt` → `Compile.dryRunExpr` else-branch). Failed-load golden pins
    `(load :ok false)` + `(diag :source pacer :code 18 …)` (`expr_eval_failed`), message
    `"expression failed to evaluate at t=0: UnknownBinding"` + its span.
  The red was the runner failing on three missing goldens (`13 case(s), 3 failed`);
  `-- --update` generated them. Gate: `zig build verify` ✓ (native corpus 13/13 + wasm
  parity `node --test` 43/43, +3 for the new cases). No JS/TS touched. **Wave 0's `11
  P1–P2` obligation is now complete** — Phases 3–5 are scheduled in Wave 4.

- **Phase 3 — easing program table into `'PACM'` (done, 2026-07-17).** The compiled
  program table (`table.programs`, deduped, `[0]` = default linear) now serializes as a
  new `'EASE'` meta section so an external editor renders authored curves without
  re-parsing ease specs (plan 07's `curve-sample.ts` can drop live-sampling later — a
  deferred win, not this phase).
  - **RED first** — three `Abi.zig` tests (`git`-visible before the encoder existed):
    the `'EASE'` frame after the controls (programs[0] linear + out-cubic + smoothstep,
    self-delimiting `payload_len`, per-key refs `[0 1 0 2]`), a linear-only score emits
    NO section (byte-stable), and `'EASE'` rides AFTER `'SCEN'` when both are present.
    First run failed to compile (`undeclared identifier 'EASE_SECTION_ID'`).
  - **Wire (append-only, no `META_VERSION` bump).** `'EASE'` = `0x45534145`, emitted
    after `'SCEN'` (fixed order), **OMITTED when `programs.len <= 1`** (the only program
    is the default linear — so a linear-only blob stays byte-identical to a pre-ease
    one; this is the meaningful omit test, since `programs[0]` always exists). Payload:
    `[program_count u32]`, then `program_count ×` a fixed 772-byte `MetaEaseProgramRec`
    (`len u8` + 8 × 96-byte `MetaEaseStageRec`, each `t_end/v_base/v_span f32 + ops_len
    u8` + 4 × 20-byte `MetaEaseOpRec` `{code u8, params f32×4}`; unused slots ZEROED to
    match the program's zero-fill → equal programs give equal bytes), then
    `[key_ref_count u32]` + `key_ref_count × ease_ref u16` **parallel to the key stream**
    (a key's ref names the program for the segment ENDING at it; 0 = linear). Fixed
    records mirror the `'SCEN'` house pattern and earn three `@sizeOf` comptime pins.
    `META_CAP` 192→320 KiB (its comptime pin now covers a full `'EASE'` section:
    `MAX_EASE_PROGRAMS`(128) maximal programs + one ref per `MAX_KEYS`).
  - **Both `renderMeta`s extended** (the cross-plan obligation from 01 Phase 5): the
    native runner (`corpus_runner.zig` `renderEasePrograms`, walking the `'EASE'` TLV)
    and the JS parity renderer (`corpus.test.js`, from `driver.meta.easePrograms` +
    per-key `easeRef`) emit the same `(mease :index N (mstage … (mop :code NAME :params
    […])))` blocks + a flat `(measerefs […])` list. Op names are the `Easing.Op`
    `@tagName` (snake_case), mirrored by the npm `EASE_OPS` table.
  - **Goldens** — `-- --update` touched exactly the three ease-using cases
    (`keys-basic`, `ease-composed`, `ease-primitives`); the 13 linear-only goldens stayed
    byte-identical (omit-when-linear works). **Hand-verified spot values:** `ease-composed`'s
    seq normalizes to stage-1 `t_end 0.4`(`3ECCCCCD`)/`v_span 1.15`(`3F933333`), stage-2
    `v_span -0.18`(`BE3851EC`), stage-3 `v_base 0.97`(`3F7851EC`); the spring precomputes
    `λ≈5.655`(`40B4F4AB`)/`ω≈18.85`(`4196CBE4`) from `(:damping 0.3 :periods 3)`; the chain's
    bezier carries `[0.4 0 0.2 1]` and steps `n=4`(`40800000`); refs `[0 1 0 2 0 3]`.
    `keys-basic` pins the minimal `[linear, in_out_quad]` table + refs `[0 0 0 1 0 0]`.
  - **npm** — `Pacer#meta` gained `easePrograms` (typed `MetaEaseProgram/Stage/Op`) and
    every `MetaKey` gained `easeRef` (0 default). Three new `driver.test.js` tests over
    the real wasm (table + refs, parametric-op params, linear-only → `[]` with all refs 0
    — the old-blob-tolerance proof). No triple-pin bump (accumulate-till-publish; the
    next publish 0.1.0 → 0.2.0 covers this + prior surface growth).
  - **Gate green:** `zig build verify` (native corpus **16/16** byte-identical, wasm
    parity **16/16** + `driver` **52** incl. +3) + `audit-diagnostics` 29/29 (no new
    codes — programs were already a compiled surface) + npm lint/typecheck clean. Docs:
    `Abi.zig` `//!` header defines `'EASE'`; `CLAUDE.md` lists it in the section stream +
    updates the `Easing.Op` wire row; `Easing.zig` `Op`/`OpRec` comments drop "future
    wire". **Studio refresh deferred** to the Wave-4 close (07 already ships; nothing
    consumes `easePrograms` yet, so the studio wasm can stay as-is until P4–P5 land).

- **Phase 4 — compose-mode `(target …)` declarations (done, 2026-07-18).** A score
  now declares its own animatable targets with `(target :name X :arity N :registry R)`,
  so it compiles, corpus-tests, and lints STANDALONE (no host registry); declared
  targets **merge** with whatever registries a host does hand over.
  - **RED first** — five `Compile.zig` tests referencing the not-yet-existing
    `CompileResult.targets` field + `.target_decl_invalid` variant (a compile-error
    RED, exactly as P3 began): a standalone score compiling against `&.{}`; the
    host-merge (host-authoritative on a name match); an arity disagreement →
    `target_arity_mismatch`; a duplicate declaration → `target_decl_invalid`; a
    missing `:name`/`:arity` → `target_decl_invalid`.
  - **Merge model (frozen; the user chose "host wins, flag arity only").** New
    `Builder.buildTargetJoin` runs FIRST in `build()` (before transport/controls/
    tracks/triggers, so every `resolveTarget` sees declarations). Host registries
    keep indices `0..host_len`; a declared name the host does NOT provide is appended
    in document order under its `:arity`/`:registry` (its join index becoming its
    `target_id`). Rules: a duplicate declared `:name` → `target_decl_invalid`; a name
    the host also provides is host-authoritative — its arity must equal the host's
    (else `target_arity_mismatch`) and the declared `:registry` is IGNORED; missing
    `:name`/`:arity`, or overrunning `MAX_TARGETS`(1024, mirrors `Abi.MAX_TARGETS`,
    keeps every id inside `u16`) → `target_decl_invalid`.
  - **Wire (append-only, minimal).** ONE new `Compile.Code` variant
    `target_decl_invalid` = **29** (rides in `'PACD'`; never renumber). **`'PACT'`
    and `'PACM'` UNCHANGED** — declared targets never touch the inbound blob (they
    come from the doc) and their NAMES never serialize (house rule: names come from
    source, like scene names). `CompileResult.targets` (the merged join, compile-
    arena-backed, declared names duped) is a NATIVE-only view, NOT on the wire — it
    equals the host list verbatim when a score has no declarations, so nothing shifts.
  - **Corpus.** The runner now accepts an EMPTY host registry (`times.sjon` with no
    `(target …)`) and resolves write/meta target names through `result.targets`
    instead of the host-only `harness.targets` — byte-stable for the 16 existing
    goldens (merged == host when there are no declarations). New case
    `target-declared` (empty host; the score declares `glow`/`tint`/`level` across
    registries 0 and 1, via keys, vec keys, and an `:expr`). **Hand-verified:** glow
    out-cubic at u=0.25 → 0.546875 (`3F0C0000`), tint lane split, `level = (* 0.5
    beat)` → 0 / 0.5 / 1.0 over beats 0/1/2. The JS parity renderer mirrors the merged
    join (`mergedTargetNames` walks the doc in ONE left-to-right tokenizing scan —
    alternation `#|…|#` block comment / `;` line comment / `"…"` string / a real
    `(target …)` — so a declaration inside a comment or string is consumed as that
    token, never a phantom, matching the native parse-forest walk; an adversarial
    review caught the naive `;`-only strip, and the golden now embeds a
    block-commented decoy `(target :name halo …)` between the real declarations as the
    regression gate).
  - **npm.** `#target(targetId)` now TOLERATES an id past the flat host list — a
    declared-only target the host never registered — returning `name: null` rather
    than throwing (a standalone/partially-hosted score no longer crashes the decode);
    `MetaTrack.name`/`WriteEntry.name` became `string | null`, and `route.js`
    `toUniforms` skips a null-name entry (a by-name uniforms map can't key it — the
    host routes it by `registry`). The `registries` load option is now OPTIONAL
    (default `[]`). Two new `driver.test.js` tests over the real wasm: a standalone
    score loaded with registries OMITTED (declared-only ids, `name: null`, wire-borne
    registry/ncomp), and a host-merge (host name resolves, declared-only extra appends
    past the host ids). No triple-pin bump (accumulate-till-publish).
  - **Gate green:** `zig build verify` (native corpus **17/17** byte-identical, wasm
    parity **17/17** + `driver` **55** incl. +2) + `audit-diagnostics` **30/30** + npm
    lint/typecheck clean + fuzz (no panic — `fuzzCompile` feeds arbitrary source, so
    the new declaration path is fuzzed). Docs: `schema/pacer.sjon` header drops the
    last omission; `CLAUDE.md` Roadmap records the merge model. **Only the 1.0 review
    remains in Wave 4.**

- **Phase 5 — diagnostic goldens (done, 2026-07-18) → plan 11 DONE.** The compile
  diagnostics that had unit tests but no golden are now frozen — code number + span +
  message, native == wasm — so the wire-stable `Compile.Code` surface is gated end to
  end. No new wire surface (corpus/test coverage only); no Zig/JS/TS touched (the JS
  parity walk already handles failed-load diag cases).
  - **RED first** — four new `diag-*` case dirs with `doc.sjon` + `times.sjon` but NO
    `expected.sjon`; `zig build corpus` failed `21 case(s), 4 failed` (`cannot read
    expected.sjon: FileNotFound` ×4). `-- --update` generated the goldens.
  - **Cases (11 distinct codes pinned, collection-over-abort demonstrated):**
    - **`diag-controls`** — six controls trip FIVE diagnostics in ONE compile:
      `control_duplicate_id`=20 (span on the 2nd `knob`), `control_invalid`=22 ×2
      (reserved id `beat`; `:min [0 0]` arity 2 ≠ `:value` arity 1),
      `unknown_target`=0 (`nonexistent`), `target_arity_mismatch`=1 (scalar `:value 5`
      on ncomp-3 `tint`). A trackless failed-load doc (transport + controls only).
    - **`diag-ease`** — five tracks, five malformed eases, FIVE diagnostics in one
      compile: `ease_params_invalid`=9 (bezier x=2 out of [0,1]),
      `ease_ops_exceeded`=7 (5 chained > cap 4), `ease_stages_exceeded`=6 (9 stages >
      cap 8, span = the whole `(seq …)`), `ease_nesting_unsupported`=10 (span on the
      INNER `(seq …)`), `ease_weights_invalid`=8 (`:v 1` + `:v -1` → Σ=0).
    - **`diag-track-source`** — a track with both `(key …)` and `:expr` →
      `track_source_conflict`=17 (span on the `:expr` value `(+ beat 0)`).
    - **`diag-target-decl`** — a STANDALONE score (empty host registry, `times.sjon`
      with no `(target …)`) whose own declarations are malformed two ways →
      `target_decl_invalid`=29 ×2 (span on the duplicate `:name glow`; span on the
      whole `(target :registry 0)` missing both keys). First failed-load golden with an
      empty host registry — exercises that path in BOTH renderers.
  - **Review (spans hand-verified against `doc.sjon` bytes):** every span points at the
    correct, stable token (the offending id / value / ease form / expr), and every code
    number equals its `Compile.Code` enum ordinal (0/1/6/7/8/9/10/17/20/22/29). Messages
    verbatim from the emitters. The 17 pre-existing goldens stayed byte-identical
    (`git status` shows only the four new dirs).
  - **Scope — count-caps deliberately deferred (not golden-pinned):**
    `ease_cap_exceeded`(5), `control_cap_exceeded`(21), `track_cap_exceeded`(3),
    `key_cap_exceeded`(4). Each triggers ONLY on a `MAX+1` generated blob (e.g.
    `MAX_EASE_PROGRAMS + 2` = 130 distinct-ease keys) whose span points at a giant list
    and carries no information; they are already pinned BY NAME in `audit-diagnostics`
    (30/30) + unit tests, and native == wasm parity for their shared `emit()` path is
    transitively proven by the 11 span-bearing codes that ARE pinned. Pinning them would
    bloat the corpus with un-hand-checkable blobs for no parity gain.
  - **Gate green:** `zig build verify` (native corpus **21/21** byte-identical, wasm
    parity **21/21** + npm **59** incl. +4 for the new cases) + `audit-diagnostics`
    **30/30** (no new codes — data-only phase). No npm lint/typecheck (no JS/TS change).
    **Wave 4's 11-plan work is complete; only the 1.0 review remains on the board.**
