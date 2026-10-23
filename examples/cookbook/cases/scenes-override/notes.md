There are three `level` tracks: one global and one in each scene. All three
can write the same target, and the frame keeps every write in emission order,
so the overlap is visible rather than collapsed. The later scene (`drop`)
wins for a consumer that applies entries in order, which is why the 2 s and
2.5 s frames read drop's value. `scene-phase` is normalized inside each
window, while `scene-beat` counts beats since that window opened; neither
depends on where the scene sits on the transport. At 8 s the transport loops
and the whole arrangement starts over.
