# 13 — A union with disjoint arms should report the arm, not the union

**Repo:** SJON first (the ask), then pacer (`corpus/`, `docs/` regen)
**Wire impact:** none. No `Compile.Code` variant moves — the codes that change are
SJON's, on SJON's side of the `'PACD'` `source` byte.
**Gates:** `zig build verify` (corpus regen + review), `zig build audit-diagnostics`
(must stay 31/31 — nothing here touches a pacer code)
**Size:** small on the pacer side; the work is upstream, and pacer supplies the
motivating evidence and the gate.

## Why

[12](12-sjon-alignment.md) put the score language's rules into the manifest, and two
of them now report through a diagnostic that names no cause. Both slots are typed by
a hand-written `(union-shape …)`:

```
(value-kind :name key-value :underlying union
  :union (union-shape :alternatives [plain-number vec-value]))     ; number | vector

(value-kind :name ease-spec :underlying union
  :union (union-shape :alternatives [ease-name ease-form]))        ; symbol | form
```

A union tries its alternatives in declaration order, first accept wins, and on total
failure reports `union_no_branch_matched` naming the alternatives — never the private
cause of the one that could have matched. Measured against `SJON/zig-out/bin/sjon`
at `906b149`, with `schema/pacer.sjon` prepended:

```
:ease smoothstepp
  union_no_branch_matched: keyword `:ease` expects `ease-spec`, got symbol
                           (no alternative matched: `ease-name` | `ease-form`)

:value 1e39
  union_no_branch_matched: keyword `:value` expects `key-value`, got number
                           (no alternative matched: `plain-number` | `vec-value`)

:jump middle                          ; a BARE kind, for contrast
  not_member: keyword `:jump` expects `jump-mode`, got `middle`
              (allowed: `start`, `end`)
```

The third is what the first two should read like. `ease-name` is a closed
`(member-set …)` of eighteen names, so a typo'd easing — the single most likely error
in a score — could name the legal set and offer a did-you-mean, and instead says only
that neither of two kinds matched. The `:value` case is worse than cosmetic: 12's
Phase B6 exists **to say that a value must fit f32**, and `corpus/diag-repr-f32`
records in its own header that the union swallows exactly that message
(`repr_out_of_range` survives only on the slots typed by a bare kind). The rule
landed; its diagnostic did not.

## The ask (SJON-side)

SJON already built this machinery, three days before 12 was written, and scoped it to
one carrier. `(scalar-or-ref-shape …)` reports **the arm the value's shape selected**
(SJON unreleased, 2026-08-18, filed by pngine as S13): each alternative's underlying
is resolved and asked whether the value's shape reaches it; exactly one reachable arm
selects and its own diagnostic is reported; `union_no_branch_matched` stays for a
shape that reaches none or both. `Validator.scalarOrRefArm` is the one function both
walkers ask.

S13 deliberately left hand-written unions alone — *"their alternatives may overlap"*.
That is true in general and false for these two: `number` vs `vector` and `symbol` vs
`form` are disjoint by node shape, which is S13's own precondition. So the ask is not
a new rule, it is the existing rule applied to the other carrier:

> Extend arm selection to `(union-shape …)`. When exactly one alternative's underlying
> is reachable from the value's node shape, report that arm's own diagnostic; when
> zero or two or more are reachable, keep `union_no_branch_matched` exactly as today.

Properties that make it cheap to accept — **re-derived against `906b149` on
2026-08-25 while filing**, and cheaper than this plan guessed: the union loop already
computes the arm and keeps its `MatchFail` (`Validator.zig:6589`, `:6598`), both
walkers already funnel through the one function (`:9119`/`:9133`, `:9233`/`:9238`),
and `alternativeReaches` (`:6670`) never mentions `scalar_or_ref` at all — the entire
gate is `if (!kind.scalar_or_ref) return null;` (`:6717`) plus a two-arm restriction
(`:6721`). There is no re-run to pay for; S13 already removed it. The rest:

- **No document changes verdict.** Matching is untouched; only the code a failure
  carries changes. This is the same guarantee S13 shipped under.
- **No new diagnostic code, no wire change, no manifest grammar.** The reported codes
  are the arms' existing ones.
- **The overlapping case is preserved by construction** — two alternatives a shape
  reaches (a symbol against a base that is itself a symbol kind, S13's own example)
  fall through to the union code.
- **Conformance already has the shape**: `scalar-or-ref-reports-base-arm` and
  `scalar-or-ref-no-arm-keeps-union` pin the two halves for the other carrier; the
  union port wants the same pair.

pacer has filed two asks this way before and both landed — `euclid` (SJON
`80f0e523`, 2026-07-18) and `queryTreeWithEnv` (SJON `cbbc8485`, same day). Both
followed the same shape: pacer supplies the motivating case, SJON decides the design.

## What pacer keeps if the ask is refused

Nothing breaks and nothing is blocked; the diagnostics stay as they are. The fallback
is deliberately **not** to split the unions apart in `schema/pacer.sjon`: `key-value`
being one kind is what lets a scalar and a 1–4 vector share a slot whose arity is
joined against the resolved target at load, and `ease-spec` being one kind is what
lets `linear` and `(spring …)` sit in the same `:ease`. Two keys instead of one would
trade a good language for a good error message.

## Phases

### Phase 1 — file the ask · **DONE 2026-08-25**
Load: `SJON/docs/plans/asks/README.md` (the verdict table and the ledger's shape),
`SJON/docs/plans/asks/13-scalar-or-ref-branch-diagnostics.md` (the precedent this
extends), `schema/pacer.sjon` (the two kinds), `corpus/diag-repr-f32/doc.sjon`.
Work: re-derive every claim above against the SJON tree (file:line, not changelog),
then file the ask in SJON's own format — evidence first, verdict invited, the refusal
case stated. Record the ask id here and in 00-strategy's decision log.
Gate: none on this side; the deliverable is the ask document.

**Filed as `SJON/docs/plans/asks/15-union-arm-diagnostics.md`** (`15`, not `11`:
PNGine wrote up an S11 and did not file it, and the file numbers track its
S-numbers — an ask from another host takes the next number after the last).
Unverdicted, in SJON's format, registered from SJON's `docs/plans/README.md` and
its asks README's "A second host's ask (filed 2026-08-25)" — no verdict-table row
until there is a verdict, which is what PNGine's own filing did. pacer is the
second host to file here.

### Phase 2 — pin it, once SJON answers · **DONE 2026-08-26 (the ask landed)**
Load: this file, `corpus/diag-repr-f32/`, `corpus/diag-ease/`, `docs/score-language.md`.
Work — **if the ask lands**: add a red for the typo'd easing name (there is no case for
it today, which is itself a gap: `diag-ease` covers pacer's five ease codes and none of
SJON's), regen the goldens with `-- --update` and review the diff, and rewrite
`diag-repr-f32`'s header — the paragraph explaining that a union forwards no branch's
private cause becomes the paragraph explaining that it now does.
Work — **if the ask is refused**: keep the corpus header as the record of why, and add
the refusal's reasoning to it. Either way the case documents the real behaviour.
Gate: `zig build verify` green, `audit-diagnostics` 31/31 (unchanged — every code that
moves is SJON's).

**SJON built it** (`docs/plans/asks/README.md`, verdict *Valid, and built*; SJON
`08d6983`..`922579d`, 2026-08-26), and built it wider than the ask asked: the rule is
per value and N-ary — count the alternatives the value's node shape reaches, and one
reachable alternative is the arm — so `Plugin.ValueKind.scalar_or_ref` was **retired**
rather than widened. `(scalar-or-ref-shape …)` is unchanged as a spelling; it just has
no bit of its own any more. pacer's side is the corpus pin plus one test that turned
out to be a second record of the swallow — see the progress log.

## Progress log

- **2026-08-25 — Phase 1 done: the ask is filed.**
  `SJON/docs/plans/asks/15-union-arm-diagnostics.md`, unverdicted, plus its
  registration in SJON's `docs/plans/README.md` and the asks README. Two things the
  re-derivation changed about this plan's own claims, both in pacer's favour:
  (1) **the fix is smaller than "small"** — the union loop at `Validator.zig:6589`
  already calls `scalarOrRefArm` and `:6598` already keeps the selected arm's
  `MatchFail` from the probe it runs anyway, so there is no re-run and no extra
  captured reference; the gate is the two guards at `:6717` and `:6721`, and
  `alternativeReaches` (`:6670`) is already general over any alternative name.
  (2) **it is a spec question too** — `docs/portable-manifest-v1.md` §4.9 does not
  merely omit this, it states the opposite in as many words ("there is no arm to
  blame … Spelling the same two kinds by hand as a `(union-shape …)` keeps the
  collapsed report"), so a refusal is a complete answer and the ask says so.
  The reproduction is SJON-only and runs: one plugin, eight document lines, showing
  the same base kind and the same `1e39` reporting `union_no_branch_matched` through
  a hand-written union and `repr_out_of_range` through a `scalar-or-ref`, with the
  zero-reach and both-reach rows that must not change. Also noted while filing:
  §4.9's own `[byte-count symbol]` example is shape-disjoint, so it is a case the
  ask would improve too.
  No pacer code, schema or corpus touched; gates not run (nothing to gate).

- **2026-08-26 — Phase 2 done: SJON built the ask, and the corpus pins it.**
  Verdict *Valid, and built* (`SJON/docs/plans/asks/README.md`, `08d6983`..`922579d`).
  The rule shipped wider than filed — it is per value and N-ary (count the
  alternatives the value's node shape reaches; exactly one is the arm), so the
  `scalar_or_ref` bit is **retired** rather than widened, and `(scalar-or-ref-shape …)`
  keeps its spelling with no flag behind it. Manifest §4.9 now owns the rule for every
  union instead of stating the collapse as deliberate.

  pacer's side, all four gates green (`verify`, corpus 36 → **37**,
  `audit-diagnostics` 31/31, score-docs unchanged — no `:description` moved):

  - **`corpus/diag-ease-name`** is the new red the plan asked for, and it pins four
    rows rather than one, because two of them are the rule's *boundaries*:
    `:ease smoothstepp` → `not_member` with all eighteen legal names (code 35, was 38);
    `:ease (transport :bpm 120)` → `not_head_member` naming the five combinator heads
    (37, was 38); `:ease (spring2 …)` → `unknown_form` (1); `:ease "linear"` →
    `union_no_branch_matched` (38), still, because a string reaches neither arm.
  - **A typo'd combinator head does not get the arm treatment**, which the plan did not
    foresee: head resolution runs before the slot's kind is consulted, so `spring2`
    is `unknown_form` and never reaches the union. The `not_head_member` red therefore
    needs a head that *exists* — hence `(transport …)` in an `:ease` slot, which is
    otherwise an odd thing to write. Same reason `(stage …)` outside `(seq …)` is
    `unknown_form`: it is a slot-local, and outside its slot it is nothing.
  - **`corpus/diag-repr-f32`'s `:value` row moved 38 → 114** (`repr_out_of_range`), so
    both spellings of the slot now say the value does not fit f32 — the paragraph
    explaining the swallow is now the paragraph explaining the arm.
  - **One source change the plan did not list.** `src/Compile.zig`'s "values that
    narrow to f32 must FIT" test asserted `union_no_branch_matched` for the three
    union slots and `repr_out_of_range` only for the bare ones — the corpus header was
    *not* the only record of the swallow, and `zig build verify` failed on it before
    it failed on anything else. Its six cases now assert one code, and it gained the
    boundary the corpus also pins: `:value "nope"` reaches neither arm and keeps the
    union's own report.
