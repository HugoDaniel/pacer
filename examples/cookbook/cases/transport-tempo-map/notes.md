The tempo map is piecewise: the first four beats run at 120 and everything
from beat 4 onward runs at 240. That makes the eight-beat score three seconds
long, so 3.5 s is already past the loop edge and wraps back into the first
segment. The 2.5 s key is the sharpest witness: under the map it is beat 6,
while constant 120 bpm would have called it beat 5. `:emit [beat bpm]` writes
the same numbers the expression environment binds, including the step change
in bpm at the segment boundary.
