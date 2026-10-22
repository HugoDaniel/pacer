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

## A2 status append (dated — not plan prose)

2026-10-21 — A2 executed as ONE atomic commit `f76267d` on top of A1
(`33750f0`); A3+A4/A5 not started. The full runtime path landed:
`PatternTrack.queryCycleBinary` through the delivered
`queryBinaryWithEnv` (retention/ownership = SJON's delivered
semantics; no re-derived owner API), the `required_features` bit0
load gate lifted at `rt_entry.zig`, the EvalCore binary `.pattern`
`unreachable` arm replaced (shared window/sample/coerce — no second
interpreter), `RtSjon` `plugins.pattern` row + the frozen core⊕pattern
runtime schema, the load-time pattern dry-run (`dryRunPatterns`:
scene start/cycle 0, document `:value` controls, `PatternTrack.
SCRATCH_BYTES` FBA, acceptance = text dry-run's gates) refusing
through the exact reason-11 reserve, and the audit-rt-imports named
delta (12 pacer + **17** SJON visited; artifact contract unchanged —
exactly 17 `prt_*` + memory, 1 import, compiler markers absent;
`pacer-rt.wasm` 188,442 B). RED first: the four new production-loader
tests fail at the pre-lift gate (`reason 2`) —
`.agent/control/prod-four-a2-red-6.log`. GREEN: `zig build test`
829/829; `zig build fuzz parity audit-rt-imports verify` exit 0 —
fuzz/corpus 43/0, parity 43/0 **with the 4 pattern skips unchanged**
(A3+A4 scope), negatives 3738/0, node included in verify's 1101/1101;
post-commit re-run green. The RED fixture producer is the test-side
lower-level bypass (`Compile` + `PacbEncode.encode` — T3.1's uniform
path that already serializes patterns), NOT a production backdoor:
`pacer pack` still refuses `:pattern` scores until A3+A4. Logs and
report: `prod-four-a2-red-6.log`, `prod-four-a2-green-3.log`,
`prod-four-a2-green-gates.log`, `prod-four-a2-green-4-postcommit.log`,
`prod-four-a2-report.md`.

## B1 status append (dated — not plan prose)

2026-10-21 — B1 executed as ONE atomic commit `fd2e289` on top of A2
(`a7a3c78`); B2 not started (the "T6a only / T6b incomplete" qualifiers are
intentionally untouched until B2 lands). The negatives summary now prints
the actual category partition from execution counters: `35 named + 3
bad-call + 3700 prefix = 3738 attempted; 39 names = 35 mutation name(s) +
3 bad-call name(s) + 1 family label(s)`. Each term is its own counter
incremented where the operation executes (`Counters` in
`parity_negatives.zig`): the prefix term is the loop's own increment
(asserted equal to the loop counter — never the `fixtures.keys_only.len`
shorthand, OP-3), the `"prefixes"` label is counted as a label and never an
attempt, the three fixture setup loads and the bad-call family's
prior-reason re-eval stay uncounted (setup/probe loads, not attempts), and
the hardcoded `skipped 0` claim is deleted as unsupported. Internal
consistency asserts the exact arithmetic before printing (attempted ==
named + bad-call + prefix; names == mutations + bad-calls + labels), else
`error.CounterMismatch`. The ParityTests report gate no longer self-derives
its expectation: it pins a literal expected inventory (independent of the
counters) and requires every name's success line exactly once, so a removed
or double-counted run call fails per name. No mutation, reason, oracle,
fixture, or try count changed; no runtime behavior or reason-map change.

RED first (prod-four-b1-red-1.log, 828/829): the partition gate failed on
today's summary — "39 named mutation(s) + 3700 prefix case(s) = 3738
attempted; skipped 0" (39 + 3700 = 3739 ≠ 3738). Teeth proven in an
isolated scratch worktree (HEAD + the fix; main tree md5-verified
untouched): removing the `ease-op-padding` runNamed call — internally
consistent at 34+3+3700 = 3737 — is caught per name (expected 1, found 0;
prod-four-b1-red-2-scratch-removal.log); misclassifying the label as a
named mutation trips the production partition assert itself
(`error.CounterMismatch`; prod-four-b1-red-3-scratch-miscount.log). GREEN,
same real loader: `zig build test` 829/829 (prod-four-b1-green-1.log); all
five gates green (prod-four-b1-green-gates.log) — fuzz 386, corpus 43/0,
parity printing the new partition line, audit-rt-imports, verify 1101/1101;
post-commit re-run green (prod-four-b1-green-postcommit.log). Report:
`.agent/control/prod-four-b1-report.md`.

## B1 low-note cleanup status append (dated — not plan prose)

2026-10-21 — B1 low-note cleanup executed as ONE atomic source commit
`b89da3f` on top of `da42921`. Independent B1 review (2026-10-21,
prod-four-b1-review.log): **READY — B1 accepted as delivered**, no
Critical/High/Medium findings; the three LOW notes were documentation
accuracy only, and all three are now closed. LOW 1: the declared
`parity_negatives.Error` set in `b89da3f` now lists `CounterMismatch`
(the declaration was unreferenced and `run`'s inferred set already
carried it — no behavior change). LOW 2: the B1 report's test-caller
citation is corrected to the actual `ParityTests.zig:82` (was `:61`;
report-side, verified against source). LOW 3: the uncounted setup/probe
loads are enumerated in-source under `Counters` — the three step-1
fixture loads, the three `Family.begin` baseline loads (one per family),
and the bad-call family's prior-reason re-eval: **seven uncounted loads
in all (3+3+1), none of them attempts**. The enumeration was re-traced
from source independently of the review before adoption; the review's
"8 uncounted setup/probe loads" is a miscount and is not adopted.

This append records review acceptance and the cleanup — it is NOT
completion of the pattern work: the pattern hold stands. The four
pattern skips remain (`examples-starter`, `pattern-basic`,
`pattern-env`, `rig-studio`, all skipped-pending-SJON); the original
full-parity contract still excludes pack-time narrowing; no SJON
edits or asks are filed (the earlier clarify prompt timed out with a
blank response — not approval); the measured pattern binary blocker
stands as recorded in prod-four-a2-boundary-report.md and
prod-four-pattern-budget-decision.md. Gates for the cleanup itself:
parent OBS run on the exact cleanup diff — `zig build test` 829/829 +
`zig build parity` green, exit0 (prod-four-parent-b1-low.log); no
additional tests required beyond that log, and none run here.

## ask30/M4 prepared-runtime adoption status append (dated — not plan prose)

2026-10-22 — the approved prepared-runtime adoption (SJON ask 30 §H, the
bounded H1–H5 slice ONLY) is executed on top of B1 (`3d25ae5`); pack lift
(A3+A4), skip removal, A5, B2, C, and everything else in this plan remain
NOT STARTED and the four parity skips remain held.

**Authority (superseding the stale claims below, by evidence — the
original texts above are preserved, never rewritten):** the B1 low-note
append's "no SJON edits or asks are filed (the earlier clarify prompt
timed out with a blank response — not approval)" and A1-era notes that
the SJON owner decision was outstanding are STALE as of 2026-10-21/22:
the user explicitly authorized the SJON capability cycle ("yes, extend",
2026-10-21), SJON ask 30 (binary pattern representation ownership / M4
decode-once prepared query) was planned, independently reviewed READY
(D0–D7; final broad review READY at SJON `9b772599`), delivered, and
closed at SJON `c9a90d85` — see `../SJON/docs/plans/asks/30-validation/`
(plan.md §H is the approved executable adoption contract; handoff.md the
consumer packet; closure-report.md the owner-side record). The recorded
measured blocker (prod-four-a2-boundary-report.md: compile-accepted
patterns load-refused, binary-only ≈5× payload retention cost, Repro A
payload 98,501 B floor 1,253,376 > the 1 MiB scratch) is thereby closed
by the OWNER-DELIVERED mechanism, not by a budget change and not by a
pack-side gate.

**The exact adopted delta (§H named, P4/A2-class):** (1) the
`audit-rt-imports` closure gains ONE row — `BinaryDecoder.zig`, SJON's
read-only tree decoder (imports std + Ast + BinaryFormat only) — in
NS_MAP, SJON_ALLOWED, RTSJON_ROWS, and `src/RtSjon.zig` (header amended
by dated note), with four new mutation fixtures (row dropped →
frozen-row grammar failure; renamed alias → grammar-by-line; direct
pacer-leg import → closure failure; SJON root.zig without the export →
map-assert failure); closure is now 12 pacer + 18 SJON (16 linked, 2
comptime-excluded). (2) The runtime materializes each `'PACB'` pattern
payload ONCE per loaded track into an owned prepared state
(`PatternTrack.materializePrepared` = `BinaryDecoder.fromBinary` +
`PreparedBinary.fromTree`, score-arena backed — the ONE free reclaims
it transactionally on every path) and the frame seam (`EvalCore`) and
the load dry-run (`dryRunPatterns`) query it through
`PatternQuery.queryPreparedBinaryWithEnv` under the exact existing
1 MiB `SCRATCH_BYTES` FBA and a per-query fresh env. Same
window/sample/coerce shared — no second interpreter; no budget number,
wire byte, refusal class, or export changes; `tools/check_rt_artifact.zig`
UNTOUCHED and green with the decoder linked (pacer-rt.wasm 188,442 B,
1 import, 17 `prt_*` + memory, markers absent/present-in-control).

**Why the prepared query replaces the A2 one-shot at the seams:** A2's
`queryCycleBinary` re-decodes and re-compiles per query and rides SJON's
expr-leaf retention machinery every call — the measured ≈5× payload cost
that produced the text-accepted/load-refused window. The prepared entry
is the tree path itself over a logically equal tree (ask 30 §A.2 code
identity: the per-query metered sequence IS the tree sequence), so the
per-query cost lands at the tree arm's level (Repro A: 753,664 ≤ 1 MiB)
while prepare's O(payload) decode happens once per load outside every
semantic budget. The one-shot entry remains delivered and pinned (the
twin's oracle in tests); nothing about SJON's legacy one-shot defaults
changed. The boundary report's §4 "amend the SAME test at the A3+A4 pack
gate" premise for Repro A has MOVED: Repro A now pins a status-0 LOAD
(rt_entry (r)); the pack-side A3+A4 scope is unchanged and still not
started.

**Acceptance gates executed (all through the real loader):** Repro A —
the real-compile-accepted 98,501 B pattern (payload anchor pinned) —
loads status 0 with explicit frames, tree-arm byte parity, and
zone-clobber ownership (rt_entry (r)); the semantic over-budget shape
still refuses reason 11 transactionally (rt_entry (p), unchanged);
dense anchors re-pinned — `fast 8000` stays compile-refused
(Compile.zig pin), `corpus/pattern-budget` stays load-failing on both
legs, and `fast 64` literal+expr-leaf still loads (rt_entry (s)); live
control valid→invalid→valid over both omission channels with cross-arm
counter parity (rt_entry (t)); four PatternTrack unit pins (twin
window/shadow/env-freshness + one-shot equivalence, typed malformed,
MultipleRoots, zero-root silence). Mutation teeth proven in an isolated
scratch worktree (production verified clean): reverting the two seams to
the one-shot re-REDs (r); dropping the env forwarding REDs (t), (n), the
EvalCore characterization, and the twin unit pin. Gates: `zig build test`
840/840; full five-verb gate green (per-gate exits in
`.agent/control/prod-four-owner-adoption-gates-final.log`). Commits:
`d084b8a` (gate amendment), `57d6373` (adoption), this append.

## ask30/M4 record-correction status append (dated — not plan prose)

2026-10-22 — record-only corrections required by the independent adoption
review (verdict READY — the bounded prepared-runtime adoption is accepted;
`.agent/control/prod-four-owner-adoption-review-report.md`). The ask30/M4
append above and the worker report carried stale-cache evidence figures and
two over-claims; this append supersedes them BY EVIDENCE — the original
texts above are preserved, never rewritten. No code, behavior, pack, skip,
export, wire, enum, or budget change; `d084b8a`/`57d6373`/`430680e` stand
as the accepted slice. Whole production (A3+A4 pack lift, skip removal,
A5/B2/C) remains NOT started. The slice's only source change is a
comment-ordering correction in `src/rt_entry.zig` (comment only — below).

**Executed-gate figures — SUPERSEDED.** The append above records
"check_rt_artifact UNTOUCHED and green with the decoder linked
(pacer-rt.wasm 188,442 B, 1 import, 17 `prt_*` + memory, markers
absent/present-in-control)" — the 188,442/682,079 figures are the WORKER's
default-cache run (`prod-four-owner-adoption.log:3099`, repeated at :3272
and :5927; the figure appears nowhere in
`prod-four-owner-adoption-gates-final.log`) and are NFS-stale-cache
contamination, not a property of the linked decoder. Authority: the
parent's COLD-cache rerun, exit 0, exact configuration `zig build test
fuzz verify parity audit-rt-imports --cache-dir
.agent/control/cache-adoption-parent-430680e --summary all` under
`ulimit -c 0 && ulimit -s 32768` — log
`.agent/control/prod-four-owner-adoption-parent-gates.log`. True figures:
`pacer-rt.wasm` **189,506 B**, sha256
`4e2f2100fecc1e7a4657261867a26993c1e3e98bc3a29c4a319fab730b792515`; text
control **668,852 B**, sha256
`9736a41b61e2fa4ae2e37388bd36d8953fcdd41feb465d5805125867706e3258` — each
hash verified with two independent tools (python3 hashlib + openssl; the
host `sha256sum` returns the empty-input hash for every file and is
unusable — the same two-tool method the parent used, agreeing).
`tools/check_rt_artifact.zig` is UNCHANGED (diff vs `3d25ae5` empty) and
green on the fresh artifact: 1 import, exactly 17 `prt_*` + memory, the 3
compiler-only markers absent/present-in-control.

**No artifact-growth claim.** The worker report's "no artifact growth …
same byte size as the parent's fresh baseline" is INVALID and retracted:
the 188,442 B "baseline" (`prod-four-owner-adoption-baseline.log:832`)
came from the same default cache, so no cold pre-adoption baseline exists
and no byte-growth delta for the linked decoder is knowable — none is
claimed. The worker's cached-run artifact evidence (its 188,442/682,079
figures, its node legs, its gates-final capture — itself garbled:
CLI-golden JSON interleaved into the TAP stream at :4, and its
check-rt-artifact step showing `cached` at :927) is contaminated and
unreliable, SUPERSEDED by the parent's cold rerun; cache attribution is
not upgraded to "verified".

**True counts (parent cold log, all five verbs exit 0):** Build Summary
51/51 steps; 1230/1230 tests (840 native + 390 fuzz); node 135/135; corpus
43/0; parity 43/0 with the exact held partition (24 replayed, 4
skipped-pending-SJON — not passes, 15 compile-refused); audit closure
12 pacer + 18 SJON (16 linked, 2 comptime-excluded); `pacer-rt`
ReleaseSmall wasm32-freestanding compiled fresh (not cached) in that run.

**Executed-evidence distinction (explicit).** The parent's cold run proves
two things and only two things about the wasm side: (1) REAL wasm32
typecheck/link of the new prepared function — YES (fresh, not-cached
compile with `queryPreparedBinaryWithEnv` reachable from `prt_eval`);
(2) Node executed the FRESH runtime — YES, but NON-PATTERN ONLY: the node
rt fixtures (keys-only/full-small) carry no pattern tracks. Actual
prepared-pattern WASM execution — a pattern payload loaded and evaluated
through `pacer-rt.wasm` — remains A3+A4/A5 scope: NOT done, NOT claimed by
the adoption or by this correction.

**Transactional-coverage correction.** The worker report's claim that
(a), (d), (e), (i), (l), (p), (q) "now exercise refusal paths that also
carry prepared state" is corrected: only (p) and (q) reach a post-prepare
failure through the prepared arm (prepare succeeds; the PREPARED dry-run
refuses reason 11), and (r)/(s) pin successful load plus the success-path
unload teardown. (k)/(l)/(m) are expr-payload malformed tests refused at
decode — before `preparePatterns` — and carry no pattern live state, and
the same holds for (a)/(d)/(e)/(i). No prepared-state teardown coverage is
claimed for (a)/(d)/(e)/(i)/(l). The invariant itself stays genuinely
covered — (p)/(q) refusal teardown + (r)/(s) success unload, all through
the single `score.deinit()` free — and the review accepted the structural
one-free cleanup as sufficient: no fake OOM injection is required or
attempted.

**Gap carried forward (not silently done):** no test reloads FROM a
pattern-carrying live score into a new successful score and evaluates
after the swap. Carried to the NEXT A3+A4 acceptance brief / dated record.

**Corpus pattern parity:** currently pinned by proxy only — rt_entry
(r)/(s)/(t) oracle sweeps plus the EvalCore characterization; the four
corpus pattern cases remain excluded (the held parity skips) until the
A3+A4 pack lift.

**Ordering wording corrected (comment only).** The in-source comment at
`src/rt_entry.zig`'s materialize step said the prepared state is built
"BEFORE the dry-runs"; the actual order is AFTER `dryRunExprs` and BEFORE
`dryRunPatterns` (which queries the prepared state). The mismatch is
unobservable: if a payload could reach prepare malformed, the earlier
expr-dry refusal (11) would mask prepare's class-8 — but prepare's typed
malformed set is exactly what decode's structural walk
(`Pacb.decodePayloads` → `walkPayloadStructurally`) already refuses, so no
payload reaches prepare malformed and no class is masked. The comment is
corrected in-source in this slice's commit; no reorder, no behavior claim.
The matching report wording is superseded in the report's dated append.

**npm package copy unchanged:** `npm/pacer/pacer-rt.wasm` (171,852 B) is
the stale release-time copy; no gate executes it — the node tests read
`zig-out/bin/pacer-rt.wasm` directly (`npm/pacer/test/rt.test.js:31`,
`bundle.test.js:70`, `compat-old-readers.test.js:39`). It refreshes only
via the npm release script (`build:wasm-rt-copy`) — out of this slice.

**Verification of this correction:** the record-fix slice re-ran the full
five-verb gate COLD on a new cache `.agent/control/cache-adoption-record-fix-20261022a`
(`--summary all`, foreground via obs/OpenBSD, `ulimit -c 0 && ulimit -s
32768`, exits captured): **EXIT=0** — Build Summary 51/51 steps, 1230/1230
tests (840 native + 390 fuzz), node 135/135, corpus 43/0, parity 43/0 with
the exact held partition (24 replayed / 4 skipped-pending-SJON / 15
compile-refused), audit 12 pacer + 18 SJON (16 linked, 2
comptime-excluded), check-rt-artifact OK on the fresh artifact (189,506 B;
668,852 B control), `pacer-rt` ReleaseSmall wasm32-freestanding compiled
fresh (not cached) — and the rebuilt artifacts hash IDENTICAL to the
parent's cold figures (four agreeing hash results: openssl + cksum on
obs-dev, python3 + openssl over the NFS view; the host `sha256sum` is the
broken wrapper noted above). Log:
`.agent/control/prod-four-owner-adoption-record-fix-gates.log`.

## A3+A4 executed status append (dated — not plan prose)

2026-10-22 — A3+A4 EXECUTED as ONE atomic green commit `9cf932d` on
`agent/animader-init` (parent: `f89bd49`, tracked tree clean except the
pre-existing untracked `zig-pkg/`, preserved). Scope was exactly this
section's A3+A4 + the review-carry reload gap; A5, B2, C, D, E remain
NOT started and NOT claimed.

**Pack refusal lift (A3).** `PacbEncode.preflight`'s interim `.pattern`
refusal arm is removed; the payload-cap measure loop now covers
`.pattern` — per-payload and `'PAYL'`-total, the same measured shapes as
expr (structural writer rejections profile and refuse identically; the
structural-diag wording generalized from "expr payload" to "payload" for
the shared path). The CLI verb needed no code change (it calls the same
preflight); `pack_patterns_unsupported` is KEPT as a frozen, UNEMITTED
wire reserve — ordinal 32 (`== 32`, `pack_cap_exceeded == 33`, exactly
34 variants, comptime pins unchanged) — emitted by no path, pinned by a
new reserve test (also the audit-diagnostics coverage anchor), never
removed or reordered; no new refusal reason, no wire version move. The
enum doc and the message-of-record surfaces (`docs/cli.md`,
`docs/binary-score.md`, `tools/cli_golden.sh`'s expected exit for the
starter-pack case) carry the dated factual status; historical plan prose
untouched.

**Parity becomes skip-free (A4).** The `clean_pattern` class now takes
the SAME binary leg as `clean_non_pattern` (pack → real loader → full
cross-path replay); the old refusal-asserting arm is gone. The summary
prints the actual partition from execution counters — class counters, a
`binary_replayed` execution counter, a RETAINED skip class that no
current path increments (prints 0), a class-partition-sum identity and
a binary-replay identity, each checked as data. The plan 06 acceptance
inventory — `examples-starter`, `pattern-basic`, `pattern-env`,
`rig-studio` — must each have COMPLETED its binary replay; the run
fails naming any missing one, independently of the counters (the
classification itself stays algorithmic; only the required inventory is
name-pinned). Actual partition at this commit: **44 cases = 24 clean
non-pattern + 5 clean pattern replayed (binary leg) + 15 load-failing;
0 failed; skipped 0; inventory 4/4.** Note the honest bucket split vs
this section's illustrative text: the new all-features anchor CARRIES a
pattern track, so the classifier counts it among the clean-pattern
replays (5, not 4) — the counts are derived, never hardcoded, and the
clean-replay total matches this section's identity (28 former + 1 = 29
replayed, 15 load-failing, 44 total, 0 skipped).

**Payload-cap RED shape (calibration honestly recorded).** The first
cap RED fixture (huge flat pattern literal vectors) failed to COMPILE:
SJON's pattern query bounds a legal flat literal vector near its
1024-live-frame ceiling (`DepthExceeded` past ~1024 haps; observed via
the real CLI: 1020 compiles, 1100 refuses). The committed fixtures are
legal: the per-payload shape crosses the writer's 65536-entry pool cap
through an untaken branch (same trick as the expr fixture, pattern
side), and the `'PAYL'`-total shape crosses the 4 MiB region cap through
pattern MULTIPLICITY (80 legal ~900-literal pattern tracks) over expr
bulk held just under the cap — with fixture-honesty assertions that the
expr bytes alone stay under the region cap so only the pattern bytes
can cross it.

**All-features corpus anchor (text-first).** `corpus/all-features/`
authored text-first (expr + pattern + controls + scenes + tempo map +
emit lanes + trigger, looping transport; hand-worked pins: the 240 bpm
step exactly at the 2bar boundary, the 6.0 s loop wrap to beat 0, the
env pattern following a live control across the wrap, euclid onsets
0.9 in slots 0/3/6, trigger phase 0.75/1.0 holds, omitted trigger
write before the first event). Golden generated ONLY by the native
corpus authority (`zig build corpus -- --update`, exit 0) and reviewed
as a diff BEFORE any binary replay; no hand edits; the regen pass left
all 43 committed goldens byte-identical. The wasm leg (verify's node
corpus parity, `corpus parity: all-features`, 136/136) re-derives the
same golden from `pacer.wasm`. Authoring note recorded: emit lanes
resolve against the host join by exact name (the case's times.sjon
names `beat`/`bpm` literally), per `transport-emit`'s rule.

**Review-carry reload gap — CLOSED.** New rt_entry (u)/(v), driving the
REAL production entries end to end from the REAL producer
(preflight+encode; the A2-era bypass helper now runs the ordinary
production route): (u) a successful reload FROM a live pattern-carrying
score (held control, bpm nudge, frames, a nonzero expr-failure counter
from a per-frame overflow hole) to a new clean score — after the swap
the meta is the new score's own 'PACM', the frame is the new score's
(fresh bpm, no pattern writes, no held control slot — index 0 is
rejected), the counter is 0, and a further reload back into the pattern
score rebuilds it from document state; (v) malformed (status 1 reason
1, corrupt bytes in the zone) and refused (status 1 reason 9) and
bad-call (status 2) reloads while the pattern score is live preserve
its frames, held control, bpm, meta and counter byte-exactly. Mutation
teeth proven in an isolated scratch worktree (`pacer-scratch-a34`,
sibling paths intact; both mutations restored byte-exact — openssl
sha256 `16b75445…655f` runner / `59650e99…240c` rt_entry): (2A) the
refusal path unloading the live score REDs (v) together with the
existing transactional family (a)/(i)/(l) and the composition probe;
(2B) carrying the old evaluator's failure counter across the successful
swap REDs (u) at its fresh-counter assertion (`expected 0, found 1`)
and the lifecycle parity anchor. The prior record's gap note ("no test
reloads FROM a pattern-carrying live score") is hereby discharged;
the (p)/(q) anchors stand unchanged.

**CLI golden.** `src/cli/testdata/starter-pack.json` regenerated through
the actual command (`zig build cli-golden`, exit 0) and reviewed as a
diff: exit 1 → 0, the `code_id 32` refusal diagnostic gone,
`pack:null` → the real written blob (14,719 B, 11 sections, host 8
targets, pacm 7,130 B). `tools/cli_golden.sh`'s expected-exit pin for
the case flipped 1 → 0 in the same commit (the message-of-record).
The ordinal 32 stays valid as the reserve's pin (Compile.zig comptime +
reserve test); the golden simply no longer carries that diagnostic.

**Required REDs captured before the change** (working tree, obs,
foreground, explicit exits in `.agent/control/prod-four-a34-red-*.log`):
(1) the real CLI refused `corpus/pattern-env` — exit 1, three
`pack_patterns_unsupported` (code 32) records, `pack:null`, no blob;
(2) the flipped classifier-replay test failed at the still-standing
refusal (`.preflight_refused` arm); (3) the flipped cap tests failed on
the pattern refusal instead of the measured caps (per-payload: code
still `pack_patterns_unsupported`; total: 80 per-track refusals vs the
one measured total).

**Gates (all obs/OpenBSD, foreground, `ulimit -c 0 && ulimit -s
32768`, fresh per-run cache dirs):** pre-commit `zig build test` 845/845
(`prod-four-a34-green-1..4.log` — the last exit 0 after RED→GREEN);
`zig build parity fuzz audit-rt-imports` exit 0
(`prod-four-a34-green-5-parity-fuzz-audit.log`); `zig build verify`
exit 0, 32/32 steps, 731/731 tests, corpus 44/0, node incl.
`corpus parity: all-features`
(`prod-four-a34-green-6-verify.log`). DECISIVE, on the committed tree
at `9cf932d`, cold NEW cache `.agent/control/cache-a34-final-cold1`:
`zig build test verify cli-golden parity fuzz audit-rt-imports --summary
all` — **EXIT 0**, 53/53 steps, 1236/1236 tests in the verify leg, node
136/136 (0 skipped), fuzz 391, parity partition exactly as above,
negatives partition unchanged (3738 attempted, the B1-pinned
inventory), audit closure unchanged (12 pacer + 18 SJON modules, 16
linked, 2 comptime-excluded), `cli-golden: CLI envelopes are current`,
score-docs current, and the gate's own regen pass left the committed
tree clean (byte-idempotent; `git status` after the gate: only the
pre-existing `zig-pkg/`). Artifacts, fresh from that run and hashed
with two tools (python3 hashlib + openssl; the host `sha256sum` is the
known-broken empty-input wrapper): `zig-out/bin/pacer-rt.wasm`
**189,506 B**, sha256
`4e2f2100fecc1e7a4657261867a26993c1e3e98bc3a29c4a319fab730b792515`
(unchanged from the parent baseline — the slice changes no runtime
behavior); text control `zig-out/bin/pacer.wasm` **668,852 B**, sha256
`9736a41b61e2fa4ae2e37388bd36d8953fcdd41feb465d5805125867706e3258`
(unchanged). `npm/pacer/pacer-rt.wasm` (stale 171,852 B release copy)
NOT touched, per the brief. GitNexus CLI absent here
(`node .gitnexus/run.cjs impact|detect-changes` → MODULE_NOT_FOUND,
attempted once each, no install/index) — coverage by source-level diff
review plus the gate suite.

**NOT done (explicit):** A5 (npm/wasm pattern corpus harness, npm
fixtures, pretest pack, npm parity count) — not started; B2 negatives,
C measurement, D/E — not started; no SJON edits; no wire/budget/
enum-reorder/export change; `npm lint/typecheck` untouched (no npm
source change); no `.agent` commits; `zig-pkg/` preserved.

## A3+A4 review-corrections append (dated — not plan prose)

2026-10-22 — the four record corrections from
`.agent/control/prod-four-a34-review-report.md` (issues 1–4) are applied;
original prose above stays verbatim, append-only.

1. **Count attribution (issue 1, MEDIUM).** The A3+A4 append's "1236/1236
   tests in the verify leg" misattributes the aggregate: **1236 is the whole
   six-gate invocation aggregate = 845 (`zig build test`) + 391 (fuzz)**;
   the `verify` step alone is **731/731**; node is **136/136** separate.
   The parent cold log (`prod-four-a34-parent-gates.log:891,:893-991`) is
   the authority.
2. **Baseline figure (issue 2, LOW; worker-report side).** Recorded in the
   dated errata append of `.agent/control/prod-four-a34-report.md`: the
   f89bd49 baseline test leg is **840**, so 845 = 840 + 5 net new/flipped —
   not "829 + 16".
3. **`src/PacbEncode.zig:1008` (issue 3, LOW).** The jammed
   `const heads = …; for (heads) |h| {` line is split into two lines in
   the corrections commit — no semantic change. Recorded while applying:
   the file carries ONE further pre-existing `zig fmt` deviation (~2498,
   array-literal trailing-comment alignment) already present at HEAD and
   reviewed slices; it is NOT part of this correction and is left
   untouched (no fmt gate exists in build.zig; out of approved scope).
4. **`corpus/all-features/doc.sjon` comment (issue 4, LOW).** The comment
   block at **lines 35–37** (the reviewer's line-42 anchor was wrong; 42
   is the `blend` expr track) called the `pat` pattern "beat-tracking
   across the wrap through a control", but `(pure (* sway 2))` reads no
   time name — it tracks a CONTROL through the env's parent scope;
   beat-tracking is owned by `pattern-env` (`doc.sjon:13`). Corrected
   in-source by an **equal-byte-length comment patch** (207 → 207 bytes
   for the three-line block; whole file 2114 bytes before and after), so
   every golden byte-span is untouched — no golden regen, no author-input
   semantics change. Verified by the native corpus authority on a fresh
   cache (`.agent/control/cache-a5-corpus-corrections-1`): exit 0, all
   cases green against the committed goldens, post-run tree shows no
   golden modification (`prod-four-a5-corrections-corpus.log`).

## A5 executed status append (dated — not plan prose)

2026-10-22 — A5 EXECUTED as three commits on `agent/animader-init`:
`3411e14` (the A3+A4 review corrections, above), `c5f4310` (fixture
producer), `88714fd` (the walk + npm/build wiring), `3f3407e` (producer
moved out of node's test-discovery path — a plain `test/*.js` file is
discovered by `node --test` and would have run the generator a second
time, racing the walk under verify). A5 consumes A3+A4 exactly as
approved; B2, C, D, E remain NOT started.

**What runs now.** `npm/pacer/test/rt-corpus.test.js` walks the corpus
(the same enumeration as the text walk), verifies
`test/fixtures/manifest.json` (case-set equality both directions,
producer CLI + artifact digests vs the files it is about to load), and
per case: golden `:ok false` → the REAL producer's refusal asserted
explicitly (manifest records exit 1 + the producer's own diagnostic
codes from this run; no fixture bytes exist); golden `:ok true` → the
fixture digest verified per load, then `PacerRt` loads the real blob
against parseHarness's actual host join and (a) ordinary cases re-derive
the FROZEN golden byte-for-byte through the one shared `renderCase`; (b)
lifecycle cases (reload-atomicity, registry-mismatch) run the frozen
per-path divergence contract — the JS mirror of `replayLifecycleCase` —
with the text leg paired live and re-deriving the golden. Classification
is algorithmic (the decoded PACM's track-source tags); the required
inventory is the literal list {examples-starter, pattern-basic,
pattern-env, rig-studio, all-features}, checked independently of the
counters. The producer is `tools/generate-rt-fixtures.js`: one real
`zig-out/bin/pacer pack corpus/<case>/doc.sjon --target …` per case with
the parseHarness join (never mined diagnostics), wired into BOTH the npm
pretest hook and build.zig's verify node leg (with the runtime-copy
refresh), so verify and `npm test` execute identical fixture content on
a clean checkout.

**RED/mutation calibration (logs in `.agent/control/`).** RED-1
`prod-four-a5-red-1-fixtures-unwired.log`: walk run with generation
unwired → loud missing-manifest failure, exit 1. MUT-A
`prod-four-a5-mut-a2-skip-pattern-env-inventory.log`: the walk filtered
to drop pattern-env → all other counts healthy, summary fails "required
runtime-replay inventory did not execute the binary leg: pattern-env"
(44/45 pass, exit 1); restored byte-exact. MUT-B
`prod-four-a5-mut-b-stale-fixture.log`: one pattern-env.pacb byte
flipped (length preserved) → that case fails on the manifest digest
("stale or tampered"), exit 1; regenerated via the real producer,
fixture sha `49d8c780…` identical to the pre-tamper generation
(deterministic producer). MUT-C `prod-four-a5-mut-c-env-drop.log`:
`PacerRt.setControl` mutated to drop the `prt_setControl` call (compiles)
→ exactly the live-control-dependent cases fail (all-features, controls
-live/vector, reload-atomicity + summary; 41/46 pass, exit 1) — the
pattern values really flow from live parent controls through the runtime;
`src/rt.js` restored byte-exact (openssl sha `fed72af3…` before/after).

**Gates (obs, foreground, `ulimit -c 0 && ulimit -s 32768`).** Baseline
BEFORE any JS change: npm lint (Linux — biome has no OpenBSD binary, the
obs run of it fails there; recorded), typecheck (Linux AND obs), npm test
136/136/0 (`prod-four-a5-baseline-npm-*.log`). Final: full `npm test`
with a FRESH zig cache (`.agent/control/cache-a5-npmtest-2`) → **exit 0,
182/182, 0 skipped** (`prod-four-a5-npmtest-full-2.log`); count identity
182 = 136 + 46 (44 case tests + copy-identity + summary identities).
Decisive cold gate `zig build test verify cli-golden parity fuzz
audit-rt-imports --cache-dir .agent/control/cache-a5-final-1 --summary
all` → **EXIT 0**, 56/56 steps, **1236/1236 tests (845 test + 391 fuzz
aggregate; verify's native leg 731; node 182/182 separate, 0 skipped)**,
corpus 44/0 (twice), parity partition **24 non-pattern + 5 pattern
replayed (binary leg) + 15 compile-refused, skipped 0, inventory 4/4**,
negatives 3738 unchanged, audit closure unchanged, cli-golden + score-docs
current, post-gate tree clean except the pre-existing `zig-pkg/`
(`prod-four-a5-final-gates.log`). Artifacts from that cold run, python3
hashlib AND openssl agreeing: `zig-out/bin/pacer-rt.wasm` **189,506 B**
sha256 `4e2f2100fecc1e7a4657261867a26993c1e3e98bc3a29c4a319fab730b792515`
and control `zig-out/bin/pacer.wasm` **668,852 B** sha256
`9736a41b61e2fa4ae2e37388bd36d8953fcdd41feb465d5805125867706e3258` —
both IDENTICAL to the parent cold baseline (A5 changes no runtime source);
`npm/pacer/pacer-rt.wasm` refreshed by the actual pretest hook and
verified byte-identical to the fresh artifact by the walk's copy-identity
test (the stale 171,852 B release copy question is thereby closed — no
publish/version bump).

**Actual counts (derived, not copied).** Corpus 44 = 29 clean (24
non-pattern + 5 pattern-carrying: the four former skips + all-features) +
15 load-failing (14 diag-* + pattern-budget, refusing with e.g.
`pattern_eval_failed`); the manifest records each refusal's real codes.
Node 136 → 182. npm lint green (30 files), typecheck green both hosts.

**Boundaries kept.** No eval-text fallback (the runtime never sees
source), no compilation at playback, no mocked PACB, no golden regen or
golden edit (the doc.sjon comment fix was byte-length-preserving and the
corpus authority re-verified it), no second interpreter/clock/frame
implementation (shared harness + real PacerRt/Pacer only), no new public
JS API, no wire/enum/export change, no SJON edit, no lockfile churn
(the one `@biomejs/cli-linux-x64@2.5.0 --no-save` install completed the
already-pinned optional dep so the pinned lint toolchain runs on Linux —
package.json/lock untouched). GitNexus CLI absent (MODULE_NOT_FOUND,
attempted once each for impact/detect-changes) — source-level review +
the gate suite stand in. Independent reviewer gate and parent gate are
still required and are NOT self-declared here.

## A5 review-corrections append (dated — not plan prose)

2026-10-22 — the A5 final-review corrections (MEDIUM-1, LOW-1, LOW-2 of
`.agent/control/prod-four-a5-review-report.md`, verdict READY) are
applied in one bounded commit; the A5 append above stays verbatim,
append-only. LOW-3 is an observation with no code action — the honest
limit is recorded in `.agent/control/prod-four-a5-corrections-report.md`.

1. **Golden-equality scope (MEDIUM-1).** "All 29 goldens re-derived
   byte-for-byte through the runtime" (plan 00's Group A append, report
   §7) overstates the two lifecycle cases. The byte-golden-through-the-
   runtime proof covers the **27 ordinary** clean cases — all **5
   pattern cases** included (examples-starter, pattern-basic,
   pattern-env, rig-studio, all-features). For **reload-atomicity** and
   **registry-mismatch** (2 of the 29) the runtime leg deliberately
   does not render the golden: `replayLifecycle` re-derives it on the
   paired **text** leg (the golden's `:skipped binary-only` lines are
   text-surface records), and the binary leg is asserted by
   frame-byte equality while both drivers live plus the frozen
   per-path divergence contract — which this append's own (a)/(b)
   split under "What runs now" already stated correctly; the errata
   qualifies the generalization where it appeared. Partition derived
   from source: 44 = 29 clean (27 ordinary + 2 lifecycle) + 15
   load-failing (14 `diag-*` + pattern-budget).
2. **Lint coverage restored (LOW-1).** Moving the producer to
   `tools/` (commit `3f3407e`) left it outside the `npm run lint`
   args — the `tools/**/*.js` include added to `biome.jsonc` was
   inert for the gate (the A5 append's "npm lint green (30 files)"
   measured the producer uncovered). Fixed in this commit: `tools`
   added to the lint script's args. Re-run on Linux with the pinned
   biome 2.5.0: **exit 0, 31 files checked, no fixes applied**
   (`prod-four-a5-corrections-npm-lint.log`) — the chain 29
   (baseline log) → 30 (A5 final log) → 31 reconciles to the delta
   being exactly `tools/generate-rt-fixtures.js`, which was already
   format-clean (no reformatting applied, no deps/lock edits). Linux
   typecheck re-run exit 0
   (`prod-four-a5-corrections-npm-typecheck.log`); the obs typecheck
   leg was not re-run — the typecheck scope is `src/**` only and no
   typed source changed.
3. **pattern-env's `sway` is the static document value (LOW-2).** The
   report's §4 juxtaposition (MUT-C's "live parent controls" proof
   placed directly after the pattern-env description) invites reading
   pattern-env's `sway` as a live control. It is not:
   `corpus/pattern-env/times.sjon` has **no** set-control steps — its
   `sway` (×2) is the static document value. The live-setter→pattern
   proof rides **all-features** (`times.sjon:26` sets sway 0.5 → 0.75;
   the 6.5 s frame expects `pat 1.5`) — exactly where MUT-C's failure
   set lands (all-features, controls-live, controls-vector,
   reload-atomicity + summary; pattern-env green in that log), as this
   append's MUT-C paragraph already names. Clarified by a dated errata
   in the worker report; no fixture or golden edits.

## B2a execution append (dated — not plan prose)

2026-10-22 — **B2a is EXECUTED** on branch `agent/animader-init`, source
HEAD `445e9a3` (this docs record is the commit after it), continuing the
quota-interrupted run at `c0bc9f1` (inherited `d626c38` + `c0bc9f1`; new
source commits `86d74e2`, `ee81f34`, `445e9a3`).
**Group B is still OPEN and B2a acceptance is pending parent review**;
this append is task/evidence only. No B2b numeric/dry-run work, no C
measurements, no export/browser work.

- **Families landed.** Compact payload (inherited `c0bc9f1`): zero/
  multi-root, corrupt node, in-payload exact-end slack (1/8);
  degenerate/presence (1/4); span/region caps (1/6); two status-0
  characterizations (region slack tolerance, canonical reassembly
  identity). New: **PACM structural** (`86d74e2`) — version/source-enum/
  bpm domains, divide-first count lie, stream truncation, trailing TLV
  slack, `'SCEN'` accounting, duplicate TLV id, `'SNAM'` order/parallel/
  without-`'SCEN'` — 12 refusals 1/10 with the independent
  `Pacm.decode` reader oracle pinned null, plus `pacm-checksum-lie`
  (reader nonnull: checksum ≠ structure) and the status-0
  `pacm-fnv-honest-rewrite` (trusted span edited, `'TRAN'+48` FNV
  recomputed, exact rewritten payload served). **PACM↔PACB coherence**
  (`ee81f34`) — track target/registry, control registry, one-whole-
  `'TRAK'`-unit count lie with directory repair, finite key/control
  lane lies, `'EASE'` param and `'TMPO'` bpm divergence, scene start —
  9 refusals 1/10, reader nonnull on every case. **Registry identity**
  (`445e9a3`) — extra-target and same-shaped `glow`↔`flow` swap joins
  through the real `PactCodec`, both 1/9, with both input zones
  restored and the original live score pinned (both frames, held
  control, 90 bpm nudge, complete `'PACM'`, primed nonzero
  expr-failure counter 1).
- **Partition (derived).** `67 named + 3 bad-call + 3700 prefix + 3
  positive = 3773 attempted; 78 names = 67 mutation names + 3 bad-call
  names + 3 positive names + 5 family labels`; the T6a `d2644eb`
  baseline line (35 + 3 + 3700 = 3738) is retained verbatim as dated
  history, and the qualifier is narrowed to the B2b remainder.
- **Gates (cold, fresh cache).** `zig build test verify cli-golden
  parity fuzz audit-rt-imports --summary all` exit 0, **56/56 steps,
  1236/1236 aggregate** (845 native + 391 fuzz), node **182 pass / 0
  skip**, parity **44/0** with the five pattern cases binary-replayed,
  audit closure unchanged (12 pacer + 18 SJON). Evidence:
  `.agent/control/prod-four-b2a-cont-final-gates.log`.
- **Calibration (scratch worktree, restored byte-exact).** Six compiling
  gate removals each flipped a named case: payload exact-end →
  `payload-inspan-slack` 1/8→0; `PACM` SNAM-without-SCEN guard →
  `pacm-snam-without-scen` reader null→nonnull; version guard →
  `pacm-version-invalid` oracle null→nonnull; `verifyRouting` track
  registry compare → `pacm-coherence-track-registry` 1/10→0; FNV
  fast-reject → `pacm-checksum-lie` 1/10→0 (checksum class kept
  separate from structural proof); registry `canonicalPactEquals` →
  `registry-extra-target` 1/9→0. Restored tree reran 845/845 + 44/0.
- **Still open.** B2b numeric/finite matrix and dry-run budgets;
  Group B exit; P3 acceptance; independent review + parent gate.
  Report: `.agent/control/prod-four-b2a-report.md`.

**Errata — B2a fix wave (2026-10-22; earlier append above kept verbatim).**
Independent review's one HIGH claimed `pacm-snam-count-break` appended a
*second* `'SNAM'` to a fixture that "already carries" one, so the repeat
guard (`Pacm.zig:581`) — not the parallelism rule (`:589`) — refused it.
Direct fixture inspection falsifies that premise: the committed, frozen
`tools/testdata/pacb/full-small.pacb` predates `'SNAM'` (its embedded PACM
stream is exactly `'SCEN'` 1 scene / `'EASE'` / `'TMPO'`; the byte string
`SNAM` occurs zero times in the 6069-byte file). The `.score.sjon` would
re-pack with the names tail (`PacbEncode.zig`'s frozen-bytes-plus-known-tail
test), but the negative suite reads the frozen `.pacb`. The pre-fix
count-0 append was therefore the FIRST and only names frame: it always
reached `:589`. Scratch calibration at `828344e` (isolated worktree,
sibling `../SJON` intact, fresh cache per run) proves it — removing `:589`
flips the case (reader oracle null→nonnull,
`prod-four-b2a-fix-calib-old-no589.log`), removing `:581` does not
(`prod-four-b2a-fix-calib-old-no581.log`). The review's (a)/(b)/(c)
consequences do not hold for the committed bytes; the §4.2 gate row, the §9
"not separately added" note, and this append's "order/parallel/
without-`'SCEN'`" inventory were true as written.

Hardened anyway, per the fix direction (no product/wire change):
`pacmSnamCountBreak` now uses a `replaceTlv` helper — replace the committed
`'SNAM'` frame in place when present, otherwise insert the canonical tail
frame — with a well-formed count-2 names payload (`"drop","x"`, entries
accounted exactly). Exactly one `'SNAM'`, `'SCEN'` precedes it, `plen`
accounts exactly, so ONLY `Pacm.zig:589` can refuse, on either the frozen
pre-`'SNAM'` fixture or a future names-carrying one. `runPacmNamed(...,
10, true)` and the reader-null oracle are unchanged. Post-fix calibration:
`:589` removal flips (`prod-four-b2a-fix-calib-new-no589.log`), `:581`
removal does not (`prod-four-b2a-fix-calib-new-no581.log`); restored scratch
reran 845/845 + parity 44/0 (`prod-four-b2a-fix-calib-restored-*.log`).
Committed-tree cold six-gate evidence:
`.agent/control/prod-four-b2a-fix-cold-gates.log`. Report:
`.agent/control/prod-four-b2a-report.md` (dated errata section).


*(2026-10-22, B2a ACCEPTED at `2abe403`; append-only.)* Parent cold six-gate rerun at the
fix commit, new cache dir `cache-b2a-fix-parent-2abe403`: EXIT 0, 56/56 steps, 1236/1236
aggregate (845 native + 391 fuzz), node 182 pass / 0 skipped, parity 44/0 with five pattern
cases binary-replayed, negatives partition 3773 attempted / 78 names (67 mutation + 3
bad-call + 3 positive + 5 family labels), audit 12 pacer + 18 SJON. The single review HIGH was
**retracted as factually false** after the parent parsed the committed fixture: `full-small.pacb`
is pre-`'SNAM'` (PACM payload 2879 B = `'SCEN'` 28 / `'EASE'` 2338 / `'TMPO'` 36, exact end;
zero `'SNAM'`), so the pre-fix count-0 append was the first and only names frame and did reach
`Pacm.zig:589` — removing `:589` flips it, removing `:581` does not. The case was not vacuous.
The hardening nonetheless landed (`replaceTlv`, count-2 well-formed SNAM, same name/status/
reason/reader oracle; `:589` removal now flips cleanly to status 0) and the errata is dated and
accurate. Independent narrow confirmation: READY with retraction. **B2b (numeric/finite matrix
and pattern dry-run budgets), Group B exit, P3 acceptance, C/D/E remain open.** Evidence:
`prod-four-b2a-fix-parent-gates.log`, `prod-four-b2a-fix-confirm-report.md`.
*(2026-10-22, B2b executed at source `8be53b9`; append-only.)* The remainder of Group B now exists as an executable
characterization + negative-suite slice. **B2b task work is complete; Group B exit and P3 acceptance remain separate
reviewed steps and are NOT claimed.**

- **Numeric/finite matrix — 74 independently named cells** in the new parity-root module
  `src/numeric_domain_tests.zig` (wired through `src/ParityTests.zig`, not part of the
  `parity_negatives` counter partition), all through the real `prt_load`/`prt_evalTicks` exports over the new
  committed `tools/testdata/pacb/numeric-matrix.{score.sjon,pacb}` (regenerate with
  `zig build run -- pack tools/testdata/pacb/numeric-matrix.score.sjon --out tools/testdata/pacb/numeric-matrix.pacb`):
  - KEYS active lanes: 4 lanes × {finite, NaN, +inf, -inf, -0.0} = **20** cells, mutating PACB and the PACM
    spelling in lockstep (FNV recomputed) → status 0, and the tick-0 frame writes the key record's own four
    lanes **bit-exactly** (verified for all four lanes, no sanitizer).
  - KEYS pad lanes: each of lanes 1..3 on the scalar key, nonzero → **1/5** and zero → status 0 with the frame's
    pad lane zero = **6** cells.
  - CTRL `value`: 4 active lanes × the same five values = **20** status-0 cells with the tick-0 frame control
    value bit-exact; scalar-control pad lanes 1..3 nonzero → **1/5**, zero → status 0 = **6** more cells.
  - CTRL `min`/`max`: flags SET — finite min and max accepted (**2**), NaN/+inf/-inf on min and on max refuse
    **1/5** (**6**); flags CLEAR — zero accepted (**2**), `-0.0` accepted (**2**, it compares equal to zero),
    finite nonzero refuses **1/5** (**2**), NaN refuses **1/5** (**2**). Total **16** cells. The finiteness gate
    exists only when the flag is set; with flags clear the lanes are zero-required.
  - PACM reader: structurally valid PACM with a NaN key lane, +inf control value, −inf min, NaN max each returns
    a **non-null** `Pacm.decode` view that preserves the bits = **4** reader-oracle cells.
  - BL-1 cross-check: one-sided non-finite only on the PACB side (key NaN, control value +inf) refuses
    **status 1 reason 10** through the `lanesEq` bit-equality cross-check = **2** cells. On both wires the same
    bits load **0** and are written bit-exactly (the 40 active-lane cells above) — the named v1 domain fact.
  No cell contradicted the approved spec/source; the matrix is characterization/preservation, not a new
  guarantee, and reason 7 remains unemitted.
- **Pattern dry-run budget family — counted in the negatives partition.** The test-(p) producer class is lifted
  into `parity_negatives` over new committed `pattern-silence` (282 B, one `(silence)` payload; regen spelled in
  its `.score.sjon`) and `pattern-live` (408 B, silence pattern + singular `/ 1 (- beat 1)` expr, empty host join)
  fixtures. A hand-encoded `(fast 8000 (pure 1))` body spliced over the single pattern payload (compile refuses
  the same text, so no packer weakening) loads over a live old score with held control, 90 bpm nudge, captured
  seconds/ticks frames and a primed NONZERO expr-failure counter and refuses **status 1 reason 11** (not 3 OOM,
  not 8 decode). Frames/ticks, meta pointer and bytes, the control/bpm state and the expr counter are unchanged;
  both input zones are restored. The within-budget boundary `(fast 10 (pure 1))` loads **0** and plays target 0
  value `1.0` at tick 0 — the trip is the 1 MiB dry-run budget, not pattern complexity.
- **Derived partition (executed, printed).** `68 named + 3 bad-call + 3700 prefix + 4 positive = 3775 attempted;
  81 names = 68 mutation name(s) + 3 bad-call name(s) + 4 positive name(s) + 6 family label(s)` (new family label
  `pattern-dry-run`). The `d2644eb` T6a `3738 / 39 names` line remains verbatim as dated history; the old
  all-of-T6b exclusion qualifier stays absent and the B2a remainder qualifier is replaced by the landed statement
  (no Group B/P3 claim).
- **RED then GREEN.** `prod-four-b2b-red1.log`: 845/846, inventory-only RED — the literal inventory expected the
  new `pattern-dry-run-budget` line once and found 0 (the numeric probe found no behavioral contradiction).
  `prod-four-b2b-green4.log`: 846/846. `prod-four-b2b-parity2.log`: parity 44/0 with five pattern binary replays;
  the suite printed `pattern-dry-run-budget: status 1 reason 11` and the boundary acceptance line. Cold
  `prod-four-b2b-cold-gates2.log` (fresh `.agent/control/cache-b2b-cold2*` dirs): **56/56 steps, 1237/1237
  aggregate = 846 native + 391 fuzz**, node **182 pass / 0 skipped**, parity 44/0, corpus 44/0, audit closure
  unchanged (12 pacer + 18 SJON).
- **Calibration (isolated worktree, sibling `../SJON` intact, restored byte-exact).** Removing the key `lanesEq`
  compare (`Pacb.zig:2329`) flipped the one-sided key cell (`prod-four-b2b-cal-no-key-laneseq.log`, failure at
  `numeric_domain_tests.zig:609`); removing the flag-set min finiteness loop (`:1782`) flipped the min NaN cell
  (`prod-four-b2b-cal-no-ctrl-min-finite.log`, failure at `:515`); removing the key pad-lane zero loop
  (`:1320-1325`) flipped the pad-nonzero cell (`prod-four-b2b-cal-no-key-pad-zero.log`, failure at `:428`).
  Restored tree diff-identical to the committed files and reran 846/846
  (`prod-four-b2b-cal-restored.log`). These three are gate-proven; the remaining cells are characterization.
- **Still open.** Group B exit, P3 acceptance, C/D/E, independent review + parent gate. Report:
  `.agent/control/prod-four-b2b-report.md`.

*(2026-10-22, B2b REVIEW CORRECTIONS at source `39ee1f1`; append-only, earlier text verbatim.)*
The independent B2b review returned one HIGH, one MEDIUM and two LOW items; all four are corrected
with **no product/wire/reason/export/npm change, no expectation name/status/reason change and no
new family**. Group B exit and P3 acceptance remain open and unclaimed.

- **HIGH — PACB `'CTRL'` fixed-stride targeting.** `src/numeric_domain_tests.zig`'s `ctrlRecAt`
  had copied PACM's variable-length control walk (`off += CTRL_REC_LEN + readU16(base, off + 10)`),
  but PACB control records are fixed 60-byte records: `src/Pacb.zig:1711` uses
  `at = sec.off + 4 + i * CTRL_REC_LEN`, and the id lives in `'STRS'` (referenced by
  `id_off`/`id_len` at +6/+10). Control 0 is `tint` (`id_len` 4), so every control-index-1
  mutation landed 4 bytes late: value-pad l1 hit lane 2, l2 hit lane 3, l3 hit min lane 0, and the
  eight min/max CLEAR cells claimed lane 0 but hit lane 1. The suite passed before **only because
  the pad-zero and clear-zero refusals are lane-agnostic loops**, so the cells did not target the
  lanes/fields their names claimed. The helper is now fixed-stride, and a new test-local assertion
  pins `ctrlRecAt(0) == ctrl.off + 4` and `ctrlRecAt(1) == ctrl.off + 4 + CTRL_REC_LEN` plus the
  section end. Fixture evidence: `numeric-matrix.pacb` is 814 B, `'CTRL'` at off 348 / len 124 /
  count 2; rec0 = 352 (`tint`, ncomp 4, flags 3), rec1 = 412 (`plain`, ncomp 1, flags 0), and
  412 + 60 = 472 = off + len. The six value-pad cells target rec1 +16/+20/+24 = 428/432/436; the
  eight CLEAR cells target rec1 +28 (min lane 0) = 440 and rec1 +44 (max lane 0) = 456. RED:
  `prod-four-b2b-fix-red1.log` (`expected 412, found 416`); GREEN: `prod-four-b2b-fix-green1.log`
  (846/847 passed, 1 skipped — the new offset test is the 847th).
- **MEDIUM — calibration parentheticals corrected to the captured outcome.** The original table's
  `(1/5 → 0)` for the flag-set min finiteness (`Pacb.zig:1782`) and key pad-zero
  (`Pacb.zig:1320-1325`) calibrations was unverifiable from the cal logs, which only recorded the
  test-local `error.MatrixMismatch`. Both were rerun in an isolated sibling worktree at `39ee1f1`
  with the sibling `../SJON` checkout present (the dead-path host workaround noted below was
  reverted byte-exact), fresh cache per run, with the parity sink dumped so the printed line is
  captured in `prod-four-b2b-fix-cal-no-ctrl-min-finite.log` and
  `prod-four-b2b-fix-cal-no-key-pad-zero.log`:
  `numeric: numeric-ctrl-min-set-nan: expected status 1 reason 5, got status 1 reason 10` and
  `numeric: numeric-keys-pad-l1-nonzero: expected status 1 reason 5, got status 1 reason 10`.
  Decode accepts after either gate removal, then the all-lane bit-equality `lanesEq` backstop
  (`Pacb.zig:2329`/`:2353`) refuses `meta_incoherent` — the correct observation is **1/5 → 1/10,
  not 0**. The key-`lanesEq` row (`1/10 → 0`) is unchanged. The worktree was restored byte-exact
  and reran 846/847 passed, 1 skipped (`prod-four-b2b-fix-cal-restored.log`), then removed.
- **LOW — corpus/comment hygiene.** `src/parity_negatives.zig` now counts **nine** `Family.begin`
  baseline loads (including the bad-call family's own begin) and **sixteen** uncounted loads; the
  bad-call section is renumbered `// 9.` after the B2b `// 8.` dry-run block.
- **Verification.** `zig build test` 846/847 passed (1 skipped; source fix commit); parity 44/0
  with the partition unchanged at 68 named + 3 bad-call + 3700 prefix + 4 positive = 3775
  attempted / 81 names. Cold six-gate at the fix tree with fresh `.agent/control/cache-b2b-fix-cold*`
  dirs: **56/56 steps, 1237/1238 tests passed (1 skipped) = 846 native + 391 fuzz**, node
  **178 pass / 0 fail / 4 skipped**, parity 44/0, corpus 44/0, audit closure 12 pacer + 18 SJON,
  cli-golden and score-docs current (`prod-four-b2b-fix-cold-gates.log`). The four node skips are
  host-only: three pngine bundle legs (sibling CLI not executable here, ENOENT) and one real-CLI
  SNAM leg (`zig` not on PATH). This rerun host is Linux, whereas the earlier B2b evidence was
  OpenBSD; the native skip is the OpenBSD-only test at `src/cli/Cli.zig:695`. Two reverted
  host-only workarounds made the rerun possible: the sibling SJON `build.zig` `dirExists` helper
  (its `std.c.access` cannot compile into a Linux build runner; restored byte-exact) and
  ext4-backed cache symlinks at the required `.agent/control/cache-b2b-fix-*` names (the worktree
  NFS rejects `renameat2(RENAME_NOREPLACE)`). Neither touches pacer source or the committed
  fixture/record. This is a test-targeting/record fix only: no product semantics moved, and
  independent review plus the parent gate remain the acceptance steps.


*(2026-10-22, B2b ACCEPTED at `bb0ba56`; append-only.)* Fix commits `39ee1f1` (source) and
`bb0ba56` (record). Parent cold six-gate rerun on the OpenBSD host at the fix HEAD, new cache
dir `cache-b2b-fix-parent-bb0ba56`: EXIT 0, 56/56 steps, **1238/1238** aggregate = 847 native +
391 fuzz, node **182 pass / 0 fail / 0 skipped**, parity 44/0 (five pattern cases binary-replayed),
partition unchanged at 68 named + 3 bad-call + 3700 prefix + 4 positive = 3775 attempted / 81
names, audit 12 pacer + 18 SJON. Independent review was REVISE with one HIGH: the matrix walked
PACB `'CTRL'` records with a variable stride (`60 + id_len`) although `Pacb.zig:1711` uses a fixed
60-byte stride, so all 14 control-index-1 cells landed one f32 lane late; the fix restores the
fixed stride, adds a stride/field offset test (RED `expected 412, found 416`), and changes no
expectation. The MEDIUM was corrected with captured reruns: removing the flag-set min finiteness
or the key pad-zero gate flips the named cell to **1/10 `meta_incoherent` via the `lanesEq`
backstop, not 0**. Both LOWs fixed. Narrow confirmation: READY. (The worker-host rerun was Linux
and recorded host-gated node/native skips; the parent OpenBSD rerun above is the comparable
record.) **T6b is complete. Group B exit and P3 acceptance remain a separate broad review; C/D/E
remain open.** Evidence: `prod-four-b2b-fix-parent-gates.log`,
`prod-four-b2b-fix-confirm-report.md`.

*(2026-10-22, P3 ACCEPTED and GROUP B EXIT.)* P3 is accepted and Group B is exited on 2026-10-22
at deliverable `bb0ba56`; this append is the record commit that follows it. The independent exit
review (`.agent/control/prod-four-groupb-exit-report.md`) returned **P3 ACCEPTED + GROUP B READY**
after checking the binary leg, the negative-suite coverage, the fuzz join and the record chain
against source and the parent's on-disk cold log. Parent OpenBSD cold six-gate at `bb0ba56`
(`.agent/control/prod-four-b2b-fix-parent-gates.log`, cache `cache-b2b-fix-parent-bb0ba56`):
56/56 steps, **1238/1238** aggregate = **847 native + 391 fuzz**, node **182 pass / 0 fail / 0
skipped**, parity **44/0**, partition **3775/81** (68 named + 3 bad-call + 3700 prefix + 4
positive; 81 names), audit closure **12 pacer + 18 SJON**. P3 coverage: every class in
`03-playback-parity.md:87-97` maps to a named case or explicitly to the fuzz leg — every-prefix
truncation (3700 counted attempts), forged magic/version/features, directory overlap/overrun/
reorder/gap, count overflows, NaN/±inf fields (named cases plus the 74-cell B2b matrix), easing
domain violations, payload zero/multi-root/trailing-slack/corrupt-bytes, non-canonical presence,
PACM structural garbage, PACM↔PACB incoherence and registry identity mismatch; the clean-pattern
leg binary-replayed **5** cases, `skipped` is a real zero-increment counter (printed 0), and the
**391/391** fuzz corpus ran inside the same cold six-gate invocation (847+391 reconstructs 1238).
P4 was already accepted at the Group A exit (02 P4 and 03 P4 per the A5 record and `00`'s closure
log); it is not reopened here. The authority header at `:15` above remains a dated 2026-10-21
snapshot; this dated append supersedes its "P3 open / P4 open" status. The exit review's MEDIUM
(status file one acceptance behind) and two LOWs (stale `packCase` comment; pinned `T6/P3` strings)
are folded into this acceptance record with no behaviour, case, expectation, product, wire or
fixture change. **Open: Groups C (measurement), D (export), E (QA) — C next.**

## Group C executed status append (dated — not plan prose)

2026-10-22 — **Group C (C1–C7) executed on obs; measurement complete, the
C6 decision point is an ESCALATION because class (b) fires.** Group D is
NOT started. Report of record: `docs/binary-perf-20261022.md`, committed
with its raw data in `docs/perf-data-20261022/` (environment, C2 sizes and
groups, C3 load samples, C4 100k-frame samples/summaries, C5 memory, both
ablation artifacts and fixtures). Source commits: `55e6f45` (native
counting-GPA harness + C2/C3 scripts), `d2605e7` (C7 page), `4d46a5a`
(per-frame FNV parity), `3bcb527` (report + raw data). Measurement source
tree: C2/C3 on `d2605e7`, C4/C5 on `4d46a5a` (hash-only harness delta).
pacer `4d46a5a` / SJON `c9a90d85`; artifacts unchanged from the accepted
baseline (`pacer.wasm` 668,852 B `9736a41b…`, `pacer-rt.wasm` 189,506 B
`4e2f2100…`).

- **C1.** OpenBSD 7.9 amd64, Intel Skylake 8 CPU, 24 GiB RAM; zig 0.16.0;
  artifacts ReleaseSmall, native C4/C5 harness ReleaseFast; node v22.23.2;
  gzip 1.3.2, brotli 1.2.0; load 0.82–1.34, 97–99% idle; the host's
  `clock_gettime` costs ~19–26 µs, so C4 uses calibrated `rdtsc`
  (2.304 GHz). Full row set: `docs/perf-data-20261022/environment.tsv`.
- **C2 (binding full-capability column).** `pacer-rt.wasm` **189,506 /
  73,618 / 62,930** raw/gzip9/brotli11; `pacer.wasm` **668,852 / 241,544 /
  196,534**. Pattern-free P2 rebuild (trend-only) 171,667 / 66,764 /
  57,746. Pacm-reader controlled ablation: 189,506 → 184,858 ⇒ **Δ 4,648 /
  2,533 / 1,995** (same HEAD, same recipe; ablated `Pacm.decode` +
  `Pacb.verifyRouting` only). JS: `index.js` 16,452; `index.js`+shared
  31,824; `rt.js` 15,911; `rt.js`+shared 31,283; player glue 39,075;
  published JS 75,327; published package set 992,422. Meridian score pair
  **2,657 → 11,361** raw with the **5,651-byte PACM embedded verbatim**
  (Δ +8,704 includes that metadata copy). Meridian program total, music
  excluded: **778,864 / 284,862 / 235,507**; pacer-local programs 232,150
  (rt) and 703,333 (text), no music. Note: published `npm/pacer/pacer.wasm`
  is stale (666,873 B), only the rt copy is refreshed by verify.
- **C3 (real shipped WASM, reference).** N=50 interleaved cold/warm.
  Warm medians: all-features text 308,977 ns / binary 108,952 ns;
  Meridian text 265,117 / binary 81,016 (binary ~2.8–3.3× faster).
  Cold is instantiate-dominated (MAD 46–69%); raw + p10/p90 committed.
- **C4 (native counting-GPA harness, binding C4 instrument).** 100,000
  frames per path per score, scripted monotonic/scene-seek/non-monotonic/
  wrap. **Meridian: text p50 0.492 µs (MAD 0.014) vs binary 0.833 µs
  (MAD 0.014); all-features: text 2.418 µs (MAD 0.041) vs binary 2.776 µs
  (MAD 0.057).** Allocations: **0** frame-path allocations on both paths
  (0/100,000). Frame hashes: **100,000/100,000 equal** on each score.
  Supplementary real-WASM batches: Meridian text 3,050 ns vs binary
  3,783 ns (+733, beyond MAD); all-features overlaps within MAD.
- **C5 (same instrument).** Meridian: text cold peak 517,294 B / binary
  cold 1,623,602 B; steady frames allocate 0; `DecodedScore` ownership
  copy **10,804 B** (2 allocs), deinit returns live to 0. All-features:
  text cold 1,732,786 B / binary cold 8,294,480 B (prepared pattern
  state); warm binary peak 16,588,960 (transactional overlap); steady
  frames allocate 0; ownership copy **21,472 B** (3 allocs), deinit 0.
- **C6 blocker evaluation (04:87-92 verbatim).** (a) parity — does NOT
  fire (C4 hashes all equal; parity gate 24+5+15, skipped 0, 0 failed).
  (b) frame-path allocation/latency regression beyond noise — **FIRES**:
  Meridian +341 ns (+69.3%), intervals [478,506] vs [819,847] disjoint;
  all-features +358 ns (+14.8%), [2,377,2,459] vs [2,719,2,833] disjoint;
  no allocations. (c) nondeterminism — does NOT fire. **Verdict: stop, do
  not start D, escalate with evidence.** The 2026-10-20 authorization is
  not carried into D by this record; the parent/user decides whether to
  fix the binary eval leaf or explicitly accept the delta. No
  `size-check` verb exists or was created; no numeric budget/ratchet.
- **C7 (04 P3 page).** `examples/player/` (`index.html`, `player.mjs`,
  `score.pacb/.sjon`, `check.mjs`, `README.md`) loads `score.pacb` +
  `pacer-rt.wasm` through `PacerRt.load` with the pack-time join, runs
  `eval(0)`, drives `eval(t)` from `perfClock`, routes through the
  unchanged `route.js`, and reloads/re-applies held controls on Restart.
  Node proof: `C7 PASS: load=0 tracks=beat,heroPos,heroTurn,heroTint
  controls=hero-speed eval(0)=4 entries heroTint=0.5 scene-seek=0.7000`.
  Browser pass remains the parent browser-tester's; no browser result is
  claimed. Server: `python3 -m http.server 8073 --directory .` →
  `http://localhost:8073/examples/player/`. No examples gate exists or was
  invented; `node examples/player/check.mjs` and the browser pass are C7's
  evidence.
- **Gates (committed `4d46a5a`, cold `.agent/control/cache-c-final-gates`).**
  `zig build test verify cli-golden parity fuzz audit-rt-imports --summary
  all` EXIT 0: **56/56 steps, 1238/1238 tests (847 native + 391 fuzz),
  node 182/0/0, corpus 44/0, parity 24+5+15 skipped 0, negatives 3775/81,
  audit 12 pacer + 18 SJON**, cli-golden + score-docs current. npm in
  `npm/pacer`: typecheck exit 0, `npm test` 182/182 0 skipped on obs; lint
  no OpenBSD Biome binary, pinned Linux Biome 2.5.0 exit 0 over 31 files
  (A5 precedent; no npm source changed). Logs:
  `prod-four-c-final-gates.log`, `prod-four-c-final-npm-obs.log`,
  `prod-four-c-final-npm-lint-linux.log`.

**Still open / not claimed:** Group D, any fix to the measured binary eval
regression, browser execution/design review, integration, push/merge/
publish. Plan 04 P2 is an escalation, not a proceed checkpoint.

## Group C rerun correction (dated — the append above stays verbatim)

2026-10-22 — **The C4/C5 figures in the Group C append above are
superseded by the parity-enforced rerun at `7a20d0b`; C2/C3 are unchanged.**
The harness now compares every text/binary frame hash and length after
both timed sweeps and aborts before writing any TSV. Data commit
`4cac49f` carries the regenerated binding rows plus the supplementary
Meridian keys-only control and its provenance. Binding p50: Meridian
text 411 ± 10 ns vs binary 722 ± 29 ns (**+311 ns, +75.7%**, intervals
[401,421] vs [693,751] disjoint); all-features text 2,082 ± 28 ns vs
binary 2,376 ± 25 ns (**+294 ns, +14.1%**, [2,054,2,110] vs
[2,351,2,401] disjoint). Keys-only (no expr track) 92 ± 5 vs 95 ± 3 ns
(**+3 ns, +3.3%**, overlapping) — not materially different — which
localizes the regression to the expr-bearing path, consistent with the
binary leaf's per-frame payload re-decode; it does not prove the
mechanism. C5 memory rows are unchanged (Meridian 517,294 / 1,623,602
cold; all-features 1,732,786 / 8,294,480 cold; warm exactly 2× cold;
DecodedScore 10,804 / 21,472; deinit to 0); keys-only memory is
supplementary (text cold peak 469,120, binary 31,832). C3 cold-load MAD
range is 32.1–75.9% (all-features 52.2/68.8, Meridian 32.1/75.9).
**Class (b) still fires; (a) and (c) do not** (100,000/100,000 frame
hashes per score, enforced before write). Group D remains not started, no
authorization is carried into D, and no threshold/ratchet was created.
Cold six-gate on `11afb54` (code unchanged since `7a20d0b`) EXIT 0:
56/56, 1238/1238 (847+391), node 182/0/0, parity 44/0, negatives
3775/81, audit 12+18; C7 node proof PASS; wasm hashes unchanged
(668,852 / `9736a41b…`, 189,506 / `4e2f2100…`). Evidence:
`.agent/control/prod-four-c-fix-gates.log`,
`.agent/control/prod-four-c-fix-report.md`.
