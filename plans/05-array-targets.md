# 05 — Array uniform fields as targets

**Repos:** pacer npm, studio editor, possibly pngine worker
**Wire impact:** none (an element target like `env[3]` is just a name in `'PACT'`)
**Gates:** npm gate; studio editor test verb; pngine gates only if its worker changes

## Why

The demo's `motion` buffer is 4 floats; every new envelope means editing WGSL structs,
buffer sizes, and bind groups. Worse, the studio's `buildRegistries`
(`studio/editor/src/lib/preview/preview.ts`) silently drops any reflected uniform with
ncomp ∉ 1..4 — arrays and matrices simply vanish as targets with no warning. Letting a
score drive `env: array<f32, 16>` element-wise gives dozens of lanes with zero WGSL
struct churn.

## Design (verify feasibility in Phase 0)

- pacer core is untouched: `env[3]` is an ordinary registry name with ncomp 1 (or 2/4
  for vec-element arrays). The work is entirely host-side:
  1. studio `buildRegistries` expands reflected array fields into element targets,
  2. the uniforms path delivers element writes to the GPU buffer at the right offsets,
  3. dropped/unrepresentable fields produce a visible warning instead of silence.
- The unknown: what pngine's worker `setUniforms` seam accepts. If it resolves only
  whole named fields, either (a) extend the worker to accept `name[i]` (offset =
  field offset + i·stride from reflection — mind WGSL array stride rules, `array<f32,N>`
  strides 16 in uniform address space unless vec4-packed), or (b) have the studio
  coalesce element writes into one whole-array value per frame. (b) touches no pngine
  code — prefer it for v1 if reflection exposes enough layout info.

## Phases

### Phase 0 — investigation (RED = a failing characterization test)
Load: `studio/editor/src/lib/preview/preview.ts` (buildRegistries + uniformsAt +
worker draw path), pngine worker `setUniforms` handling (`pngine/npm/pngine/src/worker.js`),
the reflection reply shape, `pacer/npm/pacer/src/route.js`.
Reds: a characterization test (studio editor test runner) feeding a fake reflection
containing `env: array<f32,16>` through `buildRegistries` — assert today's behavior
(dropped) to lock the baseline, marked as the behavior to change.
Output: record in this file which delivery option (a)/(b) is viable, the array stride
facts, and where uniform writes are applied.
Gate: editor tests pass with the characterization test in.

### Phase 1 — registry expansion + warning (RED first)
Load: only `preview.ts` (extract `buildRegistries` into a pure module first if it
isn't — e.g. `lib/preview/registries.ts` — so it's unit-testable).
Reds: `array<f32,16>` → 16 targets `env[0]`..`env[15]` ncomp 1; `array<vec4f,4>` → 4
targets ncomp 4; matrix field → still excluded but returned in a `dropped` list; plain
scalars unchanged.
Green: expansion + `{targets, dropped}` return; surface `dropped` through the existing
diagnostics/status channel (`onScoreDiagnostics` or a console-visible warning — match
studio conventions).
Gate: editor tests.

### Phase 2 — write delivery (RED first)
Load: the option chosen in Phase 0 — either the worker's setUniforms code (pngine) or
the studio-side coalescing site in `preview.ts`/`route.js` usage.
Reds: unit test — pacer writes for `env[3]`=0.5 and `env[7]`=1.0 produce either worker
messages with correct byte offsets (option a) or one coalesced `env` array value with
those elements set and others preserved from the previous frame (option b; pin the
"holes hold last value" semantics explicitly).
Green: implement; if pngine changes, run pngine's own gates and keep the change
append-only on its worker message schema.
Gate: editor tests (+ pngine gates if touched).

### Phase 3 — end-to-end + example
Load: a template score + doc (`studio/public/shaders/demoscene.*`).
Work: extend the demoscene template (or a new template) with an
`env: array<f32, 8>` buffer field driven by 8 score tracks; verify in the running
studio (real-wasm integration test alongside `score-uniforms.test.js` is the durable
red — add one asserting an element write reaches `toUniforms` output and the drawn
uniforms message).
Gate: editor tests + manual studio smoke.

## Progress log

### Phase 0 — investigation → DONE (2026-07-15, pngine `1095d61`)

**RED→GREEN.** Extracted `buildRegistries` (+ `UniformReflection`) out of
`preview.ts`'s closure into a pure `studio/editor/src/lib/preview/registries.ts`
so it unit-tests with `node --test` and no worker. Added `registries.test.js` (7
tests): a fake reflection with `env: array<f32,16>` (size 256), `array<f32,4>`
(size 64), `mat4x4f` (size 64), and an odd non-÷4 size — all asserted **DROPPED
today** (ncomp = size/4 ∉ 1..4), with scalars + vec2/3/4 kept in reflection
order. The array cases are explicitly commented as the baseline Phase 1 changes.
Gate green: tsc 0, svelte-check 0 err (5 pre-existing App warnings), biome clean,
full editor suite **1603/1603** (+7). Behavior-preserving extraction — no pngine
worker touched.

**Delivery option — (b) is viable and preferred; (a) needs a pngine change.**
Traced the write path end-to-end:

- **Reflection reply** (`worker-core.js` `handleGetUniforms` ← `gpu.js`
  `parseUniformTable`): per field `{ type, size, bufferId, offset }` — `size` =
  field byte size, `offset` = byte offset in the buffer, `type` = a UT_* tag.
  **No stride field, and no `UT_ARRAY` type** — `uniformToTypedArray` handles
  only scalar / vec2–4 / mat3x3 / mat4x4; an array field falls through to the
  f32 `default`.
- **The write seam** (`gpu.js` `setUniforms` → `setUniform(name, value)`):
  `uniformMap.get(name)` is a **whole-named-field lookup only** — no `name[i]`
  parsing. It writes `uniformToTypedArray(value, type, size)` at `info.offset`,
  and `uniformToTypedArray` **already accepts a JS array** and truncates to
  `size` bytes (`gpu.js:878/886`). So `setUniform('env', [...64 floats])` writes
  the whole array field today, unchanged.
- **Where writes are applied (the chokepoint):** `renderFrame` /
  `prefetchRange` → `uniformsAt(t)` → `toUniforms(writes, 0)` (pacer `route.js`
  folds entries into `{ [name]: value }`, keyed by the literal target name) →
  `worker.postMessage({type:'draw', uniforms})` → `gpu.setUniforms`. `uniformsAt`
  is the single funnel feeding both live frames and the thumbnail strip.

**Verdict:** **Option (b), studio-side coalescing** — no pngine code changes.
pacer emits element targets (`env[3]=0.5`, `env[7]=1.0`); `toUniforms` yields
`{ 'env[3]':0.5, 'env[7]':1.0 }`, whose keys match no reflection field, so
`setUniform` silently drops them today. Phase 2 will coalesce those element
writes at `uniformsAt` into one whole `env` array value (holes holding the
previous frame's value) and hand it to the existing `setUniform('env', […])`.
Option (a) (`name[i]` in the worker) is a genuine pngine change: `setUniform`
would need `[i]` parsing **and** a stride the reflection doesn't carry — deferred
unless (b) proves insufficient.

**Array stride facts (WGSL uniform address space):** array elements stride to a
16-byte boundary. `array<f32,16>` → stride 16 B, size 256 B = 64 f32 slots,
element `i` at float index `i·4` (3 pad floats each). `array<vec4f,N>` → stride
16 B, packs tight (element `i` at floats `i·4 .. i·4+3`, ncomp 4). The studio
**derives** stride from this rule (always 16 B) rather than from the reflection —
element count = `size / 16`, and it never asks pngine to grow its schema.

### Phase 1 — registry expansion + `dropped` warning → DONE (2026-07-15, pngine `ea22401`)

**RED→GREEN.** Rewrote `registries.test.js` (7 baseline tests → 10 spec tests)
to assert the expanded `{ targets, dropped }` shape with **realistic `type`
tags**, observed 10/10 fail against the size-only `buildRegistries` (returns a
bare `Registry[]`, drops all wide fields), then greened `registries.ts`. Full
gate: tsc 0, biome clean, svelte-check 0 err (5 pre-existing App warnings), full
editor suite **1606/1606** (−7 old baseline tests +10 new = +3 net). No pngine
worker/core touched.

**`buildRegistries` v2 — `{ targets: Registry[], dropped: DroppedField[] }`.**
Per reflected field:

- **Plain field (`size/4 ∈ 1..4`)** → one target, `ncomp = size/4`. This is the
  ORIGINAL size-only rule kept **verbatim, with no `type` dependency** — so real
  scalar / vec2 / vec3 / vec4 fields can never regress even if a reflection ever
  carried a wrong `type` tag. A plain `vec4f` (size 16) stays one target, NOT
  expanded.
- **Wider (`size/4 ∉ 1..4`)** → consult the WGSL `type` tag to split array from
  matrix. `LANES_BY_TYPE` maps the wire-stable pngine `UT_*` enum (gpu.js:
  F32/I32/U32→1, VEC2*→2, VEC3*→3, VEC4*→4; matrices UT_MAT3X3F=6 / UT_MAT4X4F=7
  and any unknown tag are ABSENT). An array of a 1..4-lane element expands into
  `name[0]`..`name[N-1]` with `count = size / 16` (the 16 B uniform stride);
  a matrix / unknown type, or a size that isn't a clean 16 B multiple, lands in
  `dropped` with an author-facing `reason`.

**The discriminator that forced this:** `array<f32,4>` and `mat4x4f` are BOTH
`size: 64` — only the `type` tag separates them (UT_F32 vs UT_MAT4X4F). The Phase
0 fake used `type: 0` throughout (fine for the size-only baseline); the Phase 1
test uses correct tags. `motion` (vec4f, size 16) and `array<f32,1>` (size 16)
share the degenerate size-16 slot — the size-only rule resolves both to one
4-lane `name` target; single-element arrays are pathological and drive
identically, so this is accepted and commented, not special-cased.

**`dropped` surfacing:** preview.ts's `'uniforms'` handler now destructures
`{ targets, dropped }`, uses `targets` for `lastRegistries` (+ the registries
key), and `console.warn`s `dropped` once per reflection (gated on non-empty). It
rides the **console, not `onScoreDiagnostics`** — a dropped uniform is a
shader-layout fact with no score-text span, so it can't carry the char offsets
`ScoreDiagnostic` requires. Matches the existing `[pacer]`-prefixed warns.

**Deferred to Phase 2:** the WRITE side. Expanded targets now EXIST in the
registry, so a score can target `env[3]`; but `toUniforms` still emits them
name-keyed (`{ 'env[3]': 0.5 }`) and `setUniform` drops unmatched keys. Phase 2
coalesces at `uniformsAt` (option b) into one whole `env` array per frame.

### Phase 2 — write delivery (studio-side coalescing) → DONE (2026-07-15, pngine `930d3f4`)

**RED→GREEN.** New pure module `studio/editor/src/lib/preview/coalesce.ts`
(`makeUniformCoalescer`) + `coalesce.test.js` (6 tests). RED first: the tests
import a non-existent module (whole file errors) and assert the sample-and-hold
semantics; extended `registries.test.js` (+2) asserts a new `arrays` plan that
`buildRegistries` didn't yet return. Greened both. Editor gate: tsc 0, biome
clean, svelte-check 0 err (5 pre-existing App warnings), full suite
**1614/1614** (Phase 1 1606 + 8 new). No pngine worker/core touched — delivery
**option (b)** confirmed sufficient, exactly as Phase 0 predicted.

**`makeUniformCoalescer(arrays)` — the fold.** pacer emits per-element writes
(`toUniforms` → `{ 'env[3]':0.5, 'env[7]':1.0 }`); `setUniform` resolves only
WHOLE named fields, so element keys were dropped. The coalescer folds them into
one whole flat-float array per base at the **byte-exact layout
`uniformToTypedArray` writes**: every WGSL uniform-address-space array element
strides to 16 B = 4 floats, so element `i` lane `j` lands at flat index
`i·4 + j` and the whole value is `count·4` floats (`array<f32,16>` → 64 floats,
3 pad each; `array<vec4f,4>` → 16 floats, tight). Verified against gpu.js
`uniformToTypedArray` (`new Float32Array(arr)` truncated to the field's byte
size). Plain scalar/vector keys pass through untouched.

**Holes hold last value — the pinned semantic, made concrete.** An array
element with no write this frame keeps its previous value (accumulator init 0);
a base is emitted only on frames that write ≥1 of its elements, so an untouched
array is omitted and the GPU buffer retains it — the exact analog of how an
un-rewritten plain uniform is simply absent from the draw and keeps its buffer
content. This makes the coalescer **stateful**, which collides with the
`uniformsAt` purity invariant (a thumbnail must render the same motion the
playhead shows). Resolved by **scoping the state per call-site, not inside
`uniformsAt`**: `uniformsAt` stays pure (raw element-keyed writes); the **live
playhead** owns a persistent coalescer (true sample-and-hold, mirrors the GPU
buffer during playback), while the **thumbnail strip** builds a throwaway
coalescer per prefetch batch over ascending indices — a self-consistent,
reproducible sequence that can't contaminate the playhead's held holes. For a
fully-keyframed array (every element written every frame — the Phase 3 case)
there are no holes, so both paths are identical and the purity concern is moot;
the divergence only exists for sparse/trigger lanes, where live sample-and-hold
is the desired synth-like behavior (scrubbing backward does not replay history
— an accepted preview limitation).

**Consistency by construction.** `buildRegistries` now returns
`{ targets, dropped, arrays }`, the `arrays` plan (`{ base, count, lanes }`,
`count = size/16`) built in the SAME walk as the `base[i]` targets — so the
coalescing plan can never disagree with the expanded target set (a target with
no plan entry would silently re-drop). Zero-overhead default: no reflected array
⇒ `liveCoalescer = null` ⇒ renderFrame passes raw straight through (the common
demoscene case is untouched).

**Deferred to Phase 3:** the end-to-end proof. The write path now delivers, but
nothing exercises it against real wasm + a real shader. Phase 3 extends the
demoscene template with `env: array<f32, 8>` driven by 8 tracks, adds a
real-wasm integration test (an element write reaches the drawn uniforms), and a
manual studio smoke.

### Phase 3 — verification → **BLOCKED** (2026-07-15); user chose PAUSE & re-plan, no code

**The end-to-end verification Phase 3 mandates ("verify in the running studio")
surfaced that the host-side premise Phases 0–2 rest on is contradicted by real
pngine reflection. No demoscene example or integration test was written — the
feature does not connect to reality as built.**

Before authoring anything I compiled real probe shaders through pngine's actual
pipeline (`zig build run -- compile`) and dumped the PNGB uniform table the
studio worker truly hands `buildRegistries` (`gpu.js parseUniformTable`,
forwarded verbatim by `worker-core.js handleGetUniforms` as
`{ type, size, bufferId, offset }` per field). Ground truth:

| Probe (uniform) | What the studio sees |
|---|---|
| struct member `bands: array<vec4f, 2>` | field `bands` → **`type = 255` (unknown)**, `size = 32` |
| bare binding `env: array<vec4f, 2>` | **absent** — no field at all |
| `env: array<f32, 8>` | **compile error** — *"array with element stride 4 (uniform requires a multiple of 16)"* |

**Why.** pngine's `UniformType.fromWgslType` (`src/bytecode/uniform_table.zig`)
has **no `array<…>` case**, and the field flattener (`Emitter.zig flattenFields`)
recurses only into nested *structs* — so an array member is a leaf stamped
`unknown (255)`, **discarding the element type + count** that wgslender's own
reflection JSON does carry (`"type": "array<vec4f, 2>"`). The PNGB uniform table
therefore conveys, for any array, only `{ type: 255, size: <total bytes> }`.

**Consequence.** `buildRegistries` (Phase 1) expands arrays by consulting a real
vec/f32 `type` tag (`LANES_BY_TYPE`), but real pngine tags *every* array `255` →
`LANES_BY_TYPE[255]` is undefined → the field is **dropped** as "unsupported".
Phases 0–2 are unit-green only because their fixtures fed `type: 5 (UT_VEC4F)` /
`type: 0 (UT_F32)` for arrays — values pngine never emits. From `{255, size}`
alone the studio cannot even recover which array it is (`array<vec4f,2>` vs
`array<vec2f,4>` both hide behind `255`), so host-side expansion is
under-determined. And the plan's headline `env: array<f32,16>` → 16 scalar lanes
is not merely un-reflected — it **cannot compile** as a uniform (WGSL's 16-B
stride rule); the only efficient uniform array is `array<vec4f, N>`, lanes in 4s.

This also re-frames Phase 0's finding: **option (b) coalescing was never the
blocker.** The blocker is upstream — the reflection carries no array info to
expand from. Phase 2's coalescer + Phase 1's expansion are correct *given* an
array plan; they just never receive one from real pngine.

**Options for the re-plan (user picks before any more 05 code):**

- **(A) Host-side vec4 convention — no pngine change.** Redefine the array rule
  to `type === 255 (unknown) && size > 0 && size % 16 === 0 ⇒ array<vec4f,
  size/16>`, expanding into `base[i]` targets ncomp 4. Sound because a uniform
  struct member that reflects `unknown` is in practice an array (matrices are
  `6`/`7`, scalars/vecs are mapped), and vec4 is the only tight uniform element.
  Cost: **vec4-grouped lanes only** (no scalar-lane arrays — the `array<f32,16>`
  headline is retired), and P1–P2 fixtures rewrite from `type:5` to `type:255`.
  Authoring drives whole vec4 elements; whether a single pacer track can emit 4
  lanes (vs. needing per-lane targets) is an open ergonomics question this option
  must answer.
- **(B) Extend pngine's reflector — wire change.** Teach `UniformType` /
  `fromWgslType` to parse `array<ELEM, N>` and carry element-type + count through
  the PNGB uniform-table field encoding (append-only). Precise expansion, any
  element width. Cost: modifies a **wire-stable pngine surface** — contradicts
  this plan's "Wire impact: none" — and spans pngine Zig + `gpu.js` + the studio.
- **(C) Drop uniform arrays as the mechanism.** Reconsider whether "many
  envelopes without WGSL churn" is best served by uniform arrays at all — e.g.
  widen a struct with more scalar fields, or drive a `var<storage>` array (which
  *does* allow tight `array<f32,N>`, at the cost of a different, non-`setUniform`
  write seam).

**Status:** Phases 0–2 pngine commits (`1095d61`, `ea22401`, `930d3f4`) stand;
this pause wrote **no code** (docs only). Probe shaders lived in `/tmp` — neither
repo tree was touched. `00-strategy.md`: board `05 · P3 BLOCKED`, benchmark #2
blocked on it, What's next + a Decision-log entry point at the decision.

### Phase 3 — UNBLOCKED (2026-07-16): the user implemented Option (B) in pngine; validated end-to-end

**The user picked Option (B) by shipping it** — pngine commits `2b659bf`
(reflect: element type + count from wgslender's structured TypeInfo, so aliases
and const-expression counts arrive resolved) → `21215a2` (bytecode: the field
record's always-zero pad byte 9 now carries `elem_count`; for an array leaf the
`type` byte holds the ELEMENT's UT_* tag — append-only, old payloads carry 0
there, `elemCount 0` = not-an-array) → `9c5456f` (bare uniform bindings —
`var<uniform> env: array<vec4f,2>`, previously reflected as NOTHING — now become
one leaf named after the var; runtime-sized storage arrays stay unreflected) →
`9519e03` (npm: `parseUniformTable` returns `elemCount`, `handleGetUniforms`
forwards it) + journal §253.

**Validation (grounded in real bytes — same probe method that found the block):**

| Probe (uniform) | Was (2026-07-15) | Now (2026-07-16) |
|---|---|---|
| struct member `bands: array<vec4f,2>` | `{type: 255, size: 32}` | **`{type: 5 (VEC4F), size: 32, elemCount: 2}`** |
| bare binding `env: array<vec4f,2>` | **absent** | **`{type: 5, size: 32, elemCount: 2}`**, named `env` |
| `env: array<f32,8>` | compile error (stride 4) | **still rejected** — correct; a WGSL limit, not a pngine gap |

Then fed the REAL `parseUniformTable` output through the REAL `buildRegistries`
(node strips the `.ts` natively): both probes expand into `bands[0]`/`bands[1]`
resp. `env[0]`/`env[1]` (ncomp 4) + a matching `arrays` plan
(`{base, count: 2, lanes: 4}`), `dropped: []`. **The Phase 1–2 studio code
works against real reflection with ZERO changes** — its fixtures fed
`type: 5` for arrays, which is exactly what Option (B) now emits. Gates:
pngine `test-reflect` / `test-bytecode` / `test-sjon` /
`test-descriptor-encoder` green; editor suite **1614/1614**, tsc 0, biome
clean, svelte-check 0 err (5 pre-existing App warnings).

**Two spec corrections for the resumed Phase 3 (supersede the plan text above):**

1. **The example is `array<vec4f, N>`, not `array<f32, 8>`** — scalar-lane
   arrays are illegal in the uniform address space (revalidated); §253 records
   them as storage-only. Lanes come in 4s: `env: array<vec4f, 2>` = 2 targets
   × 4 lanes = 8 scalar values.
2. **Consume `elemCount`.** The studio currently ignores it (`buildRegistries`
   derives `count = size/16` — equal to `elemCount` for every legal uniform
   array element, since vec2/3/4 all stride to 16 B, so this is correct today,
   not a bug). Phase 3 should add `elemCount` to `UniformReflection` and prefer
   it as the authoritative count — it also future-proofs >16-B elements, which
   today drop via `LANES_BY_TYPE`.

**"Wire impact: none" in this plan's header is superseded:** Option (B) was a
deliberate append-only pngine wire change (pad byte → `elem_count`; element
type in the `type` byte), decided and shipped by the user. Phase 3 resumes
from here: demoscene `array<vec4f, N>` example + real-wasm integration test +
manual studio smoke.

### Phase 3 — studio re-base DONE (2026-07-16, pngine `419226b`); element targets renamed DOTTED

**Both spec corrections above are implemented, and the resumed verification
immediately surfaced a second unauthorability gap the 2026-07-16 validation
could not see: the `[i]` target spelling doesn't lex in a score.** The
validation fed registry names straight into `buildRegistries`, but never
*authored* one — probing the real pacer wasm shows `(track :target bands[1] …)`
is impossible: `:target` is `target-name :underlying symbol`, and `[` opens a
vector in SJON, so `bands[1]` lexes as symbol `bands` + vector `[1]` (schema
error: "positional argument expects key-section, got vector"); the string form
`"bands[1]"` is rejected by the value kind. Phases 1–2's `base[i]` naming made
every expanded target unreachable from a score — the same class of gap as the
reflection block, one seam later.

**Fix — dotted element names, zero pacer changes.** Element targets are now
`bands.1` (studio-side rename in `registries.ts`/`coalesce.ts`): `.` is in
SJON's symbol-body charset (verified in the lexer + live against the real
wasm: `(track :target bands.1 …)` loads, resolves, and `toUniforms` yields
`{"bands.1": …}`), and it is exactly how pngine's own flattener names nested
struct leaves (`params.glow`) — so the spelling is native to the reflection.
Unambiguous by construction: a WGSL identifier is never all-digits, so a
trailing `.N` can only be an element index (coalescer key regex
`^(.+)\.(\d+)$`, greedy head keeps a nested base intact: `fx.bands.1` →
base `fx.bands`). `target-name` stays an unconstrained symbol — the plan's
"pacer core is untouched" principle holds.

**`buildRegistries` v3 — `elemCount` is the discriminator, stride is real:**

- `elemCount > 0` ⇒ array: count = `elemCount` (authoritative, replacing
  `size/16`), `type` = the ELEMENT's tag → lanes, and **stride is DERIVED
  per-field** (`size/elemCount`, carried in the `arrays` plan as
  `strideFloats`). Phase 2's "always 16 B = 4 floats" byte-lock is superseded:
  a tight STORAGE `array<f32,8>` (stride 4 B) reflects through the same table
  and now expands into 8 scalar targets — **the retired `array<f32,N>`
  headline returns via `var<storage>`, through the unchanged
  `setUniform` seam** (`uniformToTypedArray` truncates a flat array to the
  field's byte size regardless of address space). `array<vec3f,N>` (16 B
  stride, 3 lanes) holds its pad float at 0.
- Arrays of matrices/structs (element tag 6/7/255) drop with an
  element-facing reason; a size that doesn't divide by `elemCount` refuses
  (mis-address guard); a **pre-§253 reflection (no `elemCount`) degrades wide
  fields to `dropped`** — visible warn, never a crash. A 1-element array now
  expands (`solo.0`) instead of collapsing into a plain target.
- Fixtures rewritten byte-for-byte to the real `getUniforms` shape (mirroring
  pngine's own `tests/npm/uniform-reflection.test.js` pins) — the fake-tag era
  is closed.

**The durable red landed too** (`array-targets.test.js`): REAL pacer.wasm + an
authored score (keyframed `bands.1` vec4 element, expr-driven `lanes.3`
scalar) chained through `buildRegistries → Pacer.load → eval → toUniforms →
makeUniformCoalescer` into the exact whole-field write shape `setUniform`
accepts (`bands` → `[0,0,0,0, 1,2,3,4]`), holes sample-held across frames.
Everything but the worker/GPU hop is the production path — this is the test
that would have caught both the reflection block and the naming block.

Gates: tsc 0, biome clean, svelte-check 0 err (5 pre-existing App warnings),
editor suite **1626/1626** (+12). pngine journal §254.

**Remaining to close Phase 3 / plan 05:** the demoscene `array<vec4f, N>`
template example (score + WGSL, an authoring decision) + manual studio smoke
against the running editor. All docs/examples must use the DOTTED spelling.

### Phase 3 — demoscene example + template test → DONE (2026-07-16, pngine `72d49f8`); manual smoke is the last gate item

**RED→GREEN.** The durable red rode the real-wasm template suite
(`score-uniforms.test.js`): its hand-listed registries were replaced with a
derivation through the REAL `buildRegistries` from a §253-shaped reflection of
the extended doc ("model the wire, not the wish"), plus a new test asserting
`env.0` grade keys, `env.1` trigger lanes, and the coalesced whole-field write
— observed failing against the unextended score (5 pass / 1 fail), then
greened by authoring the score, then the doc.

**The example (flagship template, minimal-churn by design):** a **bare**
`var<uniform> env: array<vec4f, 2>` binding added to the POST stage only —
the `Motion` struct declared in all four modules is untouched, which is the
plan's "new lanes with zero WGSL struct churn" pitch made visible, and it
exercises the §253 bare-binding reflection path in the shipped template.
Score side (all DOTTED targets):

- `env.0` — keyframed vec4 color grade `[r g b amt]`: cool `[0.85 0.95 1.25
  0.4]` over the noise, easing to warm `[1.2 1.0 0.75 0.55]` across beats
  10→14 (the chroma window). WGSL: `col = mix(col, col * env[0].rgb,
  clamp(env[0].w, 0, 1))`.
- `env.1` — `(trigger :target env.1 :every 1b)`: the four trigger lanes land
  in one vec4 element, and the shader shapes a per-beat pulse from the phase
  lane (`pow(max(1 - env[1].x, 0), 4)`), brightening with the cube reveal —
  **triggers (02) driving array lanes (05) in the default template.**
  Scoreless, everything is 0: grade amount 0 (pass-through) and a constant
  imperceptible +4% lift — the bare template still renders the noise scene.

**Pins in the new test:** structural landing makes the vec4 keyframe land
BIT-EXACTLY (`deepEqual` vs `[1.2, 1.0, 0.75, 0.55].map(Math.fround)` at the
beat-14 tick); trigger lanes `[0, 14, 1, 0]` on the beat and `[0.5, 14, 0,
0.5]` mid-beat (dyadic-exact); the coalescer folds both elements into the one
8-float `env` write `setUniform` accepts. Verified against the REAL compiled
doc: `pngine compile` → `parseUniformTable` → `env {type: 5, size: 32,
elemCount: 2}` → `buildRegistries` → `env.0/4 env.1/4`, plan `{count: 2,
lanes: 4, strideFloats: 4}`, `dropped: []` — the test's modeled reflection
matches the wire byte-for-byte on every consumed field.

**Ripple (legitimate fixture reality change):** the four suites that load the
real demoscene score (`anchors`, `span-edit`, `curve-sample`,
`score-timeline`) learned the two element targets in their registry models,
and anchors' track-list pin grew 3 → 5 rows (`env.0` keys ncomp 4; `env.1`
source `'trigger'`, `(trigger …)` formSpan) — first template exercise of the
02 `'trigger'` meta source in the timeline path.

Gates: editor **1627/1627** (+13 net: +1 template test, +12 from the suite
churn), tsc 0, biome clean on the touched scope (whole-`src/lib` biome was
already failing at HEAD — pre-existing, untouched), svelte-check 0 err (5
pre-existing App warnings).

**Remaining — the single last gate item: the manual studio smoke.** Load the
Demoscene template in the running studio and eyeball: per-beat flash pulses
once the cube reveals (trigger cadence), the palette warms across the reveal
(grade crossfade), and the Motion tab timeline shows the two new lanes
(`env.0` keys, `env.1` trigger row). On a green smoke: tick 05 on the board
→ benchmark #2 closes Wave 2.
