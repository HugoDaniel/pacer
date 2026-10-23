This is the ordinary missing-target refusal. The host join has `level`, but
the track asks for `missing`, so pack exits 1 with an `unknown_target`
diagnostic at the track's span. The JSON envelope still has its full shape:
`pack` is null because no blob landed, and the diagnostics array is the data.
The text loader re-runs the same compile and reports the same code and
message. Nothing is guessed or silently dropped: the score cannot produce a
table until the name resolves.
