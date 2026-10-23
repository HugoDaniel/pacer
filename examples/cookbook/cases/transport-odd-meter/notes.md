Seven beats per bar is the point: the meter changes the beat count inside a
bar but not the bar's tick length, so positions in bars stay exact. 128.5 bpm
is deliberately fractional, and only the seconds-to-ticks conversion sees it.
The `mark` track proves that an `s`-unit key still lands structurally: 3 s is
6.425 beats into the bar, not a beat position, but the evaluator selects the
key at its own tick edge. `lfo` reads the emitted `phase` lane, which is the
same 0..1 bar fraction a score could bind with an expression.
