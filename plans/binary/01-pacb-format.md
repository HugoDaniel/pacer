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
**Created 2026-10-18; Phase 1 complete 2026-10-18; Phase 2 complete
2026-10-19 (T2.1–T2.7 landed 2026-10-18 with the interim-review decoder
correction — folded-tick envelope + canonical hardening; T2.8 —
`decode`/`DecodedScore` + the PACM coherence cross-check + ownership —
landed 2026-10-19); Phase 3 complete 2026-10-19 (encoder core, pack
refusals, the `pacer pack` verb); Phase 4 complete 2026-10-19 (T4.1–T4.4:
audit closure, never-panic decode fuzz harness, `docs/binary-score.md`
format of record + the `CLAUDE.md` wire row, wave-plan corrections
record). The plan is COMPLETE **QUALIFIED, not silently**: the
tree-trailing-comments acceptance criterion is known-failed as shipped
and stays an explicitly deferred owner decision, pinned by a KNOWN-GAP
test (the packer never emits such a payload, so `pacer pack` output is
unaffected); the broad post-wave review is also pending.**

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
1..16; `dur > 0` when the present-flag is set; the tick envelope is
fold-dependent (the interim decoder review's R1/R2, architect-ruled):
scened fields — keys `at`, periodic `trig_offset`, explicit `'TICK'`
entries — accept `|v| ≤ 2·MAX_TICK` **inclusive** (each is one checked
i64 add of a scene start ≤ MAX_TICK and a local position ≤ MAX_TICK, so
2·MAX_TICK itself is compile-reachable and accepted), while unfolded
fields keep the plain grid bound — `trig_every` ∈ 1..MAX_TICK (never
scene-folded) and `'TRAN'`/`'TMPO'` ticks stay ≤ MAX_TICK (no fold
exists there); `'TMPO'` ascending, `[0].tick == 0`, `[0].bpm ==
'TRAN'.bpm`, every segment bpm finite and 1..1000, count ≤
`MAX_TEMPO_SEGMENTS`.

Records: counts ≤ the caps table (00-strategy Global constraints) and
the **global `'TICK'` count ≤ `MAX_TICK_ENTRIES`** (the cap proposal
below — decode checks directory exactness first, then the cap);
`ncomp ∈ 1..4`; `scene == 0xffff (NO_SCENE, src/TrackTable.zig:53)` or
**< the actual `'SCEN'` count** (the table invariant is a valid index
into `scenes`, `src/TrackTable.zig:25`; compile assigns structurally
`< scenes.len`, `src/Compile.zig:965` — the row count, not the cap);
`'EMIT'` count ≤ 5 with **unique** name ordinals (the `EmitName`
field-count ceiling and lane uniqueness `Eval` asserts,
`src/Eval.zig:184-186`) and a scalar joined entry per lane;
`trig_kind`/`source`/`name` ordinals in range; per-source
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
ascending, inside the folded envelope above (`|v| ≤ 2·MAX_TICK`
inclusive); scene `start_tick + dur_ticks` checked-add (compile
raises `tick_overflow` — decode refuses the same class).

Controls: ids unique, non-empty, not reserved, in range of `'STRS'`;
`type` ordinal ≤ 2 (`TrackTable.ControlType` is `enum(u8)`
slider/xy/color, `src/TrackTable.zig:195` — a wider byte is
illegal-enum behavior at first switch, a decoder trap decode must
pre-empt) and env-only `ncomp ∈ 1..4` (no join entry exists to check
it against, `src/TrackTable.zig:212-214`); `type`/min/max flags
coherent (a min/max flag set ⇒ the corresponding lanes are finite);
env-only controls use `target_id == 0xffff`
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
recorded in `docs/binary-score.md`. `MAX_TICK_ENTRIES` = **131072**
joins them under the same proposals-with-rationale authority, with
this derivation: the wasm artifact's static doc zone is 256 KiB
(`MAX_DOC_SIZE`, `src/wasm_entry.zig:72`), explicit `:at` entries are
a direct literal vector with no sharing/repetition construct
(`buildAtList`, `src/Compile.zig:1105-1131`), and each entry costs at
least 2 source bytes (shortest atom + separator/delimiter, amortized)
— so the **global** sum of explicit ticks across **all** tracks of any
wasm-compilable score is ≤ 256×1024/2 = 131072 (worst-case `'TICK'`
section ≈ 1 MiB). A conservative producer bound, not a claim of
tightness; native-band sources (256 KiB–1 MiB, `src/cli/Source.zig:20`)
and direct-API compiles can exceed it, and `pack` refuses loudly with
the measured count (`pack_cap_exceeded`). The text path stays
uncapped — a v1 binary-format resource policy. `pacbWorstCase()` (the `metaWorstCase`
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
   `(target_id, registry, ncomp, source)` == `'TRAK'[i]`, with the
   key-range comparison **per source** (B1/G9: a keys track's PACM
   `key_start/key_len` == the `'TRAK'` fields; every other source's
   meta range is the constant `(0,0)` — `Abi.encodeMeta`'s own
   spelling for non-keys, `src/Abi.zig:437-440` — never compared
   against a real `'TICK'` slice, which `'TRAK'` carries for an
   explicit trigger); `key_count` == `'KEYS'` count; `control_count` ==
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
  binary-arm schema (core [+pattern at P4]). **Refusal is the
  full-outcome compare** (I1/G11 — the identity rule, replacing the
  earlier "found in both ⇒ identical"): a head packs clean iff the
  binary schema resolves it `.found` **in the core plugin** AND the
  text `eval_schema` resolves it `.found` with the **SAME (plugin,
  func) identity**; `eval_schema` resolving `.ambiguous` refuses even
  when the binary schema finds the head (a user plugin redeclaring a
  core name makes the bare head ambiguous on BOTH schedule paths —
  `error.AmbiguousFunction`, `SJON/src/Schema.zig:143-168`,
  `SJON/src/Expr.zig:2854`); `eval_schema` finding it in a non-core
  plugin (binary: not-found) or with a different identity likewise
  refuses — `pack_user_expr_unsupported` naming the head and span.
  Found in NEITHER ⇒ a form-as-data literal — legal
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

- **2026-10-18 — Phase 2 continued (T2.5 only; phase NOT complete).**
  `src/Pacb.zig` gained the ease/control stage:
  `decodeEaseControls(gpa, bytes, directory, records, registry,
  refusal) DecodeError!EaseControlStage` — an owned, arena-backed
  result (`deinit`) carrying `programs` (the verbatim `'EASE'` table,
  or the synthesized shared linear default alone when absent, spelled
  exactly as compile spells it) and `controls` (ids deep-copied out of
  `'STRS'`; `DecodedControl` is the frozen T2.1 representation).
  Validation: `'EASE'` program_count ≤ 128 (`cap_exceeded`), present ⇒
  ≥ 2 programs with program 0 linear (`non_canonical`/`ease_invalid`),
  section length arithmetic exact (`4 + n×772 + 4 + k×2`), per program
  `len ∈ 1..8`, `ops_len ≤ 4`, `t_end` strictly increasing from the
  virtual 0 boundary (the `denom > 0` eval assert pre-checked), all
  floats finite, op ordinals within the frozen `Easing.Op` set, pads
  and every unused stage/op slot byte-zero (the normalized-on-copy
  rule), `key_ref_count == 'KEYS'` count (`count_mismatch`), every
  refs-array entry and every KEYS `ease_ref` bounded by the real table
  (`ease_invalid`, subsuming T2.4's absent-section check);
  `'STRS'` count ≤ 64, present ⇒ count ≥ 1 and byte_size ≥ 1
  (`non_canonical`), byte_size == section length − 8 with entries
  consuming it exactly, sorted by (len, bytes) ⇒ unique, no empty
  entries, no `ExprTrack.reserved_names` shadow (frozen copy
  `reserved_control_names`, equality-asserted in `src/root.zig`);
  `'STRS'` iff a control exists (`non_canonical`, both directions);
  `'CTRL'` count ≤ 64 / ≥ 1, reserved flag bits zero, `type` ordinal ≤
  2 (`control_invalid`), ids resolving to exactly one `'STRS'` entry
  and never shared between controls, env-only spelling
  (`target_id == NO_TARGET`) with zero registry byte and `ncomp ∈
  1..4`, targeted ids inside the join with the exact
  `(registry, ncomp)` triple (`registry_mismatch`), value lanes ≥
  ncomp zero, min/max flag set ⇒ finite lanes and clear ⇒ zero lanes.
  RED: 4× missing-export compile errors (`decodeEaseControls`,
  `Pacb.reserved_control_names`), then 10 named WronglyAccepted FAILs
  against the carry/copy-only increment (positive controls passing).
  Two fixture defects found on the way (an `id_off` pointing at the
  entry's length prefix — pinned to the string BYTES, the
  `payload_off` convention; three EASE-mutation fixtures omitting the
  KEYS/TICK/EMIT/SCEN sections their `'TRAK'` rows require) were fixed
  and the RED re-run clean before GREEN. GREEN: `zig fmt --check`
  clean; `zig build test` 7/7 steps, **364/364 tests (303 root + 61
  CLI)**; `zig build verify` 15/15 (303 native, corpus 37/0 failed,
  93 node/0 skipped, score-docs and cli-golden current); corpus/CLI/
  docs/npm drift vs `90dc758` zero. Imports grew to std, sjon,
  `PactCodec`, `TimeMap`, `TrackTable`, `Easing` — still never
  `Compile`/`Abi`/`Schema`/`Driver` in production code. Payload
  (`'PAYL'`), the PACM reader, and coherence remain T2.6–T2.8; no
  `decode`/`DecodedScore`, no corpus/CLI golden byte changed, no
  encoder/CLI/runtime/npm work.

- **2026-10-18 — Phase 2 continued (T2.6 only; phase NOT complete).**
  `src/Pacb.zig` gained the payload stage:
  `decodePayloads(gpa, bytes, directory, records, refusal)
  DecodeError!PayloadStage` — an owned, arena-backed result (`deinit`)
  carrying per-track payload COPIES parallel to
  `RecordsStage.tracks` (empty slices for non-payload sources), the
  seam T2.8's assembly zips into the still-empty
  `DecodedSource.expr`/`pattern` arms. Validation: `'PAYL'` iff an
  expr/pattern track exists (`non_canonical`, both directions), the
  section's `[byte_size u32]` arithmetic exact with the degenerate
  zero-size region the omitted case (`payload_malformed`/
  `non_canonical`), `byte_size ≤ MAX_PAYL_BYTES` and every span
  `len ≤ MAX_PAYLOAD_BYTES` (`cap_exceeded`), spans region-bounded
  through checked u64 adds and non-overlapping in track order (the
  `'TICK'` discipline, `payload_malformed`), then per payload the
  STRUCTURAL CONSUMPTION WALK: `sjon.BinaryCursor.Cursor.init` (header/
  pool/roots-offset equality — it rejects pool↔roots slack), a pool
  index on the stage arena (O(1) lookups, `compileBinary`'s own
  pattern), exactly one root (zero and multiple both refuse), and an
  iterative depth-first walk through the cursor's child/vector
  iterators consuming EVERY node kind at its exact wire width — depth
  capped at `MAX_TREE_DEPTH`, every cursor error mapped to
  `payload_malformed` — which must end exactly at `payload_len`
  (trailing slack inside a payload refuses). No evaluation, no schema,
  no compiler on this path; pattern-payload acceptance is schema-free
  until 02 P4. Ownership proven by decode → `@memset(input, 0xAA)` →
  byte-identical payload read-back. RED: missing-export compile errors
  on `decodePayloads`, then 7 named WronglyAccepted FAILs against the
  clamp-span copy-only increment (zero/multi root, trailing slack,
  corrupt node bytes, oversized pool, per-payload + total caps,
  iff-presence, span bounds/overlap/arithmetic/zero-size). GREEN
  evidence: `zig fmt --check` clean; `zig build test` 7/7 steps,
  **372/372 tests (311 root + 61 CLI)**; `zig build verify` 15/15
  (311 native, corpus 37/0 failed, 93 node/0 skipped, score-docs and
  cli-golden current); corpus/CLI/docs/npm drift vs `90dc758` zero.
  Positive fixtures compile real payloads through `sjon.parse` +
  `Binary.toBinary(forMode(.compact))` — the frozen encoder choice
  (A29) as the test-side oracle — covering form/vector/number/symbol/
  number-with-unit/string/nil/boolean/keyword-child kinds; mutation
  fixtures hand-patch root counts, tag bytes and pool-count varints.
  One T2.5-commit doc-comment seam (a stray line above
  `readEaseProgram`) was found and removed in this task's commit.
  Imports grew to std, sjon (`Pattern`, `BinaryCursor`, `Binary`),
  `PactCodec`, `TimeMap`, `TrackTable`, `Easing` — still never
  `Compile`/`Abi`/`Schema`/`Driver` in production code. The PACM
  reader and coherence remain T2.7–T2.8; no `decode`/`DecodedScore`,
  no corpus/CLI golden byte changed, no encoder/CLI/runtime/npm work.

- **2026-10-18 — Phase 2 continued (T2.7 only; phase NOT complete).**
  `src/Pacm.zig` landed — the std-only `'PACM'` reader
  (`Pacm.decode(blob) ?Pacm.MetaView`), imported by `src/root.zig`
  (export + discovery). Imports std ONLY (`Abi` stays the encoder and
  format of record; never `Pacb`/`Compile`/`TrackTable`/`Easing`/sjon),
  so every wire constant and ordinal family it spells is a frozen copy
  gated by equality asserts in `src/root.zig` (magic/version, header 40,
  track 24 / key 32 / control 64 / scene 24 / tempo 16 / ease
  op 20 / stage 96 / program 772, section ids, `META_NO_TARGET`;
  `TrackSource` 0..3 vs `Abi.TrackSourceKind`, `ControlKind` 0..2 vs
  `TrackTable.ControlType`, `MAX_EASE_OP` 21 vs `Easing.Op`'s 22
  variants, stage/op slot counts vs `Easing.MAX_STAGES`/`MAX_OPS`).
  `MetaView` carries the transport scalars plus byte-slice sections and
  typed accessors mirroring `Abi.MetaView`'s read shapes — every slice
  ALIASES the input blob (the view borrows; `Pacb` copies what it
  keeps). `decode` is total: null on bad magic/version, truncated
  header/record/id, width lies, key ranges past the key stream (u64
  compare), unordered span pairs (track/key/control-value/scene-name),
  enum bytes outside the frozen families, transport outside the
  compiler's domains (bpm finite 1..1000, beats_per_bar 1..16 — the
  closed boundaries accepted), truncated/trailing TLV slack, duplicate
  section ids, section payloads not accounting exactly for their
  records, and `'EASE'` op ordinals past 22 — with unknown ids skipped
  by length (the TLV contract) and divide-before-multiply length
  arithmetic throughout (no trap on any byte sequence, native/wasm32).
  Oracle discipline: three FROZEN producer blobs under
  `src/testdata/pacm/` (`keys-controls` 288 B, `scenes-tempo-ease`
  1772 B, `minimal` 108 B) generated once by the real
  `Abi.encodeMeta` over fixture sources already proven in `Abi`'s own
  decoder tests; a root test recompiles those sources and byte-pins the
  files to fresh producer output every run, and three field-for-field
  comparisons walk `Pacm.decode` against `Abi.decodeMeta` (the
  Zig-side shared oracle, A38) with own literal expectations (spans
  sliced from the fixture sources, domain values, section contents).
  `verifyRouting` is deliberately ABSENT: its plan signature takes a
  `*const Pacb.DecodedScore`, which would make std-only `Pacm` import
  `Pacb` (closure violation + cycle). Recorded as a layering conflict,
  staged unimplemented for T2.8 — which the plan already assigns the
  wiring ("Modify `src/Pacb.zig`, `src/Pacm.zig` (wire
  `verifyRouting`)") — to resolve with the architect via the approved
  layering/generic signature if the typed form stays impossible; no
  silent loosening of the std-only closure. RED evidence
  (`.agent/control/binary01-t27-*.log`): RED 1 genuine missing-module
  compile error (`unable to load 'Pacm.zig': FileNotFound`); RED 2 the
  carry increment (structural read of valid blobs only) wrongly
  accepting 8 named refusal classes (truncated-prefix tails, trailing
  bytes, duplicate ids, accounting lies, enum bytes, unordered spans,
  transport domains, key-range overrun) — 384/392 with the positive
  control green; truncation sweeps, count/width lies and TLV payload
  cuts were green-on-arrival (a non-trapping read needs those bounds).
  GREEN: `zig fmt --check` clean; `zig build test` 7/7 steps,
  **392/392 tests (331 root + 61 CLI)**; `zig build verify` 15/15
  (331 native, corpus 37/0 failed, node parity green, score-docs and
  cli-golden current); corpus/CLI/docs/npm drift vs `90dc758` zero.
  Phase 2 remains open at T2.8 (coherence cross-check,
  `DecodedScore` completion, ownership proof); no encoder/CLI/runtime
  work, no corpus/CLI golden byte changed.

- **2026-10-18 — Interim decoder review correction (decoder-only,
  pre-T2.8; parent control brief
  `.agent/control/binary01-review-correction-brief.md`).** The interim
  review's findings 1+2 (BLOCKER + IMPORTANT, one root cause — the
  scene-fold tick envelope applied inconsistently) and the batched
  optional canonical gaps are corrected in `src/Pacb.zig`, per the
  architect's focused rulings:
  `MAX_FOLDED_TICK = 2·sjon.Pattern.MAX_TICK` (inclusive) now bounds
  keys `at`, periodic `trig_offset`, and explicit `'TICK'` entries
  (`key_invalid`/`trigger_invalid`; `trig_every` ∈ 1..MAX_TICK — it is
  never scene-folded), with the comptime headroom pin
  `4·MAX_TICK < maxInt(i64)`; scene `start_tick`/`dur_ticks` stay
  checked-add-only (window-gated at eval, non-trapping). Boundary
  tests: ±2·MAX_TICK accepted / ±(2·MAX_TICK+1) refused per family,
  `every`=MAX_TICK/MAX_TICK+1, the scened-fold parity case (scene
  start MAX_TICK + local MAX_TICK ⇒ 2·MAX_TICK accepted — the T3.1
  round-trip class), the 2⁵³-ceiling fixture repointed. Batched
  canonical hardening (all producer-impossible, premises verified
  against `Compile`/`Abi` source): `'EASE'` refs elementwise-equal the
  key stream's `ease_ref`s (`ease_invalid`); `required_features` bit0
  ⇔ a pattern-source track (`non_canonical`); present zero-count
  `'DECL'` refuses `non_canonical` (the zero-declared join is the
  absent section); `'KEYS'` runs non-overlap in track order like
  `'TICK'` slices (`key_invalid`); `'EMIT'` lanes join scalar
  (ncomp 1) targets (`registry_mismatch`). The early T2.2/T2.3 stage
  reads now route through `sectionPayload` with count×width defenses —
  a mismatched directory/buffer pair is a refusal, never the
  out-of-bounds trap the review demonstrated. New payload fixtures:
  date/time literals (real encoder, the walk's last uncovered arms),
  node-comments+spans (root leading, element leading, vector
  trailing), and the tree-trailing KNOWN-GAP test pinning the current
  `payload_malformed` refusal — deferred pending the owner's SJON
  cross-repo-edit decision (focused ruling 3); compact-only refusal
  was ruled out as unilateral narrowing. No T2.8 work, no
  encoder/CLI/runtime/npm/source-compiler change, no wire-format
  change. RED evidence per behavior
  (`.agent/control/binary01-review-correction-report.md`): observed
  reds 392/395 (envelope), 396/396+1 … 400/401 (one per optional),
  400/402 incl. the demonstrated `index out of bounds` panic
  (registry mismatched pair); GREEN `zig build test` 405/405
  (344 root + 61 CLI), `zig fmt --check` clean.

- **2026-10-19 — Phase 2 complete (T2.8; phases 3–4 remain — the plan
  is NOT done, the encoder is still open).** `src/Pacb.zig` gained the
  whole-blob API: `decode(gpa, bytes, refusal) DecodeError!DecodedScore`
  runs the full validated chain (`parseDirectory` → `decodeTransport` →
  `decodeRegistry` → `decodeRecords` → `decodeEaseControls` →
  `decodePayloads`), assembles one arena-owned `DecodedScore` (payload
  copies zipped into the `expr`/`pattern` arms, `'EMIT'` folded into the
  transport, the `'PACM'` blob copied once, `required_features` carried
  for the future stages, no AST anywhere) and closes with the PACM
  coherence cross-check: `pacm_fnv` fast reject ⇒ `meta_incoherent`,
  `Pacm.decode` structural ⇒ `meta_malformed`, then
  `verifyRouting(&view, &score) ?RefusalCode` — resident in `Pacb.zig`
  per the focused ruling (the plan's T2.7 signature spelling was a wrong
  premise: `Pacm` stays std-only; tracked-plan correction recorded by
  T4.4). `verifyRouting` compares transport scalars, counts, per-track
  identity, the per-source key-range rule (B1/G9: keys ⇒ equality;
  expr/trigger/pattern ⇒ `(0,0)` — `src/Abi.zig:437-440`'s own
  spelling, never compared against a real `'TICK'` slice), key content,
  control identity/values, the shared scene fields, and
  `'EASE'`/`'TMPO'` presence + content; documented spans/source strings
  are trusted, never cross-checked; a missing required `'PACM'` refuses
  `non_canonical`. OWNERSHIP is a clean transfer, not a copy chain:
  `decode` creates the score's arena first and hands its allocator to
  every stage as that stage's `gpa`, so each sub-arena allocates inside
  memory the returned score already owns — the stage structs die at
  return with their memory retained, no stage arena can outlive
  `score.deinit()`, and the errdefer chain releases everything on any
  refusal. Tests are REAL: each compiles a fixture score through
  `test_support.schema()`, embeds `Abi.encodeMeta`'s own PACM, mirrors
  every section from the same result (the T3.1 encoder's test-side
  twin), mutates single PACM fields with the fnv repointed per
  predicate, and proves ownership by `@memset(input, 0xAA)` before any
  read — then `Expr.evalBinary` over the decoded payload vs the text
  path (`ExprTrack.evalAt`) at tick 0 plus the inline key-segment math
  at two interior ticks (O-b rescope: no `Evaluator` is constructed
  from decoded bytes — impossible without a `CompileResult`). RED
  evidence (strict vertical): (1) genuine missing-API compile error
  (`use of undeclared identifier 'decode'` ×3); (2) with the assembly
  wired but no PACM check, 408/420 with exactly the 12 coherence tests
  failing `WronglyAccepted`; GREEN after the checks: `zig build test`
  **420/420 (359 root + 61 CLI)**. Two test-fixture defects were
  corrected during RED (absolute-vs-relative PACM patch offsets; the
  integer-tagged `.toF64()` widening) plus two literal corrections
  (scene `:dur 2bar`; track records indexed by kind — compile emits
  top-level tracks, then scene children, then triggers).
  `zig fmt --check` clean; `zig build verify` **15/15 steps, 359/359
  tests, corpus 37/0 failed, node parity 93/0, cli-golden and
  score-docs current**; `zig build fuzz` **5/5, 219/219** (the existing
  text harness — the never-panic PACB fuzz harness is T4.2, not
  claimed here). The tree-trailing-comments KNOWN GAP is unchanged and
  still deferred to the owner (SJON cross-repo edit vs approved
  narrowing); only the flag-combo acceptance fixture rides with it. No
  encoder, `pack` CLI, runtime, npm, or wire-format change; corpus and
  CLI goldens byte-identical.

### Phase 3 — T3.1 (encoder core, landed 2026-10-19)

**T3.1 `src/PacbEncode.zig` — the encoder core + round-trip.**
`encode(gpa, result, host_targets)` (precondition `result.ok()`, error
set `error{OutOfMemory}` alone — the v1 caps preflight is T3.2's)
mirrors one `Compile.CompileResult` + the actual host join into the
canonical container; `fnv1a64` is the public checksum spelling. All 14
sections emit in the frozen order with the frozen presence/omit rules
(degenerate `'EASE'`/`'TMPO'`/`'REGS'`/`'DECL'`/record sections
omitted; `'TRAN'`/`'PACM'` always); the directory is contiguous,
gap-free, exact-end, and the zero-filled output keeps every
pad/reserved byte zero. `'DECL'` is `result.targets[host_targets.len..]`
(A22) while `'REGS'` carries the canonical `'PACT'` of the ACTUAL
passed host list (empty ⇒ the zero-count spelling `'TRAN'` checksums);
`'EASE'`/`'TMPO'` are sliced verbatim out of the ONE `Abi.encodeMeta`
pass whose blob is embedded whole (pinned on the wire: the sections
byte-equal the embedded PACM's own TLV payloads); expr/pattern
payloads are `cloneNode` into a one-root tree + `toBinary(.compact)`
(A29) — no shadow evaluation anywhere, the table's own AST only.
`Pacb.strsEntryLess` went public so the encoder sorts `'STRS'` with
the decoder's own comparator (one definition of the order); the
encoder additionally imports `Pacm` (std-only leaf) to reuse its TLV
walk for the verbatim slices rather than duplicate it. Tests (7
vertical RED→GREEN behaviors + 2 pin blocks, 9 new tests): the
missing-module compile error; transport-only, keys-only,
expr+keys (payload byte-oracle + `Expr.evalBinary` at t=0 ≡ text-path
`ExprTrack.evalAt`, same env, same `[4]f32`),
trigger/scene/control/emit, tempo-mapped (EASE/TMPO verbatim pins),
and declared-join (incl. the host-mix case) round-trips — each with
exact table parity and pack-twice byte-equality; the pattern-track
test PASSED IMMEDIATELY as a pin (the payload path treats expr and
pattern uniformly by design — no manufactured RED; NO pattern
evaluation parity is claimed, T3.2's preflight owns refusing pattern
scores until the runtime wave lands the SJON env); wire-pin blocks
assert the header literals, per-record zero pads, and FNV-1a-64 known
answers. Two fixture defects were corrected during RED (a scalar expr
on a 3-comp target — `expr_result_invalid`; `:every` needs its unit)
plus two implementation defects caught by already-green tests
(sorting sections by the enum's 4-CC value put `'PACM'` before
`'TRAN'`; a stale-frame error trace sent the first investigation
astray until a diagnostic print isolated the real failure). RED
evidence and commands: `.agent/control/binary01-t31-red{1..7}.log`,
GREEN + pins: `binary01-t31-green{1..7}.log`, `-pins.log`; gates:
`zig build test` **429/429 (368 root + 61 CLI)**, `zig fmt --check`
clean, `zig build verify` **15/15 steps, 368/368 tests, corpus
37/0 failed, node parity current, cli-golden + score-docs current**,
`zig build cli-golden` **4/4**, and `git diff --exit-code` empty for
`corpus`/`src/cli/testdata` plus zero drift vs `90dc758` over
corpus/CLI/docs/npm. The decoder's independently assembled test
fixtures are untouched (only `strsEntryLess` visibility); no T3.2
classifier/preflight codes, no CLI/runtime/npm/sibling change.

### Phase 3 — T3.2 (pack refusals, landed 2026-10-19)

**T3.2 `src/PacbEncode.zig` — head-walk position classifier + pack
refusal codes + the caps preflight.** `collectCallHeads(gpa, tree,
node)` is the position classifier over the validated AST: every eval
position (root, vector elements, `if`/`cond`/`and`/`or` branches,
`let` binding values + body, binder `xs`/`init`/`body`, call
arguments, kvpair VALUES) contributes its head in source order; name
positions (let binding names, binder vectors, kvpair keys) never do.
The walk mirrors `scheduleForm`/`scheduleFormBinary` exactly,
including the scheduler's own abort order: a special form whose shape
would raise at schedule time (arity, binder shape, kvpair slots)
contributes NOTHING — the subtree is dead on both paths — and later
`cond`/`and`/`or` slots cut at the first kvpair (the error raises
when the lazy walker reaches it, killing everything after; `let`
needs no cut: kvpairs cannot appear inside vectors, the parser's
rule, so a binding value is never one). Iterative (a worklist, like
the evaluator's own frame machine), never-pruning, spans attached at
every head. `preflight(gpa, result, diags)` — precondition
`result.ok()`, `encode`'s twin — classifies every expr track's heads
and refuses through the FULL-outcome compare (I1/G11): each distinct
(namespace, head) resolves through BOTH `result.eval_schema` AND the
frozen comptime core-only binary schema; pack-clean iff found-in-core
with identical (plugin, func) identity — func-pointer equality over
the shared static declaration — with `.ambiguous` through
`eval_schema` refusing even when binary-found (a user plugin
redeclaring `sin` in an untaken branch), `.found` in a user plugin
refusing, and not-found-in-both the legal form-as-data literal.
Pattern tracks refuse loudly (`pack_patterns_unsupported`, interim
until 02 P4) while `encode` keeps serializing underneath. Caps are
MEASURED, never assumed (risk E2): per-payload bytes against
`MAX_PAYLOAD_BYTES` (the exact bytes `encode` would emit — compact IR
can exceed source text), the `'PAYL'` total against `MAX_PAYL_BYTES`,
and the global explicit-tick count against `MAX_TICK_ENTRIES` (the
131073-entry native-band score compiles clean on the deliberately
uncapped text path and refuses with the measured count; the exact-
boundary 131072 score packs AND decodes — the decoder's `>` is the
same comparison over the same total). Three `Compile.Code` variants
appended (`pack_user_expr_unsupported` 31, `pack_patterns_unsupported`
32, `pack_cap_exceeded` 33) with the comptime tail pin — ordinals
0..30 untouched, corpus/CLI goldens byte-identical. Tests (5 vertical
RED→GREEN behaviors, 11 new tests): the missing-export compile errors
(classifier; preflight+code) then semantic REDs (`expected 1, found
0`) for pattern/payload/total/tick; refusals cover the time-guarded
result branch, short-circuit tail, untaken `if` branch, vector
element, untaken `cond` value, empty-fold body, let-binding value,
namespace-qualified user head, and the ambiguous `sin` redeclaration;
the acceptance set pins vector elements, let names colliding with
`sin`/`u`, binder vectors `[u]`/`[u acc]`, kvpair keys, form-as-data,
and qualified `core/let` (found-both, identical — the core plugin's
impl-null special-form markers). RED evidence: `.agent/control/
binary01-t32-red{1..5}.log`, GREEN: `-green{1..5}.log`; gates:
`zig build test` **440/440 (379 root + 61 CLI)**, `audit-diagnostics`
**34/34** (each pack code asserted by name in a real refusal test),
`zig build verify` **15/15 steps, corpus 37/0 failed, node parity
current, cli-golden + score-docs current**, `zig build cli-golden`
**4/4** with `git diff --exit-code` empty over `corpus`/
`src/cli/testdata` and zero drift vs `90dc758` over
corpus/CLI/docs/npm. Out-of-scope finding reported (not fixed here):
a bare unitless number in a `time-pos` slot (`:at [1 2]`, `:dur 4`)
passes schema validation and then PANICS in `posToTickLocal`'s
`std.debug.assert(unit == "s")` — a user-input assert, violating the
house diagnostics rule; the tick fixture therefore uses the honest
`1b 2b …` grammar. No CLI/runtime/npm/sibling change; the CLI
preflight wiring is T3.3's.

### Phase 3 — T3.3 (CLI `pacer pack` verb, landed 2026-10-19)

`src/cli/Pack.zig` + the `Args`/`Cli` wiring: the verb, the
`--targets-json` adapter, the self-check, the atomic write, the golden,
and three byte-stability fixtures. `pacer pack FILE [--out F]
[--targets-json R]` compiles the score, runs `PacbEncode.preflight`
BEFORE `encode` (refusals ride `diagnostics` as ordinary pacer records —
exit 1, `pack:null`, nothing written), encodes, self-checks, writes, and
only then reports. The report: `pack = {out, bytes, sections,
targets:{host,declared}, pacm_bytes}` read off the landed bytes. Blob
never on stdout; default `--out` = score path with `.pacb` (last
extension swapped); stdin requires `--out` (usage exit 2 — deriving
`-.pacb` from `-` would silently hand the verb a stdin read); `--out -`
and empty refused; unwritable `--out` = usage exit 2 with zero stdout
bytes; self-check failure = exit 3 with nothing written.

The adapter is `std.json` over the `getUniforms` dump replicating
`buildJoin` rule-for-rule (twelve bare WGSL spellings → lanes,
`elemCount` non-zero skips, unknown type skips, registry 0, file order
IS the target_id space, names never mined from score text). The plan's
"parse via `sjon.Json`" is satisfied by the same `std.json.Value`
surface `sjon.Json` itself sits on top of — `fromJson` REJECTS plain
JSON objects (`{"$form": …}` tagged only), so it cannot read a
reflection dump; recorded as the A56 reading.

The self-check is real, not decode-presence: `Pacb.decode` own output,
field-for-field table parity (transport scalars bit-equal, tempo
segments, emit lanes, track identity + per-source routing, keys'
position/program-ref/lane bits, control identity/values/rails, scene
windows, declared tail arity/registry), canonical `'REGS'` re-encode of
the actual host join, feature word, and the embedded `'PACM'`
byte-equals a FRESH `Abi.encodeMeta` pass over the same result. Write =
`<out>.tmp` beside the destination then rename; report after.

Fixtures `tools/testdata/pacb/{keys-only,expr-keys,full-small}`:
`.score.sjon` + `.pacb` pairs generated by the REAL CLI
(`zig build run -- pack … --out …`, the canonical producer — 3700/3630/
6069 bytes, 6/7/12 sections), with `PacbEncode`'s byte-stability test
re-packing all three in-process and byte-comparing (cross-process
determinism anchored in the repo). Golden `src/cli/testdata/
starter-pack.json`: the starter `:pattern` refusal envelope (existing
goldens byte-identical). `docs/cli.md` pack section; README layout row.

Interrupted-run recovery note (2026-10-19): the first full-gate run of
the in-flight C3 work hung 22 min in the CLI test child. Root cause,
positively reproduced: `Args` failed to refuse `pacer pack -` without
`--out` (it derived `-.pacb`), so the in-process test reached
`Source.load`'s stdin branch — `Io.File.stdin()`, the REAL fd, which
under `zig build test` is the build runner's never-closing protocol
pipe. Fixed at the source (the usage refusal the code comment already
intended); no test weakened. Recovery report:
`.agent/control/binary01-t33-recovery-report.md`.

Gates at land: `zig build test` **463/463** (380 root + 83 CLI),
`verify` **15/15** steps green incl. corpus 37/0 + cli-golden diff
empty, `audit-diagnostics` **34/34** (no new codes — 31–33 were T3.2's,
already audited), `zig fmt --check` clean; corpus, npm and the
generated `docs/score-language.md` byte-identical to the task base
`c8b08b5` (diff-verified; that base was itself zero-drift vs
`90dc758`). Known T32 time-pos assert finding
remains open, owner-notified (unchanged by this task).

- **2026-10-19 — Phase 4 complete (T4.1–T4.4).** T4.1:
  `audit-diagnostics` green on entry (**34/34, Missing: 0** — no
  uncovered code, so no by-name test was manufactured and no commit
  was made, exactly the plan's "only if changes needed" branch). T4.2:
  the never-panic decode fuzz harness — RED was the genuine
  missing-module compile error (`src/fuzz_pacb.zig: FileNotFound`,
  wired by one import + one delegating test in `src/fuzz.zig` BEFORE
  the file existed — the G12 shape, not a fabricated missing-export
  seam), GREEN `zig build fuzz` **5/5 steps, 347/347**. The harness
  asserts only arbitrary-input invariants (`Refused` ⇒ refusal
  well-formed with `offset` inside the buffer; success ⇒ cap-bounded
  tables + the ownership no-alias contract + clean `deinit`; no panic;
  no leak) over raw Smith bytes AND structured mutations of the three
  committed fixtures (byte flips, truncations, cross-fixture splices,
  count-field inflation drawing 131073 / `u32` max / drawn values —
  directory exactness answers these with `count_mismatch`; the
  past-cap `cap_exceeded` branches proper stay unit-pinned in
  `Pacb.zig`), budget 16 KiB ≥ fixture + splice slack. Positive
  control: the three REAL-CLI fixtures decode clean. No parser bug
  surfaced — no regression RED, no `Pacb.zig` change, no fuzzer
  weakening. Gates after code: `test` **463/463**, `verify` **15/15**,
  `fuzz` **347/347**, `audit` **34/34**. T4.3: `docs/binary-score.md`
  created as the format of record (layout, frozen constants/ordinals,
  caps + the `MAX_TICK_ENTRIES` derivation, the folded-tick envelope,
  canonical presence/defaults, validation summary, structural
  consumption + the KNOWN tree-trailing gap stated as interim state
  (owner decision pending, not an accepted contract), the PACM trust
  model with its exact checked-surface claim, the core-expr capability
  set under the full-outcome head-resolution rule, the producer
  section incl. the explicit-prototype `pack_patterns_unsupported`);
  `CLAUDE.md` gained the `'PACB'` wire-table row (data at rest,
  append-only, `VERSION` bumps breaking) with the one distinguishing
  sentence. T4.4 (the corrections record) lands as this entry's
  companion commit. **Plan 01 closes QUALIFIED, not silently
  complete**: the tree-trailing flag-combo acceptance criterion is
  known-failed as shipped and stays an explicitly deferred owner
  decision (KNOWN-GAP test pins the current refusal; the packer never
  emits such a payload, so `pacer pack` output is unaffected); the
  broad post-wave review is also pending. Next: plan 02
  (binary-runtime) — P1 `EvalCore` layering; P4 pattern support stays
  gated on the same owner decision.

- **2026-10-19 — T4.4 wave-plan corrections record (tracked-docs only;
  no source, no other tracked file).** This entry IS the record (G14).
  Body corrections applied above, each with its source evidence:
  1. Validation, records bullet — `scene` bound is the actual `'SCEN'`
     count, not `MAX_SCENES` (`src/TrackTable.zig:25` invariant;
     compile assigns structurally `< scenes.len`,
     `src/Compile.zig:965`); `'EMIT'` gains count ≤ 5 + unique name
     ordinals + scalar joined entry (`src/Eval.zig:184-186`;
     R-optional 5); controls gain `type` ordinal ≤ 2
     (`src/TrackTable.zig:195`) and env-only `ncomp ∈ 1..4`
     (`:212-214`); the counts sentence gains the global `'TICK'`
     count ≤ `MAX_TICK_ENTRIES`.
  2. Embedded-PACM cross-check — the per-track `key_start/key_len`
     comparison is PER SOURCE: keys equal; expr/trigger/pattern
     compare `(0,0)` (`src/Abi.zig:437-440`; B1/G9 — the literal
     per-track equality this plan carried would refuse every valid
     explicit-trigger score).
  3. Producer refusal rule — "found in both ⇒ identical" replaced by
     the full-outcome identity compare (I1/G11;
     `SJON/src/Schema.zig:143-168` → `error.AmbiguousFunction`,
     `SJON/src/Expr.zig:2854`).
  4. Caps — `MAX_TICK_ENTRIES = 131072` with the producer derivation
     (256 KiB wasm doc zone ÷ ≥ 2 source bytes per literal `:at`
     element, summed globally; conservative, not claimed tight;
     native-band refusal at pack with the measured count; text path
     uncapped) (G6/I2).
  5. Transport/triggers wording — the folded-tick envelope (G-bis
     R1/R2, architect-ruled; T24 ruling 2 OVERTURNED): scened fields
     `|v| ≤ 2·MAX_TICK` inclusive, `trig_every` ∈ 1..MAX_TICK,
     transport ticks ≤ MAX_TICK unchanged.
  6. `plans/binary/README.md` — the "full SJON CLI unavailable" prose
     corrected: only the plugin-exec (libwasmtime) build is
     unavailable; the plugin-exec=false CLI builds from the path dep
     and runs on obs (`build.zig`'s `verify` score-docs leg) (A52/G14).
  Cross-referenced, already recorded at their owning sites and NOT
  rewritten here: the T3.3 `--targets-json` adapter premise ("parse
  via `sjon.Json`") — `sjon.Json.fromJson` maps SJON-tagged objects
  and rejects plain ones, so the adapter consumes the same
  `std.json.Value` surface natively (`src/cli/Pack.zig` module
  header); `verifyRouting`'s resolved placement in `Pacb.zig`, not
  std-only `Pacm` (`src/Pacb.zig:2246`, focused ruling); the T3.1/T3.2
  false premises of §G-ter (recorded there). The
  tree-trailing-comments KNOWN GAP is NOT claimed resolved by this
  record — it stays an owner decision (SJON `RootIter`
  exhaustion-consume vs approved narrowing), pinned by the KNOWN-GAP
  test as interim state, not an accepted contract. Gate:
  `zig build verify` green (15/15; docs-only change, score-docs leg
  unaffected), diff reviewed.
