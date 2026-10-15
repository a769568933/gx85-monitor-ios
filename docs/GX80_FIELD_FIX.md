# GX85 Monitor 0.2.1 — shutter hotfix

The user requested a shutter-only package before further exposure and tap-focus work.

## Evidence and correction

The uploaded GX80/GX85 log shows focusmode=afs, oneshot_af rejected with err_reject,
and the photo transaction exiting without ever submitting capture. The user also
reports no shutter action after an MF test, but that test has no new command log yet.

Remove both the separate focus-mode query and oneshot_af prerequisite from photo
capture. Keep camera-state/card checks and let the camera enforce its own AF/MF
and focus-priority settings. Retain single submission, press/release cleanup,
unknown-result reporting, and no automatic shutter retry. A capture acknowledgment
is still not evidence of a new file.

Diagnostic exports include version/build and failure stages: preflight, shutter
submission, release, and post-capture polling. Settings shows 0.2.1 (build 3).

Regression tests first reproduce the blocked shutter against the old code. The
corrected service must submit one capture even if a preliminary oneshot_af would
be rejected. Rejected capture, timeout, busy/card restrictions, and serialization
remain covered. Full app/core/UI tests and ARM64 packaging are required.

## Device acceptance

Update the existing App using AltStore, confirm 0.2.1 (build 3), connect to camera
Wi-Fi, and close Image App. In camera A mode, tap the shutter once and check both
the physical shutter and a new image on the card. Repeat separately in AF and MF.
If it fails, export the new diagnostic log immediately so the command stage is known.

Automated tests do not establish physical-camera success. Exposure duration,
drive modes, AF priority, and new-file creation remain actual-device checks.

## Deferred by user priority

Exposure decoding (768/256), full shutter/aperture adjustment ranges, and touch-focus
protocol compatibility are reserved for the subsequent version. Work in progress
is preserved locally; none of those product changes is in this package.

References:
- https://github.com/Rambalac/GMaster/blob/master/Core/Camera/Lumix.cs
- https://github.com/gphoto/libgphoto2/blob/master/camlibs/lumix/lumix.c
