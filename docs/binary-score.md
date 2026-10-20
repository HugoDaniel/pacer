# `'PACB'` — the compiled-score container

> Hand-written format of record for the `'PACB'` container and its producer
> `pacer pack` (binary wave 01). Convention of record for the decoder:
> [`src/Pacb.zig`](../src/Pacb.zig)'s module header; for the reader of the
> embedded metadata: [`src/Pacm.zig`](../src/Pacm.zig); for the encoder:
> [`src/PacbEncode.zig`](../src/PacbEncode.zig). Every constant on this page
> is restated from that code — where this page and the code disagree, the
> code is the truth and this page is stale.

A `'PACB'` file carries one compiled score: the transport truth, the
target-registry identity, the track/key/trigger/control/scene rows, the
expression/pattern payloads, and the `'PACM'` metadata blob — all in one
versioned, validated, little-endian container. It is **data at rest**, not a
wasm-boundary blob: it is written offline by `pacer pack` and read by the
playback runtime (plan 02). Every field is packed with explicit read/write
calls; there is no implicit struct padding or alignment on the wire, and
every reserved/pad byte is zero.

## Layout

```
[magic u32 'PACB'][version u32 = 1][required_features u32][section_count u32]
section_count × { id u32, off u32, len u32 }        ; off from buffer start
```

* `magic` = `0x42434150` (`"PACB"` little-endian).
* `version` = `1`. A breaking layout change bumps it.
* `required_features`: bit0 = at least one `:pattern` track is present.
  All other bits are reserved and MUST be zero; the decoder refuses
  unknown set bits (`unsupported_features`). Bit0 is cross-checked
  against the track table both directions (`non_canonical` on a lie).
* `section_count` ≤ 14 (the canonical table below); a directory naming
  more sections than exist kinds refuses.

The directory is **exact, not merely well-formed**: it begins immediately
after the 16-byte header (`off[0] == 16 + 12 × section_count`), sections
are contiguous and gap-free (`off[i+1] == off[i] + len[i]`), ids are
unique, present sections appear in the fixed canonical order below, and
the buffer ends exactly at the last section's end — no gaps, no
inter-section slack, no trailing bytes. A present fixed-width section's
payload is exactly `[count u32] + count × record width`; `'TRAN'` is one
56-byte record with no count. Variable-width sections validate their own
lengths in the decoding stage that owns them.

### Canonical order and record widths

| 4-CC | id (LE u32) | Payload |
|---|---|---|
| `'TRAN'` | `0x4e415254` | 56 B singleton (no count): `bpm f64`, `beats_per_bar i64`, `dur i64` (0 when absent), `flags u8` (bit0 dur present, bit1 end is loop) + pad×7, `host_targets u32`, `declared_targets u32`, `pact_fnv u64`, `pacm_fnv u64` |
| `'REGS'` | `0x53474552` | `[byte_len u32]` + the canonical `'PACT'` bytes of the pack-time host join |
| `'DECL'` | `0x4c434544` | `[count u32]` + count × 4 B `{ registry u8, ncomp u8, pad u16 }` — declared-only targets in pack-join order (indices continue the host join; declared names never cross the wire) |
| `'EMIT'` | `0x54494d45` | `[count u32]` + count × 8 B `{ name u8 (EmitName ordinal), registry u8, target_id u16, reserved u32 }` |
| `'TMPO'` | `0x4f504d54` | `[count u32]` + count × 16 B `{ tick i64, bpm f64 }` — the `'PACM'` `'TMPO'` record verbatim, segment 0 included |
| `'TRAK'` | `0x4b415254` | `[count u32]` + count × 40 B `{ target_id u16, registry u8, ncomp u8, source u8, trig_kind u8, scene u16, key_start u32, key_len u32, payload_off u32, payload_len u32, trig_every i64, trig_offset i64 }` |
| `'KEYS'` | `0x5359454b` | `[count u32]` + count × 28 B `{ at i64, value f32×4, ease_ref u16, pad u16 }` |
| `'TICK'` | `0x4b434954` | `[count u32]` + count × `i64` — the concatenation of every explicit-trigger schedule; each scoping track slices it by `key_start/key_len` |
| `'EASE'` | `0x45534145` | the `'PACM'` `'EASE'` payload verbatim: `[program_count u32]` + 772 B programs + `[key_ref_count u32]` + `u16` refs in key order |
| `'CTRL'` | `0x4c525443` | `[count u32]` + count × 60 B `{ target_id u16 (0xffff env-only), registry u8, ncomp u8, type u8, flags u8 (bit0 min, bit1 max), id_off u32, id_len u16, value f32×4, min f32×4, max f32×4 }` |
| `'SCEN'` | `0x4e454353` | `[count u32]` + count × 16 B `{ start_tick i64, dur_ticks i64 }` |
| `'STRS'` | `0x53525453` | `[count u32][byte_size u32]` + entries `[len u16][bytes]` — control ids, sorted by (len, bytes), unique, none reserved by the expr language |
| `'PAYL'` | `0x4c594150` | `[byte_size u32]` + concatenated SJON binary-IR buffers (`"SJ1\n"`, `wire_version 0x05`), each single-root; tracks address `(payload_off, payload_len)` into it |
| `'PACM'` | `0x4d434150` | the metadata blob, encoded offline by the unmodified `Abi.encodeMeta` |

The section-kind set is **wire-stable and append-only**: a new kind
appends; a breaking change to an existing payload mints a fresh id —
never reorder, remove, or retag. The canonical order above is frozen.

### Frozen ordinals (copied constants, not live references)

* track `source`: 0 keys / 1 expr / 2 trigger / 3 pattern — copied from
  `'PACM'`'s `MetaTrackRec` values (`src/Abi.zig`), test-asserted against
  the source enum via `src/root.zig`.
* `EmitName`: 0 beat / 1 bar / 2 phase / 3 bpm / 4 t — the enum order in
  `src/TrackTable.zig`.
* `trig_kind`: 0 periodic / 1 explicit.
* `Easing.Op`: u8, 22 variants (0..21) — `src/Easing.zig` is the
  authority; decode refuses any other byte (`ease_invalid`).
* control `type`: 0 slider / 1 xy / 2 color (`TrackTable.ControlType`);
  a byte > 2 refuses (`control_invalid`) — constructing the enum from a
  wider byte would be a decoder trap, so decode pre-empts it.

Per-source reads: keys → `key_start/key_len` into `'KEYS'`; expr/pattern
→ `payload_off/len` into `'PAYL'`; periodic trigger → `trig_every > 0` +
`trig_offset`; explicit trigger → `key_start/key_len` into `'TICK'`.
Every per-source unused field MUST be zero (`trig_every`/`trig_offset`
zero for keys/expr/pattern; `payload_off/len` zero for keys and periodic
triggers; `key_start/len` zero for expr/pattern).

## Canonical presence and defaults

One rule everywhere: **the packer always omits the degenerate form of a
section, and the decoder refuses it when present** — one score, exactly
one byte encoding:

* `'TRAN'` and `'PACM'` are REQUIRED (`non_canonical` when missing).
* `'REGS'` iff the host join is non-empty; `'DECL'` iff declared targets
  exist; `'EMIT'`/`'TRAK'`/`'KEYS'`/`'TICK'`/`'CTRL'`/`'SCEN'`/`'STRS'`/
  `'PAYL'` iff they carry ≥ 1 record; `'TMPO'` iff the tempo map has
  more than one segment; `'EASE'` iff the program table is more than the
  shared linear default.
* `'EASE'` absent ⇒ the program table is exactly the synthesized linear
  default (`Easing.primitive(.{ .code = .linear })`), every `ease_ref`
  is 0; present ⇒ `program_count ≥ 2` and program 0 is linear.
* `'TMPO'` absent ⇒ one constant segment `{tick 0, 'TRAN'.bpm}` — the
  constant map path, byte-for-bit the pre-map behavior.
* `'KEYS'` iff a keys track exists; `'TICK'` iff an explicit-trigger
  track exists; `'PAYL'` iff an expr/pattern track exists —
  cross-section presence is checked, not implied.

## Validation summary (decode refuses, never guesses, never traps)

Refusals are one append-only `u16` reason stream plus the offset where
the defect was detected (`Refusal { code, offset }`; the offset is
diagnostic, never aliased): `bad_magic`, `unsupported_version`,
`unsupported_features`, `directory_malformed`, `count_mismatch`,
`transport_invalid`, `tempo_invalid`, `record_invalid`, `key_invalid`,
`ease_invalid`, `trigger_invalid`, `scene_invalid`, `control_invalid`,
`strs_invalid`, `payload_malformed`, `cap_exceeded`, `registry_mismatch`,
`decl_invalid`, `non_canonical`, `meta_malformed`, `meta_incoherent`.

Highlights, by area (the owning stage in `src/Pacb.zig` is exhaustive):

* **Registry identity** — byte equality of the canonical `'PACT'`
  encoding: ordered `(name, registry, ncomp)` triples, so a same-shaped
  ordered name swap, reorder, arity change, or count change all refuse.
  `pact_fnv` (FNV-1a-64, in `'TRAN'`) is a fast reject that must agree
  with the byte compare. Every `target_id` in `'TRAK'`/`'CTRL'`/`'EMIT'`
  is < `host_targets + declared_targets`, with `(registry, ncomp)`
  matching the host join or the `'DECL'` record; an `'EMIT'` lane's
  joined entry must be scalar (`ncomp == 1`).
* **Transport domains, before any `TimeMap` call** (its contract is
  asserts): `bpm` finite and 1..1000; `beats_per_bar` 1..16; `dur` in
  1..`MAX_TICK` when the present-flag is set (0 behind a clear flag);
  `'TMPO'` ascending, `[0] == {0, 'TRAN'.bpm}`, per-segment bpm finite
  1..1000, count ≤ 512; `:end loop` requires `dur`.
* **Tick envelope** — the widest tick-domain value any decoded field may
  carry splits by fold: scened fields (keys `at`, periodic
  `trig_offset`, explicit `'TICK'` entries) are one checked i64 add of a
  scene start (|v| ≤ `MAX_TICK` = 2⁵³, the pattern grid bound) and a
  local position (|v| ≤ `MAX_TICK`), so their envelope is exactly
  **±2·MAX_TICK inclusive** — 2·MAX_TICK itself is compile-reachable
  (scene start MAX_TICK + local MAX_TICK) and accepted. Unfolded fields
  keep the plain grid bound: `trig_every` ∈ 1..MAX_TICK (never
  scene-folded), transport `dur` and `'TMPO'` ticks stay ≤ MAX_TICK. A
  comptime pin keeps 4·MAX_TICK < maxInt(i64) so every eval-side
  subtraction stays comfortably inside i64.
* **Records** — counts ≤ the caps table (256 tracks / 4096 keys / 128
  programs / 64 controls / 64 scenes / 512 tempo segments / 5 emit
  lanes / 1024 targets); `ncomp ∈ 1..4`; `scene` is `0xffff` (NO_SCENE)
  **or a valid index into the actual `'SCEN'` count** (the table
  invariant the evaluator leans on — not the cap, the real row count);
  `'EMIT'` count ≤ 5 with **unique** name ordinals; keys per keys-track
  ≥ 1, `at` strictly ascending, `'KEYS'` runs per track non-overlapping;
  `'TICK'` slices non-overlapping and schedules strictly ascending;
  value lanes ≥ ncomp zero; scene `start_tick + dur_ticks` checked-add.
* **Easing** — per program `len ∈ 1..8` stages, `ops_len ∈ 0..4`, t_end
  strictly increasing, all floats finite, op bytes within the frozen set,
  unused slots normalized to zero on copy; `'EASE'` refs are elementwise
  `refs[i] == keys[i].ease_ref`; `key_ref_count == 'KEYS'` count.
* **Controls** — ids unique, non-empty, not expr-reserved, present in
  `'STRS'`; min/max flag set ⇒ lanes finite (clear ⇒ zero); env-only
  controls use `target_id == 0xffff` with `ncomp ∈ 1..4` (no join entry
  exists to check them against); `type` ordinal ≤ 2.
* **Payloads** — the structural-consumption rule below, plus per-payload
  and total caps.

## Caps (v1 binary-format resource policy, frozen)

| Cap | Value | Scope |
|---|---|---|
| `MAX_PAYLOAD_BYTES` | 256 KiB | per expression/pattern payload |
| `MAX_PAYL_BYTES` | 4 MiB | total `'PAYL'` bytes |
| `MAX_TICK_ENTRIES` | 131072 | global explicit-trigger entries |

These are **proposals-with-rationale**, measured format policy, not
source constants and not mathematical claims: a subtree's compact IR CAN
exceed the text it was packed from (per-node record overheads mean
payload size scales with node count), so caps are enforced with the
measured size in the refusal — never assumed. `pack_cap_exceeded`
carries the measured size (payloads) or count (ticks).

**`MAX_TICK_ENTRIES = 131072` — derivation.** The wasm artifact's static
document zone is 256 KiB (`MAX_DOC_SIZE`, `src/wasm_entry.zig`), which
bounds every wasm-compilable score text. Explicit `:at` entries are a
direct literal vector in the track form — the grammar offers no sharing
or repetition construct that could spell N entries in fewer bytes than
their literal list — and each entry costs at least 2 source bytes
(shortest atom plus separator, amortized). The **global** sum of
explicit `:at` entries across **all** tracks of any wasm-compilable
score is therefore ≤ 256×1024/2 = **131072** (worst-case `'TICK'`
section ≈ 1 MiB). This is a conservative producer bound, not a claim
that the encoding is tight. Native-CLI sources in the 256 KiB–1 MiB
band and direct-API compiles can exceed it: `pacer pack` refuses loudly
with the measured count (`pack_cap_exceeded`). The text compile path
itself stays uncapped — this is a v1 binary-format resource policy
only.

`pacbWorstCase()` (in `src/Pacb.zig`, the `metaWorstCase` pattern)
derives the whole-file input-zone bound once, as comptime arithmetic
restating this table.

## The tick grid and the meter denominator

Ticks are exact integer positions on the `PPC = 720720` grid; seconds
conversions are the single documented f64 seam in `TimeMap`, rebuilt at
decode in the compile's own op order (`loop_secs` recomputed once from
the map, bit-equal to the text path). `'PACB'` carries **only**
`beats_per_bar`: the meter denominator is schema-validated display
truth that the compiled table never represents (compile reads meter
component 0 only), exactly as `'PACM'` already does — intentionally
unrepresented, not lost.

## Payloads — structural consumption

Each expr/pattern payload is a standalone SJON compact binary-IR buffer
produced at pack by `cloneNode` into a one-root tree + compact
`toBinary`. At decode, each passes `BinaryCursor.Cursor.init`
(header/pool/roots-offset equality — which already rejects slack between
pools and roots), must have exactly one root (the `MultipleRoots` rule),
and is consumed by a **full structural walk over every node** —
depth-first through the cursor's child/vector iterators, the same
primitives `PatternQuery.compileBinary` uses — which (a) decodes every
node kind and exact payload width, covering branches an evaluation
would not visit, and (b) must end at exactly `payload_len` (trailing
slack inside a payload refuses). This is a syntax-level walk over SJON's
own cursor, not a second interpreter. Spans and comments never influence
acceptance — they are structural bytes the walk sizes and skips.

> **Known gap, owner decision pending.** SJON's `RootIter` does not
> consume the tree-trailing comments block on exhaustion (unlike its
> sibling iterators), so a payload emitted with
> `with_tree_trailing_comments` currently refuses as
> `payload_malformed`. The owning fix is an SJON-side `BinaryCursor`
> change (a purely additive decoder capability, zero wire-format
> change); the cross-repo edit ask timed out with no answer, so the
> refusal is pinned by a KNOWN-GAP test as the **interim state — not an
> accepted contract**. Every other flag combination walks and accepts.
> Until the owner decides, a packer that could emit such a payload does
> not exist in this repo (the packer emits compact, span-free IR), so
> the gap is unreachable from `pacer pack` output.

## Embedded `'PACM'` — the trust model

`'PACB'` is a **producer-authored, host-served asset**; the operative
truth at runtime is the PACB sections, and `'PACM'` is embedded verbatim
at pack and served verbatim to JS — but only after `src/Pacm.zig`, a
std-only runtime-side reader (the encoder stays compiler-side and never
enters the runtime closure), has validated it at decode:

### The `'SNAM'` scene-name section

Appended to the `'PACM'` section stream after `'TMPO'` (2026-10-20, the
source-free metadata wave — plans/binary/05). Id `"SNAM"` LE
(`0x4D414E53`); payload `[count u32]` then `count × { name_len u32,
name bytes }`, where `count` MUST equal the `'SCEN'` count and the
entries run in scene order. The bytes are the verbatim source-symbol
bytes of each scene's `:name` — carried **exactly**: no per-name cap,
no truncation, no drop, no empty fallback; `name_len = 0` means a
genuinely empty name span, never a degrade. Names are non-overlapping
slices of one source document, so the aggregate is bounded by that
document's size (`Abi.MAX_DOC_SIZE` = 256 KiB; the static worst-case
term in `Abi.metaWorstCase` / the frozen copy in
`Pacb.pacmWorstCase`). The section is OMITTED when the scene count is
0, so a sceneless blob stays byte-identical to its pre-`'SNAM'`
encoding. Decoders (Zig and JS) that predate the section skip it by
TLV length; bound-checking only, never name re-validation.

1. **Structural read of the whole blob** — magic/version, every record
   width, the post-controls TLV section stream walked to EXACT
   end-of-buffer, span pairs ordered (`end ≥ start`), transport domains
   — so a consumer never receives bytes the format would choke on.
2. **Routing coherence, field by field** (`Pacb.verifyRouting`, resident
   in `Pacb.zig` per the focused ruling — not in std-only `Pacm`):
   transport scalars, track/key/control counts, per-track
   `(target_id, registry, ncomp, source)`, key content, control
   identity/values, shared scene fields, and `'EASE'`/`'TMPO'`
   presence + content, each compared against the decoded sections. The
   **per-source key-range rule**: a keys track's PACM
   `key_start/key_len` IS the `'TRAK'` fields; every other source's
   meta range is the constant `(0,0)` — `Abi.encodeMeta`'s own spelling
   for non-keys sources — and is never compared against a real `'TICK'`
   slice, which `'TRAK'` carries for an explicit trigger.
   `pacm_fnv` (FNV-1a-64, in `'TRAN'`) is the fast reject and must
   agree with the full walk.

The exact checked-surface claim: **structural safety + routing
coherence — NOT producer authentication.** A PACM that lies about
routing can only REFUSE (`meta_incoherent`), never misroute — the
never-drop/route audits keep their meaning on binary assets. Documented
spans and source strings inside `'PACM'` are trusted, never
cross-checked: the decoder has no source text, and those fields are
anchors for a consumer that does.

## The producer — `pacer pack`

`pacer pack <score.sjon|-> [--target …] [--targets-json FILE] [--out
FILE.pacb]` compiles a score and writes the container (JSON report to
stdout, blob bytes only to `--out`; atomic temp+rename write). Between a
clean compile and encode sits a **preflight** whose refusals are three
append-only `Compile.Code` variants surfaced as ordinary diagnostics
with score-coordinate spans:

* `pack_user_expr_unsupported` — the **core-expr capability boundary**
  (below).
* `pack_patterns_unsupported` — any `:pattern` track. **Interim and
  explicit prototype state**: the binary runtime's leaf schema stays
  core-only until the SJON pattern-query handoff resolves (plan 02 P4),
  so pattern tracks refuse loudly rather than silently losing behavior.
* `pack_cap_exceeded` — a measured cap breach (payload bytes, `'PAYL'`
  total, global explicit-tick count).

Before writing, the verb re-decodes its own output and checks
field-for-field table equivalence plus embedded-PACM byte-equality
against a fresh encode — any mismatch is an internal error (exit 3),
never a bad file on disk. The `--targets-json` adapter consumes a
pngine `getUniforms` reflection dump (plain JSON) through the native
`std.json` surface — `sjon.Json.fromJson` maps SJON-tagged objects and
rejects plain ones, so it cannot read a reflection file — replicating
the hello player's `buildJoin` rules (LANES f32/i32/u32→1 … vec4*→4;
skip `elemCount`-nonzero; skip unknown types; registry 0).

### The core-expr capability set

A packed expression may call exactly what the **core plugin** resolves —
nothing user-defined, nothing pattern-side. The check is not a name
list: at pack, a position classifier walks every expr track's AST
(mirroring the scheduler's dispatch shapes; untaken branches and
short-circuit tails included — nothing is pruned) and collects every
call head in eval position. Each collected head is resolved TWICE —
through the score's own `eval_schema` (core ⊕ the document's user
plugins) and through the frozen core-only binary schema — and the
**full lookup outcomes are compared**: pack-clean iff the binary schema
finds the head in the core plugin AND the text schema finds it with the
SAME (plugin, function) identity. `.ambiguous` through the text schema
refuses even when the binary schema finds the head (a user plugin
redeclaring a core name makes the bare head ambiguous on both schedule
paths). A head found in NEITHER schema is a form-as-data literal —
legal, identical on both paths, packs clean. Name positions (`let`
bindings, binder vectors, kvpair keys) are never call heads. The
capability set itself is therefore: the ten core special forms
(`let if cond and or map filter any all fold`) plus the core plugin's
`expr_funcs` table (`SJON/src/plugins/core.zig` is the authority) plus
the built-in environment — `t`, `tick`, `beat`, `bar`, `cycle`,
`phase`, `bpm`, `dur` when the transport spells it, scene-local
`scene-beat`/`scene-phase` inside a window, and every control id.
Adding a core function widens the capability set with no format
change; a user plugin's names remain text-path-only until a later
version says otherwise.

## Versioning

`VERSION = 1`. Appending a section kind or a refusal code rides a minor
release; any change to the header, the directory contract, a record
layout, or a section's own payload mints a fresh id or bumps `VERSION`
— a breaking release (see `CLAUDE.md`'s wire-stability policy; the
`'PACB'` row there is the cross-reference for this page).
