Every track runs from 0 to 1 over one bar, so the sampled values read
directly as easing outputs. `hold` is the constant form: it keeps 0 until the
end key jumps to 1. `steps` splits the segment into treads, and `jump end` vs
`jump start` decides which side of each tread carries the jump. The composed
rows are the interesting ones: `seq` is an overshooting three-stage program,
`spring` is a closed-form damped cosine, and `chain` feeds a cubic-bezier
through a staircase. All of them still land exactly on 1 at the final key.
