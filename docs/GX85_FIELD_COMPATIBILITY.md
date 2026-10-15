# GX85 Monitor 0.2.2 field compatibility

## Device feedback and evidence

The user verified physical mechanical-shutter capture with 0.2.1/build 3. Electronic
single-shot capture does not create a new image on the camera, according to the user.
The attached log contains accepted captures at 15:05:52 and 15:06:58 followed by SD
write activity and a remaining-capacity decrease. The log does not identify the
physical shutter type; those counters alone do not prove a particular new file.

The same log shows a touch-focus request timing out, followed by state-query
timeouts and a failed photo preflight. Playback replies use `cammode=play` without
`rec`; shooting replies use `cammode=rec`, `rec=off`, and `remaincapacity`.

## Capture policy

Read current drive metadata before capture. For a reported normal/single drive
and a recognized finite shutter setting, let the camera finish its single exposure
without sending `capture_cancel` after 100 ms. This removes a plausible cancellation
race for electronic shutter and delayed AF, but does not establish device success.
Keep one capture request, bounded post-capture polling, and no automatic retry.

Retain explicit release for burst/hold modes and the legacy path when metadata is
unavailable. A timed-out metadata request must not be followed by a speculative
shutter. A timed-out shutter is still uncertain and may receive one cleanup release.
Neither the camera's shutter type, drive mode, nor focus priority is forcibly changed.

## Exposure

Decode Lumix APEX/256 values into photographic shutter and f-number labels. For the
field values, `1451/256` means approximately 1/50 s and `768/256` means F2.8. Prefer
an actual camera menu title when available; writes preserve the original wire value.

For the embedded aperture menu, use valid lens-reported opened/closed limits and
verified Lumix stop codes to populate aperture choices. Apply the current menu's
permission afterward: camera-controlled modes remain read-only. Refresh lens limits
when loading parameters so zoom/lens changes are not identified solely by `lens=normal`.
Invalid or absent lens metadata must not invent a range. Embedded shutter menus
without reported choices/ranges remain read-only; A-mode shutter is camera-controlled.

## Focus and playback

Use the GX80/GX85 new touch-point request (`type=touch`, normalized coordinates,
`value2=on`), preserving MF and rejecting out-of-frame/control taps. No separate
one-shot AF prerequisite or touch-shutter command is added; an acknowledgment is
still not a confirmed AF lock.

Normalize rec/recmode and play/playmode. Playback entry waits for an actual play
reply. Explicit play may omit `rec` and can safely transition back to shooting;
missing `rec` in shooting/unknown mode remains unconfirmed. Start the live stream
only after a confirmed shooting reply. Never stop an existing body-started recording
to restore the album's previous state. Recognize the actual `remaincapacity` key.

## Validation and boundaries

Regression tests first exercise the existing implementation, then the corrected
services and actual simulator UI. Physical electronic-shutter behavior, AF position,
lens metadata compatibility, and system photo/video export require user device checks.
Existing original-file download/Photos/Files protections remain in place. Automatic
physical photo/video dial detection is not inferred from cammode=rec.

References:

- [Panasonic GX85 advanced instructions](https://www.panasonic.com/content/dam/pim/au/en/DM/DMC-GX/DMC-GX85KGN/DMC-GX85_ADVANCEDOI_sqw0685.pdf)
- [GMaster camera operations](https://github.com/Rambalac/GMaster/blob/master/Core/Camera/Lumix.cs)
- [GMaster lens parsing and stop codes](https://github.com/Rambalac/GMaster/blob/master/Core/Camera/CameraParser.cs)
- [Lumix menu structure example](https://gist.github.com/auberginehill/132104749d2da304a48ebccb90571dfd)
