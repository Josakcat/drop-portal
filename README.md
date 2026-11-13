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
  file, drag drops it anywhere. It also goes to Droppy's File Tray (a setting).
  The card is not drawn over a full-screen app; the file still arrives.
- **Effects you can pick.** Portal light, Liquid, Wormhole, Beam, Paper plane,
  Stardust and Lightning, in any colour or Rainbow, or a cartoon courier: Pip
  the hamster, Tofu the cat, Digby the mole or the Matcha Trio ducklings. A
  landing sparkle and an animated file name finish each crossing.
- **Text too.** Paste on the phone and press Send, and it is on the Mac's
  clipboard with a "Clipboard received" banner. A link can also open in your
  browser if you switch that on.
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
2. Scan it with the phone camera (same Wi-Fi as the Mac). The browser opens the page.
3. In the browser, Add to Home Screen (iPhone: Share › Add to Home Screen) keeps it one tap away.
4. Press Pick, choose items, flick a card off the left edge. Keep the page open
   while a card is sending.

The phone and the Mac must be on the same Wi-Fi. Some office or public Wi-Fi
keeps devices apart; there, turn on the phone's Personal Hotspot and join it
from the Mac. A card that says "Mac not reachable - same Wi-Fi?" sends again
when you tap it.

## Settings

Settings follow the order you use them: Getting started (until the first
crossing), Connect your phone (the QR code and the live phone status), Send to
phone, Look & sound (the effect, its colour, a Preview button, the landing
sound, Landing sparkle, Animated file name and Haptics; Reduce motion turns
every effect into a plain fade and a courier into a still sticker), Recent, Phone
shortcuts and More.

Under More:

- **Add received files to File Tray** is on from the start: every file from
  the phone also goes to Droppy's File Tray, besides Downloads › Drop Portal.
  Switch it off to keep files in Downloads only.
- **Open links from your phone** is off from the start: text from the phone
  goes to the clipboard only. Switch it on and a message that is one web link
  also opens in your browser.
- **Drag to the right edge** (on), the keyboard shortcut (⌃⌥→, Change… opens
  Droppy's Shortcuts page), the Finder Quick Action, the Drop Portal folder,
  and Troubleshooting with Reset pairing, which makes a new code and locks out
  every phone that had the old one.

## Privacy & permissions

- **Local network server.** While Drop Portal is on, the Mac listens on port
  8787 (the phone page, uploads and downloads) and port 8788 (the live preview
  of the card you drag), on your local network only. There is no cloud relay
  and no account: what you send goes straight between the phone and the Mac
  and never leaves your network. Both stop when you switch Drop Portal off. If
  macOS asks whether Droppy may accept incoming connections, that is the phone.
- **Pairing code.** The QR code carries the Mac's local address and a random
  pairing code; every request without it gets 403, so only a phone that
  scanned the code can send or download. Treat the QR code like a password, and
  use Reset pairing to lock out every phone at once.
- **Plain HTTP.** The connection is not encrypted, so someone on the same
  network could read what you send. Use it on networks you trust.
- **Received files** go to Downloads › Drop Portal, never overwriting anything,
  at most 2 GB each, with a cleaned-up name. They are quarantined like browser
  downloads, and a click on an app, script or installer shows it in Finder
  instead of opening it.
- **Apple Events to Finder.** The Send to phone keyboard shortcut asks Finder
  for its selected files, through a short-lived `osascript` helper, so macOS
  asks once whether Droppy may control Finder. It only reads the selection, and
  only when you press the shortcut.
- **"Add to Droppy Shelf".** With Add received files to File Tray on, each
  received file is handed to Droppy's own "Add to Droppy Shelf" service by a
  short-lived `osascript` helper. It talks only to Droppy and is stopped after
  10 seconds at most.
- **Signed shortcuts.** The iPhone shortcuts and the Finder Quick Action are
  built on this Mac with your pairing code in them and signed locally with
  macOS's `shortcuts sign` tool; nothing is uploaded.
- **Zipped folders.** A folder you send to the phone is zipped with macOS's
  `ditto` into Drop Portal's own folder, and the zip is removed 10 minutes
  after the phone downloaded it (or after a day).
- **Finder Quick Action** sends the file's path to this Mac's own address
  (127.0.0.1) with the pairing code; the Mac takes it only from itself, never
  from the network.
- **Files waiting for the phone** are remembered by path (not copied) for up
  to 24 hours, in a small list in Drop Portal's own folder. Recent keeps the
  last 30 transfers as paths only.
