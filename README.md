# ☕ Caffeinate

**Keep your Mac awake for exactly as long as you need — then optionally shut it down.**

A tiny, native menu bar app for macOS. Set a timer, walk away, and your Mac stays awake
(no sleep, no screen saver, no idle sleep) until the timer ends.

![platform](https://img.shields.io/badge/macOS-13%2B-blue)
![arch](https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-green)
![license](https://img.shields.io/badge/license-MIT-lightgrey)

### [⬇️ Download Caffeinate.zip](https://github.com/the-abraar/Caffeinate-my-mac/releases/latest/download/Caffeinate.zip)

---

## What it does

- **Menu bar timer** — a coffee cup in the menu bar with a live countdown next to it.
  No Dock icon, no clutter.
- **One-click presets** — 30m, 1h, 2h, 3h, or pick any hours and minutes.
- **Desktop widget** — see the time left right on your desktop.
- **Shut down when finished** — good for overnight downloads, renders and backups.
  When the timer runs out, the Mac shuts down on its own.
- **Stop any time** — stopping early never shuts the Mac down.
- **Lightweight** — it simply runs Apple's built-in `caffeinate` tool. Nothing runs
  in the background once a session ends.

## Install (1 minute)

1. **[Download Caffeinate.zip](https://github.com/the-abraar/Caffeinate-my-mac/releases/latest/download/Caffeinate.zip)**
   and double-click it to unzip.
2. Drag **Caffeinate.app** into your **Applications** folder.
3. Open it. The app isn't notarized by Apple, so the first launch shows a warning
   that Apple can't verify it. To allow it:
   - Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**
     next to the Caffeinate message, **or**
   - run this once in Terminal:
     ```bash
     xattr -dr com.apple.quarantine /Applications/Caffeinate.app
     ```
4. A ☕ appears in your menu bar. You're done.

**Start it at login (recommended for daily use):**
System Settings → General → Login Items → **+** → choose Caffeinate.

## How to use

1. Click the ☕ in the menu bar.
2. Pick a preset or set hours and minutes.
3. Click **Start**. The cup fills in and the countdown begins.
4. Click **Stop** to end early.

### Desktop widget

Right-click your desktop → **Edit Widgets** → search **Caffeinate** → drag it onto the
desktop. It shows *AWAKE* with the countdown, or *IDLE*. Desktop widgets need macOS 14
(Sonoma) or later. On macOS 13 the widget is available in Notification Center.

### Auto shutdown

Turn on **Shut down when finished** before you start.

- The first time you turn it on, macOS asks to let Caffeinate control **System Events**.
  Click **OK**. You're asked now, so nothing will stop to ask at the end while you're away.
- When the timer finishes, Caffeinate **force-quits every open app and shuts the Mac down**.
  ⚠️ **Unsaved work is lost.** Save your work before you leave.
- If you clicked *Don't Allow* by mistake, enable it under
  System Settings → Privacy & Security → **Automation** → Caffeinate → System Events.

## FAQ

**Can I run two timers at once?**
No. Only one copy of Caffeinate runs at a time. Opening it again does nothing.

**Does it keep running if I close the lid?**
No. macOS sleeps a MacBook when the lid closes, unless it's plugged in with an external
display connected. Keep the lid open.

**How do I uninstall it?**
Quit it from the menu (☕ → Quit), then delete `/Applications/Caffeinate.app` and
`~/Library/Application Support/Caffeinate`.

---

## For developers

Requires Xcode or the Command Line Tools (Swift 5.9+).

```bash
git clone https://github.com/the-abraar/Caffeinate-my-mac.git
cd Caffeinate-my-mac
./build.sh            # builds a universal, ad-hoc signed Caffeinate.app
./build.sh --install  # ...and copies it to /Applications
```

### How it works

- Starting a session spawns `/usr/bin/caffeinate -d -i -m -s -t <seconds>`. Stopping it,
  or quitting the app, terminates that process, so no `caffeinate` process is left behind.
- A file lock in `$TMPDIR` makes sure only one instance runs at a time.
- The app writes the session state to `~/Library/Application Support/Caffeinate/state.plist`.
  The sandboxed widget reads that file through a read-only entitlement.
- Auto shutdown force-terminates every regular app, then runs
  `osascript -e 'tell application "System Events" to shut down'`. Each rebuild is
  re-signed ad hoc, so macOS may ask for Automation permission again after a rebuild.

### Project layout

```
Package.swift                          # Swift package: app + widget targets
Info.plist                             # App bundle metadata (LSUIElement = menu bar only)
WidgetInfo.plist, Widget.entitlements  # Widget extension metadata + sandbox entitlements
build.sh                               # Builds + ad-hoc signs Caffeinate.app (with widget)
Sources/CaffeinateApp/
  CaffeinateAppMain.swift              # MenuBarExtra entry point + single-instance lock
  ContentView.swift                    # Dashboard UI
  CaffeinateManager.swift              # caffeinate process, timer, shutdown, widget state
Sources/CaffeinateWidget/
  CaffeinateWidget.swift               # WidgetKit desktop widget
```

## License

MIT
