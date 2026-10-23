This case loads only through `PacerRt`, so the score text never reaches the
runtime. The host join is three ordered buses: `mix` (vec3) on registry 0,
`send` on registry 1, and `extra` (vec2) on registry 2. Those arities add up
to six active lanes across the flat target space; the carrier stores no target
names, only references, which is why the join must be supplied again at load.
At 1 s (beat 2) the mix expression writes `[2, 4, 3]`, and the keyed extra
lane is halfway through its first segment. Loading the same carrier
against a different join would refuse with reason 9 rather than guess.
