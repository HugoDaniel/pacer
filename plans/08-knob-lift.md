# 08 — Knob lift: WGSL `const` → uniform + `(control …)`

**Repos:** wgslender (const inventory API), studio editor (transform + UI)
**Wire impact:** none on pacer; wgslender adds an API (respect its semver)
**Gates:** wgslender's own test verbs; studio editor test verb

## Why

The impulsos WGSL is littered with `const TUN_SPEED: f32 = 0.55; // … (KNOB)` — dozens
of constants the author live-tuned by editing source and recompiling. pacer's
`(control …)` + `drv_registerControl` exist precisely for live knobs, and wgslender
already parses WGSL. "Lift this const" = rewrite the WGSL to read a uniform, plumb the
buffer through the pngine doc, and pin a control in the score. A real three-project
synergy that exists nowhere today.

## Design (v1 scope, freeze in Phase 0)

- **wgslender:** a const-inventory query — module-scope `const` declarations with
  name, scalar type, literal value, and source span. Decide the exposure route in
  Phase 0: an LSP custom request (the studio already runs the wgslender LSP worker)
  vs. a new C-ABI/wasm export. Prefer the LSP request — no new artifact to ship.
- **studio transform,** given a chosen const in one shader module of the pngine doc:
  1. add/extend a dedicated `knobs` uniform buffer in the SJON doc (buffer form,
     size, bind-group entries for every pipeline whose module uses the const —
     `(layout auto)` strips unused bindings, which helps),
  2. in the WGSL: add the struct field + binding declaration, delete the `const`,
     leave every use site untouched (same identifier — make the uniform struct field
     name the const's name and reference it via a `let` alias, or rename uses; pick
     whichever survives wgslender validation in the Phase 2 red),
  3. append `(control :id <name> :target <name> :value <literal> :min/:max guessed
     from value)` to the score text.
- v1 lifts scalar f32 consts only; vec/int later. The transform is text→text on both
  documents, so it's a pure, golden-testable function.
- The riskiest assumption is (2) keeping the WGSL valid across all its uses (const
  used in `const` contexts like array sizes CANNOT be lifted — detect and refuse with
  a clear reason).

### Phase 0 — API spike (RED first)
Load: `~/Dev/wgslender/CLAUDE.md`, `src/Reflect.zig` (public surface), the LSP request
dispatch (find it by grepping for an existing custom/handler table).
Reds (wgslender repo): a Zig test calling the (not yet existing) const-inventory on a
snippet with two consts, one in a lifting-hostile position (array size) — expect
names, values, spans, and a `liftable: bool`.
Green: implement inventory in wgslender; wire the chosen exposure (LSP request or
export).
Gate: wgslender test verbs.
Carry-forward: the request/export name + response shape.

### Phase 1 — studio access (RED first)
Load: `studio/editor/src/lib/lsp/lsp-integration.ts` (+ `lsp-worker.ts` request
plumbing).
Reds: editor test — send the inventory request for a WGSL string through the LSP
worker, get typed results.
Green: `lib/knobs/inventory.ts` thin client.
Gate: editor tests.

### Phase 2 — the transform (RED first)
Load: a pngine template doc (`studio/public/shaders/demoscene.sjon`) as fixture
material; `lib/preview/preview.ts` only for how docs recompile (minifiedKey path).
Reds: `lib/knobs/lift.test.ts` — golden text→text: lifting `TUN_SPEED` from a fixture
doc produces (a) a doc whose WGSL passes wgslender validation (call the LSP
diagnostics as the assertion), (b) a `knobs` buffer + bind-group entries only on
affected pipelines, (c) a score with the appended control; lifting an array-size const
refuses with the reason; lifting into a doc that already has a `knobs` buffer extends
it (offset bookkeeping).
Green: `lib/knobs/lift.ts` — `liftConst(doc, score, moduleName, constName) →
{doc, score} | {refused}`.
Gate: editor tests.

### Phase 3 — UI + live loop
Load: WGSL editor gutter/action conventions (`lib/codemirror/`), control-pin UI if one
exists (grep `setControl` in the editor), `App.svelte` mount points only.
Reds: component test — gutter action on a liftable const dispatches both document
edits through the normal actions; the new control appears and `pacer.setControl`
round-trips to a changed uniform in the next frame (real-wasm integration red).
Green: gutter affordance ("lift to knob"), wired end to end.
Gate: editor tests + manual smoke (tune a lifted knob while playing).

## Progress log

### Phase 0 — API spike (const inventory + exposure) — DONE 2026-07-17

**Exposure decision: a dedicated `wgslender/constInventory` WASM LSP request**, NOT
an extension of the existing `wgslender/reflect`. Reflect's JSON is cross-checked
against the reference `wgsl_reflect` library (`tests/cross_check_wgsl_reflect.mjs`)
and consumed by npm; bolting a knob-lift-specific `liftable` flag onto it would be a
layering leak plus wire churn (npm reflect types/goldens). A dedicated request keeps
the const inventory isolated — the gate stays `zig build test`, no reflect-wire or npm
churn — and gives the studio a purpose-named request. (Native `NativeServer` is NOT
wired: it doesn't handle `wgslender/reflect` either; the studio runs the **wasm** LSP.)

**Core — `Reflect.constInventory(arena, module) → []ConstInfo`** (`src/Reflect.zig`),
mirroring the override-collection pass. `ConstInfo { name, typ, value, decl_span,
liftable }`: name/scalar-type/initializer-text/full-decl-span verbatim from source
(same span/renderExprText fallback the override pass uses), plus the liftability call.
**Liftability is two-step:** (1) scan every const-required position — array element
counts across *all* type annotations (var/let/const/alias/struct-member/fn-param/
return, recursing composite + `call` template types), `@workgroup_size` args,
`const_assert` exprs, symbol-bearing attribute args (filtered by
`Ast.attributeArgsResolveSymbols`, so `@builtin`/`@interpolate`/`@diagnostic` keyword
args are skipped), and `override` initializers — collecting referenced **names**; (2)
fixpoint propagating const-required-ness *backward* through const→const initializer
refs (a const feeding a const-required const is itself const-required). `liftable =
name ∉ const-required set`. Name-based (not `SymbolIndex`) is exact here because every
scanned position is module-scope — no shadowing. **Function bodies are not scanned in
v1** (integer const-contexts there — e.g. a body-local `array<f32,N>(…)` constructor —
are rare, and Phase 2's transform re-validates the emitted WGSL via wgslender
diagnostics, which is the hard gate). Note: for the v1 f32-only lift the array-size /
workgroup_size detectors mostly matter for correctly reporting *integer* consts
non-liftable; an f32 const goes non-liftable only via `const_assert` or a
const-required chain.

**Exposure wiring:** `Handler.runConstInventory` (reuses the cached analysis module,
mirrors `runReflect`) → `ConstInventoryCommandResult { uri, consts }` →
`wire.workspace_commands.appendConstInventoryResult` renders
`{"uri","consts":[{name,typ,value,liftable,span:{start,end}}]}` straight from the
slice (no pre-rendered JSON to embed, unlike reflect). Method `wgslender/constInventory`
added to the `lsp/wasm.zig` dispatch table + a `handleConstInventory` adapter in
`lsp/wasm/workspace_commands.zig`; `Handler` re-exports `runConstInventory` +
`ConstInventoryCommandResult`.

**RED→GREEN (TDD):** wrote `tests/const_inventory_test.zig` first (RED: symbol absent) —
3 core tests: `array<f32, GRID_N>` → GRID_N non-liftable + TUN_SPEED liftable with
`typ`/`value`/`decl_span`; `@workgroup_size`+`const_assert` pin two non-liftable, a lone
f32 liftable; a `BASE → N → array size` chain proves backward transitivity. Then
`tests/const_inventory_lsp_test.zig` (2 handler round-trip tests: happy path +
`DocumentNotFound`) and the `appendConstInventoryResult` serializer test in
`lsp/wire/workspace_commands.zig`. **Gate: `zig build test` green; `zig build lsp-wasm`
+ `zig build lsp` compile.**

**Carry-forward for Phase 1** (studio access): request **`wgslender/constInventory`**,
params `{ textDocument: { uri } }`, result `{ uri, consts: [{ name, typ, value,
liftable, span: { start, end } }] }` (`span` is a byte range into the document source;
`value`/`typ` are verbatim source text, `typ` empty when the const omitted its
annotation). The studio's `lib/knobs/inventory.ts` sends this through the wgslender LSP
worker and filters to `typ == "f32" && liftable` for the v1 lift.

### Phase 1 — studio access (const inventory thin client) — DONE 2026-07-17

**Deliverable — `studio/editor/src/lib/knobs/inventory.ts`** (pngine `35c6cb7`, its own
repo + gate). `fetchConstInventory(lsp, wgsl, opts?) → Promise<ConstInventory>` opens a
throwaway virtual WGSL document under its own URI (`inmemory://knob-inventory-N.wgsl`, a
module-level counter — never collides with the editor's open regions), notifies
`textDocument/didOpen`, requests `wgslender/constInventory`, and `didClose`s in a
`finally` so the temp doc never leaks. Span offsets in the result index into the passed
`wgsl` string. Returns typed `ConstInventory { uri, consts: KnobConst[] }` where
`KnobConst = { name, typ, value, liftable, span: { start, end } }`; JSON-RPC being
dynamically shaped, a defensive normalizer coerces the wire payload with sane defaults
(bad/absent fields → empty string / `false` / `{0,0}`, unnamed entries dropped) rather
than trusting it. `liftableF32(inv) → KnobConst[]` selects the v1 lift set (`liftable &&
typ === "f32"`) — vec/int consts are inventoried but not yet liftable.

**The port, not the transport.** The client depends on a minimal
`InventoryLsp { request(method, params): Promise<unknown>; notify(method, params): void }`
— NOT the editor's full `LspTransport` (which adds version gating + a stale sentinel). A
one-shot inventory fetch has no staleness concern, so the narrow port keeps `inventory.ts`
decoupled and trivially fakeable. Phase 3 wires production by binding the editor's existing
transport (`(m, p) => _transport.request(m, p, v)` / `notify`) — reusing the one worker
the editor already runs, no second wasm instance.

**RED→GREEN (TDD):** wrote `inventory.test.js` first (RED: `ERR_MODULE_NOT_FOUND` for
`./inventory.ts`). It drives the REAL `public/wgslender-lsp.wasm` (the sibling wgslender
`zig build lsp-wasm` output, symlinked in) through the same `wgslender_lsp_alloc/_send/
_dealloc/_recv` framing the LSP worker uses (a byte-for-byte mirror of `lsp-wasm-framing.ts`
— the worker and inline backends share this exact wire), wrapped in the minimal
`{ request, notify }` port. Three cases: typed consts + liftability + span bracketing the
full decl (`GRID_N: u32 = 4u` non-liftable via array count, `TUN_SPEED: f32 = 0.55`
liftable), the `liftableF32` filter, and an empty inventory for const-free WGSL. Skips
(not fails) when the wasm isn't built. **Gate: editor `npm test` green (3/3 new; 1696/1696
suite), `tsc` + `svelte-check` clean (0 errors), biome clean.**

**Carry-forward for Phase 2** (the transform): `liftConst(doc, score, moduleName,
constName) → {doc, score} | {refused}`, text→text on both documents (pure, golden-testable).
Consume Phase 1's `fetchConstInventory` to get the chosen const's `value`/`span`/liftability;
refuse when `!liftable` with a clear reason. The RED calls the LSP diagnostics on the
emitted WGSL as the assertion that step (2) — struct field + binding, delete the `const`,
keep every use site valid — survives wgslender validation. See Phase 2 section above.

### Phase 2 — the transform (`liftConst`) — DONE 2026-07-17

**Deliverable — `studio/editor/src/lib/knobs/lift.ts`** (pngine `af61d2d`, its own repo
+ gate). `liftConst({ doc, score, moduleName, constName, inventory }) → LiftOk | LiftRefused`
— a PURE text→text transform over three surfaces:

1. **the pngine doc** — adds a `(buffer :name knobs :size N :usage [uniform copy-dst])`
   form (after the last buffer form; N rounds one f32-per-field up to a 16-byte multiple),
   and inserts `(entry :binding K :buffer knobs)` into the `@group(0)` bind groups of every
   pipeline that uses the module and ONLY those (`(layout auto)` derives each group's layout
   from its shader, so an unaffected group must keep its exact binding set). Module→pipeline→
   bind-group is resolved with `sjon-read.ts` (`read`/`fields`/`isForm`); the text inserts are
   placed with a span-aware top-level-form scanner (mirrors `sjon-regions`' private paren
   walk) and applied right-to-left so earlier offsets stay valid.
2. **the module WGSL** — via `sjon-regions.ts` (`extractSjonShaderRegions`/
   `replaceSjonShaderRegion`, which splice one module body byte-for-byte). Prepends
   `struct Knobs { <name>: f32, };` + `@group(0) @binding(K) var<uniform> knobs: Knobs;`
   (K = next free binding in group 0), deletes the whole `const` line, and rewrites each
   whole-word use to `knobs.<name>` (a `\b…\b` replace — comment hits are harmless, WGSL has
   no string literals).
3. **the pacer score** — appends `(control :id <name> :type slider :target <name>
   :min <lo> :max <hi> :value <literal>)`, the widget range guessed from the value
   ([0,1] for a unit value, else 0..2×).

**Refusals** (both documents untouched, `{ refused: <reason> }`): const absent, `!liftable`
(the array-size / const-context case — Phase 0's analysis is the source of truth), non-f32
(v1 scope), `:id` collides with a reserved time name (`t tick beat bar cycle phase bpm dur`),
or the score already pins that control id. **Extend path:** when the module already declares
`struct Knobs`, the field is appended to it (no second struct/binding), the existing knobs
buffer's `:size` grows only if the field count crosses a 16-byte boundary, and no duplicate
bind-group entry is added — so lifting a second const into an already-lifted doc is a clean
superset (the "offset bookkeeping" case).

**Why pure (inventory passed in, not fetched):** the plan calls the transform "a pure,
golden-testable function". Keeping the LSP fetch OUT of `liftConst` (the caller — Phase 3's
UI, or the test — resolves the inventory and hands it in) makes the transform deterministic
text→text with no async/IO; the LSP is used only to *validate the output*, which is the gate,
not a dependency of the logic. `LiftResult` is a `LiftOk | LiftRefused` union with `?: never`
witnesses so a consumer can branch on `res.refused` without a type guard.

**RED→GREEN (TDD):** wrote `lift.test.js` first (RED: `ERR_MODULE_NOT_FOUND` for `./lift.ts`).
It drives the real `public/wgslender-lsp.wasm` twice — Phase 1's `fetchConstInventory` for the
const spans, then pull-model `textDocument/diagnostic` on the *emitted* module WGSL, filtered
to `severity === 1` (errors) — that diagnostic assertion IS the hard gate. Four cases: the
fixture validates clean pre-lift (isolates fixture bugs from transform bugs); a full lift
(valid WGSL + knobs buffer + `bgC1` gains the entry while the unrelated `bg2` does not + the
control appended); refusal of an array-size const; and the extend path (lift a second const
into the first lift's output → one struct with both fields, one binding, one buffer, one
entry, both controls). **Gate: editor `npm test` green (4/4 new; 1700/1700 suite), `tsc` +
`svelte-check` clean (0 errors), biome clean.**

**Carry-forward for Phase 3** (UI + live loop): the gutter action on a liftable const calls
`fetchConstInventory` (Phase 1) then `liftConst` (this phase), and dispatches the returned
`{ doc, score }` through the editor's normal document-edit actions; surface `{ refused }` as a
non-blocking notice. The new control then round-trips through `pacer.setControl` to a changed
uniform next frame (the real-wasm integration red). `liftConst` targets `@group(0)` and f32
scalars only — vec/int lifts and non-zero groups are the first v2 asks.

### Phase 3 — UI + live loop — DONE 2026-07-17 · **plan 08 COMPLETE**

**Deliverable** (pngine `c43164b`, studio editor's own repo + gate). The WGSL editor gains a
`⛭ lift` chip after each liftable module-scope const; clicking it lifts the const end to end
and the new `(control …)` drives a live uniform. Built as the house **pure/edge split**
(cf. `sjon-shader-links.ts`): the logic is a tested pure controller, the CodeMirror widget +
Svelte wiring is the thin (manual-smoke-gated) shell.

1. **`lib/knobs/lift-controller.ts`** (PURE, the tested heart): `planKnobLifts(inventory) →
   KnobMark[]` — the affordance placement, the liftable-f32 set (`liftableF32`) with each decl's
   byte span. `liftToActions({ source, score, moduleName, constName, inventory }) → { actions } |
   { refused }` — wraps Phase-2 `liftConst` and hands back the SAME document-edit actions a
   hand-edit dispatches: `[{ type: 'SOURCE_CHANGED', source }, { type: 'SET_SCORE', score }]`,
   or a `{ refused }` notice (no actions). Reducing those through the REAL `reduce` proves the
   lift lands on AppState identically — that IS the "dispatches both edits through the normal
   actions" red.
2. **`lib/codemirror/knob-lift.ts`** (edge shell): a Facet carrying the lift callback, a
   `setKnobMarks` StateEffect the host pushes fresh marks through, and a StateField rendering the
   `⛭ lift` widget at each decl end. Inert until marks are pushed, so safe to install
   unconditionally. Its pure planner (`planKnobLifts`) is the tested part; the DOM shell is not
   DOM-tested (house convention — the studio has NO jsdom/component harness).
3. **Wiring** (edge, typecheck + manual-smoke gated): `codemirror-setup` gains an `onLiftKnob`
   option + a `pushKnobMarks` handle method + the chip style; `lsp-integration` exports
   `fetchWgslConstInventory(wgsl)` binding the ONE live LSP transport to Phase-1's
   `fetchConstInventory` (throwaway virtual doc, no second wasm); `CodePane` takes a `score`
   prop, pushes inventory-derived marks on the shader-module WGSL tab, and on click runs
   `liftToActions` + dispatches (refusal → `console.warn`, a defensive backstop since the chip
   only shows for liftable consts); `App.svelte` passes `score={appState.score}`.

**RED→GREEN (TDD):** wrote `lift-controller.test.js` first (RED: `ERR_MODULE_NOT_FOUND`). It drives
BOTH real wasms — `public/wgslender-lsp.wasm` (Phase-1 inventory) AND `public/pacer.wasm` (the
driver) — end to end. Four cases: the planner marks TUN_SPEED + DECAY (not the array-size GRID_N)
with decl-bracketing spans; `liftToActions` → the two actions, which reduced through the real
`reduce` yield the lifted doc (knobs buffer) + score (control); a refusal carries a reason and no
actions; and the **LIVE LOOP** — the lifted score `Pacer.load`s, the control holds the authored
`0.55`, `setControl('TUN_SPEED', 0.9)` changes the next `eval`'s uniform to `0.9`, and
`clearControl` returns it to `0.55`. **Gate: editor `npm test` 1704/1704 (+4 new), `tsc` +
`svelte-check` 0 errors (5 pre-existing App.svelte warnings), biome clean.**

**Scope note — no control-pin slider.** The plan's Phase-3 load list said "control-pin UI **if one
exists** (grep `setControl`)" — and none exists in the studio. So Phase 3 delivers the lift
affordance + controller + a proven `setControl` round-trip; a drag-slider widget is the plan's
explicitly-conditional piece and is NOT built. Live tuning today is via the control's `:value` in
the score (a `SET_SCORE` edit re-arms the driver); a slider bound to `pacer.setControl` is the
natural first v2 ask, alongside vec/int lifts and non-zero bind groups. **Manual smoke** (lift a
const, play, confirm the uniform is driven) is the user's to run — the browser preview can't be
driven from here.
