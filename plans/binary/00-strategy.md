# binary 00 — rollout strategy

The living guide for this wave. Same rules as [`../00-strategy.md`](../00-strategy.md):
read this file, pick the top unchecked item, open only that plan, execute its
next phase; update the board and pointer when a phase or plan completes.
**Created 2026-10-18; plan 01 Phase 1 (T1.1) landed 2026-10-18; phases
2–4 await their separate correction.**

## North star

**The Meridian-class export without the compiler.** Today's release ships
`assets/score.sjon` (2,657 B) + `pacer.wasm` (661,334 B) and compiles text in
the browser (`animader/animader/demo/lib/score.mjs:124-200, 300-325`). The
measure of this wave: *the same export shape, with `assets/score.pacb` +
`pacer-rt.wasm`, rendering byte-identical frames*. **No KB number and no
percentage is promised anywhere in this wave** — the size story is measured
by [04](04-measurement-acceptance.md)'s procedure and decided by the user at
its checkpoint; the correctness story (parity, closure, negative suites) is
decided by gates, not by size.

## Ordering rationale

- **Format first.** `'PACB'` is the contract every later piece leans on, and
  its decoder is testable natively before any wasm exists. Its first phase
  is the `'PACT'` codec extraction — shared live code (`Abi.zig` imports
  `Compile.zig` at `src/Abi.zig:110`), so it is a gated zero-diff refactor
  of its own, not a footnote inside a bigger phase.
- **The prerequisite is drafted up front, filed never.** The SJON pattern
  gap is the only cross-owner item. Its full text lives pacer-local
  ([handoff](handoff-binary-pattern-query-env.md)); whether and where it is
  filed is SJON's owner's call, so the wave never blocks on a foreign repo's
  numbering and never invents one.
- **Measure early, decide late.** 02 P2 takes a *preliminary* size trend on
  the pattern-free artifact — labeled incomplete, non-binding, a cheap
  kill-switch for the trend only. The binding measurement is 04's
  full-capability report after the prerequisite's fork is resolved, and the
  decision is the user's.
- **Parity breadth last in core; acceptance last overall.** The parity
  runner is cheap once format + runtime exist. 04's smoke page is
  pacer-local; the real Animader vertical is a separate, blocked handoff —
  no sibling repo is edited by this wave.

## Global constraints (verbatim values; every phase inherits them)

- Zig 0.16 (`CLAUDE.md`); SJON by path dep `../SJON` with
  `.@"plugin-exec" = false` (`build.zig.zon`, `build.zig:73-77`).
- Tick grid `PPC = 720720`; `|tick| ≤ sjon.Pattern.MAX_TICK = 2^53`
  (`src/wasm_entry.zig:269-274`, `src/Eval.zig:338-340`).
- Caps (`src/TrackTable.zig:42-49`): `MAX_TRACKS 256`, `MAX_KEYS 4096`,
  `MAX_EASE_PROGRAMS 128`, `MAX_CONTROLS 64`, `MAX_SCENES 64`,
  `MAX_TEMPO_SEGMENTS 512`; `MAX_TARGETS 1024` (`src/Compile.zig:66`);
  `MAX_DYNAMIC_CONTROLS 64` (`src/Eval.zig:88`); `EmitName` 5 lanes
  (`src/TrackTable.zig:68`); `Easing.MAX_STAGES 8`, `MAX_OPS 4`
  (`src/Easing.zig:34-36`).
- Scratch: `ExprTrack.SCRATCH_BYTES = 256 KiB` (`src/ExprTrack.zig:75`),
  `PatternTrack.SCRATCH_BYTES = 1 MiB` (`src/PatternTrack.zig:71`), SJON
  `PATTERN_EXPR_SCRATCH = 256 KiB` (`SJON/src/PatternQuery.zig:88`).
- Transport domains: `bpm` 1..1000, meter components 1..16 — asserted, not
  diagnosed, in `TimeMap.init` (`src/TimeMap.zig:84-97`); tempo segments
  strictly ascending with `[0] == {0, bpm}` (`src/TimeMap.zig:99-115`,
  `TrackTable.Transport.segments` doc). A decoder must refuse outside these
  domains BEFORE calling `TimeMap` — never trap on host-supplied bytes.
- SJON binary IR: magic `"SJ1\n"`, `wire_version 0x05`, 16-byte header,
  unknown versions rejected by the cursor
  (`SJON/src/BinaryFormat.zig:44-52`; `SJON/src/BinaryCursor.zig:158-161`).
- Wire policy: append-only; appends ride a minor, VERSION/abi bumps are
  breaking (`CLAUDE.md:47-89`, `src/Abi.zig:102-106`). `drv_abiVersion() = 1`
  (`src/wasm_entry.zig:148-150`) is the full artifact; `prt_abiVersion() = 1`
  is a *separate* lineage.
- Determinism seams are untouchable without corpus regen + diff review: the
  mul+floor conversions, seconds-domain wrap for mapped scores, fixed-count
  bezier bisection, pinned `sjon.trig` kernels, single f64→f32 truncation at
  emission, structural landing, NaN omission at the expr boundary
  (`CLAUDE.md:91-128`).
- Baseline sizes (measured, `animader/animader/.agent/releases/meridian.size.json`
  — the file lives in the animader repo): `pacer.wasm` 661,334 raw /
  238,810 gzip9 / 194,275 brotli11; `app.mjs` 93,555; `assets/score.sjon`
  2,657; demo music excluded from program totals by the report's `musicPath`
  scoping. These are the only size numbers this wave starts from; everything
  else is measured by 04 before it is claimed.
- Version pins: `package.json` / `build.zig.zon` / `src/root.zig` = 0.2.0
  (triple-pin, lockstep-tested). This wave does not bump them; the npm
  append (`./rt`) rides the next publish decision, per house
  accumulate-then-bump convention.
- Corpus inventory (dated 2026-10-18 at HEAD `5f28aaa`, derived from the
  goldens — the method, not a hardcoded count: `grep -l "(load :ok false)"
  corpus/*/expected.sjon`): **37 cases; 23 load-clean, 14 load-failing**
  (the 13 `diag-*` cases *plus* `pattern-budget`, whose pattern dry-run
  exceeds the frame budget at load). Clean pattern cases: `pattern-basic`,
  `pattern-env`; clean non-pattern (packable + replayable before the
  prerequisite): **21**, symlinked `examples-*` included. The parity runner
  must classify algorithmically and FAIL on any case it cannot classify —
  never trust this paragraph over the tree.

## Status board

| Wave | Item | Status |
|---|---|---|
| A | SJON prerequisite handoff drafted (pacer-local, unfiled) | ☐ |
| A | 01 pacb-format · all phases | ◐ Phase 1 (T1.1 `'PACT'` leaf) landed; phases 2–4 open |
| B | 02 binary-runtime · P1 Eval layering (`EvalCore` leaf + facade) | ☐ |
| B | 02 binary-runtime · P2 artifact + closure gate + preliminary size trend (non-binding) | ☐ |
| B | 02 binary-runtime · P3 `pacer/rt` glue | ☐ |
| C | 02 binary-runtime · P4 pattern support (gated on the prerequisite) | ☐ |
| C | 03 playback-parity · P1–P3 (non-pattern legs) | ☐ |
| C | 03 playback-parity · P4 wasm leg + pattern legs | ☐ |
| D | 04 measurement-acceptance · report + user checkpoint | ☐ |
| D | 04 measurement-acceptance · pacer-local smoke; consumer handoff stays blocked until authorized | ☐ |

## What's next

→ Plan 01 Phase 2 (decoder + validator). Phase 1 (the `'PACT'` codec
extraction, T1.1) landed 2026-10-18 with its zero-diff gate; phases 2–4
await their separate plan correction before execution.

## Decision log

- 2026-10-18 — Wave created from the architecture read; independently
  reviewed the same day; this revision applies the review's B1–B4/I1–I11
  against source. Frozen up front:
  1. **Payloads are per-node SJON binary IR** — no new bytecode, no
     whole-document AST shipping. Forced: `Expr.evalBinary` requires
     single-root buffers (`SJON/src/Expr.zig:1891-1893`) and subtrees are
     not sliceable.
  2. **`'PACB'` stores authored truth** (ticks, bpms, key values, programs,
     schedules) and re-derives projections through the SAME `TimeMap` calls
     — one derivation site, not two truths.
  3. **Registry binding is exact, names included.** The container embeds the
     canonical `'PACT'` bytes of the pack-time host join (ordered
     name+registry+ncomp); the runtime byte-compares a canonically
     re-encoded host blob. FNV-1a-64 is a fast-reject/checksum only, never
     the identity. Same-shaped name swaps refuse.
  4. **The runtime owns every live byte it serves.** Nothing live aliases
     the host-written input zones after `prt_load` returns; every refusal
     is transactional (prior score AND its control/BPM/counter state stay
     live). A deliberate, documented divergence from the text path's
     teardown-on-diagnostics (see 02's load-contract table).
  5. **One evaluation engine, layered not duplicated.** A pure evaluator
     core leaf (`EvalCore`) carries a type-safe mutually exclusive leaf
     source (tree | payloads); the existing `Eval.zig` stays public API as a
     compiler-side facade/adapter outside the runtime closure. The encoder
     and decoder of `'PACB'` are separate modules at birth.
  6. **PACM is embedded verbatim at pack; the runtime READS it before
     serving.** A std-only runtime-side reader (`src/Pacm.zig`, 01)
     structurally decodes the whole section and cross-checks the
     routing-relevant fields (registry/target identity, counts,
     transport, `'EASE'`/`'TMPO'`/`'SCEN'` payloads) against the PACB
     sections — the operative truth — so consumers may keep authorizing
     routing from the served metadata: a lying PACM refuses
     (`meta_incoherent`), never misroutes. The compiler's metadata
     encoder never enters the runtime closure; v1 claims exactly that
     checked surface (structural safety + routing coherence, proven by
     the negative suites), not producer authentication. Spans stay
     opaque — pairing-checked only — in a text-free release.
  7. **The runtime artifact is a second artifact** with `prt_*` exports,
     never a mode of the full one; no text entry point exists to fall back
     to. Its import closure crosses into SJON at ONE audited window
     (`src/RtSjon.zig`, the runtime's only `@import("sjon")`) and is
     gated in two layers — a syntactic allowlist auditor with
     mutation-proof fixtures, and a physical post-build artifact check
     (import section empty or exactly the one statically unavoidable
     `env.sjon_host_invoke_plugin` function import, exact `prt_*`
     export set, no compiler markers) — frozen in 02.
  8. **Core-only expr capability, refused loudly, never silently.**
     `CompileResult.eval_schema` is core ⊕ the document's user plugins
     (`src/Compile.zig:263-272, 329-334`), so user-plugin expr heads are a
     real restriction of the binary path. `pacer pack`'s head walk is a
     grammar-context POSITION classifier (call positions only — never
     let/binder binding names, never pattern combinator heads) that
     resolves each collected head against BOTH schemas and refuses
     exactly the divergence: resolvable through `eval_schema` but not
     through the frozen core-only binary schema ⇒ diagnostic naming the
     head and span. Heads resolving in NEITHER schema are legal
     form-as-data and pack clean — no silent degradation, and no
     over-broad refusal of valid scores (01 freezes the rules).
  9. **Patterns gate on the prerequisite; a refusal blocks and escalates.**
     If SJON's owner declines, the pattern class is *blocked* — escalate to
     the user with the measured cost; "patterns stay text-path-only
     forever" is a user decision recorded then, not a plan default. Until
     resolution, `pacer pack` refuses `:pattern` scores and the wave's
     pattern-free stages are an explicit prototype.

- 2026-10-18 — The final independent review's findings applied against
  source (HIGH-1 the closure gate's module blind spot, MEDIUM-2 the
  unstated PACM trust model, LOW-3 canonical section presence), plus the
  parent-noticed fixups: the grammar-context head scan and the per-arm
  `EvalCore.Context.schema` contract. Decisions 6–8 re-frozen above; the
  detailed mechanisms live in 01/02. No plan outside this wave touched;
  no SJON-owner work was added by any of it.

- 2026-10-18 — The confirming review verified HIGH-1's traversal
  design, MEDIUM-2, LOW-3, and both parent fixups as fixed, and raised
  one residual finding, now applied as a docs-only amendment: layer
  2(a)'s empty-import-section rule was unsatisfiable under the plan's
  own build recipe, because `wasm_plugin_host` is hardcoded `true` for
  the `sjon` module (`SJON/build.zig:64`) and the extern is statically
  retained (`SJON/src/Expr.zig:2847-2852` into `invokeViaHostImport`).
  The allowance is now the frozen exact set (empty or exactly
  `env.sjon_host_invoke_plugin` at its source signature), stated in
  02's build paragraph, layer 2(a) and its synthetic-module tests, the
  P3 instantiate note, and the decision-7 mirror above.
  `plugin-exec` (the native plugin runtime, off) and `wasm_plugin_host`
  (the wasm host stub, on) are recorded as the two separate flags they
  are. No build recipe change, no SJON-owner work; every gate remains a
  plan gate — implementation is NOT STARTED and no WASM artifact has
  been built or tested by this wave.

## Open issues

| # | Issue | Status |
|---|---|---|
| O1 | SJON prerequisite (binary pattern query env + `(pure …)` leaves) | **Blocking** for 02 P4 and 03's pattern legs only; handoff drafted pacer-local, unfiled. Declined ⇒ blocked class + user escalation (decision 9). |
| O2 | Scene names / spans in the embedded PACM reference source text a text-free release doesn't ship | Non-blocking: the player audit reads names through the registry join and control ids inline; spans are inert u32 offsets (01's reader checks only their pairing). Documented opaque in `docs/binary-score.md` (created by 01). |
| O3 | Registry identity choice | Resolved at creation: exact canonical `'PACT'` bytes (decision 3). FNV kept as fast-reject. Frozen with PACB v1. |
| O4 | Payload caps (`MAX_PAYLOAD_BYTES`, `MAX_PAYL_BYTES`) and the input-zone worst case | Defined in 01 as proposals-with-rationale — measured format policy, not source constants and not mathematical claims (compact IR CAN exceed its source text; the packer ENFORCES via `pack_cap_exceeded` with the measured size, never assumes); frozen with v1; `pacbWorstCase()` comptime derivation feeds the zone assert. |
| O5 | Size/perf outcomes | **Measured later** — 02 P2's preliminary trend (incomplete, non-binding), 04's full report + user checkpoint. No budget invented now; the numeric ratchet exists only after the user ratifies one. |
| O6 | Pattern dry-run at load (binary) | Design decided, lands with 02 P4: `prt_load` dry-runs the first pattern cycle through the env-carrying binary query, mirroring the text path's acceptance ⊆ runtime rule (`src/PatternTrack.zig:61-70`) — decode accepts only what the frame path can evaluate. Before the prerequisite resolves there is nothing to dry-run: pack refuses pattern scores outright. |
| O7 | `pacer/rt` as a separate class vs a mode of `Pacer` | Proposed separate (`prt_*` makes mixing a link error); 02 P3 review is the decision point. |
| O8 | User-plugin expr functions on the binary path | Out of scope for this wave, refused loudly at pack (decision 8). A user who needs them on the binary path escalates; a future SJON follow-up (embedding plugin fn tables) would be its own pacer-local handoff. |
