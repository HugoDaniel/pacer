This is one vec3 built from three deliberately different trees. The first lane
shows that subtraction with three arguments left-folds; the second shows
nesting as the only precedence rule; the third shows unary minus applied to a
hex literal. The scalar `gain` track repeats the point with a time-varying
inner form, so at beat 0 it is 16 and at beat 1 it is 48. `0x` literals are
SJON's, not pacer's: the score language inherits their meaning from the
lexer, which is why they appear in keys, controls and expressions alike.
