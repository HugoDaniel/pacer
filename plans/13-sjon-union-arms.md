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

Properties that make it cheap to accept, each to be re-derived against the tree before
the ask is filed (the `docs/plans/asks/` discipline: an ask is a claim about SJON made
from outside SJON):

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

### Phase 1 — file the ask
Load: `SJON/docs/plans/asks/README.md` (the verdict table and the ledger's shape),
`SJON/docs/plans/asks/13-scalar-or-ref-branch-diagnostics.md` (the precedent this
extends), `schema/pacer.sjon` (the two kinds), `corpus/diag-repr-f32/doc.sjon`.
Work: re-derive every claim above against the SJON tree (file:line, not changelog),
then file the ask in SJON's own format — evidence first, verdict invited, the refusal
case stated. Record the ask id here and in 00-strategy's decision log.
Gate: none on this side; the deliverable is the ask document.

### Phase 2 — pin it, once SJON answers
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

## Progress log

_(empty — Phase 1 not started)_
