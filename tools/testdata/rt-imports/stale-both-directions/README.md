# stale-both-directions — `rt_entry.zig` no longer reaches `Writes.zig`
# (pacer list) and `BinaryCursor.zig` no longer reaches `BinaryFormat.zig`
# (SJON list). Expected: layer 1 FAILS naming both stale entries — an
# allowlisted module that is no longer reached fails, so the lists cannot
# drift away from reality in either direction. (The SJON-side entry must
# be a NON-root file: the window rows' files are seeded as BFS roots
# by the namespace→file map itself, so they can never read as stale.)
#
# Dated note (2026-10-22, ask30/M4 delta): `BinaryDecoder.zig` joined the
# seeded roots and the real leaf imports `BinaryFormat.zig`, so this
# fixture's LOCAL decoder stub stops reaching it — the stale
# demonstration stays BinaryFormat.zig by making the whole tree unreached.
