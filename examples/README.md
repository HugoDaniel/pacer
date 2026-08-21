# examples

Four files, two of which are pacer scores.

| File | What it is |
|---|---|
| `starter.score.sjon` | The score `index.html` loads into its editor — a tour of the language: keyframes with every easing combinator, an `:expr` track behind a pinned `(control …)`, a `:pattern` track, two `(trigger …)` lanes, a `(tempo …)` change and a `(scene …)` window. |
| `demoscene.score.sjon` | The flagship: 100 bars at 128 bpm driving the four `motion` uniform fields of `impulsos_camaradas.sjon` — `sceneMix`, `spin`, `chromaAmt`, and `beat` through `:emit`. |
| `impulsos_camaradas.sjon` | **A pngine document, not a pacer score.** pngine owns it; it lives here so the score next to it has something to read. It builds the SDF pipeline, the halftone dot layer and the cube-canvas grid, and takes all of its motion from the `motion` buffer. |
| `index.html` | The browser demo. |

Both scores are written in **compose mode** — they declare their own targets
with `(target …)`, or (in the starter's case) target the demo page's
registries — so each one compiles, evaluates and lints standalone. Both are
pinned by the golden corpus: `corpus/examples-demoscene/doc.sjon` and
`corpus/examples-starter/doc.sjon` are symlinks to the files above, so the
example that ships is the example the gate compiles. Editing one and running
`zig build verify` tells you immediately if it stopped compiling; regenerate
its golden with `zig build corpus -- --update` and review the diff.

`sjon-project.sjon` at the repo root points `sjon-lsp` at `schema/pacer.sjon`,
so both scores get diagnostics, hover and completion in an editor with no
`(use-plugin …)` line of their own.

## Running the demo

`index.html` fetches `pacer.wasm` and the starter score over HTTP, so serve it
from the repo root rather than opening the file directly:

```sh
zig build wasm
python3 -m http.server        # then open http://localhost:8000/examples/
```

Edit the score in the left pane: it recompiles ~150 ms after you stop typing,
diagnostics appear underneath with spans into your own text, and the last good
table keeps animating while the text is broken. Drag the `sway-amt` slider for
a live `drv_setControl` override and press *clear* to hand authority back to
the document. *play music* starts a click track that is **rendered from the
score** — the page walks `t` and watches the `click` trigger's count lane — so
retiming the transport, or editing the `(tempo …)` line, retimes the music with
the picture, and the audio transport takes over as the master clock.

`impulsos_camaradas.sjon` does not run here — it needs pngine, which loads the
document, binds `demoscene.score.sjon`'s writes into the `motion` buffer, and
renders the pipeline.
