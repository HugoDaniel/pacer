The same ramp as a hold case would freeze, but here the transport loops every
two bars. At 120 bpm 4/4 that is 4 s, so 4 s wraps to tick 0 and 5 s lands one
second into the next cycle. The interesting edge is the negative clock: pacer
uses floor-mod, so -1 s wraps to beat 6 of the previous cycle rather than
producing an error or a negative tick. At 100 s the playhead has completed
25 cycles and lands exactly on tick 0 again.
