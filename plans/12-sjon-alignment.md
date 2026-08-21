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
