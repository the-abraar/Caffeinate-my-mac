# ☕ Caffeinate

**Keep your Mac awake for exactly as long as you need, even with the lid closed. Then let it
sleep, or shut it down.**

A tiny, native menu bar app for macOS. Set a timer, walk away, and your Mac stays awake
(no idle sleep; the screen still turns off and locks unless you turn on **Keep display
awake**) until the timer ends. Or let it stay awake
until your AI agents finish, with the lid closed in your bag.

![platform](https://img.shields.io/badge/macOS-13%2B-blue)
![arch](https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-green)
![license](https://img.shields.io/badge/license-MIT-lightgrey)

### [⬇️ Download Caffeinate.zip](https://github.com/the-abraar/Caffeinate-my-mac/releases/latest/download/Caffeinate.zip)

The download is still v1.1.0 (2026-10-15). This README describes `main`: the display may
sleep by default, auto shutdown has a 60-second countdown, the CLI has exit codes, and the
app has an icon. Those changes arrive in the next release. Build from source to get them now.

---

## What it does

- **Menu bar timer**: a coffee cup in the menu bar with a live countdown next to it.
  No Dock icon, no clutter.
- **One-click presets**: 30m, 1h, 2h, 3h, any hours and minutes, or until a time of day.
  **+15m** extends a running timer.
- **Lid closed**: keeps a MacBook running with the lid shut, on battery, with no external
  display. Made for agents that keep working while you commute.
- **Commute**: one click for 45 minutes with the lid closed.
- **Until agents finish**: stays awake while Claude Code or Codex is working, and ends
  5 minutes after they go idle.
- **Until an app quits**: stays awake while a chosen app or process is running.
- **iPhone hotspot aware**: optionally turns on lid mode by itself when you join your
  iPhone's hotspot while agents are working.
- **Phone alerts**: a notification when a session ends, sent to your phone through
  [ntfy.sh](https://ntfy.sh) if you set a topic.
- **Safety stops**: a lid-closed session ends if the Mac gets hot, if the battery drops
  to 15%, or after 2 hours, and the Mac goes back to sleeping normally.
- **Session history**: the last 20 sessions with battery used, heat and time offline.
- **Desktop widget**: see the time left right on your desktop.
- **Shut down when finished**: good for overnight downloads, renders and backups.
- **Command line and URL scheme**: control it from Terminal, Shortcuts or an agent.
- **Lightweight**: it runs Apple's built-in `caffeinate` tool and `pmset`. Once a session
  ends, only the lid-mode failsafe check runs (every 30 seconds, and only after lid setup).

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

**Start it at login (recommended for daily use):** ☕ → Settings → **Launch at login**.

## How to use

1. Click the ☕ in the menu bar.
2. Under **Ends**, choose *After a timer*, *At a time*, *When agents go idle* or
   *When an app quits*.
3. Click **Start**. The cup fills in and the countdown begins.
4. Click **Stop** to end early, or **+15m** to add time.

### Lid closed (Commute mode)

A MacBook normally sleeps the moment its lid closes, unless it's plugged in with an external
display. The only way to keep it running on battery with the lid shut is the system setting
`pmset -a disablesleep 1`, which needs administrator rights. To set it up once:

1. ☕ → **Settings** → **Set Up…**, then enter your password once.
   This installs `/etc/sudoers.d/caffeinate-my-mac`, which lets your user run exactly these
   four commands without a password, and nothing else:
   ```
   /usr/bin/pmset -a disablesleep 0
   /usr/bin/pmset -a disablesleep 1
   /usr/bin/pmset -b lowpowermode 0
   /usr/bin/pmset -b lowpowermode 1
   ```
   The rule is checked with `visudo` before it's installed. Setup also installs a small
   failsafe (see below).
2. Click **Commute: 45 min, lid closed**, or turn on **Keep awake with lid closed** for any
   session, then close the lid.

During a lid-closed session:

- **Low Power Mode** is on while on battery (less heat in a bag). Your previous setting
  comes back afterwards.
- The session **stops by itself** if macOS reports serious heat, if the battery drops to
  15%, or after 2 hours. Whatever ends it, your previous sleep settings come back and the
  Mac sleeps again, even with the lid still closed.
- If you plug in or unplug the charger, the setting is applied again. On Apple Silicon,
  closed-lid mode can otherwise stop working after a power change.
- Closing the lid turns the display off. For anyone who opens the lid to see a lock screen,
  set **System Settings → Lock Screen → Require password after screen saver begins or
  display is turned off** to **Immediately**. Caffeinate warns you if it isn't.
- "Shut down when finished" is unavailable, because it would force-quit your agents.

⚠️ **Heat.** A closed laptop in a bag can't cool itself well. Only do this in a bag with
airflow and for short trips. The heat stop is a last resort, not a cooling system.

**The failsafe.** `disablesleep` applies to the whole system and stays on after a reboot,
so Caffeinate never relies on itself alone to turn it off:

- Every session writes `~/Library/Application Support/Caffeinate/lid-session` with your
  previous settings and a hard deadline.
- A LaunchAgent (`com.abraar.caffeinateapp.failsafe`) checks it every 30 seconds and at
  login. If Caffeinate isn't running, or is still running past the deadline, the failsafe
  restores your previous settings.
- When Caffeinate starts, it also restores the settings left behind by a run that crashed.

**To remove it:** ☕ → Settings → **Revoke**. This restores sleep if a session is running,
then deletes the sudoers rule and the failsafe. To do the same by hand:
```bash
sudo pmset -a disablesleep 0
sudo rm -f /etc/sudoers.d/caffeinate-my-mac
launchctl bootout gui/$(id -u)/com.abraar.caffeinateapp.failsafe
rm -f ~/Library/LaunchAgents/com.abraar.caffeinateapp.failsafe.plist
```

### Until agents go idle

The session counts agents as working while either of these is true:

- a transcript is being written under `~/.claude*/projects` (every Claude config folder,
  such as `~/.claude` and `~/.claude-work`) or `~/.codex/sessions`;
- a `claude` or `codex` process and everything it started use more than 5% CPU. This covers
  long builds and test runs that write nothing until they finish.

The session ends 5 minutes after the last sign of work. The countdown shows its hard cap:
2 hours with the lid closed, 12 hours otherwise.

### iPhone hotspot

Caffeinate recognizes your iPhone's Personal Hotspot (over Wi-Fi or USB) without Location
permission: macOS marks it as an expensive network, and the iPhone is always at
`172.20.10.1`. Turn on **Settings → Auto commute on iPhone hotspot**. When you join the
hotspot while agents are working, Caffeinate starts a lid-closed session that runs until they
go idle. This happens once per hotspot connection, and **before** you close the lid. Closing
the lid without it would put the Mac to sleep immediately. The session history records how
long you were offline, which helps explain an agent run that failed.

Tip: a USB cable to the iPhone is a steadier connection than Wi-Fi, but the Mac charges the
phone from its own battery.

### Phone alerts

Pick a hard-to-guess topic name, enter it under **Settings → ntfy.sh topic**, and subscribe
to the same topic in the ntfy app on your phone. You get "Agents idle at 08:42" or "Stopped:
battery at 15%" while the Mac is in your bag. ntfy.sh topics are public, so anyone who knows
the name can read them. Leave the field empty to keep alerts local only.

### Command line, Shortcuts and agents

```bash
ln -s /Applications/Caffeinate.app/Contents/Resources/caffeinate-my-mac ~/.local/bin/

caffeinate-my-mac for 45m --lid     # 45 minutes, lid can close
caffeinate-my-mac until 09:30
caffeinate-my-mac commute
caffeinate-my-mac idle --lid        # until Claude Code / Codex go idle
caffeinate-my-mac while 12345       # while that process runs
caffeinate-my-mac extend 15m
caffeinate-my-mac off
caffeinate-my-mac status --json
```

Exit codes: `0` ok, `1` the app refused (for example, the lid setup is missing), `2` bad input,
`3` no answer from the app within 10 seconds. If macOS can't find the app at all, `open` fails
and the CLI exits `1` with its error. `extend` and `off` don't wait for an answer. (The v1.1.0
download's CLI always exits `0`.)

The CLI opens `caffeinate-my-mac://` URLs, which you can also use from Shortcuts (**Open
URLs**) or Raycast: `start?minutes=45&lid=1`, `start?until=09:30`, `commute`, `idle?lid=1`,
`while?pid=123`, `extend?minutes=15`, `stop`. Any app on your Mac can open these URLs.
They can only start or stop sessions within the same limits, and lid mode still needs the
one-time setup.

### Desktop widget

Right-click your desktop → **Edit Widgets** → search **Caffeinate** → drag it onto the
desktop. It shows *AWAKE* with the countdown, or *IDLE*, plus a laptop icon in lid mode.
Desktop widgets need macOS 14 (Sonoma) or later. On macOS 13 the widget is available in
Notification Center.

### Auto shutdown

Turn on **Shut down when finished** before you start (timer sessions without lid mode).

- The first time you turn it on, macOS asks to let Caffeinate control **System Events**.
  Click **OK**. You're asked now, so nothing will stop to ask at the end while you're away.
- When the timer finishes, a 60-second countdown starts (cancel it from the ☕ menu, or with
  `caffeinate-my-mac off`). Then Caffeinate **force-quits every open app and shuts the Mac
  down**. ⚠️ **Unsaved work is lost.** Save your work before you leave.
- If you clicked *Don't Allow* by mistake, enable it under
  System Settings → Privacy & Security → **Automation** → Caffeinate → System Events.

## FAQ

**Can I run two timers at once?**
No. Only one copy of Caffeinate runs at a time. Opening it again does nothing. Starting a
new session replaces the current one.

**Does it keep running if I close the lid?**
Yes, if you set up lid mode and the session has **Keep awake with lid closed** turned on
(Commute does this). Otherwise no: macOS sleeps a MacBook when the lid closes.

**How do I uninstall it?**
☕ → Settings → **Revoke** (if you set up lid mode), turn off **Launch at login**, quit it
(☕ → Quit), then delete `/Applications/Caffeinate.app` and
`~/Library/Application Support/Caffeinate`.

---

## For developers

Requires Xcode (Swift 5.9+).

```bash
git clone https://github.com/the-abraar/Caffeinate-my-mac.git
cd Caffeinate-my-mac
swift test            # unit tests, the failsafe script and the CLI
./build.sh            # builds a universal, ad-hoc signed Caffeinate.app
./build.sh --install  # ...and copies it to /Applications
```

### How it works

- A session spawns `/usr/bin/caffeinate -i -m -s -t <seconds> -w <app pid>`, plus `-d` only
  when **Keep display awake** is on (never in lid mode). `-w` makes it exit with the app, so a
  crash leaves no assertion behind.
- Lid mode wraps the session with `sudo -n pmset -a disablesleep 1` and Low Power Mode, and
  then restores the previous values saved in the `lid-session` marker. `Resources/failsafe.sh`
  is the LaunchAgent that restores them if the app dies or hangs past the deadline.
- Agents are detected with FSEvents on the transcript folders, plus `ps` every 15 seconds.
- A file lock in `$TMPDIR` makes sure only one instance runs at a time.
- The app writes the session state to `~/Library/Application Support/Caffeinate/state.plist`.
  The sandboxed widget and `caffeinate-my-mac status` read it.
- Auto shutdown force-terminates every regular app, then runs
  `osascript -e 'tell application "System Events" to shut down'`. Each rebuild is
  re-signed ad hoc, so macOS may ask for Automation permission again after a rebuild.
  The sudoers rule doesn't depend on the signature.

### Project layout

```
Package.swift                          # Swift package: app, widget, tests
Info.plist                             # App bundle metadata, caffeinate-my-mac:// URL scheme
WidgetInfo.plist, Widget.entitlements  # Widget extension metadata + sandbox entitlements
build.sh                               # Builds + ad-hoc signs Caffeinate.app (with widget)
Resources/
  failsafe.sh                          # LaunchAgent: restores sleep if the app dies mid-session
  caffeinate-my-mac                    # Command-line wrapper around the URL scheme
Sources/CaffeinateApp/
  CaffeinateAppMain.swift              # MenuBarExtra entry point, URL handling, single-instance lock
  ContentView.swift                    # Dashboard UI
  CaffeinateManager.swift              # Sessions, safety stops, auto commute, history, shutdown
  LidControl.swift                     # sudoers setup/revoke, pmset, marker, failsafe install
  PowerInfo.swift                      # Battery, lid state, screen-lock check
  AgentWatcher.swift                   # Claude Code / Codex activity
  NetworkWatcher.swift                 # Online state, iPhone hotspot detection
  Notifier.swift                       # Local notifications + ntfy.sh
  SessionHistory.swift                 # Last 20 sessions
  URLCommand.swift                     # caffeinate-my-mac:// parsing
Sources/CaffeinateWidget/
  CaffeinateWidget.swift               # WidgetKit desktop widget
Tests/CaffeinateAppTests/              # XCTest suite
```

## License

MIT
