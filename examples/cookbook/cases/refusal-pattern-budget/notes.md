`fast` multiplies the number of haps in a cycle, and 8000 copies of a pure hap
is more than the frame's fixed scratch can hold. The compile dry-run queries
cycle 0 under that same budget, so the refusal happens at load with
`pattern_eval_failed` (27) and a message that names the budget. This is not
a process out-of-memory: it is a deterministic property of the document, so
the same score refuses the same way on every host. The binary runtime reserves
reason 11 for its own dry-run refusal, but a normally packed score cannot
reach it here: pack runs the text compile first, so this document never
produces a carrier. The cookbook pins the text refusal rather than hand-building
a malformed payload.
