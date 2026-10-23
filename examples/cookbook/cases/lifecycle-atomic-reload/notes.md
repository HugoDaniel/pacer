The good score is live and writing, then a second carrier is offered. That
carrier references a target named `ghost` which the live host join does not
provide, so the runtime refuses it with status 1 and reason 9
(`registry_mismatch`). The important part is what does not happen: the old
table is not unloaded, so the very next frame at the same clock is
byte-identical to the one before the refusal. Reloading the good carrier
succeeds and reproduces the same frame again. The text path is different by
design: its diagnostics reload does tear the table down, which is why this
case uses the playback runtime.
