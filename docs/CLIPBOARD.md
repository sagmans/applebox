# Clipboard history

AppleBox lists captured copies from newest to oldest. Copying the same content
twice in a row keeps one entry. Copying it again after another item creates a
new entry at the top.

Replaying a saved clip leaves the order of history alone. AppleBox also skips
copies that other apps mark as generated, concealed, or transient.

Press Option-Return on a selected clip or choose **Copy to Clipboard** from
its context menu. Paste it yourself with Command-V wherever you need it.

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

The history directory and file are owner-only. AppleBox reads up to 64 MiB
from an existing archive. If it cannot read or migrate that archive, it
keeps the file intact and captures new clips for the current session.

Right-click a clip and choose **Delete Clip** to remove that entry. Choose
**Clear History…** and confirm to remove all saved clips. Both actions leave
the current system clipboard available for pasting.
