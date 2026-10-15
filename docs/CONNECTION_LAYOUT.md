# GX85 Monitor 0.2.5 — connection screen overlap

The attached iPhone portrait screenshot shows the connection guide title and first
step under the monitoring status and exposure chips. CameraView renders a guide
inside its full-screen preview layer whenever there is no image, while its separate
control overlay still renders unconditionally. The two layouts reserve no space
for each other.

Use a dedicated connection layout whenever no live frame is available. Keep the
settings and optional disconnect action in a toolbar, then place the guide in a
separate scrollable region below it. Hide unused exposure, photo/video, album and
fullscreen controls until a frame exists. If the body is already recording, keep
a distinct stop-recording control available even while waiting for the first frame.

The live preview and its overlay remain geometrically unchanged when an image
exists, including paused/recovering frames, native parameter wheels and notices.
Connection notices belong to the guide's scrollable content, so they cannot cover
the separate stop-recording row or settings toolbar, even when expanded.

Regression checks cover the real disconnected screen in portrait and both
landscapes, title/toolbar separation, settings navigation, and stopping an active
recording without any received frame. Existing monitoring tests continue to cover
centered frames, gestures, exposure selection and album/video interactions.
