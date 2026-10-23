The malformed input is derived from the case's own real pack, which keeps the
cookbook free of hand-written binary blobs. Forty bytes preserves the PACB
magic but cuts the directory and section table, so the decoder refuses the
size relationship before it can trust any offset. The status is 1 and the
reason is 3, `directory_malformed`; this is a fresh driver, so no score becomes
armed (`live` is false). The full carrier then loads normally and supplies the
frames, which demonstrates that the refusal was about the prefix and not about
the score. Regenerating the case re-derives the prefix from the new bytes
automatically.
