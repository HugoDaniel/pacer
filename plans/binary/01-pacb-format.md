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
**Created 2026-10-18; not started.**

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
present sections must appear in canonical order:

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
`off/len` in bounds; sections non-overlapping and monotonic in canonical
order; each section's counts × record width consume its length exactly
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
`ease_ref < program_count`; `program_count ≥ 1` and program 0 is linear (the
shared default, `src/TrackTable.zig:16-18`); per program `len ∈ 1..8`,
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
**proposals-with-rationale** (format choices, not source constants): 256 KiB
per payload / 4 MiB total — a subtree's compact IR cannot exceed the 256-KiB
document zone it was packed from, and 4 MiB bounds `MAX_TRACKS ×` per-payload
without letting one pathological expression dominate; frozen with v1 and
recorded in `docs/binary-score.md`. `pacbWorstCase()` (the `metaWorstCase`
pattern, `src/Abi.zig:158-174`) derives the input-zone bound once, as
arithmetic restating the spec.

Embedded-PACM coherence (not two authorities): the operative truth at
runtime is the PACB sections; `'PACM'` is served verbatim as metadata.
Coherence is guaranteed (i) at construction — the packer embeds the blob it
just encoded from the same `CompileResult` and self-checks (below); (ii) at
load — `pacm_fnv` is recomputed over the section bytes it carries, and the
three PACM header counts (track/key/control, fixed offsets in the frozen
wire header, `src/Abi.zig:31-35`) are peeked and must equal the PACB counts.
The runtime does NOT decode PACM — a full PACM reader in the closure would
duplicate the format the npm glue already mirrors; the boundary is stated,
not hidden.

All refusals are deterministic — same bytes, same refusal, native and wasm.

### Producer — split modules, public API, `pacer pack`

**Two files at birth** (the encoder could never enter the runtime closure —
it needs `Compile`/`Abi` — and a hidden import is the facade pattern the
closure gate exists to kill):

- `src/Pacb.zig` — constants, decoder + validator, `DecodedScore`
  (arena-backed `.deinit()`), `pacbWorstCase`. Imports: std, `PactCodec`,
  sjon `BinaryCursor`/`BinaryFormat`. Never `Compile`/`Schema`/`Driver`.
- `src/PacbEncode.zig` — encoder + FNV. Imports `Compile`, `Abi`, `Pacb`,
  `PactCodec`. Never referenced by `rt_entry` (02).

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

- `pack_user_expr_unsupported` — any head the payload's forms resolve to a
  call that a **core-only** schema cannot satisfy. The check is NOT the t=0
  dry-run alone (an untaken branch can hide a user head behind `if`): the
  packer walks every payload structurally (same walk as decode) collecting
  every operator-position symbol, and each must resolve through a comptime
  core-only schema (`sjon.Schema.Schema` over `sjon.plugins.core.plugin` —
  the precedents are `SJON/src/wasm_common.zig:30`, `SJON/src/wasm_binary.zig:33-34`,
  and pacer's own `src/ExprTrack.zig:298-300`) via `lookupExprFunc`
  (`SJON/src/Schema.zig:184`) or `isCoreSpecialForm`
  (`SJON/src/Expr.zig:3451`). NEVER checked against `result.eval_schema` —
  it carries the document's user plugins (`src/Compile.zig:329-334`) and
  would accept what the runtime cannot evaluate. No hardcoded name list; the
  rule is resolution, not enumeration (`docs/binary-score.md` documents the
  resulting capability set for humans).
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
| `src/Pacb.zig` | format constants, decoder/validator, `DecodedScore`, `pacbWorstCase` |
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
  overlap/overrun/reorder/duplicate, unknown features bit, count overflow,
  non-finite fields, easing `len`/`ops_len`/monotonicity violations,
  out-of-domain bpm/meter/ticks, per-source non-zero slack, unsorted keys,
  explicit-schedule disorder, payload zero/multi-root, payload trailing
  slack, corrupt node bytes mid-payload, oversized pool, caps exceeded,
  PACM fnv/count-peek mismatch, registry identity mismatch **including a
  same-shaped name swap**. Each refuses with the right reason class.
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
  directly); targets-json adapter fixtures vs the buildJoin rules.
- GREEN: `PacbEncode.zig`, the verb, envelope goldens via
  `zig build cli-golden` (diff reviewed).
- Gate: `zig build verify` + `zig build cli-golden`.

### Phase 4 — codes, fuzz, docs

- RED: `audit-diagnostics` fails until the new codes are exercised by name;
  decode fuzz harness never panics (`src/fuzz.zig` discipline).
- GREEN: codes + by-name tests; harness wired into `zig build fuzz`;
  `docs/binary-score.md` written from `Pacb.zig`'s header (frozen constants,
  caps + rationale, the payload structural-consumption rule, span opacity);
  `CLAUDE.md` wire-table row for `'PACB'` (data at rest; append-only;
  VERSION bumps breaking).
- Gate: `zig build verify` + `zig build audit-diagnostics` + `zig build fuzz`.

## Progress log

_(created 2026-10-18; entries appended per phase)_
