# 05 — Builder appends rows, not parallel arrays

**Repo:** pacer
**Wire impact:** none
**Gates:** `zig build verify` with a byte-identical corpus (the whole point: a pure
refactor)
**Size:** small — mechanical, one file.

## Why

`Compile.zig`'s Builder threads six lists (`tracks`/`track_spans`,
`keys`/`key_spans`, `scenes`, plus `ta`) through 8–9-parameter signatures
(`buildTrackForm`, `buildScenes`, `buildTriggerForm`), appends the row/span pairs in
lockstep at four separate sites, and asserts the lengths agree only after the walk
(`Compile.zig:459-460`). Correct and documented — but it's the one module where an
invariant is upheld by convention + post-hoc assert instead of by shape: a missed
second `append` line compiles fine and fires an assert three functions away.
`buildTrackForm`'s `bool` return ("false ONLY when the key cap forced the whole walk
to stop") is the same pattern — a sentinel meaning carried by a primitive,
documented rather than typed.

## Design

- The under-construction table state moves onto the Builder as fields (`ta:
  Allocator` set once in `build()`, plus the five lists). Two helpers own lockstep:
  `appendRow(track, span)` and `appendKey(key, span)` — the only places a row or key
  is ever appended, so `track_spans.len == tracks.len` becomes true by construction;
  the end-of-walk asserts stay (cheap, and they now document the helpers' guarantee
  rather than police call sites).
- Signatures shrink to what varies per call: `buildTrackForm(idx, scene_win,
  scene_index)`, `buildScenes()`, `buildTriggerForm(idx, scene_win, scene_index)`,
  etc. The `transport` param stays threaded (it's built mid-walk, not Builder-wide
  state from the start — moving it to a field would misstate its availability).
- `buildTrackForm`'s bool becomes `enum { keep_walking, stop_walk }` with the
  key-cap meaning on the variant's doc comment — call sites read
  `if (… == .stop_walk) return;`.
- Sorting stays as is (`sortKeysWithSpans` already takes the paired slices — it is
  the co-sorted proof that the pairing is one thing; consider renaming nothing).

Explicitly out of scope: any behavior, message, span, or ordering change. The gate
is an empty corpus diff.

## Phases

### Phase 1 — mechanical migration
Load: `src/Compile.zig` lines 372–1100 only (the Builder — tests stay untouched and
green throughout, they ARE the red/green here).
Work: fields + two append helpers + signature shrink + the walk-verdict enum, in
that order, keeping `zig build test` green after each step (a pure refactor earns
continuous green, not reds — note this deviation from the reds-first default in the
log).
Gate: `zig build verify` — corpus byte-identical, `zig build audit-diagnostics`
unchanged, npm gate untouched (no wasm-visible change, but run it once for the
wasm rebuild sanity).

## Progress log

(empty)
