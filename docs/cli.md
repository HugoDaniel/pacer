# `pacer` — the command-line interface

> Hand-written, unlike [`score-language.md`](./score-language.md) next to it,
> which is generated from `schema/pacer.sjon`. Edit this page directly.

Ask one score a question without writing a host: what did the compiler make of
it, and what does it write at a given time?

## Build from source

The CLI is a native binary, not part of the npm package. `npm install @mr_hugo/pacer`
installs the JS/wasm runtime only. Build from the Pacer checkout with the
pinned inputs:

- Zig **0.16.0**
- sibling SJON **1.5.0 or newer** (the 0.1.0 release pin is `v1.5.0`,
  revision `97e12f39d9e63d028aa9b124660cc4cfed4cc726`)

```sh
git clone https://git.hugodaniel.com/hugo/SJON.git ../SJON
git -C ../SJON checkout 97e12f39d9e63d028aa9b124660cc4cfed4cc726
zig build cli          # → zig-out/bin/pacer
```

The same prerequisites and `zig build verify` are documented in the repo
[`README.md`](../README.md).

## Verbs

```
pacer check FILE            Validate a score; report diagnostics.
pacer ir    FILE            Print the compiled IR as JSON.
pacer eval  FILE --at SECS  Print the write frames at given times.
pacer pack  FILE --out F    Compile the score to a 'PACB' file.
```

`FILE` may be `-`, which reads stdin and labels the input `<stdin>`.

## Targets

A score's `(track :target …)` names resolve against the host's registries. Pass
them with `--target`, repeatable, where **flat order is the `target_id` space** —
exactly as a `times.sjon`'s `(target …)` sequence is:

```
--target NAME[:ncomp[:registry]]      ncomp defaults to 1, registry to 0
```

Omit them entirely for a **compose-mode** score, one that declares its own
targets with `(target :name … :arity …)`. Those compile against an empty host
registry, so `pacer ir score.sjon` works with no flags at all.

```sh
pacer ir corpus/target-declared/doc.sjon | jq .targets
```

Every target in the output carries `origin`: `host` for one you passed, `declared`
for one the score contributed. That distinction exists only natively — no wire
blob carries it.

## `check`

Human by default, one grep-stable line per diagnostic:

```
score.sjon:8:14: error: control_duplicate_id: duplicate control id `knob`
5 errors, 0 warnings
```

`--json` emits the envelope instead. Diagnostics carry the code as a **name** and
as its **wire ordinal**, plus byte offsets and a 1-based line/column:

```sh
pacer check score.sjon --target tint:3 --json | jq '.diagnostics[0]'
```

## `ir`

The compiled `TrackTable`: the merged target join, transport (bpm, meter, the
tick grid, `dur_ticks`/`dur_seconds`, emit lanes, the tempo map with
`start_seconds`), scenes, tracks with their keys, controls with their rails, and
the deduped easing table.

```sh
pacer ir examples/starter.score.sjon --target circle-x … | jq '.transport.tempo'
# [{"tick":0,"bpm":120,"start_seconds":0},
#  {"tick":1441440,"bpm":160,"start_seconds":4}]
```

Expr and pattern tracks carry their **source text**, which is not on the wire
either:

```sh
pacer ir examples/starter.score.sjon … | jq '[.tracks[] | select(.expr) | .expr]'
# ["(+ 0.5 (* sway-amt (sin (* (tau) bar))))"]
```

## `eval`

Sample times are explicit, and there is no default — `eval` with neither form is
a usage error:

```
--at SECONDS                Repeatable. Order is kept: no sorting, no dedup,
                            so the frames array indexes 1:1 with the request.
--from S --to S --fps N     Sweep: t = from + i/fps, endpoint included.
                            All three flags, or none.
```

Every frame reports the **tick it was actually computed at**, after the loop or
hold wrap — not a recomputed conversion, which would disagree on any looping
score:

```sh
pacer eval examples/starter.score.sjon … --from 6.5 --to 7.5 --fps 2 \
  | jq -c '.frames[] | {t, tick}'
# {"t":6.5,"tick":2642640}
# {"t":7,"tick":0}          ← the 7 s loop point
# {"t":7.5,"tick":180180}
```

A time off the grid is reported, not fatal — the score is fine, that time simply
is not on it, so the exit code does not move:

```json
{"t": 1e300, "tick": null, "out_of_range": true, "reason": "TickOverflow", "writes": []}
```

`expr_failures` closes the envelope: a track whose expression goes non-finite
omits its write for that frame rather than letting a NaN reach the buffer, and
this is the count of times that happened.

### Knobs

`--set` holds a `(control …)` for the whole run, replacing its document `:value`
for writes *and* for expression bindings. Address it by `:id` or by slot index —
unambiguous, because a control's `:id` is a symbol and can never be an integer.

```sh
--set sway-amt=0.2          # by id
--set pan=0.25,0.5          # an xy control; lanes past these are zero
--set 0=0.2                 # by slot
```

```sh
pacer eval examples/starter.score.sjon --target circle-x … --at 0.5
# circle-x = 0.62            (sway-amt at its document :value 0.12)
pacer eval examples/starter.score.sjon --target circle-x … --at 0.5 --set sway-amt=0.2
# circle-x = 0.70            = 0.5 + 0.2·sin(τ·0.25)
```

The envelope echoes each override with the slot its key resolved to, so a
consumer can address the same control numerically next time. `--set` is `eval`
only: `ir` reports the *document's* IR, which a live override does not change.

## `pack`

Compile the score one more time and write the whole `'PACB'` container — the
blob a runtime loads — to a file. stdout stays the JSON channel; the blob never
joins it:

```sh
pacer pack score.sjon                     # → score.pacb (last extension swapped)
pacer pack score.sjon --out built/x.pacb  # explicit
```

`--out` is **required** when the score is `-` (stdin has no path to derive
one from), and cannot itself be `-` — stdout is the report's channel.

The host registry can come from a pngine `getUniforms` dump instead of (or
before, then beside) `--target` flags — file order is the `target_id` space:

```sh
pacer pack score.sjon --targets-json reflect.json --out built/x.pacb
```

The adapter replicates the player's `buildJoin` rule for rule: the twelve
bare WGSL spellings (`f32`…`vec4u`) map to 1–4 lanes, an `elemCount`-non-zero
field (an array) is skipped, an unknown `type` is skipped — never guessed —
and registry is 0. The file names a HOST registry and nothing else: target
names are never mined out of the score text.

The report says what landed and how big, read off the bytes that actually
did:

```json
"pack": {"out": "built/x.pacb", "bytes": 3700, "sections": 6,
         "targets": {"host": 0, "declared": 2}, "pacm_bytes": 1784}
```

Before the first report byte, the verb **self-checks**: it decodes its own
output, proves the decoded table equals the compiled one field-for-field,
proves the embedded `'PACM'` byte-equals a fresh encode of this compile, and
re-encodes every expression/pattern payload through the production writer to
byte-compare the `'PAYL'` content (presence alone proves nothing — `'PACM'`
never carries the payload bytes). A self-check failure exits 3 having written
nothing. The write itself is atomic (temp file + rename beside the
destination), a refused write — including a refusal *part-way through* the
blob — leaves no partial temp behind and never touches prior output, and an
`--out` that cannot be written is a usage error naming the path — stdout
untouched. The temp name is fixed (`<out>.tmp`): one writer per destination
at a time is the verb's scope; no uniqueness is claimed.

v1 refuses to pack some scores rather than pack them wrongly, as ordinary
diagnostics in score coordinates (exit 1, `pack` rides as `null`, nothing
written): expr heads the core-only binary schema cannot resolve
identically. A score that compiles clean reports `"ok": true` even when
pack refuses it — the compile succeeded; the refusal is in `diagnostics`
and the exit code. (Dated status, 2026-10-22, plan 06 A3+A4: `:pattern`
tracks pack — the interim `pack_patterns_unsupported` refusal is lifted,
the SJON pattern query env having been delivered (ask30/M4) and adopted;
the code itself stays as a frozen, unemitted wire reserve at ordinal 32.)

## Channels and exit codes

`check` is a **report** verb — its report is the product, so it goes to stdout.
`ir` and `eval` are **data** verbs: stdout carries one complete JSON object and
nothing else, while diagnostics also go to stderr. So this always works:

```sh
pacer ir broken.sjon 2>/dev/null | jq .ok      # false, and still parses
```

On a usage error stdout gets **zero bytes** — never half an object.

| Code | Meaning |
|---|---|
| 0 | No diagnostics. |
| 1 | The score has diagnostics (for `pack`: or a pack preflight refusal). |
| 2 | Usage error — bad flags, an input that could not be read, or (for `pack`) an output that could not be written. |
| 3 | Internal error — out of memory, a dead output stream, or (for `pack`) a failed self-check. |

This is SJON's table rather than pngine's, because a pacer score *is* an SJON
document and the two binaries sit in the same pipelines: `sjon check x.sjon &&
pacer check x.sjon` must not mean two things by the same number.

## The JSON is not a wire-stable surface

pacer's four `'PAC*'` blobs are append-only because a second, independent
implementation decodes them (`npm/pacer/src/index.js`). A format with two
implementations must be frozen or they drift.

This JSON has one producer and no second decoder, so it is **versioned instead of
frozen**: `"pacer": {"format": N}` bumps on a breaking envelope change and never
on an added field. What *is* stable is every value in it — `Compile.Code` names
and ordinals, `Easing.Op` names, the tick grid, the four-lane f32 shape — because
each is already pinned elsewhere. The envelope may move; the meanings cannot.

The shape never varies with the outcome: a defective score still yields a
complete object, with `"ok": false`, a populated `diagnostics`, and the verb's own
keys present but empty. A consumer never branches on whether a key exists.

## Gates

`zig build verify` runs the CLI's in-process tests (they drive `Cli.run`
directly, so they cover the code path the binary runs) and diffs the committed
envelopes in `src/cli/testdata/`. Regenerate those with `zig build cli-golden`
and **review the diff** — never hand-edit one.
