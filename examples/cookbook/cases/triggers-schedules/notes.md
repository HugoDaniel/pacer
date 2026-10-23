Two schedules, two arities. `pulse` is periodic with an offset, so its events
land at beats 1, 2, 3 and so on; at a beat boundary the phase is 0 and the
gate is 1, and between events the phase climbs toward 1. `hit` uses an
explicit list, and because its target has one component only the phase lane
is written. Before an event the trigger is not in the frame at all: whether a
write exists is a pure function of time. The 4 s sample is exactly `:dur`, so
the loop has wrapped to tick 0 and both schedules are at their pre-first-event
state again.
