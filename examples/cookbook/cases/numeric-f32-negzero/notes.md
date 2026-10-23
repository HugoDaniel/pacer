The decimal values in expected.json are only half the pin; the hex strings are
the other half. 0.1 cannot be represented exactly in binary, so the nearest
f32 is 0x3dcccccd, and 1/3 rounds to 0x3eaaaaab. 16777217 is 2^24 + 1, which
needs 25 significant bits; f32 keeps 2^24 and drops the low bit. Negative zero has three
spellings here: the `-0.0` key is a float and the expression `(- 0)` produces
one, so both write 0x80000000; the integer `-0` key writes 0x00000000 because
SJON parses it as zero. The decimal pin spells the two float zeros as `-0` and
the integer zero as `0`; `JSON.stringify` alone would print all of them as `0`,
so the sign bit is why the bits are pinned too.
