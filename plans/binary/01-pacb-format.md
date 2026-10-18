# binary 01 — `'PACB'`: the compiled-score format, the `'PACT'` codec leaf, and `pacer pack`

**Repos:** pacer
**Wire impact:** new — mints `'PACB'` (a data-at-rest format, not a
wasm-boundary blob; `CLAUDE.md`'s wire table gains a row noting the category
when this plan lands its docs phase). No existing surface moves: `'PACM'` is
embedded *verbatim* by an untouched `Abi.encodeMeta`; `'PACT'` bytes are
byte-identical through the codec extraction. `Compile.Code` gains variants
(append-only) for pack refusals — audited via `zig build audit-diagnostics`.
**Gates:** `zig build verify` every phase; `zig build fuzz` from Phase 4;
determinism gate — pack the same score twice ⇒ byte-identical output.
**Created 2026-10-18; Phase 1 complete 2026-10-18; Phase 2 in progress
(T2.1–T2.4 landed 2026-10-18, T2.5–T2.8 open); phases 3–4 not started.**

## Why

There is no playback binary-loader ABI at all: `drv_load` compiles score
text (`src/wasm_entry.zig:192-228`) and that is the only load path.
Everything the runtime needs exists as in-memory structures (`TrackTable`,
`src/TrackTable.zig`) tied to a compile arena and, for expr/pattern tracks,
to the AST (`src/Eval.zig:132-133`). This plan defines the portable,
versioned, validated container that carries a compiled score — and the
offline producer that writes it. It builds no runtime: the decoder is proven
natively, and the round-trip is `Compile.compile` → encode → decode → table
equivalence + payload-eval equivalence + byte determinism.

## Design

### The `'PACT'` codec leaf first (Phase 1 — a zero-diff refactor with its own gate)

The runtime must decode the host `'PACT'` blob, but the codec lives in
`Abi.zig`, which imports `Compile.zig` (`src/Abi.zig:110`) and types against
`Compile.Target`. Extract `src/PactCodec.zig`, a leaf owning:

- the `'PACT'` wire spec verbatim (`[magic u32][count u32]` then
  `count × { ncomp u8, registry u8, name_len u16, name bytes }`,
  `src/Abi.zig:7-14`), `encodeTargets`/`decodeTargets` moved byte-identical;
- `Target` (name/ncomp/registry) and **`MAX_TARGETS = 1024` as THE
  definition** — the single-definition rule inverts direction:
  `Compile.MAX_TARGETS` aliases `PactCodec.MAX_TARGETS` (Compile imports the
  leaf, never the reverse), keeping `src/Compile.zig:61-66`'s one-definition
  discipline while cutting the compile chain out.

`Abi.encodeTargets`/`decodeTargets`/`MAX_TARGETS` remain spelled (they are
public surface) as delegating re-exports; `wasm_entry`, the CLI, and the
corpus runner change nothing behaviorally. Gate: `zig build verify` with a
zero-byte corpus diff and an empty `zig build cli-golden` diff. The leaf
imports std only — it must never import `Compile`/`Abi`/`Schema` (02's
closure allowlist will list it; the column-0 import convention from
`SJON/tools/audit_wasm_imports.zig:13-26` applies from line one).

### Container layout (little-endian, packed, explicit pads; `docs/binary-score.md` — created by this plan — is the doc of record)

```
[magic u32 'PACB'][version u32 = 1][required_features u32][section_count u32]
section_count × { id u32, off u32, len u32 }        ; off from buffer start
```

`required_features`: bit0 = pattern tracks present. All other bits zero; a
decoder refusing unknown set bits is the honest unsupported-feature path.
Sections are emitted in the fixed canonical order below and OMITTED when
empty (the `'PACM'` omit-when-empty byte-stability rule, `src/Abi.zig:56-59`);
the [canonical presence and defaults](#canonical-presence-and-defaults-final-review-low-3--frozen-with-v1)
freeze below completes this rule; present sections must appear in
canonical order:

| 4-CC | Payload |
|---|---|
| `'TRAN'` | 56 B: `bpm f64`, `beats_per_bar i64`, `dur i64` (0 when absent), `flags u8` (bit0 dur present, bit1 end is loop) + pad×7, `host_targets u32`, `declared_targets u32`, `pact_fnv u64`, `pacm_fnv u64` |
| `'REGS'` | `[byte_len u32]` + the **canonical `'PACT'` bytes of the pack-time host join** (see Registry identity) |
| `'DECL'` | `[count u32]` + count × 4 B `{ registry u8, ncomp u8, pad u16 }` — declared-only targets in pack-join order (indices continue the host join; names stay in source per the declared-names-never-cross-the-wire rule) |
| `'EMIT'` | `[count u32]` + count × 8 B `{ name u8 (EmitName ordinal), registry u8, target_id u16, reserved u32 }` |
| `'TMPO'` | `[count u32]` + count × 16 B `{ tick i64, bpm f64 }` — the `'PACM'` `'TMPO'` record verbatim (`src/Abi.zig:88-97`), segment 0 included |
| `'TRAK'` | `[count u32]` + count × 40 B `{ target_id u16, registry u8, ncomp u8, source u8, trig_kind u8, scene u16, key_start u32, key_len u32, payload_off u32, payload_len u32, trig_every i64, trig_offset i64 }` |
| `'KEYS'` | `[count u32]` + count × 28 B `{ at i64, value f32×4, ease_ref u16, pad u16 }` |
| `'TICK'` | `[count u32]` + count × `i64` — the concatenation of every explicit trigger schedule; each scoping track slices it by `key_start/key_len` |
| `'EASE'` | the `'PACM'` `'EASE'` payload verbatim (`src/Abi.zig:71-86`): `[program_count u32]` + 772 B programs + `[key_ref_count u32]` + `u16` refs in key order |
| `'CTRL'` | `[count u32]` + count × 60 B `{ target_id u16 (0xffff env-only), registry u8, ncomp u8, type u8, flags u8 (bit0 min, bit1 max), id_off u32, id_len u16, value f32×4, min f32×4, max f32×4 }` |
| `'SCEN'` | `[count u32]` + count × 16 B `{ start_tick i64, dur_ticks i64 }` |
| `'STRS'` | `[count u32][byte_size u32]` + entries `[len u16][bytes]` — control ids, sorted by (len, bytes), unique, none in `ExprTrack.reserved_names` (`src/ExprTrack.zig:94`) |
| `'PAYL'` | `[byte_size u32]` + concatenated SJON binary-IR buffers (`"SJ1\n"`, `wire_version 0x05`), each single-root; tracks address `(payload_off, payload_len)` into it |
| `'PACM'` | the metadata blob encoded offline by the unmodified `Abi.encodeMeta` |

`source` ordinals are **frozen copied constants** in `docs/binary-score.md`
(0 keys / 1 expr / 2 trigger / 3 pattern — copied from `'PACM'`'s
`MetaTrackRec` values, `src/Abi.zig:36-39`, not a live reference), as are the
`EmitName` ordinals (beat=0, bar=1, phase=2, bpm=3, t=4 — the enum order at
`src/TrackTable.zig:68`) and `trig_kind` (0 periodic, 1 explicit). Per-source
reads: keys → `key_start/key_len` into `'KEYS'`; expr/pattern →
`payload_off/len` into `'PAYL'`; periodic trigger → `trig_every > 0` +
`trig_offset`; explicit trigger → `key_start/key_len` into `'TICK'`.

### Canonical presence and defaults (final-review LOW-3 — frozen with v1)

One rule everywhere: **the packer always omits the degenerate form of a
section, and the decoder refuses it when present**, so one score has
exactly one byte encoding:

- `'TRAN'` and `'PACM'` are REQUIRED — `'TRAN'` carries the transport
  truth, and `'PACM'` always encodes its ≥ 40 B header, so neither has
  an empty case.
- `'REGS'` omitted ⇒ the host join is empty: `host_targets` must be 0
  and `pact_fnv` must be FNV-1a-64 of the canonical zero-count `'PACT'`
  encoding (the fast-reject stays well-defined); present ⇒ `count ≥ 1`.
- `'EASE'` omitted ⇒ the program table is the shared linear default
  alone (`src/TrackTable.zig:16-18`) and every `'KEYS'` `ease_ref` must
  be 0 — matching PACM's linear-only omission (`src/Abi.zig:71-86`);
  present ⇒ `program_count ≥ 2` with `program 0` linear (a linear-only
  table is the omitted case).
- `'TMPO'` omitted ⇒ constant tempo: the decoder synthesizes the
  single-segment degenerate map `[{0, 'TRAN'.bpm}]` (the `[0] == {0,
  bpm}` pin, `src/TimeMap.zig:99-115`) — behavior identical to a
  one-segment section, which is exactly why the encoding must be
  canonical; present ⇒ `count ≥ 2` (segment 0 alone is the omitted
  case — PACM's constant-tempo omission, `src/Abi.zig:88-97`).
- Every other section: present ⇒ `count ≥ 1` (`'PAYL'`/`'STRS'`:
  `byte_size ≥ 1`), and cross-section presence is CHECKED, not
  implied: `'KEYS'` present iff a keys track exists, `'PAYL'` iff an
  expr/pattern track does, `'TICK'` iff an explicit-trigger track
  does, `'STRS'` iff a control does.
- The directory is exact, not merely well-formed: it starts immediately
  after the 16-B file header (`off[0] == 16 + 12 × section_count`),
  sections are CONTIGUOUS (`off[i+1] == off[i] + len[i]`), and the
  buffer ends exactly at the last section's end — no gaps, no
  inter-section slack, no trailing bytes. Pads and reserved fields
  zero; ids unique; canonical order as tabled.

Decode re-derives every projection through the SAME functions compile uses:
`TimeMap.init` + `withSegments` in the documented op order
(`src/TimeMap.zig:8-38, 84-115`), `loop_secs = map.secondsFromTick(dur)`
(`src/TrackTable.zig:105-110`). Nothing derived is stored.

### Registry binding — exact, names included (review I6 + parent ruling)

The runtime must not mistake a same-shaped registry swap for the right one.
Identity is **byte equality of the canonical `'PACT'` encoding** — which is
the ordered sequence of `(name, registry, ncomp)` triples; names are IN the
blob (`src/Abi.zig:7-14`), so ordered name swaps, reorders, arity changes,
and count changes all refuse. At load, the runtime decodes the host blob via
`PactCodec.decodeTargets`, RE-ENCODES it canonically, and byte-compares
against `'REGS'`. `pact_fnv` (FNV-1a-64 over the canonical bytes) stays in
`'TRAN'` as a fast-reject + diagnostic checksum only — the byte compare is
the identity. `declared_targets` + `'DECL'` records are validated separately:
every `target_id` in `'TRAK'`/`'CTRL'`/`'EMIT'` must be < `host_targets +
declared_targets`; for host ids the record's `(registry, ncomp)` must equal
the host join entry; for declared ids it must equal the `'DECL'` record.

### Validation (decode refuses, never guesses, never traps)

Directory: magic/version; unknown `required_features` bits; every
`off/len` in bounds; sections contiguous, gap-free, byte-exact to the
buffer end, and monotonic in canonical order (the layout rules above);
each section's counts × record width consume its length exactly
(including `'TICK'`); duplicate section ids refuse.

Transport and domains — all BEFORE any `TimeMap` call (its contract is
asserts, `src/TimeMap.zig:84-97`): `bpm` finite and 1..1000; `beats_per_bar`
1..16; `dur > 0` when the present-flag is set; `|tick| ≤ MAX_TICK` wherever
a tick rides; `'TMPO'` ascending, `[0].tick == 0`, `[0].bpm == 'TRAN'.bpm`,
every segment bpm finite and 1..1000, count ≤ `MAX_TEMPO_SEGMENTS`.

Records: counts ≤ the caps table (00-strategy Global constraints);
`ncomp ∈ 1..4`; `scene == 0xffff (NO_SCENE, src/TrackTable.zig:53)` or <
`MAX_SCENES`; `trig_kind`/`source`/`name` ordinals in range; per-source
unused fields MUST be zero (`trig_every`/`trig_offset` zero for
keys/expr/pattern; `payload_off/len` zero for keys and periodic triggers;
`key_start/len` zero for expr/pattern); `reserved`/pad fields zero.

Keys and easing (the `'EASE'` safety the review demanded — `Program.eval`
asserts its invariants, `src/Easing.zig:162-170`, so decode checks them
first): keys per keys-track ≥ 1, `at` strictly ascending (the table
invariant, `src/TrackTable.zig:13-15`), value lanes ≥ ncomp zero;
`ease_ref < program_count`; program 0 is linear (the shared default,
`src/TrackTable.zig:16-18` — when `'EASE'` is absent the synthesized
table is exactly that default and every `ease_ref` is 0; presence
counts are the canonical rules above); per program `len ∈ 1..8`,
`ops_len ∈ 0..4`, `t_end` strictly increasing, all floats finite, op codes
within the frozen `Easing.Op` set (unused slots are normalized to the
zeroed convention on copy — the format's own rule, `src/Easing.zig:143-146`);
`key_ref_count == 'KEYS' count`.

Triggers/scenes: `trig_every > 0` for periodic (the compile rule,
`plans/00-strategy.md:543-546`); explicit schedules non-empty, strictly
ascending, in tick range; scene `start_tick + dur_ticks` checked-add (compile
raises `tick_overflow` — decode refuses the same class).

Controls: ids unique, non-empty, not reserved, in range of `'STRS'`;
`type`/min/max flags coherent (a min/max flag set ⇒ the corresponding lanes
are finite); env-only controls use `target_id == 0xffff`
(`TrackTable.NO_TARGET`).

Payloads (the structural-consumption rule): each payload passes
`BinaryCursor.Cursor.init` (header/pool/roots-offset equality — it already
rejects slack between pools and roots, `SJON/src/BinaryCursor.zig:188-193`),
exactly one root (the `MultipleRoots` rule, `SJON/src/Expr.zig:1891-1893`),
and a **full structural walk over every node** — depth-first through the
cursor's child/vector iterators, the same primitives
`PatternQuery.compileBinary` uses (`SJON/src/PatternQuery.zig:958-980`) —
which (a) decodes every node kind and exact payload width, covering branches
an evaluation would not visit, and (b) must end at exactly `payload_len`
(trailing slack inside a payload refuses). This is a syntax-level walk over
SJON's own cursor, not a second interpreter. Per-payload and total caps
(`MAX_PAYLOAD_BYTES`, `MAX_PAYL_BYTES`) are set here as
**proposals-with-rationale** — measured format policy, not source
constants and NOT mathematical claims: a subtree's compact IR CAN
exceed the text it was packed from (per-node record overheads mean
payload size scales with node count, not source bytes), so the cap is
enforced, never assumed — 256 KiB per payload / 4 MiB total, coarse
bounds that keep one pathological expression from dominating the
input zone while sitting far above every corpus case, with `pack_cap_exceeded`
carrying the measured size in its diagnostic; frozen with v1 and
recorded in `docs/binary-score.md`. `pacbWorstCase()` (the `metaWorstCase`
pattern, `src/Abi.zig:158-174`) derives the input-zone bound once, as
arithmetic restating the spec.

### Embedded-PACM coherence — a bounded cross-check, not a checksum (final-review MEDIUM-2; trust model frozen with v1)

`'PACB'` is a **producer-authored, host-served asset**; the operative
truth at runtime is the PACB sections, and `'PACM'` is embedded verbatim
at pack and served verbatim to JS — but only after `src/Pacm.zig`, a
std-only runtime-side READER (the encoder stays compiler-side and never
enters the closure), has validated it at decode:

1. **Structural read of the whole section** — magic/version, every
   record width, the post-controls TLV stream walked to EXACT
   end-of-buffer, span pairs ordered (`end ≥ start`; spans stay opaque
   u32s — 00's O2), transport domains (`bpm` 1..1000, finite) — so JS
   never receives bytes the format would choke on.
2. **Semantic cross-check, field by field, of exactly what consumers
   use to AUTHORIZE ROUTING** — the never-drop audit reads
   `meta.tracks[i]` registry/target identity and the control registry
   (`animader/animader/demo/lib/score.mjs:167-197`) — against the
   decoded sections: transport header block == `'TRAN'`; `track_count`
   == `'TRAK'` count and per-track
   `(target_id, registry, ncomp, source, key_start, key_len)` ==
   `'TRAK'[i]`; `key_count` == `'KEYS'` count; `control_count` ==
   `'CTRL'` count with per-control identity/value lanes == `'CTRL'[i]`
   and the id matched in `'STRS'`; `'SCEN'` == `'SCEN'`;
   `'EASE'`/`'TMPO'` payloads byte-equal to their PACB sections when
   present (both are verbatim by construction — absent both sides ⇒
   the linear/constant defaults above).

A PACM that lies about routing can therefore only REFUSE
(`meta_incoherent`, a status-1 refusal), never misroute — the
never-drop/route audits keep their meaning on binary assets. The
reader's constants are frozen copies with a test-side equality assert
against `Abi`'s (the `source`-ordinal pattern above), and its tests
share the oracle with the npm `'PACM'` decoder
(`npm/pacer/src/index.js:28-44`): the same golden blobs decode in both,
views compared. `pacm_fnv` stays in `'TRAN'` as a fast-reject +
diagnostic checksum only (decision 3's stance — FNV is not
authentication and proves no coherence); the earlier count-peek is
subsumed by the full read. What v1 claims is exactly this checked
surface — structural safety and routing-relevant coherence of the
served metadata, proven by the enumerated negative classes (Phase 2,
03's suites) — NOT producer authentication (anyone can author a PACB)
and NOT a blanket "forged input is semantically safe" claim; content
trust remains the producer's, and hosts serving third-party PACBs get
precisely the same checked boundary, nothing more.

All refusals are deterministic — same bytes, same refusal, native and wasm.

### Producer — split modules, public API, `pacer pack`

**Three files at birth** (the encoder could never enter the runtime
closure — it needs `Compile`/`Abi` — and a hidden import is the facade
pattern the closure gate exists to kill):

- `src/Pacb.zig` — constants, decoder + validator, `DecodedScore`
  (arena-backed `.deinit()`), `pacbWorstCase`; decode's LAST stage is
  the `Pacm` structural read + cross-check (below). Imports: std,
  `PactCodec`, `Pacm`, sjon `BinaryCursor`/`BinaryFormat` (via the
  runtime's SJON window, 02). Never `Compile`/`Schema`/`Driver`.
- `src/Pacm.zig` — the runtime-side `'PACM'` reader: full structural
  decode of the metadata section + the routing-relevant cross-check
  against the decoded sections. Imports std ONLY — never `Abi` (whose
  import of `Compile`, `src/Abi.zig:110`, would drag the compiler in);
  the wire constants are frozen copies with a test-side equality
  assert against `Abi`'s, and the tests share the golden-blob oracle
  with the npm `'PACM'` decoder.
- `src/PacbEncode.zig` — encoder + FNV. Imports `Compile`, `Abi`,
  `Pacb`, `PactCodec`. Never referenced by `rt_entry` (02).

`PacbEncode.encode(gpa, result: *const Compile.CompileResult, host_targets:
[]const Compile.Target) Error![]u8`, exported — with `Pacb` (decode) and
`PactCodec` — on the public `pacer` module (append-only `root.zig` exports;
the CLI-as-consumer precedent, `build.zig:131-158`, keeps the list
load-bearing). Encode requires `result.ok()`. Per expr/pattern track it
`cloneNode`s the source node into a one-root tree
(`SJON/src/Ast.zig:2010-2014`) and `toBinary`s it with
`ToBinaryOptions.forMode(.compact)` — no spans, no comments, the smallest
output (`SJON/src/Binary.zig:151-157`) — recording that choice as frozen.
Refusals, each an appended `Compile.Code`:

- `pack_user_expr_unsupported` — a call head the TEXT path resolves as a
  user-plugin function. The check is NOT the t=0 dry-run alone (an
  untaken branch can hide a user head behind `if`), and NOT a naive
  "every operator-position symbol" sweep — the expr grammar puts
  symbols in positions that are not calls, and refusing those would
  reject valid scores. The packer walks every payload structurally
  (same walk as decode) as a **position classifier** mirroring the
  dispatch shapes of `scheduleForm`/`scheduleFormBinary`
  (`SJON/src/Expr.zig:813-845`) — no evaluation, no env, no values, no
  second interpreter:
  - **eval positions (scanned):** the payload root; every element of a
    vector in eval position (vectors evaluate element-wise — the
    `vec_collect` walk); every branch of `if`/`cond`/`and`/`or`
    (nothing is evaluated, so nothing is pruned); `let` binding values
    and body; binder `xs`/`init`/`body`.
  - **name positions (never call heads):** `let`'s binding-vector name
    slots; the binder vectors of `map`/`filter`/`any`/`all`/`fold`
    (`[x]`, `[acc x]` — syntactic, never-evaluated subnodes); kvpair
    keys. A binding name that collides with a core head is still a
    binding — heads resolve through the schema, never the env
    (`scheduleForm` consults `special_forms` + `lookupExprFunc` only),
    so variable shadows cannot smuggle or mask a call.
  - **call positions:** a form in eval position whose head child is a
    (namespace-qualified) symbol — the head is collected.
  The special-form catalog is `isCoreSpecialForm`'s ten — `let if cond
  and or map filter any all fold` (`SJON/src/Expr.zig:3451-3470`) — and
  function resolution is `lookupExprFunc` (`SJON/src/Schema.zig:184`)
  through the comptime core schema (`sjon.Schema.Schema` over
  `sjon.plugins.core.plugin`; precedents `SJON/src/wasm_common.zig:30`,
  `SJON/src/wasm_binary.zig:33-34`, pacer's `src/ExprTrack.zig:298-300`)
  — resolution, not enumeration. Each collected head is resolved
  TWICE: through the compile result's `eval_schema` (what the TEXT path
  evaluates — core ⊕ the document's user plugins,
  `src/Compile.zig:329-334`, `src/Eval.zig:230`) and through the frozen
  binary-arm schema (core [+pattern at P4]). **Refusal is exactly the
  divergence:** resolves (found OR ambiguous) through `eval_schema` but
  not found through the binary schema ⇒ `pack_user_expr_unsupported`
  naming the head and span. Found in both ⇒ core — identical on both
  paths. Found in NEITHER ⇒ a form-as-data literal — legal
  (`scheduleForm`'s not-found pass-through builds a `Value.form`;
  "an unresolved head quietly evaluates to a form literal",
  `src/Compile.zig:264-268`) and IDENTICAL on both paths; refusing it
  would reject valid scores, so it packs clean. No hardcoded name list;
  `docs/binary-score.md` documents the resulting capability set for
  humans. Pattern payloads (P4): the pattern graph is walked
  structurally per `PatternQuery`'s combinator vocabulary — pattern
  heads (`stack`, `seq`, …) resolve through the pattern plugin and are
  never expr-call heads — and ONLY `(pure <form>)` leaves' forms are
  classified under the expr rules above.
- `pack_patterns_unsupported` — any `:pattern` track while the SJON
  prerequisite is unresolved. Interim, honest refusal; removed by 02 P4.
  The binary runtime's leaf schema stays core-only until then (the pattern
  plugin joins it at 02 P4, matching `pattern_schema`'s precedent —
  `SJON/src/wasm_binary.zig:34`).
- `pack_cap_exceeded` — a payload or section past the caps.

CLI: `pacer pack <score.sjon|-> [--target NAME[:ncomp[:registry]]]…
[--targets-json FILE] [--out FILE.pacb]` — same load path and target grammar
as `ir`/`eval` (`plans/14-cli.md:29-47`); exit codes and channels per the
house table (0/1/2/3, `plans/14-cli.md:96-109`) — JSON report to stdout,
`.pacb` bytes to `--out`, stdout stays blob-free. Pack self-check before
writing: decode its own output, verify table equivalence and that the
embedded PACM byte-equals a fresh `Abi.encodeMeta` of the same result
(refusal = internal error, exit 3).

**`--targets-json` is specified, not referenced into existence** (review
I10): the file is exactly the JSON serialization of a pngine `getUniforms`
answer — one JSON object mapping name → `{ "type": string, "elemCount":
number }`, insertion order preserved (order IS the target_id space). The
pack CLI's adapter replicates `buildJoin`'s rules verbatim — LANES
`f32/i32/u32`→1, `vec2*`→2, `vec3*`→3, `vec4*`→4; skip `elemCount`-nonzero;
skip unknown types; registry 0
(`animader/animader/examples/hello/player/join.js:13-46`) — implemented once
here with fixture tests locking the correspondence against join.js's
documented cases; the animader-side dump PRODUCER is deferred to the consumer
vertical (no sibling edits in this wave). The public pack API takes the
generic in-memory registry (`[]Compile.Target`); the JSON flag is a thin
adapter over it. Unknown-target handling stays the compile join's own
diagnostics — no manufactured workaround.

### Files

| File | Owns |
|---|---|
| `src/PactCodec.zig` | the `'PACT'` leaf codec + `Target` + `MAX_TARGETS` (THE definition) |
| `src/Pacb.zig` | format constants, decoder/validator (ends in the `Pacm` cross-check), `DecodedScore`, `pacbWorstCase` |
| `src/Pacm.zig` | the std-only runtime `'PACM'` reader + routing-relevant cross-check (frozen constants, shared JS oracle) |
| `src/PacbEncode.zig` | encoder + FNV + the core-scope head walk |
| `src/cli/Pack.zig` | the `pack` verb (args, targets-json adapter, report JSON), wired into `src/cli/Cli.zig` |
| `docs/binary-score.md` | the format spec — hand-written doc of record (the `docs/cli.md` precedent); frozen constants, caps, rules |
| `tools/testdata/pacb/` | committed golden `.pacb` for 2–3 tiny scores (byte-stability tests) |

`DecodedScore` **owns everything it returns** in its arena — payload copies,
the `'PACM'` section, control-id strings, the re-embedded registry identity —
and never retains a pointer into the input slice (the ownership contract 02
P2 tests at the wasm boundary; proven natively here by decode → clobber
input → eval).

## Phases

### Phase 1 — the `'PACT'` codec leaf (zero-diff refactor)

Files to load: `src/Abi.zig`, `src/Compile.zig:60-70, 130-140`, this plan.
- RED: none constructible — the gate IS the diff. Pin behavior first: the
  existing `Abi` codec tests keep passing unchanged; add, in the same
  commit, an encode→decode→canonical-re-encode byte-equality test (the
  property the registry identity leans on).
- GREEN: extract `PactCodec.zig`; invert `MAX_TARGETS`; re-export from
  `Abi`.
- Gate: `zig build verify` (corpus byte-identical) + `zig build cli-golden`
  (diff empty).

### Phase 2 — decoder + validator (RED first)

Files to load: `src/TrackTable.zig`, `src/Easing.zig`, `src/TimeMap.zig`,
`src/Abi.zig` (header), SJON `BinaryCursor.zig`, this plan.
- RED: a test-only byte builder (inside the test file, not a binary fixture)
  emits a minimal valid PACB plus one mutation per Validation class — every
  prefix of the minimal fixture (truncation sweep), directory
  overlap/overrun/reorder/duplicate/gap/trailing slack, unknown features
  bit, count overflow, non-finite fields, easing `len`/`ops_len`/
  monotonicity violations, out-of-domain bpm/meter/ticks, per-source
  non-zero slack, unsorted keys, explicit-schedule disorder, payload
  zero/multi-root, payload trailing slack, corrupt node bytes
  mid-payload, oversized pool, caps exceeded, non-canonical presence
  (a degenerate `'EASE'`/`'TMPO'`/`'REGS'`/count-0 section PRESENT; a
  required `'TRAN'`/`'PACM'` ABSENT; cross-presence contradiction —
  e.g. `'KEYS'` with no keys track), PACM structural garbage (bad
  magic/version, truncated TLV stream, record-width drift, unordered
  spans), PACM↔PACB incoherence (a track registry/target lie, a control
  identity lie, count mismatches, `'EASE'`/`'TMPO'` payload divergence),
  PACM fnv mismatch, registry identity mismatch **including a
  same-shaped name swap**. Each refuses with the right reason class
  (`meta_incoherent` for the semantic lies).
- GREEN: `Pacb.decode` + `DecodedScore` + `pacbWorstCase`, with the
  ownership test (decode → clobber input → tables still evaluable).
- Gate: `zig build test`.

### Phase 3 — encoder + `pacer pack` + determinism

Files to load: `src/Compile.zig:240-361`, `src/cli/Cli.zig`,
`src/cli/Frames.zig`, SJON `Ast.zig:2006-2014`, `Binary.zig:151-236`.
- RED: CLI golden envelope for `pack` on `examples/starter.score.sjon`
  (`src/cli/testdata/`); round-trip — compile fixture scores, encode,
  decode, assert table equivalence AND `Expr.evalBinary` over each emitted
  payload reproducing `Expr.eval` at t=0 under the same env; pack-twice
  byte-equality; `pack_user_expr_unsupported` RED twice — a user-plugin head
  in a RESULT position (dry-run visible) and one hidden in an UNTAKEN branch
  (only the head walk catches it — the unit builds the payload subtree
  directly); the grammar-context ACCEPTANCE set — vector-literal elements,
  `let` binding names (incl. one colliding with a core head), binder
  vectors (`[x]`, `[acc x]`), and a form-as-data head resolving in
  NEITHER schema that MUST pack clean (the over-broad-refusal
  regression); targets-json adapter fixtures vs the buildJoin rules.
- GREEN: `PacbEncode.zig`, the verb, envelope goldens via
  `zig build cli-golden` (diff reviewed).
- Gate: `zig build verify` + `zig build cli-golden`.

### Phase 4 — codes, fuzz, docs

- RED: `audit-diagnostics` fails until the new codes are exercised by name;
  decode fuzz harness never panics (`src/fuzz.zig` discipline).
- GREEN: codes + by-name tests; harness wired into `zig build fuzz`;
  `docs/binary-score.md` written from `Pacb.zig`'s header (frozen constants,
  caps + rationale, the payload structural-consumption rule, span opacity,
  the canonical presence/defaults rules, and the PACM trust model with its
  exact checked-surface claim);
  `CLAUDE.md` wire-table row for `'PACB'` (data at rest; append-only;
  VERSION bumps breaking).
- Gate: `zig build verify` + `zig build audit-diagnostics` + `zig build fuzz`.

## Progress log

_(created 2026-10-18; entries appended per phase)_

- **2026-10-18 — Phase 1 complete (T1.1).** `src/PactCodec.zig` owns
  `Target`, `MAX_TARGETS`, the `'PACT'` wire constants and the byte-identical
  encoder/decoder; `Compile.Target` / `Compile.MAX_TARGETS` and the `Abi`
  codec surface are aliases/delegates. RED: the consuming
  encode→decode→canonical-re-encode test failed on missing
  `src/PactCodec.zig`. GREEN: `zig build test` 284/284; `zig build verify`
  15/15 (223 native, 37 corpus, 93 node, zero skips); `zig build cli-golden`
  4/4 with `git diff --exit-code src/cli/testdata corpus docs/score-language.md`
  empty. Frozen-bytes, duplicate-name and
  empty/overlong-name characterization tests added; no wire byte changed and
  no corpus goldens were regenerated.

- **2026-10-18 — Phase 2 started (T2.1 only; phase NOT complete).**
  `src/Pacb.zig` now owns the `'PACB'` container header, the exact
  directory validator, the frozen 14-kind id/width/order table, the
  append-only `RefusalCode` set (`u16` from birth), the v1 caps
  (`MAX_PAYLOAD_BYTES` 256 KiB, `MAX_PAYL_BYTES` 4 MiB,
  `MAX_TICK_ENTRIES` 131072 with its producer derivation), `parseDirectory`,
  and `pacbWorstCase`/`pacmWorstCase` (comptime arithmetic; the PACM term
  equality-asserted against `Abi.metaWorstCase` in `src/root.zig`). RED:
  the root export consumer failed on missing `src/Pacb.zig`, then 10 named
  semantic directory-mutation tests failed against the header-only skeleton.
  GREEN: `zig build test` 7/7 steps, **306/306 tests (245 root + 61 CLI)**;
  `zig build verify` 15/15 (**245 native, 37 corpus/0 failed, 93 node/0
  skipped**, score-docs and cli-golden current); `zig build cli-golden` 4/4
  with an empty `git diff --exit-code src/cli/testdata corpus
  docs/score-language.md`. `parseDirectory` is an INTERIM directory-only
  view: the whole-blob `decode`/`DecodedScore` API is deliberately not
  exposed until every section stage validates, and transport, registry,
  records, ease/control, payload, PACM, and coherence remain T2.2–T2.8.
  No corpus/CLI golden byte changed; no encoder/CLI/runtime/npm work.

- **2026-10-18 — Phase 2 continued (T2.2 only; phase NOT complete).**
  `src/Pacb.zig` gained the transport stage: `decodeTransport(gpa, bytes,
  directory, refusal) DecodeError!TransportStage` — an owned, arena-backed
  result (`deinit`; authored `'TMPO'` table copied in, `emit` left empty
  for T2.4) plus the raw `'TRAN'` registry fields carried for T2.3.
  `'TRAN'` domains are validated BEFORE any `TimeMap` call (its contract
  is asserts): bpm finite 1..1000, `beats_per_bar` 1..16, `dur > 0` when
  flagged and `≤ MAX_TICK`, zero spelling behind a clear flag, reserved
  flag bits / pads zero, `end loop` requires `dur` (compile's
  `loop_requires_dur` mirror). `'TMPO'` (count ≥ 2 canonical presence,
  count ≤ `MAX_TEMPO_SEGMENTS` ⇒ `cap_exceeded`, `[0] == {0, 'TRAN'.bpm}`
  bit-equal, strictly ascending ticks, per-segment bpm domains,
  `|tick| ≤ MAX_TICK`) then rebuilds through `TimeMap.init` +
  `withSegments` in compile's own op order, with `loop_secs =
  map.secondsFromTick(dur)`; an absent `'TMPO'` synthesizes `[{0, bpm}]`
  and keeps the constant code path (the degenerate pin), exactly matching
  a compiled constant-tempo score. RED: 3× missing-export compile errors
  on `decodeTransport`, then 7 named semantic FAILs against the safe
  constant-path increment (6 wrongly-accepted `'TMPO'` mutation classes +
  the pin test's derived-table mismatch). GREEN: `zig fmt --check` clean;
  `zig build test` 7/7 steps, **321/321 tests (260 root + 61 CLI)** — the
  pin test compiles a tempo-mapped and a constant score through
  `test_support.schema()` + `Compile.compile` (test-body-only imports,
  the recorded plan-02 seam) and compares decoded vs compiled transport
  field-for-field (bpm/derived `start_sec`/`tps`/`loop_secs` bit-equal).
  Imports grew to the frozen T2.2 subset: std, sjon (`Pattern.MAX_TICK`),
  `TimeMap`, `TrackTable` — still never `Compile`/`Abi`/`Schema`/`Driver`
  in production code. Registry (`'REGS'`/`'DECL'`), records, ease/control,
  payload, PACM reader, and coherence remain T2.3–T2.8; no
  `decode`/`DecodedScore`, no corpus/CLI golden byte changed, no
  encoder/CLI/runtime/npm work.

- **2026-10-18 — Phase 2 continued (T2.3 only; phase NOT complete).**
  `src/Pacb.zig` gained the registry-identity stage:
  `decodeRegistry(gpa, bytes, directory, refusal) DecodeError!RegistryStage`
  — an owned, arena-backed result (`deinit`) carrying a DEEP copy of the
  registry identity bytes (`regs`; the zero-count `'PACT'` spelling when
  `'REGS'` is absent, so `canonicalPactEquals(host, stage.regs)` is the
  uniform load-time check), the `Decl` records (the T2.1-pinned
  `pub const Decl = struct { registry: u8, ncomp: u8 }`, added by this
  task), and the raw `'TRAN'` counts/fnv. Identity is BYTE equality of
  the canonical `'PACT'` encoding: a present `'REGS'` must be the
  canonical encoding of its own decoded content (`registry_mismatch`
  otherwise — byte_len lies, non-decodable PACT, bad magic), carry
  count ≥ 1 (`non_canonical` — the zero-count join is the omitted case),
  count == `host_targets` (`count_mismatch`), and an `fnv1a64` that
  agrees with the bytes (`registry_mismatch` — fast-reject + diagnostic
  checksum only, never the identity). An absent `'REGS'` requires
  `host_targets == 0` (`non_canonical`) and the zero-count `'PACT'`'s
  FNV (`registry_mismatch`). `'DECL'`: count == `declared_targets`
  (`count_mismatch`, both directions), `host_targets + declared_targets
  ≤ MAX_TARGETS` (`cap_exceeded`), per-record pad zero + `ncomp ∈ 1..4`
  (`decl_invalid`). The `'TRAK'`/`'CTRL'`/`'EMIT'` consumers of the id
  bound land with their sections (T2.4/T2.5), per the task's own
  exclusion. `canonicalPactEquals(host_blob, regs)` is the public,
  allocation-free load-time predicate (lockstep structural walk ≡
  decode→re-encode→byte-compare; validates the host blob's decodability,
  never consults fnv or caps) — the function 02's `prt_load` calls.
  RED: 4× missing-export compile errors (`decodeRegistry`,
  `canonicalPactEquals`), then 9 named WronglyAccepted FAILs against the
  carry/copy-only increment (a fixture-builder offset-vs-index bug found
  on the way was fixed and the RED re-run clean before GREEN).
  GREEN evidence additionally includes a deliberate neuter pass: with
  the name-byte comparison disabled, exactly
  `canonicalPactEquals catches same-shaped registry swaps` fails —
  proving the swap test detects a shape-only implementation — then
  restored. Final: `zig fmt --check` clean; `zig build test` 7/7 steps,
  **332/332 tests (271 root + 61 CLI)**. Imports grew to std, sjon,
  `PactCodec`, `TimeMap`, `TrackTable` — still never
  `Compile`/`Abi`/`Schema`/`Driver` in production code. Records,
  ease/control, payload, PACM reader, and coherence remain T2.4–T2.8; no
  `decode`/`DecodedScore`, no corpus/CLI golden byte changed, no
  encoder/CLI/runtime/npm work.

- **2026-10-18 — Phase 2 continued (T2.4 only; phase NOT complete).**
  `src/Pacb.zig` gained the record-sections stage:
  `decodeRecords(gpa, bytes, directory, registry, refusal)
  DecodeError!RecordsStage` — an owned, arena-backed result (`deinit`)
  carrying `tracks: []const DecodedTrack` (the frozen T2.1
  representation), `keys: []const TrackTable.Key`, `scenes:
  []const DecodedScene`, `emit: []const TrackTable.EmitLane` (document
  order; `TransportStage.transport.emit` stays empty until T2.8 folds
  them in), and `payload_spans` parallel to tracks — the wire
  `(payload_off, payload_len)` carry for T2.6, whose copies will fill
  the still-empty `DecodedSource.expr`/`pattern` arms. Validation:
  counts over caps (TRAK 256, KEYS 4096, SCEN 64, EMIT ≤ 5 lanes — G10;
  TICK's cap is T2.1's directory check); canonical presence (a present
  section is never count-0); `'KEYS'` iff a keys track exists and
  `'TICK'` iff an explicit-trigger track does (a source/trig_kind
  ordinals pre-scan owns those two ordinal checks so a shape defect
  never misreports as a presence contradiction); per record: `ncomp ∈
  1..4`; the registry-join bound plus the EXACT `(registry, ncomp)`
  triple of the joined entry — host ids walked out of the stage's owned
  `'REGS'` bytes, declared ids read from `'DECL'` — refusing
  `registry_mismatch`; `scene` `NO_SCENE` or `<` the actual `'SCEN'`
  count (G10 — NOT `MAX_SCENES`); per-source unused-field zero slack
  (`trig_every/offset` zero for keys/expr/pattern; `payload_off/len`
  zero for keys/periodic; `key_start/len` zero for expr/pattern); keys
  runs ≥ 1, slice-bounded through checked u64 adds, strictly ascending,
  value lanes ≥ ncomp zero; periodic `every > 0`; explicit schedules
  non-empty, slice-bounded (checked adds), strictly ascending,
  `|tick| ≤ MAX_TICK`, and non-overlapping in track order (`'TICK'` is
  the concatenation of every schedule); scene window ends
  checked-added; `'KEYS'` `ease_ref` must be 0 when `'EASE'` is absent
  (the synthesized linear default; T2.5 owns the real-table bound);
  `'EMIT'` lanes: ordinal ≤ 4, unique per name (Eval leans on
  uniqueness — G10), reserved zero, joined by id AND registry. Section
  payloads are read through a bounds-defended helper, so a mismatched
  `directory`/`bytes` pair is a refusal, never a trap (the documented
  same-buffer precondition plus its defense). RED: genuine
  missing-export compile errors on `decodeRecords`/`SOURCE_*`/
  `TRIG_*`, then 17 named WronglyAccepted FAILs against the
  carry/copy-only increment (one fixture-slice bug found on the way — a
  presence subcase still held the keys track — fixed, RED re-run clean;
  one Zig-0.16 reflection-name fix in the root test's tag lookup).
  GREEN: `zig fmt --check` clean; `zig build test` 7/7 steps,
  **351/351 tests (290 root + 61 CLI)**; `zig build verify` 15/15 (290
  native, 37 corpus/0 failed, 93 node/0 skipped, score-docs and
  cli-golden current); corpus/CLI/docs drift vs `90dc758` zero. The
  frozen ordinal copies (`SOURCE_*` against `Abi.TrackSourceKind`,
  `TRIG_*` against `TrackTable.Trigger`'s tag order) are
  equality-asserted in `src/root.zig` — import-cycle-safe, the same
  pattern as the worst-case assert. Ease/controls
  (`'EASE'`/`'STRS'`/`'CTRL'`), payload (`'PAYL'`), the PACM reader,
  and coherence remain T2.5–T2.8; no `decode`/`DecodedScore`, no
  corpus/CLI golden byte changed, no encoder/CLI/runtime/npm work.
