This case isolates the time bindings rather than hiding them inside a formula.
At 120 bpm in 4/4, one bar is two seconds, so 1 s is beat 2 and 0.5 bar; the
tick binding counts 720720 ticks per bar. `dur` is in beats, so `:dur 2bar`
binds 8, and `rate` is the constant 960. The vec3 row shows that a single
expression can produce a vector when the host target declares arity 3. All
of these are read-only numbers; a track cannot change the transport.
