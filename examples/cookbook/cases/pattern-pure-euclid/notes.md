Two pattern shapes, one target each. `(pure 0.25)` is the simplest possible
pattern: a single hap spanning the cycle, so the target writes on every frame.
`(euclid 3 8 0.8)` spreads three onsets over eight slots, which is the
tresillo rhythm on the bar grid. At 0.25 s and 0.5 s the euclid lane has no
active hap, so `pulse` simply disappears from the frame; a gap is an omission,
not a zero write. At 1.5 s the third onset fires at slot 6. The 2 s sample is
the next cycle, so the same tresillo starts again at slot 0.
