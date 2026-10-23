One target, three animated lanes. The join declares `tint` with arity 3, so
each key must supply a three-component value; a two- or four-lane value is a
load diagnostic, not a silent truncation. The first segment is linear and
the next two show named eases. At 1 b the first segment is halfway, at 2 b
the second key lands exactly, and at 4 b all three lanes land on the authored
values. Vector lanes are evaluated independently and narrowed to f32 only at
the write buffer.
