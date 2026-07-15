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
