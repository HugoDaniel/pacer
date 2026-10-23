Two controls, two different jobs. `depth` has a target, so it both binds into
expressions and writes `gain`; `sway` has no target, so it is only a value an
expression can read. The `spike` track is the runtime-failure witness: at
exactly beat 1 the denominator is zero, the evaluator rejects the non-finite
result, and that one write is omitted while the other tracks still land. In
the frame's `order`, `gain` appears after `mod`, which is the contract that
lets a control pin outrank a track on the same target.
