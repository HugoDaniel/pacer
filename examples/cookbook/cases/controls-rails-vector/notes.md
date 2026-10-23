Two controls demonstrate the two shapes. `depth` is a scalar slider whose
value is both a write to `gain` and an expression binding used by `mod`; the
rails are metadata, so changing them would not change any frame. `pan` is an
xy pad: its arity is two, its default is `[0.25 0.5]`, and its rails are
two-lane too. In the frame order, the `mod` track appears before `gain` and
`pan-out`, because controls land last and win on a shared target. The page
editor is what normally changes these values live; the document value is the
authority when the control is idle.
