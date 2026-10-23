The two time names are deliberately in tension. `beat` comes from the frame
environment and advances continuously, so the clock lane reads 0, 2, 3, 8, 12
at the sampled times. `tick` also exists in the outer environment, but the
pattern-local binding shadows it with the cycle onset: 0 for every frame in
cycle 0, then 720720 for every frame in cycle 1. The control `sway` has no
target, yet it resolves through the parent scope just like a targeted one, so
`swayx2` writes 0.5 without any control write appearing.
