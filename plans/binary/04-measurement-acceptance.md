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
