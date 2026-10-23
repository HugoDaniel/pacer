# binary 04 — measurement, the user checkpoint, and the acceptance shape

**Repos:** pacer (consumer integration in animader is documented, never
edited, by this wave)
**Wire impact:** none.
**Gates:** `zig build verify`; the report itself; any numeric budget ratchet
exists ONLY after the user ratifies a number (proposed verb `zig build
size-check` — created then, not before).
**Created 2026-10-18; not started.**

## Why

The wave's premise is a lighter, faster artifact; only measurement makes
that true or false. **No KB figure and no percentage threshold is named by
this wave** (review I4 — the earlier draft's "~30% Brotli savings" number
is withdrawn; the user gave no number and the plan set will not invent
one). This plan defines ONE realistic procedure, produces the report, and
puts the go/no-go to the user with evidence. Correctness gates are SEPARATE
from the size decision and bind regardless of it: by the end of 02 P2 the
repo contains a typed, valid binary representation and a proven
no-compiler closure even if the size story disappoints — those are
properties of the architecture, not of a byte count.

## Design

### The measurement procedure (frozen here; executed once at P1 and again post-P4-fork)

**Environment record (with every table):** CPU model, RAM, OS, `zig
version`, optimize flags (ReleaseSmall), pacer + SJON SHAs, date, node
version, `gzip -9` / `brotli -q 11` tool versions, and the machine's
idleness note. Every number in the report is measured on this record —
nothing is carried over, extrapolated, or "estimated".

**Size columns (per file, raw / gzip9 / brotli11 — the
`animader/animader/.agent/releases/meridian.size.json` per-file method,
cited with its repo path):**

- `pacer.wasm` (full, today's artifact) — baseline already measured:
  661,334 / 238,810 / 194,275;
- `pacer-rt.wasm` at BOTH capability sets: the pattern-free artifact (02
  P2's trend artifact — labeled incomplete) and the post-fork full-capability
  artifact (the binding one);
- the JS glue as shipped: `index.js` vs `rt.js` + their shared modules, and
  the whole published file set the page loads;
- the score asset pair for representative scores: `score.sjon` vs its
  `score.pacb` — with the **PACM-duplication named** (review O-3): PACB
  embeds the metadata blob verbatim, so the container's delta over text
  includes a metadata copy the text path encodes at runtime; the report
  states it so the comparison is read knowingly;
- the `Pacm` reader's artifact cost as its own row (00 decision 6): the
  cross-check rides every binary load, so its bytes and its load-time
  cost are visible numbers, not hidden in totals;
- program totals exclude demo music (the existing report's `musicPath`
  scoping convention).

**Load performance (compile eliminated — measured, not asserted):** cold
load = fresh `WebAssembly` instance + load call; text path runs
`drv_load(doc)` (compile included), binary path runs `prt_load(pacb)`.
N = 50 samples per path, interleaved to decorrelate machine drift; report
median ± MAD and p10/p90. Warm reload = second load on a live instance,
N = 50, same stats. Both on the same machine class as the environment
record.

**Eval latency distribution (not a mean):** per representative score —
(a) a Meridian-shape minimal (keys + expr + controls), (b) the synthetic
all-features score (expr + pattern + controls + scenes + tempo map + emit +
trigger), which EXISTS AND RUNS ONLY AFTER the SJON prerequisite resolves
(the same fork as 03's pattern legs; no all-features claim before it) —
sweep 100,000 frames across scripted times including loop wrap, scene
seeks, and non-monotonic revisits; report per-frame µs p50/p95/p99/max per
path per score, plus allocation counts per frame. **Ship-blocker class:**
any frame-path allocation or non-determinism the text path does not have
(the engine is shared; the leaf switch must not regress it).

**Memory:** peak bytes and allocation counts per load and per steady-state
frame, both paths; the `DecodedScore` ownership copy (02 P2's B3 line item)
reported as its own row.

**Report:** `docs/binary-perf-YYYYMMDD.md`, committed with raw sample data
beside it; every table names its environment record. No number appears in
any plan or README before it appears in a committed report.

### The user checkpoint (falsifiable, no invented threshold)

After the post-fork report exists, the wave stops and asks the user to
decide, with the report in hand: proceed to integration, iterate (named
options: e.g., strip tables, split capabilities), or stop. The only
pre-declared ship-blockers are correctness/property classes, not numbers:
(a) any parity failure of any class in 03; (b) any frame-path allocation or
latency REGRESSION beyond measured noise on the representative set — noise
defined reproducibly by the procedure above (median ± MAD over N=50/100k
frames, same machine); (c) a non-determinism the text path doesn't have.
If — and only if — the user ratifies a numeric size budget, a ratchet verb
(`zig build size-check`, a committed baseline file, budget changes only via
reviewed commits — the SJON coverage-baseline precedent) lands in the same
commit that records the decision in 00's decision log. Until then there is
deliberately no ratchet to fail.

### Acceptance shape — pacer-local smoke NOW, Animader vertical LATER (blocked)

**Pacer-local (this wave):** `examples/` gains a minimal player page that
mirrors the Meridian player's calls (`loadDerivedShow`'s shape,
`animader/animader/demo/lib/score.mjs:300-325`): fetch `score.pacb` +
`pacer-rt.wasm`, `PacerRt.load`, drive `eval(t)` from a host clock, route
writes through the unchanged `route.js`. It proves locally, in a real
browser: the registry join, the meta audit inputs (track names via the
join, control ids via the embedded PACM), first-frame `eval(0)` semantics,
and restart (reload ⇒ state teardown ⇒ re-apply held controls). Manual
browser smoke is run by the parent's browser-tester with parent-started
servers; no plan here claims a browser result in advance.

**The real user outcome — a separate, BLOCKED handoff (review I9 + parent
ruling):** the final intended outcome is an actual Meridian static export
whose imports/network contain no compiler, no fallback, and no text-path
load — verified on desktop AND mobile: full clock behavior, PCM audio, all
three scenes, the through-motif, READY-state `eval(0)` before first paint,
and restart — followed by browser + design review. That work edits
`animader/animader` (integration points: `demo/lib/export.mjs`
`EXPORT_FILES` at `:21-31`, `demo/lib/score.mjs` `compileShow`/
`loadDerivedShow`), so it is recorded here as a **consumer-handoff phase
that stays blocked until the parent authorizes it** — it is NOT checked
off, and it is not proven by any local unit test in this wave. This wave's
04 P4 writes the handoff notes only.

**Docs (04 P4):** `CLAUDE.md` gains the artifact/build-verb rows;
`docs/binary-score.md` already landed with 01; the top-level `README.md`'s
artifact paragraph names both wasms and when each ships. These are future
commits by this plan's phases — none of them exist today.

## Phases

| Phase | Deliverable | Gate |
|---|---|---|
| P1 | measurement harness + the report (both capability columns; all-features only post-fork) | report committed with raw data; `zig build verify` |
| P2 | the user checkpoint (and, only if a number is ratified, the ratchet verb) | decision recorded in 00's decision log; ratchet green if it exists |
| P3 | `examples/` player page + checklist docs | `zig build verify`; manual smoke deferred to the parent's browser-tester |
| P4 | docs + the Animader handoff notes (blocked phase — notes only) | review |

## Progress log

_(created 2026-10-18; entries appended per phase)_

- 2026-10-22 — **Group C executed once on obs; measurement complete, the
  P2 checkpoint is an ESCALATION.** Report of record:
  `docs/binary-perf-20261022.md` with raw data in
  `docs/perf-data-20261022/` (committed together; environment record,
  C2 sizes/groups, C3 interleaved samples, C4 100k-frame samples,
  C5 memory, ablation artifacts and fixtures). pacer `4d46a5a`, SJON
  `c9a90d85`; the P1 procedure's environment record is
  `docs/perf-data-20261022/environment.tsv`.
  - **P1 (report + harness):** done with both capability columns. Binding
    `pacer-rt.wasm` 189,506 / 73,618 / 62,930; `pacer.wasm` 668,852 /
    241,544 / 196,534; pattern-free P2 rebuild 171,667 / 66,764 / 57,746
    (trend-only); Pacm-reader Δ 4,648 / 2,533 / 1,995 by controlled
    ablation; Meridian score 2,657 → 11,361 with the 5,651-byte PACM
    embedded; program totals exclude music (Meridian 778,864 / 284,862 /
    235,507). C3 real-shipped-WASM N=50 interleaved cold/warm; C4/C5
    native-only counting-GPA harness over the production `drv_*`/`prt_*`
    objects, no new shipped exports.
  - **P2 (user checkpoint):** **class (b) fires.** 100,000 frames per path
    per score: Meridian text p50 0.492 µs (MAD 0.014) vs binary 0.833 µs
    (MAD 0.014); all-features text 2.418 µs (MAD 0.041) vs binary 2.776 µs
    (MAD 0.057) — both median±MAD intervals disjoint, +341/+358 ns. No
    frame-path allocations (0/100,000); 100,000/100,000 frame hashes equal
    on both scores; supplementary real-WASM confirms Meridian (+733 ns,
    beyond MAD) and is inconclusive on all-features. Classes (a) parity
    and (c) nondeterminism do not fire. **Stop; Group D not started;
    escalate with evidence.** No `size-check`, no committed baseline, no
    invented budget/ratchet; the 2026-10-20 authorization is not carried
    into D by this record.
  - **P3 (pacer-local page):** `examples/player/` landed; Node proof PASS
    (fixture/join/meta/binary load/eval(0)/live control/reload+re-apply);
    the real browser pass remains the parent browser-tester's, not claimed
    here. No examples gate existed and none was invented.
  - **Gates:** cold six-gate on `4d46a5a` EXIT 0 — 56/56 steps, 1238/1238
    (847 native + 391 fuzz), node 182/0/0, corpus 44/0, parity 24+5+15
    skipped 0, negatives 3775/81, audit 12+18; npm typecheck + 182/182 on
    obs, pinned Linux Biome lint 31 files (OpenBSD Biome unavailable).
    Logs: `prod-four-c-final-gates.log`,
    `prod-four-c-final-npm-obs.log`,
    `prod-four-c-final-npm-lint-linux.log`.
  - **Not done:** D, any fix to the binary eval regression, browser
    execution/design review, push/merge/publish, any numeric ratchet.

- 2026-10-22 — **Group C rerun correction (dated — the append above stays
  verbatim; its C4/C5 figures are superseded).** With the harness at
  `7a20d0b` enforcing every-frame text/binary parity before any TSV is
  written, C4/C5 were regenerated (data commit `4cac49f`); C2/C3 are
  unchanged. P1 remains done; the report's binding numbers are now
  Meridian-minimal text 411 ± 10 vs binary 722 ± 29 ns (**+311 ns,
  +75.7%**) and all-features text 2,082 ± 28 vs binary 2,376 ± 25 ns
  (**+294 ns, +14.1%**), both median ± MAD intervals disjoint. The
  supplementary keys-only control is 92 ± 5 vs 95 ± 3 ns (**+3 ns,
  +3.3%**, overlapping intervals): it localizes the delta to the
  expr-bearing path but does not prove the mechanism. **P2 is still an
  escalation: class (b) fires, D is not started, the 2026-10-20
  authorization is not carried into D, and no size-check/budget/ratchet
  exists.** C3's cold-load noise statement is corrected to the observed
  MAD range 32.1–75.9% (all-features 52.2/68.8; Meridian 32.1/75.9). Cold
  six-gate on `11afb54` (code unchanged since `7a20d0b`) EXIT 0: 56/56,
  1238/1238 (847+391), node 182/0/0, parity 44/0, negatives 3775/81,
  audit 12+18; C7 node proof PASS; wasm hashes unchanged (668,852 /
  `9736a41b…`, 189,506 / `4e2f2100…`). Evidence:
  `.agent/control/prod-four-c-fix-gates.log`,
  `.agent/control/prod-four-c-fix-report.md`.

- 2026-10-23 — **Class (b) re-measured and cleared after the prepared expr-leaf
  fix; Group D proceeded on the user's ruling.** (Append-only; this note
  supersedes the class-(b)/D-stop verdict for the current implementation while
  the two 2026-10-22 entries above stay verbatim as the historical escalation
  and its correction.) The new enforced C4 run (100,000 frames,
  100,000/100,000 frame hashes equal before write) gives Meridian-minimal text
  467 ns / binary 434 ns (MAD 20/32, p95 514/496) and all-features text
  2,118 ns / binary 2,061 ns (MAD 82/54, p95 2,474/2,412); keys-only is a
  supplementary 94/102 ns. The same-session pre-fix baseline at `ff481a5`
  (fresh local and global caches) was Meridian 441/733 and all-features
  2,140/2,464, so the prepared leaf recovers **−299 ns (−40.8%)** and
  **−403 ns (−16.4%)**. **Class (b) no longer fires on this plan's frozen
  median ± MAD statistic.** The p50 intervals overlap, so parity is claimed,
  not a disjoint win; the all-features p99 is **5,796 ns binary vs 4,075 ns
  text** and is disclosed, outside the frozen statistic. Memory residuals:
  binary cold peaks 1,680,332 B (Meridian, +3.5%) and 8,400,764 B
  (all-features, +1.3%), warm exactly 2× cold, **0 frame allocations**; warm
  binary load 82/113 µs (vs 81/109 committed; same-session baseline 70/106,
  with text moving similarly). `pacer-rt.wasm` 189,321 B; `pacer.wasm`
  668,296 B. The user's ruling — "optimise the expr leaf before D" — was
  executed, and D proceeded after the re-acceptance recorded in
  `06-production-delivery.md:1804`.
