The expected meta block is the decoded PACM, not a restatement of the source.
That is why the meter appears as `beatsPerBar: 7`: the denominator is parsed
and validated by the score schema but never crosses the wire. The two scenes
carry their own tick windows, and the key anchors are absolute positions, so
the tail scene's local 0 b is stored at 720720. `depth` has a target and
`sway` does not, which is visible as `target: gain` versus `target: null`.
The frames are a small cross-check that the metadata's tracks are the ones
actually writing.
