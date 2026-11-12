# Drop Portal

Flick a photo, video or file off the left edge of your phone and it lands on
your Mac's screen. Click it to open it, or drag it straight into any app. Pasted
text goes to the Mac's clipboard. No phone app: the phone side is a web page
the Mac serves on your Wi-Fi.

A Droplet for [Droppy](https://getdroppy.app), built with
[DroppyKit](https://getdroppy.app/docs/droppykit).

## What it does

- **Flick to send.** Pick photos, videos or files on the phone. Each becomes a
  card; flick it off the left edge (or drag it past the edge) and it flies
  across. A bar on the card shows the upload.
- **It lands where you are looking.** On the Mac, a card with the file's preview
  flies in from the right edge of the screen with the pointer, waits a few
  seconds (longer while the pointer is on it) and shrinks away. Click opens the
  file, drag drops it anywhere.
- **Text too.** Paste on the phone and press Send, and it is on the Mac's
  clipboard with a "Clipboard received" banner.
- **And back to the phone.** Drag files to the right edge of the Mac's screen
  and a portal opens there in your effect; let go and they fall through to the
  phone page, under From your Mac. Or select files in Finder and press
  Control-Option-Right Arrow, or right-click them › Quick Actions › Send to
  phone. Files sent while the phone page is closed wait up to a day and arrive
  as soon as you open it.
- **Saved in Downloads › Drop Portal**, never overwriting: a second `photo.jpg`
  becomes `photo 2.jpg`.

## How to use it

1. Turn Drop Portal on in Droppy. Add the Drop Portal widget to the shelf and the
   QR code is there whenever you open the notch; the settings page shows it too.
2. Scan it with the phone camera (same Wi-Fi as the Mac). the browser opens the page.
3. In the browser, Add to Home Screen (iPhone: Share › Add to Home Screen) keeps it one tap away.
4. Press Pick, choose items, flick a card off the left edge. Keep the page open
   while a card is sending.

The phone and the Mac must be on the same Wi-Fi. Some office or public Wi-Fi
keeps devices apart; there, turn on the phone's Personal Hotspot and join it
from the Mac. A card that says "Mac not reachable - same Wi-Fi?" sends again
when you tap it.

If macOS asks whether Droppy may accept incoming network connections, allow it:
that is the phone reaching the Mac.

## Settings

- **Your phone**: the QR code. It follows the Mac to another network by itself.
- **On this Mac**: Effect, how a file crosses from the phone to the Mac: Portal
  light, Liquid, Wormhole, Beam or Paper plane, with a Preview button that plays
  it on this Mac. The phone page follows the choice at once. Reduce motion
  turns every effect into a plain fade. Add received files to File Tray (on
  by default) also puts every received file in Droppy's File Tray. Then Open
  Drop Portal folder.
- **Send from this Mac**: Drag files to the right edge to send to phone (on by
  default; the edge only takes file drops, and only while you drag files), the
  keyboard shortcut (Change… opens Droppy's Shortcuts page) and Add Finder Quick
  Action, which opens a signed shortcut in Shortcuts: click Add Shortcut once.
  After Reset pairing, add the Quick Action again.
- **Troubleshooting**: what is wrong, in plain words, when the phone cannot
  reach the Mac, and Reset pairing, which makes a new code and locks out every
  phone that had the old one.

## Privacy and security

- **Local network only.** While Drop Portal is on, the Mac runs a small HTTP
  server on port 8787 (the phone page and uploads) and a WebSocket on port 8788
  (the live preview of the card you drag). Both stop when you switch Drop
  Portal off. There is no cloud relay and no account: what you send goes
  straight from the phone to the Mac over your Wi-Fi and never leaves it.
- **Pairing code.** The QR code carries the Mac's local address and a random
  pairing code. Every request must carry that code, or the Mac answers 403, so
  only a phone that scanned the QR code can send. **Reset pairing** (in
  Troubleshooting) makes a new code and locks out every phone that had the old
  one. Treat the QR code like a password: anyone who scans it on your network
  can send you files.
- **Received files** are saved to Downloads › Drop Portal, never overwriting
  anything. Uploads are limited to 2 GB, stream to disk and get a cleaned-up
  file name (no folders, no hidden files). They are quarantined like browser
  downloads, and a click on an app, script or installer shows it in Finder
  instead of opening it. Text you send goes to the clipboard only.
- **File Tray.** With "Add received files to File Tray" on (the default), each
  received file is handed to Droppy's own "Add to Droppy Shelf" service. This
  runs a short-lived `osascript` helper (that is why Drop Portal asks for
  `apple-events`); it talks only to Droppy, never to another app, and is
  stopped after 10 seconds at most. Switch the setting off to skip it.
- **Finder.** The Send to phone shortcut asks Finder for the selected files
  with an Apple Event, through a short-lived `osascript` helper, so macOS asks
  once whether Droppy may control Finder. It only reads the selection, and only
  when you press the shortcut. If you said no, System Settings › Privacy &
  Security › Automation turns it on again.
- **Finder Quick Action.** Its shortcut sends each file to this Mac's own
  address (127.0.0.1) with the pairing code. The Mac takes that path only from
  itself, never from the network, keeps the copy in Drop Portal's own folder
  for at most a day and offers it to the phone like any other file.
- **Files waiting for the phone** are remembered by path (not copied) for up
  to 24 hours, in a small list in Drop Portal's own folder.
- **Plain HTTP.** The connection is not encrypted, so someone on the same
  network could read what you send. Use it on networks you trust.
