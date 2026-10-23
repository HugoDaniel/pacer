This is the compile-time side of the non-finite contract. `(sqrt -1)` is a
legal expression that produces NaN, and `(pow 10 400)` produces positive
infinity; both are rejected when the t=0 dry-run inspects the result. The
code is `expr_result_invalid` (19), and the message names the finite-number
requirement rather than blaming f32 narrowing. Both diagnostics are present,
because compile collects defects instead of aborting on the first. A runtime
failure is a different surface: an expression that divides by zero only on a
later frame omits that frame's write instead of refusing the load.
