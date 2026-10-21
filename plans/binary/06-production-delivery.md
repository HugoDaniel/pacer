# Plan prod-four — close the Pacer binary wave; migrate the Animader export to the runtime-only boundary

**Brief:** `.agent/control/prod-four-plan-brief.md` + `.agent/control/prod-four-planner-finish-brief.md`;
revised 2026-10-21 per `.agent/control/prod-four-revision-brief.md` (parent rulings over
`prod-four-adversary-report.md`; finding-by-finding dispositions in §G below).
**Status:** synthesized 2026-10-21 from completed recon (`prod-four-baseline-report.md`,
`prod-four-parent-premises.md`, `prod-four-design-direction-report.md`). No implementation and
no commit **from the planner**. For the execution wave, **local implementation commits are
authorized** (user 2026-10-20 four-stage go); push, merge, publication and registry activity
remain prohibited everywhere in this plan.

**Authority (unchanged, composed not rederived):** `plans/binary/00-strategy.md` (decision log
`:190`), `01-pacb-format.md` (done), `02-binary-runtime.md` (P1–P2 complete; P3 implemented,
scene-name blocker MET by the metadata wave; P4 open — patterns end-to-end),
`03-playback-parity.md` (P1–P2 closed; P3 open — T6a only, T6b + wasm leg pending; P4 open —
pattern legs), `04-measurement-acceptance.md` (created, not started; protocol frozen there),
`05-source-free-scene-names.md` (DONE — do not repeat), and the SJON ask29 handoff
`plans/binary/handoff-binary-pattern-query-env.md` (`:3-24`: feature DELIVERED, pacer adoption
NOT done).

**User authorization (2026-10-20, recorded):** all four stages authorized, including the
Animader export integration, **subject to measured property blockers**. This is permission to
run Group D after Groups A–C's correctness/property gates and the Group C measured report
exist. It is **not** a numeric size-ratchet approval and **not** permission to ignore a real
regression (parent premises). Record this authorization as a **dated append** to 00's decision
log in the first Group A commit; owner prose everywhere stays verbatim (historical wording such
as the runner's `skipped-pending-SJON` label is corrected only in the message-of-record texts
named in A3, and only to dated factual status).

**Endpoints (pinned, verified clean at baseline):** pacer `f9164b762f…`, SJON `bad5cddfc2…`,
pngine `e9aff0d581…`, animader `78c0917aea…` (content root `animader/animader`). Untracked
`pacer/zig-pkg/`, `pngine/pnpm-lock.yaml`, `pngine/pnpm-workspace.yaml` preexist — **never
touch**. The accepted Meridian release `.agent/releases/meridian*` is historical evidence —
**never overwrite**; new export goes to a fresh `--out` (export refuses an existing target).

**Vocabulary:** PACR = text, PACB = binary. Shared EvalCore, supplied-time runtime, live
controls and metadata semantics survive every group. No sampled-frame or consumer-interpreter
workaround anywhere.

---

## 0. Recorded baseline red name set (compare exact names; never quietly green)

**Animader `zig build verify` at `78c0917` (RED, pre-existing integration debt):**
1. `npm/animader/test/pacer-version.test.js:197` — "pacer's 'PACT' magic and header length
   equal animader's restatement" (regex at `:89` matches only a literal initializer; pacer
   `src/Abi.zig:135` is now the alias `= PactCodec.TARGETS_MAGIC`, literal home
   `src/PactCodec.zig:20`, value `0x54434150` unchanged).
2. `npm/animader/test/pacer-version.test.js:227` — "the hand-built 'PACT' encoder carries
   pacer's header and record shape" (same cause, `:90`).
3. `npm/animader/test/player-link.test.js:78` — vendor pacer JS file list stale: vendored 7
   (`audio, clock, host-check, index, lane, route, types`) vs source 10 (adds `meta.js`,
   `pact.js`, `rt.js`); printed remedy `sh player/sync.sh`.
4. `player-link.test.js:78` — `vendor/animader/animader.wasm` sha256 `00f923da…` ≠ fresh build
   `03f545be…`. **This old-vs-new hash pair does NOT establish nondeterminism** (parent
   premises): different toolchain/dependency inputs or a stale producer explain it. Group E1
   settles the question properly with two pinned-input builds.

**PNGine native suite (historical record, NOT re-run):** `123/128 steps; 1880/1894 tests (8
failed, 6 crashed)` — the 8 named `cli.inprocess_test` failures (compile `--minify` + early
returns; validate ok/invalid/missing/`--strict`/`--verbose`; render pNGb/`--no-embed`/
`--no-executor`/`--flat`/`--flat --audio`/`--html`/`--types` + early returns; `render --html`
payload-float magnitude; inspect summary/`--verbose`/`--strict`/PNG/`--deep`/`--frames`;
embed-extract-bundle-list round trips; diff match/size-mismatch/missing/presets) plus failed
step binaries `sjon-invalid`, `sjon-oom`, `executor-dedicated`, `core`, `sjon-mutate`. Any
regate compares these exact names.

**Pacer gates at baseline (GREEN, all five, re-measured 2026-10-20):** test 813/813; fuzz
380/380; verify 32/32 with 699/699 + corpus 43/0 + node 135/135; parity 43 = 24 replayed + 4
skipped-pending-SJON + 15 load-failing; audit-rt-imports closure frozen (12 pacer + 16 SJON
modules; `pacer-rt.wasm` 171,852 B, 1 import `env.sjon_host_invoke_plugin`; exports exactly 17
`prt_*` + memory). Parent re-ran all five exit-0 post-recon (`prod-four-parent-baseline.log`).

---

## Cross-cutting execution rules (bind every group)

- **Sequencing:** groups run A → B → C → D → E. Within a group, tasks land as **small
  sequential green commits**, one reviewed commit per task unless a task explicitly says
  otherwise. A commit is green only when its gate set passes on obs, foreground, exit-gated.
- **Workers:** implementation by user-selected GLM Flash workers, one bounded brief per task;
  an **independent fresh reviewer** gates every group; parent gates between groups. This plan
  launches nothing itself. Worker commits are **local commits** — authorized by the user's
  2026-10-20 four-stage go; never push, merge, publication or registry activity.
- **Native command shape (only on obs):**
  `obs sh -c 'cd /home/agent/worktrees/animader-init/pacer && ulimit -c 0 && ulimit -s 32768 && zig build <steps> --summary all'`
  (animader: same shape in `/home/agent/worktrees/animader-init/animader/animader`). **Never
  detach a long command; if a gate is slow, wait for it.** obs cannot read `~/.hermes` scratch;
  shared probes live under the workspace.
- **Env pins for anything animader-side:** `ANIMADER_PACER=/home/agent/worktrees/animader-init/pacer`,
  `ANIMADER_PNGINE=/home/agent/worktrees/animader-init/pngine` exported explicitly inside the
  obs command (`demo/prepare.mjs:35-36`).
- **Oracles stay independent:** text-first goldening (`zig build corpus -- --update`, diff
  reviewed) before any binary replay; corpus hex-bit convention pins f64/f32 exactly; no
  self-derived expectations; no weakened tests. Counts are **derived from execution counters at
  run time**, never copied from historical report shorthand (parent premises).
- **Do-not-start boundaries are literal.** Each task names what it must not touch.
- **Status records:** every gate/acceptance claim lands as a dated append to the owning plan's
  progress log; stale README/prose is preserved with dated records, never silently rewritten.

---

## Group A — pacer adopts the delivered SJON ask29 APIs; parity becomes no-skip

**Goal:** env-aware binary pattern evaluation + root-iterator drain + pattern packing live;
`zig build parity` reports **0 skipped** because the real pattern runtime path executes.
**Authority:** handoff `:3-24`, `:143-153`; 02 P4 (`02-binary-runtime.md:371`); 03 P3/P4;
baseline §4.1–4.3, §10 rows 1–4.

### A1 — root-iterator drain; flip the KNOWN-GAP
- **Consumes:** SJON `RootIter` drain delivered at `8b8a38ee` (exact-end exhaustion consumes the
  tree-trailing comment block through `null`).
- **Produces:** pacer's PACB payload walk drains the `RootIter` through `null` before treating
  leftovers as invalid; the test at `src/Pacb.zig:6359` ("KNOWN GAP — tree-trailing comments
  payloads currently refuse", comment `:6363-6372`) flips to acceptance; `src/Pacb.zig:6334`
  and `src/fuzz_pacb.zig:51-52` updated to match.
- **Coverage required (parent premises):** empty tree-trailing tail accepted; nonempty
  comment-only tail accepted (drained through `null`); **residual junk after the tail still
  rejected** (`payload_malformed`, reason 8); transactional state preservation pinned.
- **RED first:** new acceptance/junk tests fail against today's refusal; then the flip.
- **Files:** `src/Pacb.zig` (walk + `:6359` + `:6334`), `src/fuzz_pacb.zig:51-52`.
- **Gates:** `zig build test fuzz verify parity --summary all` green on obs.
- **Do-not-start:** no env query adoption (A2), no pack/parity changes (A3+A4), no SJON source
  edits.

### A2 — env-aware binary pattern evaluation in the runtime
- **Consumes:** delivered SJON APIs `PatternQuery.queryBinaryWithEnv` (`SJON/src/PatternQuery.zig:2412`)
  and `queryBinaryWithBudgetAndEnv` (`:2428`) — null-free env required; the entry selects eval
  semantics. The SJON **retained cursor** is adopted properly: results are taken through the
  delivered retention/ownership semantics of these APIs — no re-derived ownership or copied
  re-implementation.
- **Produces:**
  - **Explicit feature-gate removal:** the load-time refusal of every blob with
    `required_features` bit0 at `src/rt_entry.zig:254-261` (`unsupported_features`, reason 2)
    is lifted — pattern-capable blobs load.
  - **Plugin + schema:** `src/RtSjon.zig:39-41` (frozen `core_plugins` window) gains the
    `plugins.pattern` row per 02 `:345-353`; the "`plugins.pattern` waits for P4" note at
    `src/RtSjon.zig:24` becomes dated factual status.
  - **Load-time binary pattern dry run:** mirroring `dryRunExprs` (`rt_entry.zig:284`/`:415`)
    per 02 `:347` (the O6 decision, as the text path dry-runs at `PatternTrack.zig:61-70`);
    a load-time dry-run failure reports through the **reason-11 reserve with its exact
    current behavior** — no new reason, no invented ABI.
  - **Runtime materialization:** pacer's binary leaf arm (EvalCore binary `LeafSource`, 02 P1)
    materializes pattern leaves at runtime through the new binary query entry
    **`PatternTrack.queryCycleBinary`** (02:345 — the binary parallel of the tree-typed
    `queryCycle` at `src/PatternTrack.zig:102-112`; `cycleWindowOf`/`sampleAt`/`coerce` stay
    shared, so no second pattern interpreter), wiring the host outer env (transport clock +
    live control values) exactly as the tree arm does at `src/PatternTrack.zig:111`
    (`queryTreeWithEnv`); pattern-locals shadow rule (`cycle`/`tick`/`seed` win) preserved;
    the text path's compile-time dry-run at cycle 0 preserved so acceptance and per-hap
    semantics cannot drift; `result.dropped` gains the tree-path meaning.
  - **Closure delta (pre-authorized, minimal):** the `audit-rt-imports` allowlist gains
    `plugins/pattern` plus whatever the binary query pulls — **the named, reviewed delta per
    02:350-353**, explicitly pre-authorized by the parent (checked against `rt_entry.zig:254-261`
    and 02 `original02P4:345-355`). The audit's mutation is limited to this allowlist
    addition; the **artifact compiler controls are unchanged** — compiler-marker absence and
    the export surface (exactly 17 `prt_*` + memory) stay frozen. The scratch is already
    provisioned (`src/EvalCore.zig:270-279`) — no new allocation surface.
- **Forbidden:** the legacy frozen controls `queryBinary` (`:2338`) / `queryBinaryWithBudget`
  (`:2349`) — semantically non-equivalent (`(pure …)` → silence); **do not migrate to them**
  (parent premises). No second pattern interpreter.
- **RED first — independent encoded fixture (before pack support):** the RED test's PACB input
  is encoded **independently of `pacer pack`** (pack still refuses patterns until A3+A4), so
  the RED call exercises the **real runtime path** (load → schema → dry-run → eval): a
  binary-arm pattern eval reading `(pure (* beat 2))` — including head-position
  classification for `(pure …)` heads and combinator forms per the delivered SJON semantics
  (`PatternQuery.zig:2379-2411`) — plus the `tick` shadow and a control through parent scope
  (the `corpus/pattern-env` flavors, handoff `:75-78`) fails or is unreachable before wiring.
- **Files:** `src/rt_entry.zig` (gate lift `:254-261`; dry-run beside `:284`/`:415`),
  `src/RtSjon.zig` (`:24`, `:39-41`), EvalCore binary arm + `src/PatternTrack.zig` binary
  path (`queryCycleBinary`; exact diff owned by the implementer within the 02 layering —
  `EvalCore` imports no `Compile`), the `audit-rt-imports` allowlist (the named delta).
- **Gates:** `zig build test fuzz verify --summary all` green; `audit-rt-imports` green
  **against the updated allowlist** — this named delta is the pre-authorized change, and any
  closure change **beyond** it remains an escalation, not a commit.
- **Do-not-start:** pack-side and parity classifier/anchor changes (A3+A4), npm legs (A5).

### A3+A4 — one atomic commit: pack refusal lift + parity becomes skip-free
- **Atomicity ruling (BL-3, parent):** the pack refusal lift and the parity rewire land as
  **one atomic commit**. Splitting them leaves `zig build parity` red between commits (once
  the refusal is gone, `src/parity_runner.zig:372-374` turns every clean-pattern case into
  `error.PatternEncoded` → the `parity` step, `build.zig:438-440`, is red) or forces a
  retained skip — both violate the "small sequential green commits" rule. The single commit's
  scope: pack refusal lift, classifier clean-pattern arm, refusal-test amendments, payload-cap
  extension, golden regen, the all-features anchor, skipped-0 summary.
- **Produces (pack side):**
  - `pacer pack` accepts `:pattern` scores: refusal removed at `src/PacbEncode.zig:1049-1061`
    and its CLI surface `src/cli/Cli.zig:588`; pattern IR emitted into PACB per 01's format.
  - **IM-2 (enum32 reserve intact):** the `Compile.zig:215` diagnostic variant
    `pack_patterns_unsupported` is **kept as a frozen reserve emitted by no path** — the
    reason-7 precedent (`src/rt_entry.zig:161-163`). No removal, no reordering: the comptime
    ordinal pins at `:226-232` (`== 32`, `pack_cap_exceeded == 33`, "exactly 34 variants") and
    the `code_id: 32` ordinal in CLI goldens (`src/cli/testdata/starter-pack.json:8`) stay
    valid; only the variant's doc comment (`:212-215`) is refreshed to dated factual status.
  - **IM-1 (payload caps extended):** `src/PacbEncode.zig:1084-1113`'s per-payload and
    `'PAYL'`-total cap measurement loop extends to `.pattern` (the
    `encodePayload`/`payloadProfile` structural-rejection path at `:1086-1094` already
    generalizes), preserving the pack/decode invariant at `:1063-1069` ("a preflight-clean
    pack can never emit what decode would refuse") — **RED test first**.
  - **Refusal-test amendments (same commit):** `src/ParityTests.zig:216-228` (asserts the
    preflight refusal / "encode must never run"; runs under both `test` and `verify`,
    `build.zig:468`/`:472`) and `src/PacbEncode.zig:1460`/`:1635` flip to the new acceptance.
  - CLI golden `src/cli/testdata/starter-pack.json:8` regenerated and **reviewed as a diff**.
  - Message-of-record texts that say "await the SJON owner decision" (`src/parity_runner.zig:370`,
    `src/PacbEncode.zig:1054-1058`, the `Compile.zig` enum doc) updated to dated factual
    status (feature delivered at SJON `bad5cddf`); historical plan prose stays verbatim.
- **Produces (parity side):**
  - `examples-starter`, `pattern-basic`, `pattern-env`, `rig-studio` replay through the binary
    leg in `src/parity_runner.zig` (classifier `:408`, clean-pattern arm `:355-377` — now
    packs and replays instead of asserting the refusal); summary reports **skipped 0** with
    the skip *class* retained for future genuine pendings. `pattern-env` is the named
    acceptance fixture (handoff `:149-153`): beat-tracking across the wrap, `tick` shadow,
    control through parent scope — identical haps/diagnostics/dropped text vs binary. The
    synthetic all-features corpus score (expr + pattern + controls + scenes + tempo map +
    emit + trigger, 03 `:99-103`) is authored **text-first**, goldened via
    `zig build corpus -- --update` with the diff reviewed, then replayed binary-side.
  - **Acceptance shape (corrected):** parity = **28 clean replayed, and that 28 includes the
    4 pattern cases** (24 non-pattern + 4 former skips — not "28 non-pattern"); counts derived
    from execution counters at run time, never hardcoded. Plus the all-features case + 15
    load-failing, 0 failed, **0 skipped**.
- **RED first:** the pack of `corpus/pattern-env/doc.sjon` refuses today — capture it; the
  classifier-replay and payload-cap RED evidence lands in the task log, GREEN in the single
  atomic commit.
- **Gates (the one commit):** `zig build test verify cli-golden parity fuzz --summary all` —
  **parity is inside the gate set**; `audit-rt-imports` green against the A2-updated
  allowlist.
- **Do-not-start:** T6b negative suites (Group B); measurement (Group C); npm/wasm leg (A5 may
  follow in the same group, after this commit); the KNOWN-GAP flip is already done (A1) — do
  not reopen it here.

### A5 — wasm/npm leg closes 03 P4 and 02 P4
- **Consumes:** A3+A4.
- **Produces:** `npm/pacer/test/rt-corpus.test.js` replays the corpus (pattern cases included)
  through `zig-out/bin/pacer-rt.wasm`; `pacer pack` pretest produces fixtures under
  `npm/pacer/test/fixtures/` — the directory itself is added to `.gitignore` if the pretest
  writes beyond the already-ignored single file (OP-4, `npm/pacer/test/rt-fixture.pacb` via
  `.gitignore:8`); committed byte goldens only under `tools/testdata/pacb/`. Acceptance:
  **`pattern-env` green via the binary path** (02 P4's gate, `02-binary-runtime.md:371`) and
  npm parity count grows from 135 with **0 skipped** (derived, not copied).
- **Gates:** on obs — `cd npm/pacer && npm run lint && npm run typecheck && npm test` plus the
  five pacer zig gates.
- **Group A exit:** 02 P4 and 03 P4 accepted; dated appends to 02/03 progress logs and 00's
  decision log (the authorization record); independent reviewer gate; parent gate before B.

---

## Group B — T6b negatives and the counter/numeric resolution

**Goal:** 03 P3 closes: production-loader negative suites complete and the summary arithmetic
tells the truth. **Authority:** 03 `:87-97`; baseline §4.4–4.5, §10 row 5; parent premises
(derive and assert the actual category partition from execution counters).

### B1 — negatives summary arithmetic
- **Consumes:** mechanics pinned in baseline §4.5 (`src/parity_negatives.zig:843-849`:
  `names.items.len` = 39 counts the `"prefixes"` family label `:734` as a mutation; attempted =
  3738 counts real attempts; `skipped` hardcoded 0 `:701`).
- **Produces:** the summary prints the **actual partition** — named mutations, prefix cases,
  bad-call cases, family labels, attempted, skipped — each from its own execution counter with
  an internal consistency assertion (attempted == sum of parts). The prefix-family term prints
  **the loop's own counter** (`parity_negatives.zig:739`), not the `fixtures.keys_only.len`
  shorthand at `:844` that merely happens to equal it today (OP-3). The hardcoded `skipped 0`
  becomes a real counter or a deleted claim. The "(T6b … excluded from T6a)" qualifier at
  `:843` and the "T6a only, T6/P3 remain incomplete" line at `:847` are removed **only when**
  B2 has actually landed.
- **RED first:** a test asserting the printed partition fails today (39 ≠ 38 + …); then fix.
- **Do-not-start:** no expectation changes to any negative case; no reason-map changes.

### B2 — T6b suites: payload / PACM structure+coherence / registry / dry-run
- **Consumes:** 01's reader classes and 03's negative-suite design (`03-playback-parity.md:87-97`).
- **Produces, each an explicit expectation, never a crash:**
  - compact-payload class: zero-root, multi-root, trailing-slack (post-A1: slack that is *not*
    a drainable comment tail), corrupt bytes;
  - PACM structural garbage and PACM↔PACB incoherence: track/control registry lies, count
    mismatches, `'EASE'`/`'TMPO'` divergence — status 1 + `meta_incoherent` (reason 10) where
    semantic;
  - registry identity mismatch (already corpus-anchored; extend to loader negatives);
  - pattern dry-run budget negatives (budget trip at load → refusal, transactional pins intact)
    — the producer for a load-time trip is the A2 load-time pattern dry run (reason 11 reserve,
    exact current behavior).
- **Numeric/finite resolution (BL-1 corrected; parent-ruled characterization):** B2 pins **two
  disjoint, both-real expectations** —
  - (i) **one-sided mutation is incoherent:** a non-finite active lane present only in the PACB
    (PACM finite / different bits) decodes, then fails the PACM↔PACB `lanesEq` **bit-equality**
    cross-check (`src/Pacb.zig:2234-2242`, used for keys at `:2309` and control values at
    `:2331`) → status 1, reason 10 `meta_incoherent`;
  - (ii) **self-consistent non-finite bits on both wires load clean** — the actual v1 semantic:
    KEYS/CTRL active-lane decode has no finiteness gate (`Pacb.zig:1320-1325`, `:1768-1775`;
    `Pacm.zig:435`/`:441`); only the pad-lane zero rule (lanes ≥ `ncomp` → `key_invalid`) and
    CTRL `min`/`max` finiteness when flags are set (`:1782`/`:1797`) gate. This is recorded as
    a **named v1 domain fact**: characterization/preservation of the existing documented
    bit-equality domains — **not** an assertion that the compiler can generate such values and
    **not** new user ratification. No commit in this group emits reserved reason 7
    `non_finite` (`src/rt_entry.zig:165-179`), silently changes the existing load domain, or
    converts (ii) into a refusal — that would be the first emitter of reason 7 and stays a
    reviewed wire-semantics escalation for the user, never a side effect.
  - **Acceptance/refusal matrix recorded explicitly** and each cell tested against **actual
    behavior**: finite / NaN / +inf / -inf / -0 / pad lanes / `min` / `max`, across KEYS
    active + pad lanes, CTRL value + min/max, the PACM reader, and the PACM↔PACB cross-check —
    plus **evaluation write safety according to original semantics** (a loaded non-finite lane
    value propagates to the uniform write exactly as v1 does; no invented sanitizer, no
    invented rejection — the tests characterize what the frame actually writes). If testing
    shows the documented v1 property invariant is actually broken by current source (e.g. the
    approved spec forbids emitted non-finite yet such a frame emits), report it with precise
    source evidence and escalate separately — do not invent rejection and do not weaken tests.
- **Gates:** `zig build test fuzz verify parity --summary all` green; the fuzz leg still
  380+ derived count, 0 skipped.
- **Group B exit:** 03 P3 accepted; dated appends; independent reviewer gate; parent gate
  before C.

---

## Group C — Plan 04 measurement, executed once, frozen protocol, no invented ratchet

**Goal:** the binding post-pattern measurement report exists; the integration decision point is
honored as already-authorized (dated append), subject to the property blockers below.
**Authority:** `04-measurement-acceptance.md` verbatim protocol; parent premises (no numeric
threshold ratified; no `size-check` verb created).

### C1 — environment record
- With every table: CPU model, RAM, OS, `zig version` (0.16.0), optimize flags (ReleaseSmall),
  pacer + SJON SHAs, date, node version (obs v22), `gzip -9` / `brotli -q 11` tool versions,
  machine idleness note. Every number measured on this record — nothing carried over. The
  C4/C5 counting-GPA harness provenance is part of this record; **protocol repeats and noise**
  (median ± MAD at the protocol's N) and the **exact machine** are recorded, not summarized.

### C2 — size columns (per file, raw / gzip9 / brotli11; the `meridian.size.json` per-file
method, cited as `animader/animader/.agent/releases/meridian.size.json`)
- `pacer.wasm` (full driver) — re-measured, not the 661,334 / 238,810 / 194,275 historical row;
- `pacer-rt.wasm` at **both** capability sets: the pattern-free artifact (labeled incomplete,
  trend-only) and the post-Group-A full-capability artifact (**the binding one**);
- JS glue as shipped: `index.js` vs `rt.js` + shared modules, and the whole published file set
  the page loads;
- score pair for representative scores: `score.sjon` vs `score.pacb`, with the **PACM
  duplication named** (PACB embeds the metadata blob verbatim);
- the `Pacm` reader's artifact cost as its **own row** (00 decision 6), measured by
  **controlled ablation** — two builds differing only in the reader's inclusion (precedent
  `binary02-t25-ablate-*.log`); the row reports the **measured delta**, never arithmetic
  subtraction over unrelated artifacts (IM-6);
- program totals exclude demo music (the `musicPath` scoping convention).

### C3 — load performance
- N = 50 cold samples per path, **interleaved** to decorrelate drift; text `drv_load(doc)`
  (compile included) vs binary `prt_load(pacb)`; median ± MAD and p10/p90. Warm reload on a
  live instance, N = 50, same stats. Same machine class as the environment record.
- **Protocol-substitution guard:** every timing row is **explicitly labeled** as
  native-harness or real-shipped-WASM-artifact measurement — the shipped artifact is the
  reference; the native counting harness (C4/C5) never silently substitutes for it.

### C4 — eval latency distribution + allocations
- Per representative score: (a) Meridian-shape minimal (keys + expr + controls); (b) the
  synthetic all-features score (exists after A3+A4 — **no all-features claim before it**). Sweep
  **100,000 frames** per path per score across scripted times including loop wrap, scene seeks
  and non-monotonic revisits; report per-frame µs p50/p95/p99/max plus **allocation counts per
  frame**. **Ship-blocker class:** any frame-path allocation or nondeterminism the text path
  does not have.
- **Instrument (IM-5, parent-approved):** a **native-only counting-GPA harness** (precedent:
  the `native-composition` probe pattern, `build.zig:348-395`) driving the same production
  decode/eval path — exact production composition, per-frame counts plus reset and peak
  recorded. **No new shipped exports**: shipped wasm artifacts are untouched; native-harness
  timing rows are labeled as such (C3 guard).

### C5 — memory
- Same native-only counting-GPA instrument as C4 (no new shipped exports). Peak bytes and
  allocation counts per load and per steady-state frame, both paths; the `DecodedScore`
  ownership copy (02 P2 B3) as its own row.

### C6 — report + decision point
- **Produces:** `docs/binary-perf-YYYYMMDD.md` (date at execution) committed **with raw sample
  data beside it**; every table names its environment record. No number appears in any plan or
  README before it appears in this committed report.
- **No ratchet:** `zig build size-check` does not exist and is not created; a ratchet exists
  only if the user ratifies a number later (04 `:93-97`).
- **Blocker check (04 `:87-92`, verbatim classes):** (a) any parity failure of any class;
  (b) any frame-path allocation or latency REGRESSION beyond measured noise (median ± MAD over
  N=50/100k, same machine); (c) a nondeterminism the text path doesn't have. If any fires:
  **stop Group D, escalate with evidence** — no silent narrowing. Otherwise the 2026-10-20
  authorization carries D forward; record the checkpoint outcome as a dated append to 00's
  decision log and 04's progress log.

### C7 — pacer-local vertical smoke (04 P3)
- `examples/` gains a minimal player page mirroring `loadDerivedShow`'s shape
  (`animader/animader/demo/lib/score.mjs:300-325`): fetch `score.pacb` + `pacer-rt.wasm`,
  `PacerRt.load`, drive `eval(t)` from a host clock, route writes through the unchanged
  `route.js`. Proves in a real browser: the registry join, meta audit inputs (track names via
  the join, control ids via embedded PACM), first-frame `eval(0)` semantics, restart
  (reload ⇒ teardown ⇒ re-apply held controls). Executed by the parent's shell-denied
  browser-tester against a parent-started server; this plan claims no browser result in advance.
- **Group C exit:** report committed; blockers evaluated; 04 P1–P3 closed; independent reviewer
  gate; parent gate before D.

---

## Group D — supported offline compile/pack + the Animader compiler-free export graph

**Goal:** a fresh standalone export whose deployed graph contains **no compiler, no source, no
text-path load**: offline `pacer pack` at export time over the reflected join; the page loads a
real `'PACB'` through PacerRt (`prt_*`, `pacer-rt.wasm`). **Authority:** plan-brief `:11`;
baseline §5; parent premises (Stage-4 scope: consumer seam fix, freshness, bytes-served audit);
design-direction report §2–§3 (preservation, no redesign).

### D1 — fix the consumer PACT source-pin reader (seam fix, no weakened detection)
- **Consumes:** recorded red rows 1–2 (§0).
- **Produces:** `npm/animader/test/pacer-version.test.js`'s reader (`:89-90`) resolves pacer's
  constant **through its alias**: follow `src/Abi.zig:135` → `src/PactCodec.zig:20` and compare
  values/record shape against animader's restatement. **OP-1:** the alias reader also follows
  `TARGETS_HEADER_LEN` (`src/Abi.zig:143`, aliased like `:135`), and the doc-shape checks
  (`pacer-version.test.js:94-97`) read the file now carrying the doc lines
  (`src/PactCodec.zig:5-6`) — or the guard reds on a moved comment. The guard must still catch
  **genuine** upstream constant/shape drift — prove it with a bounded temporary perturbation of
  the literal home (guard fails) restored byte-identically afterwards, covering literal **and
  shape/comment-home** mutation. Reading aliases must not turn the
  test into self-referential equivalence (parent premises). **Pacer's production format does
  not change to satisfy the brittle regex** — the consumer reader moves, the wire stays.
- **Do-not-start:** vendor sync (D2), export changes (D3+).

### D2 — vendor freshness: sync the bundle; close the producer-drift blind spot
- **Consumes:** recorded red rows 3–4 (§0); baseline §7 (`prepare.mjs --verify` checks only the
  bundle against its own recorded provenance, `demo/prepare.mjs:203-240` — producer drift after
  prepare is invisible by design).
- **Produces (IM-4 exact path/pins):** the sync script is `examples/hello/player/sync.sh` (not
  `player/sync.sh`), run on obs as
  `PNGINE_NPM=/home/agent/worktrees/animader-init/pngine/npm/pngine PACER_NPM=/home/agent/worktrees/animader-init/pacer/npm/pacer sh examples/hello/player/sync.sh`
  (the script's defaults point at `$HOME/Dev`, absent here — `sync.sh:17-18`) **after its two
  prerequisite fresh builds**: the animader `zig build wasm` artifact (`sync.sh:19-23`) and a
  current `pacer/npm/pacer/pacer.wasm` (baseline §7: vendored 661,334 B vs producer 666,873 B).
  The two vendor trees are distinct and both refreshed, never conflated:
  `examples/hello/player/vendor` via `sync.sh` (vendored pacer JS 7 → 10: adds `meta.js`,
  `pact.js`, `rt.js`) and `demo/vendor` via `node demo/prepare.mjs` with the
  `ANIMADER_PACER`/`ANIMADER_PNGINE` env pins — so every vendored
  artifact is the current producer's (incl. `animader.wasm` and `pacer/pacer.wasm`); the
  freshness seam extended so **stale-but-compatible** artifacts are caught, not just missing
  files — i.e. a current-version file-list check **and** a producer-digest-vs-vendor check
  distinct from recorded-bundle integrity; proven by a demonstration that a deliberately stale
  (but shape-compatible) vendored artifact is flagged. `vendor/provenance.json` regenerates with
  path+bytes+sha256 per file.
- **Acceptance:** animader `zig build verify --summary all` **green** on obs, with the §0 red
  name set compared exactly — the same four rows now pass by name; nothing else regresses
  (403/403 native side stays green; the `run node` step goes green). Never quietly green.
- **Do-not-start:** export pipeline changes (D3); PNGine anything (E5); the §0 historical
  records are append-only evidence — do not edit them.

### D3 — offline compile/pack in the export pipeline over the reflected join
- **Consumes:** Group A (pack patterns live), Group C (blockers clear), D2 (fresh vendor).
- **Produces (`animader/animader`, demo tooling only):** `demo/lib/export.mjs` gains the
  offline pack stage: after the vendored `PieceHost.score` derives the score and the reflection
  is read back from the baked payload (`extractBytecode`/`parseUniformTable`,
  `demo/lib/score.mjs:75-101` `reflectedJoin` — the reflection's **own target list in table
  order**; a field without a WGSL type or non-integer `elemCount` stays a named
  `bad_reflection` at `stage: 'reflect'`, never a guessed target), run the **real `pacer pack`**
  CLI (pinned via `ANIMADER_PACER`) to emit `assets/score.pacb`. `EXPORT_FILES`
  (`demo/lib/export.mjs:21-31`) changes by substitution: `pacer-rt.wasm` in, driver
  `pacer.wasm` out; `assets/score.pacb` in, `assets/score.sjon` out; the esbuild 0.24.2
  minified single-ESM `app.mjs` (no source map, no unbundled sources) now bundles
  `npm/pacer/src/rt.js` + shared modules instead of the compile path. The page loads through
  `PacerRt.load`; the baked payload's reflected uniform table defaults arrive byte-faithfully
  so the READY frame is the score's beat-0 state (design report §2.1 — physical (72,432) at
  1280×720 DPR 1, zero corner ink).
- **Boundary audit (parent premises):** no source/compiler module reachable from the deployed
  graph **even behind runtime branches** — the bundle's **own modules, including the shared
  boot, must split the compiler module out rather than fall back** to a bundled compile path;
  a shared-boot import audit over the bundle proves
  the compiler closure is absent, complementing pacer's frozen `audit-rt-imports`. The
  development CLI/player stays compiler-capable (preserved below) — only the deployed release
  graph is compiler-free. No repo outside the four authorized ones (pacer, SJON, pngine,
  animader) is touched.
- **Preserved:** the development CLI compiler/player; transport audio-master clock; the
  acknowledged renderer restart; the initial READY frame; reusable vertical seams; the show
  itself (no redesign — Rule/Gates/Bloom compositions untouched). PACR text stays the authoring
  format; PACB is the shipped format.
- **Gates on obs:** demo suite `cd demo && npm test` (192/192 baseline, derive at run time, 0
  skipped) + `zig build verify` green + pacer's five gates green at the pinned SHA.
- **Do-not-start:** serving/QA (Group E); Meridian artifacts untouched; no `index.html`/
  `player.css`/controller copy changes (design contract §2.2–2.3).

### D4 — fresh reproducible export + size/manifest evidence
- **Produces:** `node demo/export.mjs demo/pieces/three-scenes-82 --seconds 36 --out
  .agent/releases/<new-name>` on obs (existing-target refusal honored; `<out>.next` staging;
  detached `<out>.size.json`). Evidence package beside it, same conventions as Meridian:
  `manifest.json` per-file sha256; `<out>.zip` (ZIP_DEFLATED 9, fixed timestamp 1980-01-01) +
  `.zip.sha256` + `.archive.json` with `reproducible_two_runs`; `.size.json` per-file
  raw/gzip9/brotli11 **with music itemization** (`musicPath` scoping); **before/after
  same-project apples-to-apples** table against the Meridian numbers (named as a different
  runtime boundary, never a regression claim); whole-folder notices/`LICENSES.txt`. Cold HTTP
  bodies are separated from archive bytes in the report (wire vs disk).
- **Do-not-start:** QA before E's servers/instruments exist; no numeric budget claims anywhere
  (Group C rule binds).

---

## Group E — artifact/reproducibility proof + isolated-HTTP full-show QA + design review

**Goal:** the new export is proven on the wire, on real-GPU-capable desktop and mobile, with
pixels/PCM/clock evidence, then reviewed. **Authority:** plan-brief `:11-13`; design-direction
report §1, §4; parent premises (bytes-served audit; instrument honesty).

### E1 — reproducibility, correctly posed
- Two builds of each shipped wasm (`pacer-rt.wasm`, and where vendored `pacer.wasm` /
  `animader.wasm`) with **pinned identical inputs/flags/host** (obs, zig 0.16.0, ReleaseSmall,
  same SHAs, same cache-clean starting point) → compare digests. Only this comparison may
  attribute (non)determinism; the §0 row-4 old-vs-new pair is **not** such evidence (parent
  premises). Two consecutive export runs prove the archive's `reproducible_two_runs`.
- Record digests and the exact pin set in the E evidence report.

### E2 — isolated serving
- Parent starts a fresh static server (brotli, the `:8072` pattern) over the new export only —
  isolated webroot, no dev server (`:8071`) involvement. Parent hands the live URL to the
  shell-denied browser/design roles. Deployed graph audited **as bytes served**: exactly the
  manifest-authorized requests + one blob worker, all under the export root, all 200 — with the
  substitution only (`pacer-rt.wasm` + `assets/score.pacb` in; driver `pacer.wasm` +
  `assets/score.sjon` out). No `animader.wasm`, no dev/runtime/source fetches, no compiler
  module — verified from network logs, not inferred.

### E3 — full-show technical QA (pixels / PCM / clock), desktop + mobile
- Viewports: desktop 1280×720 DPR 1 and mobile 390×844 (design report §4). Native heavy gates
  and browser QA are **serialized** (the remote GPU browser shares obs resources).
- **Instrument explicitly recorded** in the evidence report: which MCP/driver produced every
  capture. The design-direction pass used Playwright headless Chromium as a **fallback** — the
  desktop real-GPU Browser MCP was **not connected**; this plan claims no instrument that is
  not connected at execution time. If only headless Chromium is available, the qualifier is
  recorded exactly as the design report did.
- Clock/scene evidence: scene transitions at ticks **1171 / 2342** (11.71 s / 23.42 s); 36.0 s
  host run with the ~0.88 s hold tail; background morphs at beats 14→16 and 30→32 are
  transitions, never cuts; end holds (all 8 vermilion triangles + circle), no fade to black;
  end red-pixel mass ~6,515 at 1280×720 DPR 1 (baseline anchor, re-measured not assumed).
- Pixels: READY frame = uniform defaults (Traveler circle at the authored origin, zero corner
  ink) — this proves the PACB repack carried the reflected defaults byte-faithfully; Rule /
  **Gates** / **Bloom** checkpoint captures compared against
  `animader/.agent/control/release82/evidence/screenshots/release82/` (the authored scene names
  are Rule/Gates/Bloom — no Field/Afterimage exists).
- Interaction: Start via native gesture (AudioContext create/resume) on both viewports;
  pause/resume via Space/tab; **Stop is terminal** (it does not resume — the ended state shows
  `ended — 36.0 s` with only Restart visible); tab-hide pause (frozen clock moves no ticks);
  Restart → early Rule, no stale Bloom ink; fault-injected load failure → the
  existing `error — <stage>` banner + auto-open diagnostics (no new visual language).
- PCM/audio: audio-master clock drives the show; PCM evidence captured where applicable
  (parent's QA owns the exact probe; this plan names the requirement, not a fabricated result).
- Hygiene: console 0 messages / 0 errors / 0 warnings across the whole run on both viewports.

### E4 — design review
- Against the design-direction §4 checklist (12 items), by the parent's design role over the
  deployed URL: chrome tokens/type/spacing/focus/letterbox byte-intent unchanged (`player.css`,
  `index.html` structure, status strings verbatim); pre-existing accepted traits (windowed
  1280×720 below-fold controls, tiny mobile motif, off-centre Bloom) labeled **baseline**,
  never migration blockers; any new anomaly labeled baseline-vs-migration explicitly. No
  redesign, no new UI, no copy changes ride along.

### E5 — PNGine and unprovisioned gates (qualifiers, no quiet greens)
- PNGine native suite stays a **historical red on record** (§0 exact name set); if a regate is
  run, compare exact names and report deltas by name; never quietly green. The npm-side
  envelope/bundle layer (423/423 in the same record) may be re-run as the supported surface.
- Genuinely unprovisioned gates are named with qualifiers, not hidden skips — and are **not a
  blanket excuse**: gates that can run with the four authorized repos available must run,
  without changing unrelated repos (`wgslender` etc. stay untouched).
  `examples/hello/check.sh` needs sibling `wgslender` (outside the authorized four repos);
  `spike/ pnpm test` begins with an install — the baseline no-installs record is **baseline
  scope, not a standing user prohibition**; if a genuinely new dependency is truly needed,
  ask the user first rather than installing silently or skipping by an invented rule; desktop
  real-GPU Browser MCP only if actually connected at execution time.
- **Group E exit (evidence tracking corrected):** `.agent/` is excluded from git
  (`.git/info/exclude:7`) — E1–E4 raw evidence reports stay under `.agent/control/` (dated,
  ignored, preserved as raw evidence; they can never be committed there, and huge recordings
  are never force-tracked); **condensed tracked acceptance records land in `docs/plans/` with
  a path+hash manifest** pointing at the ignored raw evidence. Meridian
  archive preserved beside the new export, independent browser + design reviews PASS or the
  delta is escalated with evidence. Parent gate closes the delivery.

---

## Global completion criteria (all required)

1. Pacer five gates green at the final SHA, with **parity skipped = 0** (real pattern runtime
   path), T6b landed, negatives summary partition derived-and-asserted, and the reason-7
   reserve unemitted.
2. `docs/binary-perf-*.md` committed with raw data; the three blocker classes evaluated; no
   `size-check` verb exists.
3. Animader `zig build verify` green with the §0 red name set resolved **by name** (consumer
   seam fixed, drift detection demonstrably intact, freshness seam catches stale-but-compatible).
4. New export exists with reproducible archives (two pinned builds; `reproducible_two_runs`),
   per-file raw/gzip9/brotli11 + music itemization, before/after apples-to-apples vs Meridian,
   bytes-served graph audit clean (no compiler/source reachable even behind runtime branches).
5. Desktop + mobile full-show QA evidence (pixels/PCM/clock/instrument recorded) and design
   review PASS against the §4 checklist; console 0/0/0; network confined to the manifest graph.
6. Every plan's progress log carries dated appends; owner prose preserved; the 2026-10-20
   authorization recorded in 00's decision log; no push/merge/publication anywhere.

## Explicit non-goals
- No rederivation/redesign of the 00–05 architecture; no redesign of the show or chrome.
- No implementation inside this planning run; no source edits, no commits from the planner.
- No migration to SJON legacy `queryBinary`/`queryBinaryWithBudget`; no second pattern
  interpreter; no sampled-frame or consumer-interpreter workaround.
- No overwrite of `.agent/releases/meridian*`, the §0 historical logs, or owner README prose.
- No numeric size threshold, no ratchet verb, no performance claim before the committed report.

---

## §G — Adversary-finding dispositions and control-plane rulings (2026-10-21 revision)

Every finding in `prod-four-adversary-report.md`, disposed. Authority:
`prod-four-revision-brief.md` — the parent pre-checked BL-2's gate site
(`rt_entry.zig:254-261`), 02's plugin/pattern closure pre-authorization
(`original02P4:345-355`), and BL-1's `lanesEq` bit equality (`:2234-2242`).

**BLOCKERs**
- **BL-1** (B2's non-finite expectation false for self-consistent bytes): disposed in **B2** —
  two disjoint pinned expectations: (i) one-sided (PACB-only) non-finite mutation → status 1,
  reason 10; (ii) self-consistent non-finite bits on both wires **load clean**, recorded as a
  named v1 domain fact — characterization/preservation of documented bit-equality domains,
  not an assertion the compiler generates such values, not new ratification. Full
  finite/NaN/inf/-0/pad/min/max acceptance-refusal matrix recorded and tested against actual
  behavior, with evaluation write safety per original semantics; a genuinely broken invariant
  escalates with precise source evidence — never invented rejection, never weakened tests, no
  emitted reason 7. (Resolves the adversary's user-question 1: pin (ii); refusal conversion
  stays a separate reviewed wire-semantics escalation.)
- **BL-2** (A2 gate/plugin/closure unowned; "closure unchanged" contradicted 02): disposed in
  **A2** — explicit feature-gate removal (`rt_entry.zig:254-261`), `plugins.pattern` schema
  row (`RtSjon.zig:39-41`; `:24` note updated), load-time binary pattern dry run mirroring
  `dryRunExprs` with the exact current reason-11 reserve behavior (no invented ABI), and the
  audit-rt-imports allowlist addition applied as **the named, pre-authorized reviewed delta
  per 02:350-353** — audit mutation limited to the allowlist; artifact compiler controls
  (compiler-marker absence, 17 `prt_*` + memory exports) unchanged. (Resolves user-question 3:
  no false mid-group escalation.)
- **BL-3** (A3→A4 interim red / retained skip): disposed by folding A3+A4 into **one atomic
  commit** — pack refusal, classifier clean-pattern arm, refusal-test amendments
  (`ParityTests.zig`, `Cli.zig`, both PacbEncode tests), payload-cap extension, golden regen,
  all-features anchor, skipped-0 — with `parity` inside the commit's gate set. (Resolves
  user-question 2: atomic.)

**IMPORTANTs**
- **IM-1** → A3+A4 pack scope: `PacbEncode.zig:1084-1113` cap measurement extended to
  `.pattern` (RED first), preserving the `:1063-1069` pack/decode invariant.
- **IM-2** → A3+A4: `pack_patterns_unsupported` (ordinal 32) kept as a frozen reserve emitted
  by no path — no removal/reordering; only the doc comment refreshes to dated status.
- **IM-3** → header + Workers rules: planner commits nothing; implementation local commits
  authorized; push/merge/publish prohibited.
- **IM-4** → D2: exact `examples/hello/player/sync.sh` path with `PNGINE_NPM`/`PACER_NPM`
  workspace pins, both prerequisite fresh builds, and `examples/hello/player/vendor` vs
  `demo/vendor` named as distinct trees.
- **IM-5** → C4/C5: native-only counting-GPA harness (native-composition precedent),
  production composition, counts/reset/peak, no new shipped exports. (Resolves
  user-question 4: approved.)
- **IM-6** → C2: `Pacm` reader row by controlled ablation, measured delta, no unrelated
  subtraction.

**OPTIONALs**
- **OP-1** → D1: alias reader follows `TARGETS_HEADER_LEN` and reads doc-shape lines from
  `PactCodec.zig`; perturbation-restore proof retained.
- **OP-2** → A2: the new binary entry is named `PatternTrack.queryCycleBinary`; shared helpers
  untouched — no second interpreter.
- **OP-3** → B1: the prefix term prints the loop's own counter.
- **OP-4** → A5: `npm/pacer/test/fixtures/` gitignored if the pretest writes beyond the
  already-ignored file.

**Control-plane rulings from the revision brief, landed beyond the findings:** SJON retained
cursor adopted properly (A2 Consumes); the A2 RED fixture is encoded independently of
`pacer pack` so RED calls the real runtime (A2); head-position classification with `(pure …)`
heads and combinators covered through delivered SJON semantics only (A2); earlier tasks' gates
spelled accordingly (A2 gates reference the updated allowlist; the A3+A4 gate set includes
parity); B1 asserts the real category partition from execution counters (B1); B2 distinguishes
one-sided incoherence from self-consistent acceptance without changing the load domain or
emitting reason 7 (B2); C rows explicitly label native vs shipped-WASM measurement and record
repeats/noise/exact machine (C1/C3); D confines changes to the four authorized repos and
requires the bundle's own modules incl. boot to split the compiler rather than fall back
(D3); E keeps raw evidence under ignored `.agent/control/` with condensed tracked records +
path+hash manifest in `docs/plans/`, corrects Stop (terminal) vs pause (Space/tab), pins the
metadata scene names Rule/Gates/Bloom exactly, treats unprovisioned gates as named limitations
rather than a blanket excuse, rejects an invented standing no-install prohibition (ask when a
dependency is truly needed), and retains the PNGine historical qualifier with no unrelated
repairs (E3/E5).

---

## Review disposition (dated append — not plan prose)

Copied verbatim on 2026-10-21 from `.agent/control/plan-prod-four.md`
(revised 2026-10-21) as the tracked executable plan of record for the
production delivery wave. The plan body above is the owner requirements
— unmodified.

Independent final review (2026-10-21): **READY**. Every BL/IM/OP
correction landed, task scopes are green between commits, no invented
wire semantics or reserved-enum deletion. Blockers: none. Important:
none. Residual findings recorded in the review, neither a correction
gate: LOW-1 (B2's reason-7 cite may align to `rt_entry.zig:161-163`),
LOW-2 (confirm `.agent/` git exclusion in the repo holding the E1–E4
evidence — confirmed present in this worktree's gitdir
`info/exclude:7`). A1 independently startable per the review's "A1
independent start" section. Full verdict and finding-by-finding
verification: control-plane `.agent/control/prod-four-plan-final-review.log`.

---

## A1 status append (dated — not plan prose)

2026-10-21 — A1 executed and review-corrected; A2–A5 not started. The
drain + KNOWN-GAP flip landed as `89b562d`. The independent A1 review
(verdict "With fixes", `.agent/control/prod-four-a1-review.log`) found
one HIGH and one LOW; both are closed test-only:

- **HIGH — flag-ON + empty count-0 tail accepted, uncovered** (a
  writer-produced shape: `emitCommentsByRange` writes the count varint
  even at count 0): closed at all three levels — third shape added to
  the flipped Pacb test (flags byte `0x20` pinned; length pinned at
  compact + 3: the flag-alone empty comment pool's 2 bytes + the 1
  count-0 varint; last byte `0x00`), an independent hand-spelled
  `[count 0]` wire fixture accepted by the walk, and a real-loader
  mirror `rt_entry (m)` through `loadPacB` (status 0, live score).
  Original fixtures/oracles untouched.
- **LOW — `splicePayloadRecord` "no canonical-order assumption" was
  false for 'TRAK' after 'PAYL'**: closed with the true precondition
  asserted in the helper (`trak_off < payl.off`) and a corrected
  comment; no helper redesign. The wave also fixed a latent test-helper
  size-computation panic in the shrink direction, first exercised by
  (m) (test-only file, one line).

Teeth proven per the correction brief: the new tests run against the
PRE-FIX drain in an isolated scratch worktree (`f9164b7` checkout,
sibling `../SJON` root preserved) refuse with the actual reason —
walk-level `.payload_malformed at 37`, loader-level `status=1
reason=8` — 813/819 (6 failed); source restored byte-identical (md5
verified), scratch GREEN 819/819, then all five gates green on the
restored tree (`zig build test` 819/819; `zig build fuzz parity
audit-rt-imports verify` exit 0 — fuzz 383, corpus 43/0, parity 43/0
with the 4 pinned skips, negatives 3738/0 skipped, node 135/135,
audit closure 12+16 frozen). Commands, logs and the diff:
`.agent/control/prod-four-a1-corrections-report.md`. The report's
"both tail shapes" coverage claim is corrected in place, dated.
