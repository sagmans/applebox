# Clipboard history

AppleBox lists captured copies from newest to oldest. Copying the same content
twice in a row keeps one entry. Copying it again after another item creates a
new entry at the top.

Replaying a saved clip leaves the order of history alone. AppleBox also skips
copies that other apps mark as generated, concealed, or transient.

Clipboard history opens in the same glass panel as app search. The list is on
the left. The preview of the selected clip is inside the panel, to the right of
the list. It is not a separate window.

Press Option-Return on a selected clip or choose **Copy to Clipboard** from
its context menu. Paste it yourself with Command-V wherever you need it.

Press Return on a selected clip to paste it into the app you were using.
Automatic paste needs permission to send keystrokes. The first time it is
missing, AppleBox asks macOS for it and shows "Copied. Allow AppleBox in
Privacy & Security settings to paste automatically." Turn on AppleBox under
System Settings, Privacy & Security, Device Control & Data Access (macOS 27)
or Accessibility (macOS 26). Until then the clip is copied and you paste it
with Command-V.

Choose **Pause Capture** in clipboard history to stop saving new copies.
The pause survives restarting AppleBox. **Resume Capture** starts saving from
the next copy. You can still search and replay saved clips while paused.

If macOS asks for clipboard access, allow AppleBox to capture new copies.
If capture is blocked, find AppleBox’s pasteboard access preference in
System Settings and allow it. Copy something new to confirm that capture has
resumed. Previously saved clips remain available while access is blocked.

AppleBox keeps up to 50 clips for 30 days. It skips text above 256 KiB and
images above 8 MiB. A 32 MiB storage budget counts Base64 image data and
reserves room for JSON escaping. When the budget fills, the newest clips
take priority. Expired clips disappear from search and are removed from the
saved archive on the next capture or hourly cleanup.

Each saved clip also records the bundle ID of the app it was copied from.
The preview header shows that app's icon and name, and VoiceOver reads it as
"Copied from" followed by the app name. When you paste or copy a saved
clip again, AppleBox passes the same source on to the clipboard.

The history directory and file are owner-only. The archive holds clip text
and details only. Each image is a separate owner-only file in the
`clipboard_images` folder next to it, named by the clip's ID, and is deleted
when its clip is deleted, expires, or leaves the history. AppleBox saves
history at most twice a second, and it saves any pending change when it quits.

AppleBox reads up to 64 MiB from an existing archive and up to 8 MiB from
each image file. An archive from an earlier version, which held images
inside it, is converted on the first launch, and every clip stays. Going
back to an earlier version is not supported: it shows image clips without
their images, and the images are lost when it saves history. If
AppleBox cannot read or migrate the archive or one of its image files, it
keeps the files intact and captures new clips for the current session.

Right-click a clip and choose **Delete Clip** to remove that entry. Choose
**Clear History…** and confirm to remove all saved clips. Both actions leave
the current system clipboard available for pasting.
