# pacer examples — minimal PacerRt player

A pacer-local vertical smoke for the playback-only runtime (plan 06 C7 /
plan 04 P3). It loads `score.pacb` through `pacer-rt.wasm` with
`PacerRt.load`, drives `eval(t)` from a host clock, and routes the frame
through the unchanged `npm/pacer/src/route.js`. There is no compiler, no
source text, and no fallback text path in the deployed page.

`score.pacb` is packed from `score.sjon` (a Meridian-shape minimal score)
against the flat join `beat, heroPos:2, heroTurn, heroTint`:

```sh
zig build run -- pack examples/player/score.sjon \
  --target beat --target heroPos:2 --target heroTurn --target heroTint \
  --out examples/player/score.pacb
```

## Run it

Serve the **repository root** so the page can reach
`npm/pacer/pacer-rt.wasm` and the shared JS leaves:

```sh
python3 -m http.server 8073 --directory .
# open http://localhost:8073/examples/player/
```

(or `npx serve .` / any static server rooted at the repo root). The parent
browser-tester runs the actual browser pass; this page makes no browser
claim by itself.

## What it proves without a browser

```sh
node examples/player/check.mjs
```

The check loads the same two files with the same join and asserts:
the binary load status, the registry join, the meta track names and
`hero-speed` control id, `eval(0)` values, a live control reaching the
`heroTint` expression, and the restart contract (successful reload tears
down held state; re-applying the held control restores it).

There is no repository gate dedicated to `examples/`; `node
examples/player/check.mjs` and the parent's browser pass are the
C7 evidence. The Node check is not a substitute for the browser result.
