This is the honest edge of a cycle-0 dry-run: a pattern is only proven for
the cycle the compiler inspects. Here the expression divides by zero exactly
when `tick` equals one bar, so cycle 1 drops the hap while cycles 0 and 2 are
fine. The frame at 2 s still contains `steady`, which proves the omission is
per track and not a whole-frame failure. The runtime's `exprFailures` probe
would be 1 after that frame; the pinned evidence is simply the missing write.
A missing binding is a different thing: it fails the load dry-run by name.
