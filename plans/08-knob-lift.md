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
