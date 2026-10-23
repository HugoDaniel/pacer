This is the hold half of pacer's end-behaviour contract. The transport is one
bar long, but the keys only occupy beats 1 through 3; beat 0 holds 0.25 and
beat 4 holds 0.75. A negative clock also holds the first value rather than
wrapping backwards. At 2 s the playhead is exactly at `:dur`, and the 5 s
sample is clamped back to that same boundary, which is why both frames are
identical. The loop twin in `keys-loop` wraps instead of clamping.
