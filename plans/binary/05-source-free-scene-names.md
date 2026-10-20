# Source-Free Metadata Names + Registered PACB Bundle Carriage — Implementation Plan (revised)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **2026-10-20 correction pass (docs-only):** independent-review findings BL-1, BL-2, IM-2..IM-4, OP-1..OP-6 applied; IM-1 disputed and rejected by tool recomputation from exact constants (§3 numbers stand — see the corrections section at the end); Group 0 marked DONE (commit `77d8c11`). No architecture change; no source change. Dispositions of record: `.agent/control/metadata-plan-corrections-report.md`.

## Correction ledger (2026-10-20)

This tracked file is the plan of record for the source-free scene-names
stage: the reviewed plan after the independent fresh-reviewer pass
(`.agent/control/metadata-plan-review-report.md`, verdict **REVISE** —
architecture stands) was dispositioned and its plan-text corrections
applied, docs-only. Working copy: `.agent/control/plan-metadata-names.md`.

- **Applied (11):** BL-1, BL-2, IM-2, IM-3, IM-4, OP-1..OP-6 — per-finding
  dispositions in "Independent-review corrections applied" below.
- **Rejected with evidence (1):** IM-1 — the reviewer's 278,512 /
  540,924 base/post-SNAM figures contradict their own term expression,
  which tool recomputation from the exact source constants evaluates to
  **274,512 / 536,924**, exactly the numbers this plan already carried
  (verification record: `.agent/control/metadata-plan-corrections-report.md`).
- **Group 0 DONE** before this pass: commit `77d8c11` (pre-SNAM pin +
  frozen reader artifacts; report `.agent/control/metadata-g0-report.md`;
  hashes `.agent/control/metadata-frozen-artifacts.md`); its one
  deviation (`meta-pre-SNAM.mjs`) is folded in (BL-2).
- Old-reader compat legs are expected-GREEN existing-back-compat pins —
  RED is never fabricated for them; criterion 7 is acceptance-required
  actual PASS, never skip.
- Baseline actuals (782 / 361 / 114 / 43 / 423, 171,667-byte rt wasm)
  are quoted from the parent log
  (`.agent/control/metadata-parent-baseline.log`,
  `metadata-parent-baseline-artifacts.json`) and recorded both ways.

**Goal:** Carry exact scene names inside the `'PACM'` meta blob (new append-only `'SNAM'` TLV section, u32 lengths, aggregate bound) so the binary `PacerRt` runtime reports names without source text — retiring the masked parity line — and prove PACB cartridges ride pngine bundles as a properly **reserved `PACB` payload kind** (pngine local-repo registration, public `payloadsOf` extraction seam) from real producer through real extractor to a source-free `PacerRt`, in node and in an actually-launched browser.

**Architecture:** One additive PACM TLV section (`'SNAM'`), emitted by `Abi.encodeMeta` after `'TMPO'`, decoded by all three PACM readers (Zig `Abi`, Zig `Pacm`, JS `meta.js`). No per-name cap: names are non-overlapping source-symbol slices, so aggregate name bytes are bounded by the source document cap; names are carried **exactly** — no truncation, drop, or empty fallback for SNAM-present names. All sizer/oracle coherence (`Abi.metaWorstCase`, frozen `Pacb.pacmWorstCase`, `META_CAP`, `PACB_CAP`, regenerated producer-oracle fixture) lands in one green commit. Bundle carriage is the proper owning route: a `PACB` row reserved per the registry's true reservation rules in the local pngine repo (no network act); `PACR` stays SJON text untouched.

**Tech Stack:** Zig 0.16.0 (all zig gates on obs-dev via `obs sh`), node v22.23.2 (obs-dev) / v26.10.0 (local ai-linux, no zig), pngine CLI + exported `payloadsOf` (sibling checkout; one local registration commit authorized), staged Linux browser + playwright for the mandatory browser pass.

**Spec:** `.agent/control/metadata-planner-brief.md` (scope of record), `.agent/control/metadata-revision-brief.md` + `.agent/control/metadata-revision-finish-brief.md` (rulings of record), evidence `.agent/control/metadata-adversary-report.md`, `metadata-baseline-report.md`, `metadata-consumer-inventory.md`, `metadata-revision.log`.

---

## 1. Adversary disposition resolution (B1-B4, I1-I6, O1-O6 — all resolved)

| # | Finding | Resolution | Owning group |
|---|---|---|---|
| B1 | Task 1 incoherent: frozen oracle (`root.zig:452-472`), frozen worst-case equality (`root.zig:164-174` vs `Pacb.zig:2487-2504`), runtime zone (`rt_entry.zig:91-92,117`) | Group 1 adds the SNAM term to **both** `Abi.metaWorstCase` and `Pacb.pacmWorstCase` in one commit; `PACB_CAP` derives automatically; `META_CAP` re-derived; fixture regenerated **once**; pre-SNAM pin committed in Group 0; immutability gates re-scoped to `tools/testdata/pacb/` + the pin | 0, 1 |
| B2 | >255 name policy: contradiction + unapproved silent loss | **Ruled:** no per-name cap, no silent loss. u32 wire length sufficient to source cap (`MAX_DOC_SIZE` = 262,144, `src/wasm_entry.zig:77`); aggregate bound over non-overlapping source slices; SNAM-present names always exact | 1, 2 |
| B3 | Browser proof could close without a browser | Completion criterion 9 requires an **actually-launched** browser pass (staged Linux browser acceptable, no WebGPU) + browser-tester + design-reviewer on the running page; env skip is a per-run note, never a completion state | 5, criteria |
| B4 | Sibling-path arithmetic off by one level | Four levels: `../../../../pngine` from `npm/pacer/test/` and from `npm/pacer/browser/`; resolved absolute path printed in every skip/failure (mirrors `ANIMADER_PACER` `missing()`, `animader test/pacer.js:28-32`) | 4, 5 |
| I1 | `node --test` discovers `test/browser/**` → `npm test` breaks | Browser harness lives at `npm/pacer/browser/` (outside `test/`); playwright `testDir` points there; `server.mjs` import-side-effect-free regardless | 5 |
| I2 | P8 misstated sizer surface | Corrected: production caller of `metaWorstCase` is `src/wasm_entry.zig:102`; coherence points are `Pacb.zig:2487`, `root.zig:164`, `rt_entry.zig:92`, `PacbEncode.zig:125-127` (actuals via `metaEncodedLen`) | 1 |
| I3 | Old-reader tolerance substituted by same-decoder tests | Frozen-old **actual runs**: pre-SNAM `pacer-rt.wasm` artifact + pre-SNAM `meta.js` copy both execute new SNAM bytes (Group 3); compensating committed evidence cited (`Pacm.zig:761-766`, `Abi.zig:1356+`, `PacbEncode.zig:281` window). No compile-side frozen leg: no consumer feeds foreign blobs to `Abi.decodeMeta` | 0, 3 |
| I4 | "No pngine edit" was invented policy | **Ruled:** registration belongs in the pngine local repo, executed this wave as a local commit (no push/publish/network); status per true reservation rules (`payload-kinds.md:67-77`, `ZFTB` precedent) — no invented fake handler | 4 |
| I5 | rt.test.js anchors wrong | Re-anchored: name-gap `:119-120`, `evalBytes 152` pin `:128`, mask comment `:162-166`, mask block `:167-187`, wasm load `:28-33` | 3 |
| I6 | SNAM gets zero fuzz coverage | Structured mutator added to `src/fuzz_pacb.zig` (:11-14 harness): SNAM splice / count-inflation / name_len overrun / truncation inside the embedded PACM, **checksums repaired** so bytes reach metadata validation; honest count delta recorded | 2 |
| O1 | `meta.js:74-76` doc + stale types | Fix doc (fallback-only); regenerate whole `types/` tree (`types/types.d.ts:189-210`, `types/rt.d.ts:74`) | 3 |
| O2 | No duplicate-`SNAM` refusal test | Added to Group 2 refusal set (house rule: a malformed-input test per refusal, cf. `Pacm.zig:493,505,526`) | 2 |
| O3 | Task-5 home vague | Home named: `src/rt_entry.zig` fixture tests (`:686-714`, real load path over `tools/testdata/pacb/*.pacb`); runner negatives stay in `src/parity_negatives.zig` | 2 |
| O4 | HTML-escape attack list | Page writes names via `textContent` only, never `innerHTML`; no object-key use of names exists, so prototype pollution has no path (stated in the spec file header) | 5 |
| O5 | verify-node count moves | 114 → 116 with `bundle.test.js`; compat file adds more — record both old and new actuals (honest-count rule) | 3, 4, criteria |
| O6 | pngine CLI freshness unestablished | CLI probe via `version`/`help` verbs (`pngine/src/cli.zig:151-156`) before pack; the prebuilt `zig-out/bin/pngine` is an **OpenBSD** binary (exec fails on Linux: "required file not found") — bundle gates run on obs-dev or skip loudly naming host + resolved path | 4 |

## 2. Rulings applied (finish brief, binding)

- **R1 — Producer vs bounded wasm caps distinguished.** Native CLI accepts larger sources than wasm (`src/cli/Source.zig` cap vs `MAX_DOC_SIZE` = 256 KiB wasm-side). The plan never claims arbitrarily large native scores load into the existing wasm runtime; cartridges beyond the static zone keep today's loud `prt_load` over-cap refusal class.
- **R2 — Aggregate cap over per-name cap.** Bound = total name bytes across non-overlapping actual source slices ≤ source document size. Wasm zone growth is the aggregate term, **not** `64 × name_size` ballooning.
- **R3 — Exact names.** Any accepted runtime cartridge carries exact names; no truncation/drop/empty fallback for SNAM-present names. `name_len = 0` on the wire means a genuinely empty name span, never a degrade.
- **R4 — Wire length sufficient to source cap.** `name_len u32` (u16's 65,535 < 262,144 source cap). Static worst-case derived honestly (§3).
- **R5 — Registration is a pngine local-repo act**, not a public-network act; `PACR` text preserved byte-for-byte; new row status follows the true reservation rules (`reserved`, owner pacer, no handler invented).
- **R6 — Proper public carrier + explicit extraction seam.** The proof carries PACB under the reserved `PACB` kind and extracts via pngine's exported `payloadsOf` (`pngine/npm/pngine/src/payloads.js:143,236,245`) — no private production workaround.

## 3. Wire format and honest static bounds

- **C1 — `'SNAM'` section**, id `"SNAM"` LE = `0x4D414E53` (no collision with `'SCEN' 0x4e454353`, `'EASE' 0x45534145`, `'TMPO' 0x4f504d54`). Payload: `[count u32]` then `count × { name_len u32, name bytes }`. Emitted after `'TMPO'`; **omitted when scene count is 0** (sceneless blobs stay byte-stable). Count MUST equal the `'SCEN'` count; names are the verbatim source bytes of the `:name` symbol span (SJON `symbol_body` is ASCII-permissive, `SJON/src/Lexer.zig:612-616`; decoders never re-validate content, bounds only).
- **C3 — Source of truth.** `TrackTable`'s scene record gains `name: []const u8`, a borrow of the compile's source slice populated at the `Compile.zig` `name_span` site (`:955-1040`); lifetime valid through `encodeMeta`.
- **C5 — No version bumps.** `META_VERSION` unchanged (TLV append is exactly what the version policy permits, `Abi.zig:51-66,102-106`); PACB container unchanged; npm `pacer` stays `0.2.0` (additive `MetaScene.name`).
- **C6 — Decode fallback chain.** `name = SNAM entry if present → else source slice at name_span if source is held → else ''`. Old blobs on new code: `''` (today's behavior). New blobs on old code: section skipped by TLV length-skip.
- **Arithmetic (constants restated beside the code per house convention):** `MAX_SCENES = 64` (`src/TrackTable.zig:46`). SNAM worst case = `META_SECTION_HEADER_LEN (8) + count (4) + MAX_SCENES × name_len-field (64×4) + aggregate name bytes (≤ MAX_DOC_SIZE = 262,144)` = **262,412**. `metaWorstCase(256)`: 274,512 → **536,924** — tool-recomputed 2026-10-20 from the exact constants, term by term: `40 + 256×24 + 4096×32 + 64×(64+256) + (8+4+64×24) + (8+4+128×772+4+4096×2) + (8+4+512×16)` = **274,512** base, + the 262,412 SNAM term = **536,924** (constants `META_HEADER_LEN 40`, `META_TRACK_LEN 24`, `META_KEY_LEN 32`, `META_CONTROL_LEN 64`, `META_SECTION_HEADER_LEN 8`, `SCENE_REC_LEN 24`, `META_EASE_PROGRAM_LEN 772`, `TEMPO_REC_LEN 16` at `src/Abi.zig:133-176`; caps `MAX_TRACKS 256`, `MAX_KEYS 4096`, `MAX_EASE_PROGRAMS 128`, `MAX_CONTROLS 64`, `MAX_SCENES 64`, `MAX_TEMPO_SEGMENTS 512` at `src/TrackTable.zig:42-49`; id allowance 256 per the `wasm_entry` call site; verification record in `.agent/control/metadata-plan-corrections-report.md`). `META_CAP` (`src/wasm_entry.zig:80,102`, today the hand-picked 327,680) is redefined as **derived from** `metaWorstCase(256)` so it cannot drift again; the comptime assert remains. `PACB_CAP = Pacb.pacbWorstCase(256)` (`src/rt_entry.zig:91-92,117`) grows automatically once `pacmWorstCase` gains the identical term; the new value is recorded in the Group 1 task report (not fabricated here).
- **Native-only class (documented, no loss budget invented):** a native CLI compile whose aggregate names exceed the wasm-bounded term produces a cartridge that `prt_load` refuses with the existing over-cap status — the same native-only boundary that exists today for oversized documents. Loud refusal, never silent loss; an owner may lift zones later with no format change (u32 lengths already suffice). Executing pins for that refusal class (cap-relative — they read the cap dynamically and survive `PACB_CAP` growth): `rt.test.js:345-350` reads `prt_pacbCap()` and asserts the JS-side over-cap throw at `cap+1`; `rt.test.js:366` asserts `prt_load(cap+1, …)` → status 2. Group 6's decision summary cites these tests as the class's evidence, not name-total arithmetic.

## 4. Compatibility matrix (each cell has an executing test)

| bytes ↓ / reader → | new Zig `Pacm`/`Abi` | new JS `meta.js` | frozen old rt wasm | frozen old `meta.js` |
|---|---|---|---|---|
| new blob (SNAM) | names exact (G2 tests) | names exact (G3) | loads, wasm skips SNAM internally, names exact via the new JS glue (`'drop'`; `''` only via frozen old `meta.js`) (G3 compat, artifact run) | decodes, skips SNAM by length, names `''` (G3 compat, artifact run) |
| old blob (pre-SNAM pin) | loads, names ABSENT (`null` — the spelling a source-holding consumer keys its span fallback on; pinned at the unit readers and through the legacy cartridge load, G2) | names `''` (existing `rt.test.js` pre-SNAM behavior) | n/a (today's behavior, baseline green) | n/a (baseline green) |

Compensating committed evidence additionally cited: `src/Pacm.zig:761-766`, `src/Abi.zig:1356+` skip-tolerance tests, and the Group-1-before-Group-2 window in which the pre-SNAM `Pacb.decode` length-skip (`src/Pacb.zig:2472-2476`, depended on by `PacbEncode.zig:281`) exercises old-decode-on-new-bytes in CI.

## Global Constraints

- Repo pins: pacer `6098fa2` (branch `agent/animader-init`), SJON `bad5cddf` (path dep `../SJON`), pngine `bc0b41ff`, animader `78c0917` (untouched). Pacer untracked `zig-pkg/` and pngine untracked `pnpm-lock.yaml`/`pnpm-workspace.yaml` stay untouched.
- **Hosts / commands (exit codes captured before any pipe; no pipe-to-tail masking):** all zig gates and all pngine-CLI runs on obs-dev via `obs sh -c 'cd /home/agent/worktrees/animader-init/pacer && ulimit -c 0 && ulimit -s 32768 && zig build <step>' > <log> 2>&1; echo exit=$?` — serialized, never concurrent obs builds. Pure-node gates (lint/typecheck/unit) may run on local ai-linux node v26.10.0. Bundle gates requiring the pngine binary run on obs-dev (O6). Browser pass on the staged Linux browser.
- Append-only discipline: no existing PACM/PACB record retyped, no section reordering, no version bump.
- **Fixture split:** `tools/testdata/pacb/*` frozen **forever**; `src/testdata/pacm/scenes-tempo-ease.pacm` regenerates exactly once (the one legitimate producer change); a new committed pin `src/testdata/pacm/scenes-tempo-ease.pre-snam.pacm` preserves the pre-SNAM bytes **before** that regen. Immutability gates scope to `tools/testdata/pacb/` + the pin.
- Pngine: exactly one local commit (the `PACB` reservation hunk + doc row); no push, publish, registry-network act, or other pngine edit.
- House test style: Zig `std.testing` byte-level assertions, a malformed-input test per refusal; JS `node --test` + `assert/strict`; honest skips only (skip prints itself with the resolved path/variable; a skip is never a completion state).
- Conventional commits, one per group; independent fresh-reviewer gate after each group before the next starts.
- Out of scope: pattern-track packing, other metadata, Animader export migration, PACB container-section changes, any handler implementation for `PACB`.

## Review Focus

1. **Hostile-but-valid name bytes** (newlines/UTF-8/HTML-like content in structurally valid SNAM) reach renderers raw: decoders carry bytes verbatim (G2 UTF-8 test); the browser page uses `textContent` only (G5 pin).
2. **Checksum shielding:** unrepaired mutations die at PACB FNV before reaching SNAM arms — the fuzz mutator must repair checksums to reach metadata validation (G2 pins; else coverage is illusory).
3. **Native-only oversized sources** may produce cartridges the wasm runtime refuses at load (pre-existing zone class). The plan documents this and claims nothing stronger (§3 pins).
4. **pngine CLI is host-bound** (OpenBSD binary): bundle gates must run on obs-dev or skip loudly with the resolved absolute path printed — a silent default-skip would repeat B4's failure mode (G4 pins).
5. **`node --test` recursive discovery** executes anything under `test/` (node ≥ 20; today's `test/harness.js` already runs as a zero-test file): browser files live outside `test/` and `server.mjs` is import-side-effect-free (G5 pins).

---

### Group 0: Preserve frozen artifacts (BEFORE any edit) — **DONE 2026-10-20, commit `77d8c11`**

> Executed as planned: pin commit `77d8c11e9d78c91544a1beb0d24c2c0c04c0161c` (only the pre-SNAM PACM pin is tracked); report `.agent/control/metadata-g0-report.md`; sizes + sha256 (triple-tool cross-checked: `/usr/bin/sha256sum`, `openssl dgst -sha256`, python3 hashlib) in `.agent/control/metadata-frozen-artifacts.md`/`.json`. One recorded deviation: the JS artifact landed as **`meta-pre-SNAM.mjs`** (a bare `.js` outside the package's `"type":"module"` scope is CJS-parsed and dies on `export`; `.mjs` forces ESM) — the plan references below are corrected per BL-2. Checkboxes are ticked as the record of what ran, not a claim about Groups 1+.

**Files:**
- Create: `src/testdata/pacm/scenes-tempo-ease.pre-snam.pacm` (byte copy of the current committed fixture)
- Create (git-excluded, `.agent/` is in `info/exclude`): `.agent/artifacts/pacer-rt-pre-SNAM.wasm`, `.agent/artifacts/pacer-rt-pre-SNAM.wasm.sha256`, `.agent/artifacts/meta-pre-SNAM.mjs`
- Create: `.agent/control/metadata-frozen-artifacts.md` (size + sha256 + openssl cross-check per artifact, capture date, source path, regeneration instruction "build any pre-SNAM checkout")

**Interfaces:**
- Produces: the frozen-old readers Group 3's compat proof executes, and the pre-SNAM PACM pin Group 2's tests point at. Nothing consumes code from this group.

- [x] **Step 1: Copy artifacts.** `cp zig-out/bin/pacer-rt.wasm .agent/artifacts/pacer-rt-pre-SNAM.wasm` (baseline: 171,667 bytes, built by audit gate on obs-dev), `cp npm/pacer/src/meta.js .agent/artifacts/meta-pre-SNAM.mjs`, `cp src/testdata/pacm/scenes-tempo-ease.pacm src/testdata/pacm/scenes-tempo-ease.pre-snam.pacm`.
- [x] **Step 2: Hash with a trustworthy binary.** `/usr/bin/sha256sum` **and** `openssl dgst -sha256` each artifact; both must agree (session note: `/home/agent/bin/sha256sum` is a wrapper that misreported — the empty-string hash `e3b0c442…` for a 171,667-byte file; the agreed value for `pacer-rt.wasm` is `656030906c8bb3b879b3c8bb4cdedef332b909afce742e8ce9a8e6b43a44b776`). Record all values in `metadata-frozen-artifacts.md`.
- [x] **Step 3: Verify + commit.** Byte-compare copies against originals; `git status --porcelain` shows only the new pin plus pre-existing `zig-pkg/`. Commit: `test(meta): pin pre-SNAM fixture and frozen reader artifacts before edits`.

### Group 1: `'SNAM'` encoder + ALL sizer/oracle coherence — one green commit — **DONE 2026-10-20** (this commit; report `.agent/control/metadata-g1-report.md`)

> Executed with actual RED (exit=1, `metadata-g1-red1.log`) before any
> production edit; fixture regenerated once and proven append-only by
> `cmp` (1772 → 1792 bytes). Measured caps (compiler-printed probe,
> `metadata-g1-probe.log`): `metaWorstCase(256)` = 536,924 (= the plan's
> number; `pacmWorstCase` equality holds), `pacbWorstCase(0)` = 6,017,076,
> so `META_CAP` = 536,924 (was the hand-picked 327,680) and `PACB_CAP` =
> 6,311,988. Three premises the plan missed, adjusted minimally as the
> brief's "legitimate known-producer append changes" (details in the
> report): (1) `PacbEncode`'s "three committed CLI fixtures re-encode
> byte-identical" full-small leg — the frozen container's embedded
> `'PACM'` grows, so the fresh pack differs from the frozen bytes in the
> directory's `'PACM'` len field, the `'TRAN'` `pacm_fnv`, and the
> appended 20-byte tail (every other byte pinned identical); (2) `Pacb`'s
> frozen cap-sum numeric pins gained the 262,412-byte `'SNAM'` term;
> (3) two existing `Abi` stream-extent asserts now see the `'SNAM'` tail.

**Files:**
- Modify: `src/TrackTable.zig` (scene record gains `name: []const u8 = ""`; `MAX_SCENES` at `:46` unchanged)
- Modify: `src/Compile.zig` (populate `name` from the source slice at the `name_span` site, `:955-1040`)
- Modify: `src/Abi.zig` (`SNAM_SECTION_ID = 0x4D414E53`; `encodeMeta` `'SNAM'` emission after `'TMPO'`; `metaEncodedLen` actuals term mirroring the `'SCEN'` term at `:394-397`; `metaWorstCase` term `8 + 4 + 64×4 + MAX_DOC_SIZE` with the convention comment; tests near `:1293`)
- Modify: `src/Pacb.zig` (`pacmWorstCase` `:2487-2504` gains the identical hand-spelled term — Pacb must never import Abi; the `root.zig:164-174` frozen equality stays green by construction)
- Modify: `src/wasm_entry.zig` (`META_CAP` `:80,102` re-derived from `metaWorstCase(256)`; comptime assert kept)
- Verify only: `src/rt_entry.zig` (`PACB_CAP` `:91-92,117` auto-grows; record new value), `src/Pacb.zig:2472-2476` (meta skip-by-length confirmed, no edit), `src/PacbEncode.zig:125-127` (sizes via `metaEncodedLen` actuals — coherent by construction)
- Regenerate (once): `src/testdata/pacm/scenes-tempo-ease.pacm`
- Modify: `docs/binary-score.md` (section-stream spec gains the `'SNAM'` block: id, payload shape, omission rule, count-parallel rule, exactness rule R3, aggregate bound §3)

**Interfaces:**
- Consumes: Group 0's pin (immutability gate re-scoped before this commit lands).
- Produces: `Abi.SNAM_SECTION_ID`, scene-record `name` field, the worst-case term formula of §3. Groups 2-4 rely on these exact names; the regenerated fixture is what npm `pretest` rebuilds downstream.

- [x] **Step 1: Write the failing tests** in `src/Abi.zig` (builder style of the `:1293` scenes test): (a) tail-frame layout — id `0x4D414E53`, payload `[count][len]["drop"]` with u32 length; (b) a 300-byte name encodes **exactly** (R3 — kills the old truncate/degrade contradiction); (c) sceneless blob byte-identical to pre-SNAM encoding; (d) `metaWorstCase`/`pacmWorstCase` equality still holds at `{0,1,16,64,256}` (existing `root.zig:164-174` test is the gate).
- [x] **Step 2: Run RED** — `zig build test` on obs-dev; new tests fail (no SNAM frame). Capture exit code pre-pipe.
- [x] **Step 3: Implement** encoder + both sizer terms + `META_CAP` re-derivation. Exactness: encode the full span slice, u32 length, no `@min` anywhere.
- [x] **Step 4: Regenerate the oracle fixture once** by running the `root.zig:452-472` oracle's own encode path and writing its output bytes over `src/testdata/pacm/scenes-tempo-ease.pacm`; review the diff (only an appended `'SNAM'` frame); the other two oracles (`root.zig:299-307,318-320`) are sceneless and stay green untouched.
- [x] **Step 5: Run GREEN gates** on obs-dev — `zig build test` (incl. oracle byte-equality + worst-case equality), `zig build verify` (corpus 43/43; node 114/114 — masks still present, binary names render `''` until Group 3). Exit codes captured pre-pipe.
- [x] **Step 6: Commit** — `feat(meta): encode scene names as append-only 'SNAM' TLV; sizers/oracle coherent`. Record in the task report: new `META_CAP`, new `PACB_CAP`, fixture size delta.

### Group 2: Zig decoders — strict refusals, skip tolerance, structured fuzz reach — **DONE 2026-10-20** (commit `d71d4d9`; report `.agent/control/metadata-g2-report.md`)

> Executed with a two-phase actual RED (`metadata-g2-red1-test3.log`: refusal
> tests failed because the decoder skipped SNAM as unknown and ACCEPTED every
> malformed shape; `metadata-g2-red2-test.log`: landing tests failed on the
> missing name fill) before any production edit. GREEN: test 812/812 (791 →
> +21 slots), fuzz 379/379 (plan-quoted baseline 361 → +18, of which +14 this
> group; corpus 9 → 13 — endpoints corrected by the 2026-10-20 review-
> corrections wave: programmatic git inventory, `61c69a8` = 9, post-G2 = 13;
> the previously quoted 11 → 15 was wrong on both endpoints), audit-rt-imports
> green with the same allowlist and
> 17 `prt_*` exports (rt wasm 171,852 B vs the 171,667 baseline), verify
> corpus 43/43 + node 114/114, parity 43/43 with exactly the 4 known pattern
> skips. Plan-premise corrections recorded in the report and applied here:
> **v1 `'PACB'` has NO container checksum** — the fuzz repair list is the
> directory's `'PACM'` len field plus `'TRAN'`'s `pacm_fnv`, nothing else;
> **`MetaScene.name` is `?[]const u8 = null`** (presence-keyed — a plain
> slice cannot express present-empty vs absence and invites the falsy
> fallback IM-3 forbids; the C6 consumer chain is `name orelse
> source[name_span]`); and `src/root.zig` gained 8 lines (frozen-copy assert,
> `pacmExpectSameView` name comparison, one oracle literal assert) so the
> twin-decoder contract is actually tested across the pair. The PacerRuntime
> composition ruling: scene names are NOT materialized into the binary arm's
> table — nothing native reads `.name`, names travel via the served `'PACM'`
> copy decoded by the G3 glue; no native exact-name claim is made or tested.
> Review-corrections wave (2026-10-20, MEDIUM-1): the four `'SNAM'` corpus
> seeds did not actually route as their comments claimed — zig 0.16's
> `Smith.sliceWithHash` consumes a leading `u32` LE length prefix, so the
> unprefixed seeds lost their first four bytes and never reached the arms
> named (runtime-probe verified; the mid-entry-cut seed routed to raw mode,
> not even to arm 7). All four seeds re-shaped to `[len u32 LE][stream]` so
> each routes to its documented arm/flaw with every draw in range; pinned by
> a new corpus-routing test that drives the real draw code and
> `fuzzPacbDecode` per entry (RED on the old seeds: test 812/813, fuzz
> 379/380; GREEN: test 813/813, fuzz 380/380). The nine pre-G2 corpus
> entries are byte-identical; no decoder/production change.

**Files:**
- Modify: `src/Pacm.zig` (id constant, `MetaScene.name: []const u8 = ""`, TLV walk arm after `'TMPO'`, tests in the hand-built-blob style of `:601,:856,:884`)
- Modify: `src/Abi.zig` (`decodeMeta` mirror arm near `:957-964`, `MetaScene` gains `name`)
- Modify: `src/rt_entry.zig` fixture tests (`:686-714`, the O3-named home): pre-SNAM **pin** blob (`scenes-tempo-ease.pre-snam.pacm`) tested at the **`Pacm.decode`/`Abi.decodeMeta` unit level** — it is a bare `'PACM'` blob which `prt_load` cannot consume (`Pacb.decode` takes a `'PACB'` container; a bare PACM is a bad_magic refusal) — asserting every scene name `""` (the C6 old-blob-on-new-code pin); the **`prt_load`-path C6 proof rides the `tools/testdata/pacb/full-small.pacb` cartridge load test** in the same group (the frozen pre-SNAM packs already carry the real-path old-blob proof)
- Modify: `src/fuzz_pacb.zig` (`:11-14` harness gains one structured mutator)

**Interfaces:**
- Consumes: Group 1 wire layout + pin. Produces: `MetaScene.name` on both Zig views; fuzz coverage of the new arms.

- [x] **Step 1: Write the failing tests** — decode landing (count-parallel); refusals, one test each: count mismatch vs `'SCEN'`, `name_len` overrun, trailing payload bytes, `'SNAM'` before `'SCEN'` (fixed encoder order), **duplicate `'SNAM'` id** (O2); tolerance: unknown section after `'SNAM'` skipped by length; pin-blob empty names; **SNAM-present-empty precedence (IM-3): a hand-built blob with `'SNAM'` present whose one entry carries `name_len = 0`, decoded against a non-empty held source slice, yields `""` — presence-keyed, never a falsy `snamName || sourceSlice` fallback**; UTF-8 bytes verbatim; 300-byte name round-trips exactly through encode→decode. *(Executed as 16 named tests: 9 Pacm, 4 Abi, 2 rt_entry, 1 fuzz_pacb — see the report's inventory; the Zig spelling of IM-3 presence is the `?[]const u8` optional, per the correction above.)*
- [x] **Step 2: Run RED** on obs-dev (`zig build test`; exit code pre-pipe). *(Two-phase RED, both exit=1 and logged; details in the report.)*
- [x] **Step 3: Implement** both TLV arms (bounds-checked reads, `null` on any violation; unknown-id skip arm untouched — that arm IS the old-code-on-new-blob guarantee). *(Identical arm in both decoders; every length compared against what remains before it is added — u32-max `name_len` cannot wrap; entries account for the payload exactly.)*
- [x] **Step 4: Structured fuzz mutator** — locate the embedded PACM inside the three committed `tools/testdata/pacb/*.pacb` fixtures (canonical section order per `docs/binary-score.md`; offsets from the PACB header), then mutate: splice a syntactically valid `'SNAM'` frame with random names, inflate the `'SNAM'` count field, overrun a `name_len`, truncate mid-entry. **Repair the PACM FNV and container checksum after mutation** (recompute as `PacbEncode.zig:646` does at pack) so bytes reach metadata validation (Review Focus 2). Malformed hostile negatives per refusal stay as unit tests. *(Executed as `spliceSnam` over full-small — the scene-carrying fixture — with the repair list corrected to directory-len + `pacm_fnv`: there is no container checksum in v1. Three fuzz arms + 4 deterministic corpus entries; the valid splice must decode with the names visible through the served `'PACM'` copy, each broken rule must refuse `meta_malformed`.)*
- [x] **Step 5: Run GREEN + closure gates** on obs-dev — `zig build test`, `zig build fuzz --summary all` (361 → record the new honest count), `zig build audit-rt-imports` (same 12 pacer + 16 SJON allowlisted modules, same 17 `prt_*` exports, 1 import; record the new `pacer-rt.wasm` byte size vs the 171,667 baseline). *(Plus `zig build verify` and `zig build parity`, both green; all actuals in the report's gate table.)*
- [x] **Step 6: Commit** — `feat(meta): decode 'SNAM' scene names; strict refusals, skip tolerance, structured fuzz reach`. *(Commit `d71d4d9`, 5 files, +972/−5.)*

### Group 3: JS decode + types + unmasked parity + frozen-old-reader actual proofs — **DONE 2026-10-20** (commit `418ea6a`; report `.agent/control/metadata-g3-report.md`)

> Executed with an actual behavioral RED before any production edit
> (`metadata-g3-red1-js.log`: two test-side slips — a stale span constant
> and a `WebAssembly.Module` overload in the compat helper — fixed;
> `metadata-g3-red2-js.log`: the clean RED, 115/131). The RED family is
> exactly the exact-name flip (rt.test.js + the compat legs'
> new-decoder assertions), the IM-3 present-empty legs, and 11 strict
> TypeError refusals; the pure back-compat legs (old-wasm load-ok,
> byte-verbatim PACM serving, old-decoder `''` names, legacy fixture)
> were green from birth — never a fabricated failure. GREEN: obs
> `npm test` **131/131, 0 skipped** (114 → 131, +17 tests; O5 both
> actuals — the long-name pack leg RAN on the wave host), biome clean
> (cached `cli-linux-x64` 2.5.15 binary — this checkout's node_modules
> lacks the platform package; exact alternative, not a skip),
> `tsc --noEmit` clean, obs `zig build verify` exit 0 (corpus 43/43,
> node 131/131), `zig build parity` exit 0 (43/43 with exactly the 4
> known pattern skips), `grep mask` empty on rt.test.js and
> parity_runner.zig, frozen fixtures byte-identical. Plan-premise
> corrections recorded in the report: (1) Step 2's "compat legs (a)-(b)
> expected already GREEN" holds only for their back-compat subsets —
> the exact-name assertions inside them are RED by design (BL-1's own
> point); (2) `zig-out/bin/pacer` is a stale installed copy — `zig
> build run` executes the build-cache artifact, so the long-name test
> packs through the pretest-style `zig build run -- pack` invocation;
> (3) the strict-refusal matrix lives in a new `test/meta.test.js`
> (wasm-free home for the directly exported `decodeMeta`); (4) the
> name-span regex asserts were retired with the differences loop —
> exact equality is strictly stronger.

> **Review follow-up (2026-10-20, executed at the start of G4):**
> MEDIUM-1 — `npm run build:types` actually run (exit=0), the three
> review-named files (`types/meta.d.ts`, `types/rt.d.ts`,
> `types/types.d.ts`) read back carrying the post-SNAM docs (evidence:
> `metadata-g4-g3followup-buildtypes.log`,
> `metadata-g4-g3followup-types-readback.log`); the inaccurate §1
> report sentence corrected in place. LOW-1/LOW-2 — `meta.test.js`
> header narrowed to the SNAM arm (the generic TLV header-walk
> RangeError class is now named as pre-existing scope, wasm-validated
> away on the served path), `test/harness.js` scene comment names
> SNAM-else-legacy. Comment-only: no JS behavior change; local biome
> (19 files) + `tsc --noEmit` clean, local node suite 131/131 with the
> one legitimate zig-absent skip — counts unchanged.

**Files:**
- Modify: `npm/pacer/src/meta.js` (`PACM_SNAM_ID` arm after `'TMPO'`; u32 count/length reads; count mismatch → `TypeError`; bounds overrun → `TypeError`; `TextDecoder` verbatim fill; C6 precedence; `docBytes` param doc `:74-76` becomes fallback-only per O1)
- Modify: `npm/pacer/src/types.js` (`MetaScene.name` doc: carried in-blob, source slice is fallback)
- Regenerate: `npm/pacer/types/` (whole tree — `types/types.d.ts:189-210` `MetaScene`, `types/rt.d.ts:74` stale doc, per O1)
- Modify: `npm/pacer/test/rt.test.js` (re-anchored per I5: flip the name-gap assertion at `:119-120` to expect `'drop'`; **retire the mask** at `:162-187` — delete the differences loop, the `/^\s+\(mscene :name {2}/` assertion, both `masked(...)` lines — replace with exact `assert.equal(rtRendered, textRendered)`; keep the `'PACW'` eval-bytes sweep and the `:128` `evalBytes 152` pin unchanged)
- Modify: `npm/pacer/test/driver.test.js` (keep the existing byte-verbatim assertion green under SNAM precedence — `:279` already pins the `nameSpan` slice === `'drop'`; do not duplicate the test)
- Modify: `npm/pacer/src/rt.js` (stale-doc sweep, OP-5: the `:40-44` `EMPTY_DOC_BYTES` comment and the `:200-213` `meta` getter doc stop claiming scene names are `''` — they describe the C6 fallback chain post-SNAM), plus `npm/pacer/test/rt.test.js`'s `:7-14` header (same sweep; `types.js`/`types/` are already covered by O1)
- Create: `npm/pacer/test/compat-old-readers.test.js` (the I3 proof)

**Interfaces:**
- Consumes: Groups 0-2 (frozen artifacts, wire, Zig decoders); npm `pretest` rebuilds `test/rt-fixture.pacb` with the Group-1 encoder. Produces: source-free `MetaScene.name` on the binary path; the P2 requirement met unmasked.

- [x] **Step 1: Write the failing tests** — flip `rt.test.js:119-120`; write `compat-old-readers.test.js`: (a) load `.agent/artifacts/pacer-rt-pre-SNAM.wasm` exactly as `rt.test.js:28-33` loads the rt wasm, feed it the freshly built SNAM-carrying `test/rt-fixture.pacb`, and assert **load ok** (the real old-runtime-on-new-bytes proof: TLV skip + TRAN FNV + routing all pass), optionally that the wasm-served meta contains the `'SNAM'` frame verbatim, and **`meta.scenes[0].name === 'drop'` under the new JS decoder** — `PacerRt` is constructed from npm `rt.js`, which imports the new (post-Group-3) `meta.js`, so names decode exact; the old wasm never needed name knowledge (BL-1: expecting `''` here is wrong — at RED it passes vacuously on the pre-arm decoder and after Step 3 it fails permanently); (b) import `.agent/artifacts/meta-pre-SNAM.mjs` (BL-2: `.mjs` — the name Group 0 actually executed), obtain the PACM bytes by instantiating the frozen old wasm and slicing `prt_metaPtr()[0..prt_metaLen()]` (OP-4: proves old-wasm-serves + old-JS-decodes on new bytes in one motion, with no hand PACB-directory parse in JS), decode the way `rt.js:225` calls `decodeMeta`, and assert sections decode and names are `''` (skipped by length — this is the correct `''` leg); (c) **SNAM-present-empty precedence (IM-3, mandatory)**: hand-built blob with the `'SNAM'` section present, one entry `name_len = 0`, `docBytes` covering a non-empty `nameSpan` → assert `name === ''` (presence-keyed; kills the `snamName || sourceSlice` falsy-fallback hazard). Honest skip with printed artifact path only if an artifact is absent; completion criterion 7 requires **actual PASS (never skip) on the wave host**. Legs (a)-(b) pin **existing back-compat**: they are expected GREEN the moment they are written and stay green through Step 3 — RED comes only from the `:119-120` flip and leg (c); never fabricate a failure to manufacture RED for the old-reader legs.
- [x] **Step 2: Run RED** — `cd npm/pacer && npm test` (pretest rebuilds wasm + fixture on obs-provided artifacts); the `:119-120` name flip and the (c) precedence test fail; the compat old-reader legs (a)-(b) are expected already GREEN — they exercise existing back-compat, so a green leg here is the correct result, not a fabricated failure to suppress. Exit code pre-pipe.
- [x] **Step 3: Implement** `meta.js` arm + fill precedence; regenerate types via `npm run build:types`.
- [x] **Step 4: Retire the mask** (edit above) — parity asserts exact equality; comment states the owner-decided requirement is now met by `'SNAM'`.
- [x] **Step 5: Run GREEN gates** — `npm run lint && npm run typecheck && npm test` (biome clean; `test/exports.test.js` unchanged green — no new exports); `grep -n mask npm/pacer/test/rt.test.js` empty; `grep -n "mask\|mscene" src/parity_runner.zig` confirms no native mask exists (recon found none). On obs-dev: `zig build verify && zig build parity` — green with the same 4 pattern skips. Record node count delta (O5).
- [x] **Step 6: Commit** — `feat(meta): JS 'SNAM' decode; unmasked source-free parity; frozen old readers run new bytes`.

### Group 4: pngine `PACB` reservation (local repo) + node bundle gate — **DONE 2026-10-20** (pngine commit `e9aff0d5`; pacer commit `b67c6f7`; report `.agent/control/metadata-g4-report.md`)

> Executed with an actual behavioral RED before the production row
> (`metadata-g4-pngine-red1.log`: count test `expected 16, found 15` +
> the new `findKind('PACB').?` null-panic — the registry row was
> genuinely absent; the pack-accepts-unknown-uppercase fact stayed an
> expected-green compat note, never fabricated as RED). GREEN:
> test-payload **21/21**, drift **"16 kinds agree"**, npm
> envelope+bundle **423/423** (baseline count unchanged, OP-3) and
> extract suites **49/49**, exactly one pngine commit (registry row +
> docs row + the required dated note; PACR untouched, no handler, no
> autoplay claim). pngine aggregate `zig build test` is
> provision-blocked on obs **pre-existing**: the identical aggregate at
> baseline `bc0b41ff` fails with the byte-identical failing set
> (OpenBSD `realPath` in `cli.inprocess_test` + `cli.render`) — A/B
> logs `metadata-g4-pngine-green5-aggregate-zig-test.log` vs
> `metadata-g4-pngine-baseline-aggregate-zig-test.log`; the narrow
> gates stand as the commit's gates of record. Pacer:
> `test/bundle.test.js` — 4 tests, obs **4/4, 0 skipped** (ai-linux 1
> pass + 3 loud host skips proving skip-not-crash), obs `npm test`
> **135/135** (O5: 131 → 135), `zig build verify` exit 0 (corpus 43/0,
> node 135/135, Zig 699/699), parity exit 0 with exactly the 4 known
> pattern skips, frozen fixtures byte-identical. Public extraction seam
> = `pngine/viewer` (`dist/viewer.mjs` exports `payloadsOf`; the node
> root stub does not). One honest iteration recorded: the first obs
> bundle run failed on my own `spawnSync` array-as-file bug, fixed
> before green. G5 replay assets produced under gitignored
> `.agent/artifacts/` (hashes in the report); no browser files started.
> Untracked names preserved: pacer `?? zig-pkg/`, pngine
> `?? pnpm-lock.yaml ?? pnpm-workspace.yaml`.

**Files (pngine — the one authorized local commit):**
- Modify: `pngine/src/payload/envelope.zig` (`v1_kinds` row after the `PACR` row at `:386`: tag `"PACB"`, owner `"pacer"`, status `.reserved` — R5 true reservation, no handler invented)
- Modify: `pngine/docs/payload-kinds.md` (table row after `:54` per the reservation rule `:67-77`, `ZFTB` precedent: body "a compiled pacer cartridge (opaque binary; pacer owns the format)", handler none, legacy carrier none; **plus the appended dated note that same rule requires — "2026-10-20: pacer reserves `PACB`, opaque compiled cartridge, owner pacer, no handler, no legacy carrier" — in the document's "Dated notes" section (IM-2: a post-freeze reservation is "an appended dated note here plus its row …, never a silent row"; the drift gate compares only zig↔docs-table tag/status/owner, `build.zig:1890-1892`, and prose is explicitly un-gated, so omitting the note would land a silent reservation — the exact I4 failure mode — without any gate catching it)**)

**Files (pacer):**
- Create: `npm/pacer/test/bundle.test.js`

**Interfaces:**
- Consumes: Groups 1-3 (SNAM-carrying `rt-fixture.pacb`, source-free `PacerRt`, `meta.js`). Produces: the registered-lane node-tier bundling gate Group 5 builds on; `PACB` becomes a family tag (drift-gated).

- [x] **Step 1: pngine registration + gates.** Apply the two hunks; on obs-dev run `zig build drift_payload_kinds` (gate at `pngine/build.zig:1891`, script `scripts/check-payload-kinds.mjs` — tag set/status/owner compared both sides) and `node --test tests/npm/envelope.test.js tests/npm/bundle-closure.test.js` — green; count recorded (baseline 423; envelope.test.js is a byte-level mutation corpus with no v1_kinds enumeration, so a benign count drift is recorded both ways, never a spurious red — OP-3). Exit codes pre-pipe. Commit in pngine: `feat(payload): reserve PACB kind for pacer cartridges (pacer metadata wave)`. No push/publish.
- [x] **Step 2: Write the bundle test.** `PACER_PNGINE` env, default `new URL("../../../../pngine", import.meta.url)` from `npm/pacer/test/` (B4: four levels; print the resolved absolute path in every skip/failure). CLI probe first: spawn `pngine version` (`cli.zig:151-156`); on exec failure skip loudly naming the host constraint (O6: the prebuilt binary is OpenBSD-only). Then: pack a fixed 1×1 PNG with `--add PACB=<rt-fixture.pacb>` (deflate and `,raw` variants), extract with the public `payloadsOf` (R6 explicit seam), assert exactly one `PACB` payload byte-identical to the fixture; load the extracted body with `PacerRt` (wasm loading mirrored from `rt.test.js:28-33`), assert `meta.scenes[0].name === "drop"` and the `evalBytes 152` pin (`:128`). The proof carries **only** the cartridge — never score text. *(Executed with the deviations recorded in the DONE note: a dedicated authored named score packed fresh by the test itself (the brief's real-producer requirement, stronger than reusing the pretest fixture), the public `pngine/viewer` seam, and the oracle literals derived from that score — `32 = 12 + 20×1` bytes replaces full-small's 152 pin.)*
- [x] **Step 3: Run** on obs-dev — `cd pacer/npm/pacer && node --test test/bundle.test.js` → PASS (not skip); local ai-linux run may loudly skip the CLI legs (host constraint printed). Record the verify-node count 114 → 116 (O5). *(4/4 PASS, 0 skipped on obs; local 1 pass + 3 loud skips. O5 actual recorded from G3's real 131: node 131 → 135.)*
- [x] **Step 4: Commit** (pacer) — `test(bundle): PACB rides the reserved pngine kind — pack → payloadsOf → source-free PacerRt`. *(Commit `b67c6f7`.)*

### Group 5: Browser proof — mandatory launched pass (no completion without it)

**Files (all OUTSIDE `test/` per I1):**
- Create: `npm/pacer/browser/server.mjs` (static server over the worktree root; records every request path; import-side-effect-free)
- Create: `npm/pacer/browser/bundle-names.html` (module page)
- Create: `npm/pacer/browser/bundle-names.spec.js`
- Create: `npm/pacer/playwright.config.js` (`testDir: "./browser"`)
- Modify: `npm/pacer/package.json` (`"test:browser": "playwright test"`; devDep `@playwright/test` + lockfile change explicit — the one new dev-only dependency; `files:` already excludes it from the package; **lint scope (OP-6): `npm run lint` is `biome check src test` (`package.json:78`), so the new `browser/` files fall outside it — this group must either extend the biome scope to `browser/` or record the exclusion explicitly in the task report; not silent**)

**Interfaces:**
- Consumes: Group 4's producer (global setup re-runs the pack into a served temp dir), pngine `/npm/pngine/src/{payloads,png-chunks,envelope}.js`, pacer `/npm/pacer/src/rt.js` + `/npm/pacer/pacer-rt.wasm`. Produces: the actual-browser producer→extractor→runtime proof and the final browser-tester/design-reviewer pass.

- [ ] **Step 1: Scaffolding.** Server roots at `PACER_WORKSPACE` (default four levels up from `npm/pacer/browser/` = the animader-init dir; resolved absolute path printed); port chosen in 8000-8099 after checking owners; never disturb historical 8071/8072. Page: module script imports `payloadsOf` and pacer `rt.js` by absolute served paths, fetches the served `bundle.png`, extracts the `PACB` payload, loads `PacerRt`, writes `meta.scenes.map(s => s.name).join(",")` into `#names` and the supplied-time write count from one `eval(0.5)` into `#writes` — `textContent` only, never `innerHTML` (O4; header note: no object-key use of names exists, so prototype pollution has no path).
- [ ] **Step 2: The spec** asserts: `#names` is exactly `drop`; `#writes` > 0; the server's request log contains zero `.sjon` fetches (source-free by observation, not construction alone).
- [ ] **Step 3: Producer wiring.** Playwright `globalSetup` performs the Group-4 pack via the obs wrapper (pngine CLI is host-bound, O6) and places `bundle.png` in the served temp dir; missing CLI/chromium produces a loud per-run skip with the resolved paths printed — never a completion state (B3).
- [ ] **Step 4: Mandatory launched pass.** Run `npx playwright test` on the staged Linux browser (no WebGPU dependency; module imports + wasm + fetch counting only) → PASS. Then a browser-tester session (no shell — hand it the live origin URL from the control plane) and a design-reviewer pass on the running page: names visible, supplied-time writes visible, source-free bundle page. Evidence (URLs, screenshots, verdicts) recorded in the task report.
- [ ] **Step 5: Confirm `npm test` untouched** (node discovery never sees `browser/`; I1) → green, count unchanged by this group.
- [ ] **Step 6: Commit** — `test(bundle): browser proof — reserved PACB payload to source-free PacerRt scene names`.

### Group 6: Record

**Files:**
- Modify: `docs/binary-score.md` (bundling section: cartridges ride the reserved `PACB` kind; extraction seam is pngine's public `payloadsOf`; `PACR` remains the registered kind for score TEXT, untouched; names travel inside the cartridge — never from co-carried source)
- Create: `.agent/control/metadata-decision-summary.md` (decisions + costs: §3 arithmetic, META_CAP/PACB_CAP before/after, rt wasm size before/after, honest test-count deltas, compatibility matrix results, unverified limits)

- [ ] **Step 1: Land docs + summary** with the actual recorded numbers from Groups 1-5.
- [ ] **Step 2: Final gates in order (Completion criteria below), then commit** — `docs(meta): bundle carriage of cartridges; decision summary`.

---

## Completion criteria (in order; hosts named; exit codes captured pre-pipe)

1. obs-dev `zig build test` — 0 fail; count = 782 + new Zig tests, recorded both ways.
2. obs-dev `zig build verify` — corpus 43/43; node count per O5 actuals, recorded.
3. obs-dev `zig build parity` — green, same 4 pattern skips; `grep -rn "mask" src/parity_runner.zig npm/pacer/test/rt.test.js` empty.
4. obs-dev `zig build fuzz --summary all` — green; new honest count recorded (361 baseline).
5. obs-dev `zig build audit-rt-imports` — same 12+16 module allowlist, 17 `prt_*` exports, 1 import; new rt wasm byte size recorded vs 171,667.
6. `cd npm/pacer && npm run lint && npm run typecheck && npm test` — green; parity test asserts exact equality; `browser/` untouched by node discovery.
7. obs-dev `node --test test/bundle.test.js test/compat-old-readers.test.js` — **PASS, not skip**: both frozen-old-reader legs are acceptance-required actual passes (frozen artifacts present on the wave host; pngine CLI present); an environment skip is a per-run note, never acceptance of this criterion.
8. pngine (obs-dev): `zig build drift_payload_kinds` + `node --test tests/npm/envelope.test.js tests/npm/bundle-closure.test.js` — green with the `PACB` row; count recorded (baseline 423); pngine tree shows exactly one new local commit plus the pre-existing untracked pnpm files.
9. **Actually-launched browser pass** (staged Linux browser acceptable) + browser-tester + design-reviewer verdicts on the running page — evidence recorded. An environment skip note is never a substitute for this criterion.
10. `git diff --exit-code -- tools/testdata/pacb/ src/testdata/pacm/scenes-tempo-ease.pre-snam.pacm` — frozen; pacer `git status` shows only `zig-pkg/` untracked; `.agent/artifacts/` excluded by `info/exclude`.

## Documented undecidable point (no loss budget fabricated)

Native CLI sources larger than the wasm caps (`Source.zig` cap > `MAX_DOC_SIZE`) can produce cartridges whose SNAM-inclusive PACM exceeds the static runtime zone; `prt_load` refuses them with the existing over-cap status — a loud, pre-existing class boundary, not SNAM-specific loss. Whether to lift the wasm zones for that class is an owner decision outside this wave; the u32 wire already admits it without format change.

## Unverified limits (carried from recon, not re-surveyed)

- Gate counts are the exact baseline actuals from the parent log (`.agent/control/metadata-parent-baseline.log` + `.agent/control/metadata-parent-baseline-artifacts.json`; worker gates `metadata-baseline-worker-*.log` — cached runs re-ran with `--summary all`); not re-executed in this revision. §3's arithmetic was tool-recomputed 2026-10-20 from exact constants (corrections report).
- pngine `zig-out/bin/pngine` freshness vs `bc0b41ff` unestablished (O6 probe in Group 4).
- Old-native-zig-reader leg covered via the frozen rt wasm + committed skip tests (I3); a separate old native binary run is not planned — no consumer feeds foreign blobs to the compile-side decoder.
- GitNexus graph coverage unavailable throughout; all evidence is direct source reads at the pins above.

## Independent-review corrections applied (2026-10-20)

The independent fresh-reviewer pass (GLM 5.3, `.agent/control/metadata-plan-review-report.md`, verdict **REVISE** — architecture stands) was dispositioned and applied on 2026-10-20; report of record with the arithmetic verification: `.agent/control/metadata-plan-corrections-report.md`.

| # | Finding | Disposition |
|---|---|---|
| BL-1 | Old-wasm compat leg asserted impossible names (`''` where the new JS glue yields `'drop'`) | **Applied** — G3 Step 1(a) and the §4 matrix now assert load-ok + exact names via the new JS decoder; `''` only on the frozen-old-`meta.js` leg |
| BL-2 | Plan named `meta-pre-SNAM.js`; Group 0 executed `meta-pre-SNAM.mjs` | **Applied** — both references corrected; the g0 deviation ruling stands |
| IM-1 | Claimed `metaWorstCase(256)` = 278,512 / post-SNAM 540,924 | **Rejected with evidence** — recomputed by tool from the exact constants: the reviewer's own term expression evaluates to **274,512 / 536,924**, exactly the plan's existing numbers; the claimed sum contradicts the reviewer's own terms. §3 now spells the full expression from exact constants |
| IM-2 | pngine `PACB` reservation omitted the dated note its own rule requires | **Applied** — G4's docs hunk appends the dated note to "Dated notes" per `payload-kinds.md:67-77` |
| IM-3 | No SNAM-present-empty precedence test | **Applied** — added to G2 Step 1 (Zig) and G3 Step 1(c) (JS, mandatory) |
| IM-4 | Pin test phrased through `prt_load` is unexecutable on a bare PACM | **Applied** — pin at the `Pacm.decode`/`Abi.decodeMeta` unit level; the `prt_load`-path proof rides the `full-small.pacb` cartridge test |
| OP-1 | Over-cap refusal class cited no executing test | **Applied** — `rt.test.js:345-350` + `:366` pins named in §3; G6's summary cites them |
| OP-2 | `driver.test.js` byte-verbatim assertion already exists (`:279`) | **Applied** — reworded to "keep green under SNAM precedence", no duplicate test |
| OP-3 | "must stay 423" was a prediction posed as a gate | **Applied** — "green; count recorded (baseline 423)" (G4 Step 1, criterion 8) |
| OP-4 | G3(b) PACM-bytes provenance unstated | **Applied** — frozen-wasm `prt_metaPtr()[0..prt_metaLen()]` slice |
| OP-5 | Stale `''`-name docs in shipped source | **Applied** — `rt.js:40-44`, `:200-213`, `rt.test.js:7-14` added to G3's sweep |
| OP-6 | `browser/` outside `npm run lint` scope | **Applied** — G5 must extend the biome scope or record the exclusion |

Also of record: Group 0 marked **DONE** (commit `77d8c11`, report + hashes linked in its section); the old-reader compat legs are expected-GREEN existing-back-compat pins — RED is never fabricated for them; criterion 7 strengthened to acceptance-required actual PASS.

## Execution handoff

Groups 0→6 execute in order, one green commit each, with an independent fresh-reviewer gate after every group and a whole-branch review at the end. **Groups 0-4 are DONE (Group 0 commit `77d8c11`; Group 1 commit `61c69a8`; Group 2 commit `d71d4d9`, corrections commit `55e1c4c`; Group 3 commit `418ea6a`, 2026-10-20 — JS `'SNAM'` decode green on all gates, parity unmasked, frozen old readers run new bytes; Group 4 commits pngine `e9aff0d5` + pacer `b67c6f7`, 2026-10-20 — `PACB` reserved per the dated-note rule with the drift gate green at 16 kinds, and the real producer→extractor→runtime bundle proof at 135/135 on obs, with the bounded G3 review follow-up executed first, commit `d576059`). Next implementation group: Group 5 (browser proof).**
