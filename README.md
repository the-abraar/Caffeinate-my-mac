# Caffeinate

A tiny native macOS menu bar app that wraps `caffeinate(1)` with a dashboard-style UI:
set a duration, keep your Mac awake, and optionally shut it down automatically when
the timer finishes.

![menu bar app](https://img.shields.io/badge/platform-macOS%2013%2B-blue)

## Features

- Lives in the menu bar (no Dock icon) with a live countdown next to the coffee cup icon.
- Click the icon for a small dashboard: big countdown, progress bar, hour/minute steppers,
  and quick presets (30m / 1h / 2h / 3h).
- **Shut down when finished** toggle — cleanly shuts down the Mac via `System Events`
  once a timed session completes naturally (skipped if you stop it manually).
- **Stop** button ends a session early without triggering shutdown.

## Requirements

- macOS 13 (Ventura) or later
- Swift toolchain (Xcode or Command Line Tools) to build from source

## Build & run

```bash
git clone https://github.com/the-abraar/Caffeinate-my-mac.git
cd Caffeinate-my-mac
./build.sh --install   # builds, ad-hoc signs, and copies Caffeinate.app to /Applications
open /Applications/Caffeinate.app
```

Omit `--install` to just produce `Caffeinate.app` in the project directory:

```bash
./build.sh
open Caffeinate.app
```

## How it works

- Starting a session spawns `/usr/bin/caffeinate -d -i -m -s -t <seconds>` and tracks
  its end time to drive the countdown UI.
- Stopping a session (or quitting the app) terminates that child process, so no
  orphaned `caffeinate` processes are left running.
- When "shut down when finished" is on and the timer completes naturally, the app runs
  `osascript -e 'tell application "System Events" to shut down'`. macOS will prompt once
  for Automation permission to control System Events — this is expected.

## Project layout

```
Package.swift                          # Swift package manifest
Info.plist                             # App bundle metadata (LSUIElement = menu bar only)
build.sh                               # Builds + ad-hoc signs Caffeinate.app
Sources/CaffeinateApp/
  CaffeinateAppMain.swift              # MenuBarExtra scene entry point
  ContentView.swift                    # Dashboard UI
  CaffeinateManager.swift              # caffeinate process + timer + shutdown logic
```

## License

MIT
