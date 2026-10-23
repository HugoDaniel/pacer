This is the cookbook's cross-path proof. The text driver compiles the score
and the runtime driver decodes the carrier packed from that same score, so
the two paths share the wire formats but not the compiler. The score is
deliberately broad: a tempo map, a loop, a scene, a control, keys, an
expression, a pattern and a trigger all contribute writes. At each clock the
runner compares the full normalized frame, including the f32 hex bits, and
refuses to write an expectation if the paths disagree. The expected block
records both loads and a true `parity` flag.
