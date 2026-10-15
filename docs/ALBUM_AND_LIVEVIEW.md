# GX85 album and live-view compatibility — 0.2.3

## Field report and investigation

The user reports an album parse error after scrolling and requests newest photos
first. The previously supplied diagnostics record entering play mode, but have no
SOAP catalog response or failing item. Therefore the exact field failure is not
confirmed from that attachment.

The existing parser rejects Lumix RAW protocol descriptors of the form
`http-get:*:application/octet-stream;PANASONIC.COM_PN=CAM_RAW`. The missing fourth
colon is present in libgphoto2's captured Lumix examples. A mixed page containing
this descriptor can reproduce the reported all-or-nothing page failure.

## Album behavior

GX80's flat catalog is reported in ascending capture order and can omit dc:date.
Probe its count with one item, then read the last bounded range first, reversing
each complete range for display. Subsequent ranges walk toward index zero. Do not
sort only the loaded subset or load the entire card to find the latest photo.
Logical offsets represent the number of newest items already loaded; SOAP offsets
remain the camera's ascending indices. A short server response must be completed
within the same range before reversing, so no photo is skipped.

Hold the count and UpdateID for that directory session. If either changes, require
reload instead of combining shifted pages. Reload probes the count again. Preserve
loaded photos on failure, stop automatic loading, and permit an explicit retry for
recoverable page errors. Changed/duplicate/no-progress pages require a full reload.

Accept standard four-part descriptors and Panasonic's semicolon form, while keeping
current-camera URL checks, byte/XML limits, count/progress checks, and distinct
original/preview roles. Normalize generic RAW and RAW-companion MIME types only for
their explicit Panasonic profile. Do not promote an unknown resource to original.
Log requested offsets/counts, reply counts/update identity, and bounded failure
context for future device diagnosis.

## Live-view quality

The user clarified that the quality request concerns live shooting, not album
playback. The existing decoder creates an image from the received JPEG at its
source pixel dimensions, without JPEG recompression or thumbnail downsampling.

At connection, when the camera explicitly advertises VGA and currently reports
QVGA, attempt VGA before starting the stream and read back the setting. Preserve
VGA, higher/unknown settings and active recording. An unsupported optional quality
request must not prevent ordinary monitoring. Do not change still-picture quality,
picture size or video recording settings. Report the actual received pixel
dimensions in settings and diagnostic entries, rather than assuming a setting
acknowledgment proves higher-resolution frames.

Wi-Fi monitoring remains the camera's compressed live feed. This cannot establish
equivalence to a recorded full-resolution photo, the viewfinder or HDMI, and does
not add invented HD/4K modes. Confirm the available modes and delivered resolution
on the user's camera after installation.

## Exposure and interaction follow-up

The user reports that M-mode shutter readings match the body, while automatic
exposure modes differ and shutter choices are absent. The embedded menu declares
controls without discrete stop values. M-mode's `menu_item_id_f_and_ss` can be
enabled while the separate aperture/shutter entries are disabled: the combined
control is an alternative route, not an ancestor whose siblings must also be on.

For recognized GX80/GX85 embedded controls, populate finite standard shutter codes
from the established Lumix stop table and retain lens-reported aperture limits.
Enable either parameter when its individual or combined control is available.
These are model-supported stop codes, not a range claimed to have been returned by
the user's camera; current mechanical/electronic shutter restrictions can still
reject a value. Exclude Bulb because this app has no timed hold interaction.
Always read back writes and preserve the body's shooting mode and shutter type.

When metadata says exposure is camera-controlled, display automatic instead of
presenting the retained manual setting as live metered exposure. M-mode continues
to show the setting readback; unknown metadata is not used to invent a live value.

Replace long context menus with a scrollable sheet and full-width, minimum-48pt
rows. Keep parameter selection taps out of the image focus gesture. The user's
requested notification policy is quiet success: update readouts, record button and
timer without a success banner. Accepted but unconfirmed photo acknowledgments
remain in diagnostics without claiming a saved image. Rejection, transport failure
and uncertain-operation errors remain visible.

## References

- [Captured Lumix resource descriptors and HTTP live-view-size setting](https://github.com/gphoto/libgphoto2/blob/master/camlibs/lumix/lumix.c)
- [GX80 owner's newest-first catalog reader](https://github.com/laurentmmeyer/lumix-gx80/blob/main/gx80_pull.py)
- [Camera-owner Lumix menu capture with VGA/QVGA options](https://gist.github.com/auberginehill/132104749d2da304a48ebccb90571dfd)
- [Lumix shutter stop codes](https://github.com/Rambalac/GMaster/blob/master/Core/Camera/CameraParser.cs)
- [Camera-owner current-menu capture showing the combined exposure route](https://www.eoshd.com/comments/topic/24995-would-you-perhaps-be-interested-in-a-different-gx8085-colour-profile/page/3/)

These references identify compatible protocol forms; they do not substitute for
the user's missing failing SOAP response or physical GX85 validation.
