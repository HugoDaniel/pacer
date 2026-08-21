# 12 — SJON 1.2+ alignment

**Repo:** pacer (+ `schema/`, `examples/`, `npm/pacer` docs only)
**Wire impact:** **none.** `'PACT'`/`'PACD'`/`'PACM'`/`'PACW'` layouts, `Compile.Code`,
`Easing.Op` and the `drv_*` set are all untouched; `drv_abiVersion` stays 1. Wave B
moves some diagnostics from `'PACD'` source 1 (pacer) to source 0 (SJON) — a record's
`source` byte and `code` change, the format does not.
**Gates:** `zig build verify`, `zig build audit-diagnostics` (must stay 31/31 — see the
reachability rule below), `zig build fuzz`, npm gate.

## Why

pacer was written against SJON 1.0. SJON has since shipped 1.1.0, 1.2.0 and an
unreleased wave, and three of those additions are aimed squarely at what pacer
hand-rolls today:

1. **`Host.preloadSchema` + `HostOptions.preloaded`** (1.1.0) is the two-phase
   replacement for exactly pacer's pattern. SJON's own `Host.zig` header names it:
   *"instead of prepending the schema to every document and rebasing every diagnostic
   span by the prefix length"*. pacer prepends a 346-line manifest to every score,
   re-parses and re-loads it on every compile, and carries `Validated.combined` /
   `prefix_len` / `userOffset` / `Abi.userSpan` purely to undo the shift.
2. **Schema vocabulary** — slot-local forms, `:default`, `:requires`,
   `(exclusive-group …)`, `(variant :when [a b])`, `(repr-shape …)` — lets
   `schema/pacer.sjon` say things it currently states in prose and re-checks by hand in
   `Compile.zig`.
3. **Tooling** — `sjon-lsp` discovers its vocabulary from a `sjon-project.sjon`, and
   `sjon export-schema --target=markdown` renders reference pages. pacer has 29 corpus
   `doc.sjon` files and an examples directory with no editor support at all.

Separately, `examples/` is stale: `impulsos_camaradas.sjon` is a **pngine** document
whose header points at a sibling `demoscene.score.sjon` that does not exist in this
repo, so the flagship example cannot be run as documented.

Nothing here is backwards-compatibility work — pacer is pre-1.0 with no consumers, so
each item is taken at full strength.

## Standing rules for this plan

- **Wave A must be byte-identical.** `'PACD'` spans are already emitted in user
  coordinates (`Abi.userSpan` subtracts `prefix_len`), and preload produces those
  coordinates natively. So every corpus golden — including the `:span [S E]` pins in
  `'PACM'` — must survive Wave A **unchanged**. A golden diff in Wave A is a bug, not a
  regen. This is the acceptance test for the whole wave.
- **The reachability rule.** `Compile.Code` is wire-stable and `zig build
  audit-diagnostics` asserts every variant is exercised by name. pacer voids the table
  on any SJON error, so a rule moved into the schema **short-circuits** the pacer
  builder. Before adopting a schema rule, check that the pacer code it overlaps keeps at
  least one reachable route; if it does not, the item is rejected (see "Considered and
  rejected"). Every Wave B phase names the overlap explicitly.
- **One phase per context window**, TDD reds first, regen + review goldens, commit in
  house style — the discipline in [README.md](README.md) applies unchanged.

---

## Wave A — the preload migration

Structural. No score-language change, no golden change.

### Phase A1 — `pacer.Schema`, the preloaded handle

Load: `src/Compile.zig` (Stage 1 only), `src/Abi.zig` (`userSpan` + `encodeDiags`),
`src/root.zig`.

New module `src/Schema.zig`, pacer's owned wrapper over `sjon.Host.PreloadedSchema`:

```zig
var schema = try pacer.Schema.load(gpa);   // parses schema/pacer.sjon ONCE
defer schema.deinit();
```

`load` asserts the embedded manifest produced **zero** diagnostics — pacer's own schema
being well-formed is a build invariant, not a per-compile diagnostic stream, and today
it is re-proved on every single compile. A test pins the assert (a deliberately broken
manifest string through the same code path).

`Compile.validate` / `Compile.compile` / `Driver.init` take `schema: *const Schema` and
pass `.{ .preloaded = &schema.preloaded }` to `sjon.validateDocument`.

Deleted outright: `Validated.combined`, `Validated.prefix_len`, `Validated.userOffset`,
`Validated.gpa` (the one place the caller's GPA was retained — `Validated` becomes a
thin wrapper over `HostResult`), and `Abi.userSpan`. `Abi.encodeDiags` writes
`d.span` directly.

**Lifetime note — the borrow-whole rule gains an outer ring.** `CompileResult.eval_schema`
holds `Plugin` structs whose interiors live in the preloaded arena, so the pair
`Schema ⊃ CompileResult ⊃ Evaluator` is now three deep. `Driver` stores the
`*const Schema` it was initialised with and its `///` documents the ordering, exactly as
it already documents in-place `init` and teardown order. The `Schema` is a host-level
object: one per process, above every `Driver`.

Reds: a test asserting `Compile.validate` on a score with a syntax error reports a span
that slices the offending token out of the **user source directly** (today's tests do
`source[v.userOffset(d.span.start)..]` — the red is dropping `userOffset` and watching
them still pass).

Gate: `zig build test`, then `zig build corpus` with **no** `--update` — the goldens
must already be green.

### Phase A2 — the three call sites

Load: `src/wasm_entry.zig`, `src/corpus_runner.zig`, `src/fuzz.zig`.

- `wasm_entry`: one module-level `Schema`, built lazily on first `drv_load` (or eagerly
  in the existing init path) and never torn down — the wasm instance owns it for its
  lifetime. `drv_load`'s "validate arguments BEFORE unload" contract is unaffected. The
  `MAX_DOC_SIZE + manifest_src.len + 2 <= MAX_FILE_SIZE` assert becomes
  `MAX_DOC_SIZE <= MAX_FILE_SIZE`; `drv_docCap` is a fixed 256 KiB buffer and does not
  change.
- `corpus_runner`: one `Schema` for the whole walk. The manifest is currently parsed and
  loaded 29× per run; this makes it once.
- `fuzz.zig`: one `Schema` per harness. Note the fuzz inputs get the **full**
  `MAX_FILE_SIZE` budget now instead of `MAX_FILE_SIZE - manifest_src.len`.

Gate: `zig build verify` + `zig build fuzz`, goldens unchanged.

### Phase A3 — docs of record

Load: `CLAUDE.md`, `README.md`, `src/Compile.zig` header, `src/Abi.zig` header.

Retire every "manifest prepend" / "combined text" / "user coordinates are recovered
via" sentence. The new statement: *the schema is preloaded once; document spans are
document coordinates by construction.* `CLAUDE.md`'s roadmap section gets this plan's
wave list.

---

## Wave B — schema vocabulary

Each phase is independent and small. Every one regenerates goldens (diagnostics move
between `'PACD'` sources); every one names its `Compile.Code` overlap.

### Phase B1 — drop `(plugin … :version …)`

`:version` is optional as of the unreleased wave. pacer's manifest declares `"0.1.0"`
while the package is `0.2.0` — a number nobody reads that is already wrong. Delete the
key. (pacer's real triple-pin — `package.json` / `build.zig.zon` / `src/root.zig` — is
unaffected and its lockstep test stays.)

Overlap: none. Goldens: unchanged (manifest never reaches a span).

### Phase B2 — `key` and `stage` become slot-local forms

`(key …)` is only ever a child of `(track …)` and `(stage …)` only of `(seq …)`, yet
both are declared as **plugin-global heads** today — the exact promotion §5.2 exists to
undo. Move them inside their parents, keeping the head-set recipe (§5.2's "closed
positional set"):

```sjon
(value-kind :name key-section :underlying form :heads (head-set :names [key]))

(form :name track :positional key-section
  (form :name key
    (key :name at    :type time-pos)
    (key :name value :type key-value)
    (key :name ease  :type ease-spec :optional true))
  (key :name target :type target-name)
  …)
```

This also retires the standing comment about `key` colliding with the meta-schema's own
`(key …)` form — with the head narrowed and the body local, the question stops being
askable. A stray top-level `(key …)` becomes `unknown_form` instead of validating clean.

Overlap: none (no pacer code fires on a misplaced `key`/`stage` today).
Goldens: `diag-validation` regens if it pins a stray-head case.

### Phase B3 — `:default` in the schema, read through `EffectiveView`

Five defaults are stated in prose in `schema/pacer.sjon` and hand-coded a second time in
`Compile.zig` / `Easing.zig`. Declare them once and read them through
`sjon.EffectiveView` over `HostResult.materialized_defaults`:

| Form / key | `:default` |
|---|---|
| `transport :meter` | `[4 4]` |
| `transport :end` | `hold` |
| `control :type` | `slider` |
| `target :registry` | `0` |
| `steps :jump` | `end` |
| `spring :periods` | `3` |
| `key :ease` | `linear` |

**`trigger :offset` cannot join them.** `Plugin.KeySpec.Default` has a `number: f64`
variant and no unit variant, so a `:default 0b` on a `time-pos` key would silently drop
its unit. `:offset`'s zero stays hand-coded in `Compile.zig`, with a `///` saying why.

Reds: a test per default asserting the compiled `TrackTable` value equals the schema's
declared default when the key is omitted — the drift gate the two-source arrangement
never had.

Overlap: none (defaults are not diagnostics). Goldens: unchanged — same values by
construction, which is the point.

### Phase B4 — `:requires [every]` on `trigger :offset`

Today `:offset` without `:every` is documented as *"Ignored without :every"* — a silent
no-op, the one thing pacer's diagnostic discipline otherwise refuses to ship. One key
turns it into `dependent_key_missing` with a span and an LSP quick-fix.

Overlap: `trigger_invalid` stays reachable (empty `:at`, unsorted `:at`, non-positive
`:every`, missing/duplicated source). Goldens: `trigger-basic` unaffected; a new red in
`diag-*` pins the dependency.

### Phase B5 — exclusive groups

```sjon
(form :name trigger
  (exclusive-group :cardinality exactly-one
    (alt :keys [every])
    (alt :keys [at])) …)

(form :name track
  (exclusive-group :cardinality at-most-one
    (alt :keys [expr])
    (alt :keys [pattern])) …)
```

`track`'s group is `at-most-one`, not `exactly-one`: the third source is `(key …)`
**children**, which an exclusive group counts nothing of. Keys-vs-`:expr` and
keys-vs-`:pattern` stay pacer's `track_source_conflict`, and `track_empty` stays
pacer's entirely.

Overlap: `trigger_invalid` and `track_source_conflict` both keep reachable routes (see
above) — check this with `zig build audit-diagnostics` before and after, not by
reading.

### Phase B6 — `(repr-shape :type f32)` on the value kinds that narrow

pacer's determinism seam is *"a single f64→f32 truncation at emission"*. Nothing
currently checks that the f64 **fits**: a `:value 1e39` compiles clean and reaches the
write buffer as `+inf`. `:repr` is range-only (precision loss is explicitly the
emitter's accepted step), which is exactly the right strictness:

```sjon
(value-kind :name plain-number :underlying number
  :unit (unit-shape :reject true)
  :repr (repr-shape :type f32))
```

Same on `stage-weight` and `bezier-points`' element. A breach is
`repr_out_of_range` with a span, at compile, before the truncation.

Overlap: none — no pacer code covers this today (that is the finding). Goldens: existing
values are all far inside f32; add a `diag-*` red pinning the rejection.

### Phase B7 — `(control …)` discriminated on `:type`

`:min` / `:max` are editor range metadata — meaningful for `slider` and `xy`, meaningless
for `color`. The brand-new multi-value `:when` says this in one declaration:

```sjon
(form :name control :discriminant type
  (key :name type :type control-type :optional true :default slider)
  (variant :when [slider xy]
    (key :name min :type key-value :optional true)
    (key :name max :type key-value :optional true))
  …)
```

`:type`'s `:default slider` (B3) satisfies the discriminant under effective axis D, so a
`(control …)` with no `:type` keeps working. `:min` on a `color` control becomes
`unknown_key` instead of validating clean.

Overlap: `control_invalid` stays reachable (reserved `:id`, `:min`/`:max` arity vs
`:value`). Goldens: `controls-vector` / `diag-controls` regen if they exercise a
`color` control with ranges.

### Phase B8 — hex literals reach the score language

`0x` opens a hex integer as of 1.2.0 — a **meaning** change pacer inherits for free
(`(track :expr (* 0xFF x))` used to evaluate `0`, silently). Add a corpus pin so the
inheritance cannot silently regress, and a `CLAUDE.md` line under the determinism
seams. No code change.

---

## Wave C — tooling and DX

### Phase C1 — `sjon-project.sjon` at the repo root

```sjon
(project :plugins ["./schema/pacer.sjon"]
         :documents ["corpus/*/doc.sjon" "examples/*.score.sjon"])
```

`sjon-lsp` discovers the nearest project file and composes its plugins into one schema,
so every corpus `doc.sjon` and every example score gets diagnostics, hover (rendering
the `:description`s already in the manifest), form-head and key completion, and
did-you-mean — for one file. `:documents` scopes the native workspace-diagnostics walk
so `times.sjon` / `expected.sjon` are not judged against the score vocabulary.

### Phase C2 — schema the corpus harness

`src/corpus_runner.zig` hand-parses `times.sjon` with ~12 bespoke shape errors
(`"(target …) needs a symbol name"`, `"(times …) takes hex strings only"`, …). A second
embedded manifest — `schema/pacer-corpus.sjon` — declares the harness forms
(`(target …)`, `(times …)`, `(set-control …)`, `(clear-control …)`, `(set-bpm …)`,
`(register-control …)`) and the golden forms (`(load …)`, `(meta …)`, `(mtrack …)`,
`(mkey …)`, `(mease …)`, `(eval …)`, `(write …)`, …). Preload it alongside the score
schema, validate the harness file, then read the validated tree.

Two wins: the bespoke shape errors collapse into SJON diagnostics with spans, and both
harness file kinds join C1's LSP coverage. The runner keeps its own **value** decoding
(`parseHexBits` and friends) — the schema checks shape, not the f64 bit patterns.

Keep the hex bit patterns as **strings**. `sjon fmt` rewrites a hex literal to decimal
(documented, LANGUAGE §4.2), so `0x3FE0000000000000` in a golden is one `fmt` away from
destruction. Strings are inert under the formatter and carry their width. This is a
deliberate no.

### Phase C3 — generated score-language reference

```sh
sjon export-schema schema/pacer.sjon --target=markdown --output=docs/
```

renders reference pages from the `:description`s the manifest already carries. Land it
as `zig build score-docs` writing `docs/score-language.md`, plus a drift check in
`verify` (regenerate to a temp path, diff). The manifest becomes the single source for
the score language's prose, not just its rules.

---

## Wave D — examples

### Phase D1 — the missing sibling score

`examples/impulsos_camaradas.sjon`'s header promises a `demoscene.score.sjon` driving
the `motion` buffer's four bare fields — `sceneMix`, `spin`, `chromaAmt`, `beat` — and
the file is not in the repo. Write it, in **compose mode** so it compiles, corpus-tests
and lints with no host:

```sjon
(target :name sceneMix  :arity 1 :registry 0)
(target :name spin      :arity 1 :registry 0)
(target :name chromaAmt :arity 1 :registry 0)
(target :name beat      :arity 1 :registry 0)

(transport :bpm 128 :meter [4 4] :dur 64bar :end loop :emit [beat])
…
```

This is the first example of the compose-mode `(target …)` form that closed the
roadmap, and it doubles as a corpus case (`examples-demoscene`) so the flagship example
is gated like everything else.

### Phase D2 — refresh `examples/index.html`

The inline score is valid under every Wave B change (it uses `:type slider` with
`:min`/`:max` — B7's `slider` variant). What it does **not** demo is anything landed
since: no `(scene …)`, no `(trigger …)`, no `(tempo …)`, no `:pattern`. Extend the
starter score to exercise them, and add a line to the HTML comment header pointing at
`demoscene.score.sjon` as the full-size counterpart.

### Phase D3 — `examples/README.md`

Three sentences: what each file is, which repo owns it (`impulsos_camaradas.sjon` is a
pngine document living here for reference), and how to run the demo.

---

## Considered and rejected

- **`(cross-ref :target target)` on `:target` slots.** Would give unknown-target
  did-you-mean natively — but only in compose mode. Host registries supply names no
  `(target …)` declares, so a cross-ref would reject every real score. pacer's
  `unknown_target` (joined at compile, against the *merged* registry) stays the only
  correct answer.
- **`(head-set … :min-children 1 :max-children 8)` on `(seq …)`.** Would duplicate
  `Easing.MAX_STAGES` in the schema — and because a SJON error voids the table before
  pacer's builder runs, it would make `ease_stages_exceeded` **unreachable** and break
  `zig build audit-diagnostics`. The per-head/per-set counts have no other fit in this
  schema: `(chain …)`'s "≥2 children" is over a union kind, which head-set counts do not
  reach.
- **A `(variant :when loop (key :name dur :optional false))` on `(transport …)`.**
  `:dur` is legal under `hold` too, and a key may live in exactly one place
  (`variant_key_collision`), so it cannot be both a common key and variant-required.
  `loop_requires_dur` stays a pacer diagnostic.
- **Hex bit patterns in goldens** — see C2.
- **Composing the harness vocabulary into `sjon-project.sjon`** (C2's second
  win). A project file composes every plugin it names into ONE ambient schema,
  and `schema/pacer.sjon` and `schema/pacer-corpus.sjon` both declare a
  `target` form — so listing both would make every unqualified `(target …)`
  `ambiguous_form` in scores and harness files alike. A `corpus/`-local
  project file inverts the loss (nearest-project-wins would cost `doc.sjon`
  the score vocabulary). Renaming the harness form or qualifying every head
  churns 34 hand-authored files plus the JS runner for an editor feature.
  Harness files keep their schema and forgo LSP coverage.
- **A `ms` unit on `time-pos`.** The 1.2.0 unit-alphabet widening makes it spellable,
  but `s` already covers it and a new unit is a new conversion path through the one
  documented `mul + floor` seam. Not worth a determinism seam for sugar.

## Progress log

- 2026-08-21 — **Wave A landed (A1 preload handle, A2 the three call sites, A3 docs).**
  Durable facts: (1) The acceptance test held — **not one corpus golden changed**
  (`git status corpus/` clean across 29 cases, both halves green). `'PACD'` already
  emitted user coordinates via `Abi.userSpan`, and preload produces exactly those
  natively, so the migration is a pure refactor and the `:span [S E]` pins in `'PACM'`
  are byte-identical. (2) `src/Schema.zig` is the new outermost ring:
  `Schema ⊃ CompileResult ⊃ Evaluator`, torn down inside-out. `Driver` records the
  borrowed `*const Schema` so the ring is visible on the struct, not just in prose;
  `Driver.init` gained the parameter. (3) **Four pieces of machinery deleted outright** —
  `Validated.combined`, `Validated.prefix_len`, `Validated.userOffset`, `Validated.gpa`
  (`Validated` no longer retains the caller's GPA at all) and `Abi.userSpan`. Every
  `us`-alias at the `'PACM'` encode sites went with them: spans are written through
  verbatim. (4) `Schema.load` asserts the embedded manifest preloads with zero
  diagnostics — pacer's own schema is a build invariant, and the prepend was re-proving
  it on every single compile. The assert is non-vacuity-guarded by
  `Schema.loadSource` on a deliberately broken manifest. (5) Hosts own exactly one
  `Schema`: `wasm_entry` preloads lazily on first `drv_load` and never tears it down
  (preloading happens BEFORE `unload`, so an OOM there leaves the live table alone —
  the bad-call no-op contract extends to it); the corpus runner builds one for the whole
  walk (manifest parsed once, not 29×); `src/test_support.zig` holds one page-allocator
  singleton for the test binary, mirroring the production lifetime instead of inventing a
  per-test one. (6) The wasm doc budget is now the whole `MAX_FILE_SIZE` —
  the comptime assert lost its `+ manifest_src.len + 2` term; `drv_docCap` is a fixed
  256 KiB zone and did not move. Gate at close: `zig build verify` green (unit tests,
  corpus 29/29 native + wasm parity, npm 85), `zig build fuzz` green, `zig build
  audit-diagnostics` 31/31, `zig fmt --check` clean. No wire change: `drv_abiVersion`
  stays 1 and all four blob `VERSION`s are untouched.

- 2026-08-21 — **B1 (drop `:version`) + B2 (`key`/`stage` become slot-local).**
  B1: `(plugin :name pacer :version "0.1.0")` lost its version — the key is only
  ever matched against a `(use-plugin … :version …)` pin no pacer score writes,
  and it had already drifted from the package's 0.2.0. A `Schema` test pins the
  absence so it cannot return as a fourth spelling of the version. The manifest
  header also lost its last "prepends this manifest" sentence (an A3 leftover).
  B2: the §5.2 closed-positional-set recipe — `key` is declared INSIDE
  `(form :name track …)` and `stage` inside `(form :name seq …)`, each still
  gated by its existing head-set value kind (`key-section` / `stage-section`),
  and both global declarations are gone. Durable facts: (1) pacer reads heads by
  TEXT (`std.mem.eql(u8, hdr.head, "key")`), never by schema lookup, so the whole
  compiler is indifferent to where the body is declared — not one line of
  `Compile.zig` changed. (2) A local form's own positional policy is still
  `.none` (omitted `:positional`); the implied-`.any` rule in §5.2 is about the
  PARENT that declares locals, and `track`/`seq` both declare an explicit
  `:positional`, so nothing loosened. (3) The standing "`key` collides with the
  meta-schema's own `(key …)`" comment is retired — with the head narrowed the
  question stops being askable. (4) New golden `diag-stray-key` pins the
  narrowing on the wire: a top-level `(key …)` is now `'PACD'` source=sjon
  code 1 `unknown form \`key\`` where it used to validate clean. No existing
  golden changed (29 → 30 cases). Gate: `zig build verify` green (corpus 30/30
  native + wasm parity, npm 86), `zig build fuzz` green, `audit-diagnostics`
  31/31, `zig fmt --check` clean.

- 2026-08-21 — **B3 landed: seven `:default`s in the manifest, six read back through
  `EffectiveView`.** `transport :meter`/`:end`, `control :type`, `target :registry`,
  `steps :jump`, `spring :periods` and `key :ease` are declared in
  `schema/pacer.sjon`; the prose "defaults to X" in their `:description`s is gone
  (the declaration says it). `Builder` gained a `view: sjon.EffectiveView` plus
  three typed readers — `effNumber` / `effSymbol` / `effVecNumber` — and every
  `if (kvNode(…)) |n| … else <constant>` fallback for those six is now a single
  `self.effX(form, key).?`. Durable facts: (1) **`key :ease` cannot come through
  the overlay.** `MaterializedDefaults.materializeForForm` resolves a form via
  `schema.lookupForm(head, ns)` — a GLOBAL lookup — so B2's slot-local `key` /
  `stage` never receive overlay entries. `:ease`'s default is structural instead:
  `programs[0]` IS linear (`TrackTable`'s own invariant), an omitted `:ease` refs
  slot 0, and the drift test pins that slot against the manifest's
  `:default linear`. Nested GLOBAL forms are fine — `steps`/`spring` sit under an
  `:ease` kvpair and the materializer's worklist descends kvpair values. (2) The
  compiled `(spring …)` params are `(lambda, omega)`, not `(damping, periods)` —
  `omega = 2π × periods`, so the drift test compares through that formula.
  (3) `trigger :offset` stays hand-coded, as planned: `KeySpec.Default` has a
  `number: f64` variant and no unit variant, so `:default 0b` would silently drop
  its unit. Both the manifest `:description` and the `Compile.zig` site now say so.
  (4) The drift gate reads the manifest at test time (`schemaKey` walks
  `plugins[0].forms` and their `local_forms`) and compares the compiled table
  against the schema's own default — never against a literal restated in the test.
  Goldens unchanged, exactly as predicted: same values by construction. Gate:
  `zig build verify` green (corpus 30/30 + wasm parity, npm 86), `zig build fuzz`
  green, `audit-diagnostics` 31/31, `zig fmt --check` clean.

- 2026-08-21 — **B4 landed: `:requires [every]` on `trigger :offset`.** The score
  language's last silent no-op is gone — `:offset` without `:every` (either alone
  or beside an explicit `:at` list) is now SJON `dependent_key_missing` (code 126)
  with a span on the offending key: *"form `trigger` keyword `:offset` requires
  `:every`, which is absent"*. Durable facts: (1) `trigger_invalid` keeps every
  route it had — neither source, both sources, non-positive `:every`, empty /
  unsorted / tied `:at` — so the reachability rule holds and
  `audit-diagnostics` stays 31/31. (2) New golden `diag-trigger-offset` pins the
  wire record; `trigger-basic` did not move, and neither did any other golden
  (30 → 31 cases). Gate: `zig build verify` green, `zig build fuzz` green,
  `audit-diagnostics` 31/31, `zig fmt --check` clean.

- 2026-08-21 — **B5 landed: two `(exclusive-group …)`s, and the branches they
  subsume are gone.** `(trigger …)` declares `:cardinality exactly-one` over
  `[every]` / `[at]`; `(track …)` declares `:cardinality at-most-one` over
  `[expr]` / `[pattern]`. Durable facts: (1) **A subsumed pacer branch is dead
  code, not a belt-and-braces guard** — pacer voids the table on any SJON error,
  so the "trigger needs exactly one of :every or :at" emit and the ":expr and
  :pattern" emit could never fire again. Both are now `std.debug.assert`s stating
  the group they rely on, which is the house rule for a validator-gated
  invariant. (2) The split that survives is *counts vs values*: a group counts
  key presence, so a non-positive `:every`, an empty / unsorted / tied `:at`, the
  two `(key …)`-children pairings and `track_empty` all stay pacer's —
  `trigger_invalid` and `track_source_conflict` keep reachable routes and
  `audit-diagnostics` stays 31/31. (3) `:offset :requires [every]` (B4) and
  `every`'s membership in an exclusive group coexist: the loader's "same
  exclusive group" rejection is about the *requiring* key sharing a group with
  its requirement, and `:offset` is in none. (4) New golden
  `diag-exclusive-groups` pins all three wire records in one case — SJON codes 27
  (`mutually_exclusive_keys_present`, twice) and 29 (`required_one_of_missing`).
  No existing golden moved; corpus 31 → 32. Gate: `zig build verify` green,
  `zig build fuzz` green, `audit-diagnostics` 31/31, `zig fmt --check` clean.

- 2026-08-21 — **B6 landed: `(repr-shape :type f32)` on the kinds that narrow.**
  `plain-number` and `stage-weight` now declare the machine type the emitter
  encodes them as, so a literal that does not FIT is refused at compile instead
  of reaching the write buffer as ±inf (`:value 1e39` used to compile clean).
  Durable facts: (1) **The code depends on the slot, and that is SJON's rule.** A
  hand-written union names its alternatives and forwards no branch's private
  cause (portable-manifest §4.9), so every slot typed by the `key-value` UNION —
  `(key :value)`, `(control :value)`, `:min`/`:max` — reports
  `union_no_branch_matched` (code 38), while slots typed by a bare kind —
  `(stage :t)`, `(stage :v)`, a `(cubic-bezier :p)` element — report
  `repr_out_of_range` (code 114). Both refuse, both carry a span on the literal;
  only the message differs. Pinning both shapes in one golden
  (`diag-repr-f32`) is what makes that visible. (2) Range-only is the right
  strictness and is now written into `CLAUDE.md`'s determinism-seam bullet:
  precision loss (16777217 losing its low bit) stays the emitter's accepted
  step; magnitude does not. (3) The largest f32 (3.4028234663852886e38) still
  compiles — the bound is the type's, not a hand-picked ceiling — and no
  existing golden moved, every corpus value being far inside f32. Corpus
  32 → 33. Gate: `zig build verify` green, `zig build fuzz` green,
  `audit-diagnostics` 31/31, `zig fmt --check` clean.

- 2026-08-21 — **B7 landed: `(control …)` is discriminated on `:type`.** `:min` /
  `:max` moved into `(variant :when [slider xy] …)`, so a range on a `color`
  control is `unknown_key` instead of validating clean and riding into `'PACM'`
  as noise. Durable facts: (1) **B3 and B7 are load-bearing for each other.** The
  common spelling `(control :id k :min 0 :max 1 :value …)` — no `:type` at all —
  keeps working only because `:type` carries `:default slider` and the validator
  resolves the discriminant from a materialized default (effective axis D). B3
  before B7 is not an ordering preference; it is the precondition. (2) **An
  explicit `:type` must precede the range keys.** SJON selects the variant as
  the walk reaches the discriminant kvpair, so `(control :id k :min 0 :type
  slider …)` makes `:min` `unknown_key` while the same keys swapped validate
  (portable-manifest §5.3). Pinned as a characterization test and written into
  the `:type` key's `:description`; the omitted-`:type` case is unaffected,
  the default applying form-wide. (3) One golden moved, as the plan predicted:
  `controls-vector`'s `tint` was a `color` control WITH rails — the exact
  spelling this phase outlaws. It now carries none and the golden reads
  `:min none :max none`, which the `'PACM'` control record already had a
  presence flag for. `pan` (xy, ranged) keeps the ranged half of the case.
  (4) `control_invalid` keeps both routes — a reserved `:id`, and a `:min`
  arity that disagrees with `:value` (`diag-controls` exercises the latter
  through the defaulted-slider path, unchanged). Gate: `zig build verify` green
  (corpus 33/33 + wasm parity), `zig build fuzz` green, `audit-diagnostics`
  31/31, `zig fmt --check` clean.

- 2026-08-21 — **B8 landed: hex literals pinned, no code touched.** `0x` opens an
  integer literal as of SJON 1.2.0, and pacer inherits the meaning for free —
  `readNumber` already accepted the integer tags, so nothing in pacer decides
  this. That is exactly why it needed a pin: an inherited meaning can regress
  with a dependency bump and no pacer diff. New golden `hex-literals` runs a hex
  value through every slot that takes a number — a key `:value` (0x10 → 0x20),
  a control's `:value` (0xFF → `437F0000` = 255), an easing parameter
  (`:n 0x4`), and inside an `:expr` (`(* 0xFF beat)`) — and a unit test asserts
  the same four in one compile. Durable facts: (1) `CLAUDE.md` gained a seam
  bullet saying pacer parses no literals: number syntax is the lexer's, so a
  meaning change there is a score-language change that arrives with no pacer
  code. (2) The case's own header warns that `sjon fmt` rewrites hex to decimal
  (LANGUAGE §4.2) — a formatter pass over `doc.sjon` would move spans and
  regenerate the golden without changing a single value. That is the same
  hazard C2 cites for keeping golden bit patterns as strings. Corpus 33 → 34.
  Gate: `zig build verify` green, `zig build fuzz` green, `zig fmt --check`
  clean.

- 2026-08-21 — **C1 landed: `sjon-project.sjon` at the repo root.** One
  `(project :name pacer :plugins ["./schema/pacer.sjon"] :documents […])`,
  plus the test that makes it load-bearing. Durable facts: (1) **The LSP and
  the CLI consume the same project file two different ways, and only one of
  them is ambient.** `lsp/Handler.loadProject` sets the handler's schema to
  `Schema.init(project.plugins)` — every `**/*.sjon` under the workspace root
  resolves the score vocabulary with no `(use-plugin …)` line, which is what
  C1 wanted. The `sjon` CLI's project check (`Cli.validateOneDoc`) instead
  calls `validateDocument` with a *resolver*, so a document's plugins come
  from its own `(use-plugin …)` directives; `sjon check` over `:documents`
  therefore reports `unknown_form` on every pacer score. Not a gate, and the
  project file's header says so. (2) `:documents` is read by the CLI walk
  ONLY — the LSP's `workspace_scan.collect` enumerates every `.sjon` under
  the root and never consults it (same for `:ignore`). The plan's C1 text had
  this backwards; the file's header carries the corrected statement.
  (3) The gate is a `Schema` test that runs the real `sjon.loadProject` over
  the repo root and asserts zero project diagnostics, `plugins = [core,
  pacer]`, and — head for head — that every form the compiler preloads
  resolves through the workspace schema. Shown to bite: pointing `:plugins`
  at a moved path fails it. The repo root reaches the test binary as an
  absolute path through a new `build_options` module (`addOptionPath`),
  shared by BOTH test roots — `src/fuzz.zig` reaches `Schema`'s tests through
  `test_support.zig`, so `zig build fuzz` needs the same import.
  (4) No `:version` in the project file, for B1's reason exactly: a fourth
  spelling of a version that lives in three places would only drift.
  (5) `examples/*.score.sjon` matches nothing until D1 writes it — harmless
  here (`loadProject` expands no globs; only the CLI walk emits
  `glob_no_matches`). (6) **Unverified end-to-end, and not pacer's to fix:**
  `sjon-lsp` built from the sibling checkout panics during `initialize` —
  lsp-kit (a path dep on `../wgslender/external/lsp-kit`) now treats
  `inlayHint/resolve` as required by SJON's `.inlayHintProvider = true`.
  A live editor session is blocked on that pair, not on this file. Gate:
  `zig build verify` green (corpus 34/34 + wasm parity, npm 90), `zig build
  fuzz` green, `audit-diagnostics` 31/31, `zig fmt --check` clean; no golden
  moved and no wire surface touched.

- 2026-08-21 — **C2 landed: the corpus harness has a schema.**
  `schema/pacer-corpus.sjon` is a second embedded manifest (the
  `pacer_corpus_schema` build import) declaring the six harness forms —
  `target` / `times` / `set-control` / `clear-control` / `set-bpm` /
  `register-control` — and `src/corpus_runner.zig` preloads it once for the
  whole walk through a new `Schema.loadChecked`, then validates every
  `times.sjon` before reading a field. Durable facts: (1) **The split is
  shape vs sequence-and-value.** Nine bespoke `corpus: …` lines pointing at
  nothing became SJON diagnostics carrying spans (`number_above_max`,
  `number_below_min`, `number_not_integer`, `wrong_underlying`,
  `missing_required_key`, `vector_length_mismatch`, `unknown_key`,
  `unknown_form`); what stayed is what a form-at-a-time schema cannot see —
  document order (targets precede the script), the non-decreasing registry
  rule the JS runner's regrouping depends on, `Abi.MAX_TARGETS`, "at least
  one script form", the hex WIDTHS, and an unoccupied `:positional` slot
  (`:positional <kind>` types a slot but cannot demand it be filled). Two
  tests pin WHICH layer refuses, by diagnostic code and by the report's
  absence — so a runner check quietly taking a refusal back fails.
  (2) **`:default` came with it:** `:registry 0` / `:ncomp 1` are declared in
  the manifest and read back through `EffectiveView`, B3's rule applied to
  the harness. `readSmallInt` / `readU32` are gone; `effInt` replaced both.
  (3) **The plan's second win is REJECTED, and the reason is structural.**
  Harness files do NOT join C1's LSP coverage: a project file composes every
  plugin it names into one ambient schema, and both manifests declare a
  `target` form, so listing the corpus manifest in `sjon-project.sjon` would
  make every unqualified `(target …)` `ambiguous_form` in scores AND harness
  files. A `corpus/sjon-project.sjon` does not help — nearest-project-wins
  would then cost `doc.sjon` the score vocabulary. The escapes (rename the
  harness form; qualify every head as `pacer-corpus/target`) both churn 34
  hand-authored files plus the JS runner to buy an editor feature, and were
  not taken. (4) **The golden forms are not declared either** — `(load …)` /
  `(meta …)` / `(mtrack …)` / … would be manifest surface for nobody: the
  runner never parses `expected.sjon` (it compares text byte-equal, which
  already catches any hand-edit), and without LSP coverage there is no second
  reader. (5) The runner's own tests now run: `root.zig`'s test block
  discovers `corpus_runner.zig` (it is its own executable root, outside the
  `pacer` module), giving the corpus authority unit coverage for the first
  time. Its `//!` header also lost a wrong example — `:value ["3F000000" "0"
  "0" "0"]` was never accepted; lanes are 8 hex digits each. Gate:
  `zig build verify` green (corpus 34/34 native + wasm parity, 213 Zig tests,
  npm 90), `zig build fuzz` green, `audit-diagnostics` 31/31, `zig fmt
  --check` clean, npm lint + typecheck clean. No golden moved, no wire
  surface touched.

- 2026-08-21 — **C3 landed: `docs/score-language.md` is generated, and the
  gate keeps it honest.** `zig build score-docs` renders the page from
  `schema/pacer.sjon` through `sjon export-schema --target=markdown`, and
  `zig build verify` re-renders to a temp path and diffs — so a `:description`
  edit that never reached the page fails the gate. 321 lines: every form with
  its key table (type, required, default, constraints) and every value kind,
  all of it prose the manifest already carried. Durable facts: (1) **SJON's
  CLI is not reachable as a dependency artifact** — its build wires `sjon` to
  its own `cli` step, not to the install step, so `sjon_dep.artifact("sjon")`
  panics with "unable to find artifact". pacer builds it from
  `sjon_dep.path("src/cli/main.zig")` with the same one-module recipe SJON
  uses; ~7s cold, cached after. (2) **`--output=-` cannot be prepended to.**
  The CLI's stdout writer is POSITIONAL, so a header line already written to
  a redirected stdout is overwritten from offset 0 — the render silently
  replaced it and the sizes matched exactly. `tools/score_docs.sh` renders
  into a temp DIRECTORY (`--output=DIR` writes `schema.md`) and concatenates
  the GENERATED banner in front. Worth remembering for any future
  shell-prepend against a Zig CLI. (3) One script serves both legs —
  `--update` writes, no argument diffs — so the gate compares exactly what the
  verb produces, the `audit_diagnostic_coverage.sh` precedent. (4) The
  exporter narrates its lossy JSON-Schema mappings on stderr as `[info …]`
  lines (17 of them); the script swallows them unless the render fails, so a
  clean `verify` stays quiet. Gate: `zig build verify` green (corpus 34/34 +
  wasm parity, 213 Zig tests, npm 90, score-docs current), `zig build fuzz`
  green, `audit-diagnostics` 31/31, `zig fmt --check` clean.

- 2026-08-21 — **Wave D landed (D1 the missing sibling score, D2 the demo page,
  D3 the README).** Durable facts: (1) **A symlink is what makes an example a
  corpus case.** `corpus/examples-demoscene/doc.sjon` and
  `corpus/examples-starter/doc.sjon` are symlinks to `examples/*.score.sjon`;
  both runners follow them transparently (Zig's `Io.Dir` open, node's
  `readFileSync`) and only the case DIRECTORY has to be real, so the file that
  ships IS the file the gate compiles — zero drift, no copy to keep in step.
  Corpus 34 → 36; not one existing golden moved. (2) **The plan's D2 was
  widened on the same reasoning.** `index.html`'s score was a string baked
  into the page: unverifiable, unreachable by `sjon-lsp`, and exactly the rot
  D1 exists to repair. It is now `examples/starter.score.sjon`, fetched into
  the textarea, covered by `sjon-project.sjon`'s `examples/*.score.sjon` glob
  and pinned as `examples-starter`. (3) **The demo page did not run.**
  `syncControls()` was called immediately after the awaited `Pacer.load` while
  `swayEl` was still in its `const` temporal dead zone — an uncaught
  `ReferenceError` at module evaluation, so the page had been blank since the
  control landed. All element lookups now sit above the await, and the same
  ordering bug is why the new click renderer is declared before it. Verified
  live in Chrome: load, live edit, a deliberate `unknown target` with its span,
  recovery, and the audio handoff. (4) **`spinAt`'s hand-rolled cubic IS a CSS
  bezier.** `(cubic-bezier :p [0.3 0.4 0.4 1])` has initial slope y1/x1 = 4/3,
  which over the 4-beat decel segment is exactly τ/4 rad per beat — the
  free-spin rate, so there is no stall at 141 — and y2 = 1 leaves it at rest.
  Structural landing puts the last key on 18 × 4π (`436231D6`) bit-exactly, so
  the cube stops face-on. (5) **The demo's click track is rendered from the
  score, not from a grid.** The page walks `t`, watches the `click` trigger's
  `count` lane, bisects each boundary to ~1e-13 s, and reads the loop length
  off the count's reset — 7.0 s, not `:dur ÷ bpm`, because `(tempo :at 8b :bpm
  160)` shortens the last two bars. Deliberately no PPC arithmetic in JS: the
  tick math stays in the driver, so the page asks questions instead of
  becoming a second determinism seam. ~3.5k evals, 17 ms, inside the 150 ms
  edit debounce. (6) Every landmark in `demoscene.score.sjon` is quoted from
  `impulsos_camaradas.sjon`'s own `const B_…` values (`B_PULSE` 32, `STOP_B`
  145, `B_FIST` 200, `B_SILENCE` 384, the 400-beat loop), including fs4's
  comment naming the chroma keys — "up 135→142, down 145→149" — that the
  pixelation envelope was built to mirror. Gate: `zig build verify` green
  (corpus 36/36 native + wasm parity, npm 92), `zig build fuzz` green,
  `audit-diagnostics` 31/31, `zig fmt --check` clean, npm lint + typecheck
  clean. No wire surface touched.

**Wave D is closed.** The flagship example exists and is gated (D1), the demo
page runs again and tours every form landed since it was written (D2), and
`examples/README.md` says which repo owns which file (D3). Two things landed
that the plan did not ask for and that the phase needed: the starter score
became a real file so it could be linted and pinned like the flagship, and the
page's load-order crash was fixed. **`plans/12-sjon-alignment.md` is closed** —
Waves A, B, C and D have all landed, no wire surface moved in any of them
(`drv_abiVersion` still 1), and the corpus grew 29 → 36 cases.

**Wave C is closed.** The project file gives scores editor support and is
tested against the compiler's own vocabulary (C1); the corpus harness has a
schema, and the split between what SJON refuses and what the runner refuses is
pinned by test (C2); the score-language reference is generated from the
manifest and drift-gated by `verify` (C3). One of the plan's stated wins was
rejected on structure — harness files do not join the LSP's coverage, because
one project file means one composed vocabulary and both manifests declare a
`target` form. Two things landed that the plan did not ask for and that were
needed: the corpus runner has unit tests for the first time (`root.zig`
discovers it), and `docs/` exists. Next: Wave D (examples).

**Wave B is closed.** All eight phases landed: `:version` dropped (B1),
`key`/`stage` slot-local (B2), seven `:default`s declared and six read back
through `EffectiveView` (B3), `:requires [every]` (B4), two exclusive groups
with their subsumed pacer branches deleted (B5), `(repr-shape :type f32)` (B6),
`(control …)` discriminated on `:type` (B7), and the hex-literal pin (B8).
Corpus 29 → 34 cases; `audit-diagnostics` 31/31 throughout — no `Compile.Code`
variant lost its last reachable route, and no wire surface moved
(`drv_abiVersion` still 1). One golden changed in the whole wave
(`controls-vector`, whose `color` control carried the rails B7 outlaws); the
other four regens are new cases. Next: Wave C (tooling / DX).
