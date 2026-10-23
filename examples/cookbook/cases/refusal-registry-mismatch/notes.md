The carrier is built against `[alpha, bravo]`, both one-lane. A different
join can still be valid PACT bytes while naming something else, so the
runtime compares the join's identity rather than merely decoding it. The
`structural` probe changes alpha's arity to two; the `name-swap` probe keeps
both names and arities but reverses their order, which changes the target_id
space. Both loads return status 1 and reason 9 (`registry_mismatch`), and the
canonical join still loads and evaluates. This is why a host should treat the
ordered registries as part of the score's contract, not incidental metadata.
