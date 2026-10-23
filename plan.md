# Plan: Commute Mode for Caffeinate

Written 2026-10-15. The plan is based on the source code of the four reference repos, not only their READMEs.

## Status (2026-10-15)

Phases 1–4 are built as v1.1 and installed to `/Applications/Caffeinate.app`. Nothing is committed yet.

**Verified:**
- `swift test`: 20 tests pass. They cover the sudoers body (`visudo -c`), the username allowlist, `pmset` parsing, the marker, the agent CPU tree, URL parsing, battery estimate, hotspot detection, history, the CLI, and `failsafe.sh` against a fake sudo: no marker, app dead, PID reused, live app before and after its deadline, garbage values, and sudo failure.
- On the built app:
  - Timer, until-time, +15m (caffeinate is respawned with the new `-t`), until-process-exits, and until-agents-idle all run.
  - A refused lid request leaves the running session alone. Bad URLs are ignored.
  - Quitting ends the session and records it. `kill -9` of the app takes `caffeinate` with it, through `-w`.

**Not verified yet (needs your password, and the lid closed):** acceptance tests 1–6 below, plus:
- whether macOS 26 locks when the lid closes during a session;
- `pmset sleepnow` after the session ends with the lid still closed;
- the auto-arm on a real hotspot;
- the ntfy push.

Run these after ☕ → Settings → Set Up….

## Use case

Agents (Claude Code and Codex) keep running locally while I commute for up to 30 minutes. The Mac is on battery, connected to my iPhone's Personal Hotspot, with the lid closed, inside a backpack that has airflow. When the agents finish or the commute ends, the Mac goes back to sleeping normally.

Target machine: Mac16,1 (MacBook Pro 14", M4), macOS 26.6.2. When I checked `pmset -g batt` it read 73% with 1:47 left under the current load. `/etc/sudoers.d/` is empty and `SleepDisabled` is 0.

## Why the app can't do this today

- `CaffeinateManager.start` runs `caffeinate -d -i -m -s -t N`. These assertions block idle sleep. They don't block **clamshell sleep**, so when the lid closes on battery with no external display, the Mac sleeps anyway. `-s` only has an effect on AC power. The README FAQ says so directly: "Keep the lid open."
- The `caffeinate` child process isn't tied to the app's PID. If the app is killed, the child keeps running until its `-t` timeout ends. The timeout bounds it, but the session no longer matches the app.
- "Shut down when finished" force-quits every app, so on a commute it would kill the running agents.

The only reliable way to stay awake with the lid closed on battery and no external display is `pmset -a disablesleep 1`, which sets `SleepDisabled`. All three reference implementations use it. It needs root, it applies to the whole system, and it **persists across reboots**. Most of the work below is about that last fact.

## What each reference does, and what to take

| Repo | Mechanism (read from source) | Take | Skip |
|---|---|---|---|
| **adiab98/Awake** (`LidGuard.swift`, `AwakeController.swift`, `PowerManager.swift`) | A sudoers rule at `/etc/sudoers.d/awake` that allows **exactly** `pmset -a disablesleep 0/1` and `pmset -b/-c lowpowermode 0/1`. It's installed through `visudo -c -f tmp && install -m 440 -o root -g wheel`. The automatic code paths use `sudo -n` only, so a password prompt never surprises the user. Status comes from `sudo -n -l`, not from checking that the file exists. It validates the username before splicing it into the rule. It turns on Low Power Mode while the lid is closed and restores the previous setting afterwards. At `thermalState .serious/.critical` it stops and restores lid sleep. It detects agents by watching transcripts with FSEvents (`~/.claude/projects`, `~/.codex/sessions`, …), by summing CPU across each agent's process tree (≥5%), and by looking for established TCP connections to API hosts through libproc. A 45 s sticky hold covers short gaps. It has a Revoke button and a test that pipes the sudoers body through `visudo -c`. | Sudoers pattern, `sudo -n`-only automatic paths, `sudo -l` check, username allowlist, Low Power Mode save/restore, thermal stop, transcript watching, CPU-tree check, Revoke, visudo test | App Store build split, libproc network probe (754 lines; add only if needed), Cursor/Desktop heuristics |
| **nickita-khylkouski/awake** (`awake-power`, `ui/main.swift`, `awake` CLI) | A root-owned helper `awake-power on|off <uid>` that saves the **prior** `SleepDisabled` value, reference-counts owners across users, clears owners when `kern.boottime` changes, and restores the prior value after the last owner leaves. A marker file `closed-lid-active` drives crash recovery on the next launch. CLI commands: `for 30m`, `until 17:30`, `status --json`, plus an Extend action. Login item through `SMAppService`. A blackout overlay on a global hotkey. SECURITY.md says "never put it in a bag while closed-lid mode is active". | Saving and restoring the prior value, marker-file crash recovery, `until HH:MM`, Extend, `status --json`, SMAppService | Root helper and multi-user reference counting (this is a single-user Mac; a sudoers rule is enough), blackout and hotkey (pointless with the lid closed), file-mailbox IPC (a URL scheme is native) |
| **x74353/Amphetamine** (Power Protect) | `Cmnd_Alias` for `disablesleep 0/1`, granted to `%admin`. It exists because on Apple Silicon, **closed-display mode stops working after the power source changes** (charger or USB-C display plugged in or pulled), so the setting has to be applied again. | Re-apply `disablesleep 1` on every power-source change while a session is active | Granting it to `%admin` (scope it to my user) |
| **x74353/amphetamine-enhancer** (`cdmManager.sh` + LaunchAgent, `StartInterval 10`) | An external watchdog. If the closed-display flag is set and Amphetamine isn't running, or holds no assertion, it restores sleep. It also triggers on any running process. | **A launchd fail-safe that runs outside the app.** A "keep awake while this process runs" trigger, which `caffeinate -w <pid>` already provides | Sparkle, LetsMove, the separate helper app |

## Design decisions

1. **Mechanism.** Keep `caffeinate` for idle sleep and add `-w <app pid>` so it dies with the app. While a lid-closed session is active, also set `pmset -a disablesleep 1` and restore the **saved prior value** afterwards, not a hard-coded 0. Don't migrate to raw `IOPMAssertion`; it gains nothing here.
2. **Privilege.** Use a sudoers file `/etc/sudoers.d/caffeinate-my-mac`. **The name must not contain a `.`**, because sudo silently skips `sudoers.d` files whose names contain one. It grants my user only these exact command lines:
   ```
   <user> ALL=(root:wheel) NOPASSWD: /usr/bin/pmset -a disablesleep 0
   <user> ALL=(root:wheel) NOPASSWD: /usr/bin/pmset -a disablesleep 1
   <user> ALL=(root:wheel) NOPASSWD: /usr/bin/pmset -b lowpowermode 0
   <user> ALL=(root:wheel) NOPASSWD: /usr/bin/pmset -b lowpowermode 1
   ```
   Install it once through `osascript … with administrator privileges` running `visudo -c -f tmp && install -m 440 -o root -g wheel tmp dest`. Revoke runs `rm -f` the same way. Automatic code paths only ever call `sudo -n` and show an error rather than a prompt. Known trade-off: any process running as my user can now toggle `disablesleep`. The worst it can do is keep the Mac awake.
3. **Fail-safe (the backpack rule).** If the app crashes in the bag, the Mac would stay awake indefinitely. Four layers protect against that:
   - Stop, timer end, Quit and `applicationWillTerminate` all restore the prior value.
   - On start, write the marker `~/Library/Application Support/Caffeinate/lid-session` containing `prior=<0|1> pid=<pid>`. On launch, if the marker exists, restore and delete it.
   - **A LaunchAgent** `com.abraar.caffeinateapp.failsafe` (`StartInterval 30`, `RunAtLoad true`) runs a shell script of about 10 lines bundled in `Resources/`. If the marker exists and `kill -0 $pid` fails, it runs `sudo -n pmset -a disablesleep $prior` and deletes the marker. `RunAtLoad` also covers a reboot during a session, since `disablesleep` survives reboots. The script only accepts `0` or `1`, and sudoers enforces that too.
   - **Hard cap.** A lid-closed session ends after at most 2 h, even if it was started as "until agents finish".
4. **Safety stops while a lid-closed session is active.** When `ProcessInfo.thermalState` reaches `.serious` or worse, stop and restore. When the battery is at or below 15% (from `IOPSCopyPowerSourcesInfo`), stop and restore. Turn on Low Power Mode on battery for the duration and restore the previous setting. When a session ends with the lid still closed, verify the Mac actually sleeps. If it doesn't within 60 s, run `pmset sleepnow`, which needs no root.
5. **Power-source changes** (Amphetamine's Power Protect). Register `IOPSNotificationCreateRunLoopSource`. During a session, if `pmset -g` then reports `SleepDisabled 0`, set it to 1 again.
6. **Shutdown and commute don't mix.** Hide "Shut down when finished" while lid mode is on, because it would force-quit the agents.

## Phase 1: Commute Mode (MVP; the use case needs all of it)

- A "Keep awake with lid closed" toggle. The first time it's turned on, it runs the one-time setup (explain, then ask for the admin password once). Add a Revoke button and a status line: "Lid mode: ready / needs setup".
- A **Commute** preset: 45 min, lid mode on, shutdown off.
- Everything in decisions 1–6.
- **Lock when the lid closes.** In a bag on public transport, someone opening the lid must hit a lock screen. Check first whether macOS 26 still locks on lid close while `SleepDisabled=1` (expected: the display turns off, and "Require password immediately" applies). At setup, read `sysadminctl -screenLock status` and warn if the delay isn't immediate. Fallback: watch `AppleClamshellState` on `IOPMrootDomain` and call `pmset displaysleepnow` when the lid closes.
- Menu bar: show a lid icon and a battery % next to the countdown while lid mode is active. Add a `lid` key to `state.plist` and show it in the widget.
- README: replace the lid FAQ, document setup and revoke, and warn about heat and bags.

**Acceptance (on this Mac, on battery):**
1. Start Commute, close the lid for 10 min while `while true; do date >> ~/lidtest.log; sleep 5; done` runs. The log has no gap over 10 s, and `pmset -g log | grep -i " Sleep "` shows no sleep in that window.
2. When the timer ends, `pmset -g | grep SleepDisabled` reads its prior value, and the Mac sleeps within 60 s with the lid closed.
3. `kill -9` the app during a session: within 30 s the LaunchAgent restores `SleepDisabled` and deletes the marker.
4. Pull or plug the charger during a session: it's still awake (the Power Protect case).
5. Simulate thermal and battery-floor stops through a debug hook: sleep is restored.
6. Revoke: `/etc/sudoers.d/caffeinate-my-mac` is gone and the toggle returns to "needs setup".

## Phase 2: Agent-aware sessions ("until my agents finish")

- A **Until agents idle** mode. It watches transcripts with FSEvents under **every Claude config dir on this machine**: `~/.claude/projects`, `~/.claude-work/projects`, `~/.claude-hat/projects`, `~/.claude-biz/projects`, `~/.claude-grr/projects` (glob `~/.claude*/projects`), plus `~/.codex/sessions`. Activity means a `.jsonl` write within the grace window (2 min).
- A long tool call, such as a 10-minute build, writes nothing to the transcript until it finishes. To cover that, poll `ps -axo pid=,ppid=,%cpu=,comm=` every 15 s. A session counts as active if any descendant of a `claude` or `codex` process is above 5% CPU. That's one fork every 15 s, which is cheap. Skip adiab98's libproc socket probe unless a model's thinking time outlasts the grace window in practice.
- After N minutes idle (default 5), end the session and restore sleep. The 2 h hard cap still applies.
- **Phone notification**, since the Mac is in the bag: post "Agents idle, Mac going to sleep" or "Stopped: battery 15%" to an optional ntfy.sh topic (one `URLSession` POST, topic set in settings), plus a local `UNUserNotification`.

## Phase 3: Hotspot awareness

- Detect the iPhone hotspot **without Location permission**. Reading the SSID through CoreWLAN needs Location Services on macOS 14+. Instead, use `NWPathMonitor`: Wi-Fi with `isExpensive == true`, and a gateway of `172.20.10.1` (the iPhone hotspot subnet is `172.20.10.0/28`).
- **Opt-in auto-arm.** When I'm on the hotspot and agents are active, offer to start Commute, or start it automatically. It has to arm **before** the lid closes. Without `disablesleep`, closing the lid sleeps the Mac at once and the app never gets a chance to react.
- Offline log: record each interval the connection drops and show it in the session summary ("offline 2m10s at 08:42"), so a failed agent run can be explained.
- README tips: USB tethering is more stable than Wi-Fi but drains the Mac's battery to charge the phone. The hotspot stays on as long as the Mac stays connected. `tcpkeepalive` is already 1.

## Phase 4: Other goodies (ranked for this use)

1. **Launch at login** through `SMAppService.mainApp` (macOS 13+). This replaces the manual Login Items step in the README.
2. **Extend +15 min** and **Until HH:MM** (from nickita).
3. **CLI and URL scheme**: `caffeinate-my-mac://start?minutes=45&lid=1`, `/stop`, `/extend?minutes=15`, plus a 20-line `caffeinate-my-mac` shell wrapper (`for 45m`, `until 09:30`, `commute`, `off`, `status --json`). With these, agents, Raycast and Shortcuts can start a session. The app reads `status` from `state.plist`.
4. **Session history**: the last 20 sessions with lid-closed minutes, battery % used, peak thermal state and offline time. This shows the real drain of a 30-minute commute.
5. **Pre-start battery estimate**: "45 min ≈ 18% at current draw", derived from IOPS time remaining.
6. **Keep awake while a process runs**: pick a PID or app, then run `caffeinate -w <pid>`. This covers Amphetamine's app-based sessions with no new mechanism.
7. A **Shortcuts automation** (macOS 26 Shortcuts has automations; verify the Wi-Fi trigger) calling the URL scheme, as an alternative to the Phase 3 auto-arm.

## Explicitly skipped

- Blackout overlay and global hotkey: useless with the lid closed.
- Mouse jiggler, Drive Alive, Amphetamine's trigger matrix (IP, USB device, display, schedule): this use case doesn't need them.
- A multi-user root helper with owner reference counting: single-user Mac.
- App Store build, Sparkle updater, LetsMove.
- A libproc network-socket probe: deferred until Phase 2 proves the transcript + CPU signals insufficient.

## Files that change

| File | Change |
|---|---|
| `Sources/CaffeinateApp/LidControl.swift` (new, ~150 lines) | Sudoers install, revoke and status (`sudo -n -l`). `setSleepDisabled`, Low Power Mode read and set, prior-value marker, `pmset -g` parsing, username validation |
| `Sources/CaffeinateApp/CaffeinateManager.swift` | `lidMode` on a session, `-w getpid()`, hard cap, observers for thermal, battery and power source, restore on every exit path, shutdown disabled during lid mode |
| `Sources/CaffeinateApp/CaffeinateAppMain.swift` | Crash recovery on launch (marker present → restore); `onOpenURL` (Phase 4) |
| `Sources/CaffeinateApp/ContentView.swift` | Lid toggle with setup and revoke, Commute preset, lid and battery status |
| `Sources/CaffeinateApp/AgentWatcher.swift` (Phase 2) | FSEvents on `~/.claude*/projects` and `~/.codex/sessions`, plus the `ps` CPU-tree check |
| `Resources/failsafe.sh`, `Resources/com.abraar.caffeinateapp.failsafe.plist` | Installed to `~/Library/LaunchAgents` during lid setup; removed by Revoke |
| `Sources/CaffeinateWidget/CaffeinateWidget.swift` | Lid-mode indicator |
| `build.sh` | Copy `Resources/*` into `Contents/Resources` |
| `Info.plist` | `CFBundleURLTypes` (Phase 4) |
| `Package.swift` + `Tests/` | A test target: the sudoers body passes `visudo -c -f`, username allowlist, `pmset -g` / `-g custom` parsing, restore-prior logic. If XCTest isn't available with only the Command Line Tools installed, use Swift Testing or a `--selftest` flag. |
| `README.md` | Lid FAQ, setup and revoke, bag and heat warning, CLI |

## Risks

- **`disablesleep` is system-wide and survives reboots.** The LaunchAgent fail-safe isn't optional. Ship it in the same change as the toggle.
- **Heat.** The lid is closed in a bag. The M4 MacBook Pro has a fan, but its air intake is restricted. The thermal stop and Low Power Mode are the only guards.
- **Battery.** Local builds and tests by agents drain much faster than idle. The 15% floor stops the session before the Mac dies mid-write.
- **Apple Silicon quirks.** The Power Protect issue shows that macOS can drop closed-display mode on a power-source change, and future macOS updates may change `pmset` behaviour. Acceptance test 4 covers the current case.
- **Ad-hoc signing.** The sudoers rule doesn't depend on the signature, but the existing System Events Automation permission still resets after every rebuild.

## Status and gaps (2026-10-19 review)

Reviewed `main` at `a4196c1`. `swift test`: 24 tests pass. No lid-closed test was run. The latest release is still v1.1.0 (2026-10-15), three commits behind `main`.

**Verified fixed in code:**
- The CLI no longer reports success when the app never answers. It waits 10 s and exits 3 (`Resources/caffeinate-my-mac:56-67`, test `testNoAnswerExitsThree`).
- Still in place from the 2026-10-18 pass: the display may sleep by default (`CaffeinateManager.swift:244-247`), auto shutdown has a 60 s countdown with Cancel (`CaffeinateManager.swift:274-293`, `ContentView.swift:90-103`), the sudoers rule is staged as root before `visudo` (`LidControl.swift:43-58`), and the app has an icon (`Info.plist:19-20`).

**Still open:**
- Unsigned and not notarized. The v1.1.0 zip is ad-hoc signed, `spctl` rejects it, and it has no stapled ticket.
- Acceptance tests 1–6 above have still not been run.
- The niche is still full of free alternatives: 2 stars, 0 forks, 3 downloads.

**Bugs found:**
- If macOS can't open `caffeinate-my-mac://` at all, `open` fails and `set -e` exits 1, which the README calls "refused". Exit 3 only covers an app that opens but stays silent (`Resources/caffeinate-my-mac:54`). Fix: `$open_url … || exit 3`, plus a test that uses `/usr/bin/false` as the opener.
- The CLI can read an answer meant for something else. It clears `refused`, then opens the URL. If a running session ends or is extended before the app handles the URL, that write says `refused=false`, and the CLI exits 0 even if the app then refuses (`Resources/caffeinate-my-mac:53-59`, `CaffeinateManager.swift:559-571`). Fix: put a request id in the URL and wait for the app to echo it in `state.plist`.

**Gaps, most important first:**
1. **The fixes aren't released.** The README's download is v1.1.0. It still has the sudoers check-then-install race, keeps the display on, force-quits with no countdown, and its CLI always exits 0. `Info.plist` still says 1.1 (build 2), so a new build would carry the same version.
2. **Unsigned, with an admin password prompt.** `build.sh:28-31` signs ad hoc, and the README tells users to strip the quarantine flag. Nobody can tell a tampered zip from the real one.
3. **Lid mode is unproven.** The headline feature has never passed acceptance tests 1–6 on a closed lid.
4. **No update path.** No Sparkle and no Homebrew cask, so v1.1.0 users never get the race fix.
5. **No demand.** Free tools (Sleepless, adiab98/Awake, crafter awake, Lidless, Amphetamine) cover the same job, with better distribution.
6. **The passwordless `pmset` rule works for any process running as the user.** The Set Up screen doesn't say so.
7. **Failures stay quiet in the app.** A refused start from the popover or a URL only sets the grey caption; nothing is notified (`CaffeinateManager.swift:131-167`). The notification prompt appears at first launch with no context (`CaffeinateManager.swift:94`).
8. **UI polish.** Settings and history sit in the menu bar popover, warnings start with ⚠️ instead of an SF Symbol, history dates are always 24-hour (`SessionHistory.swift:27`), there are no accessibility labels, and the README has no screenshots.
9. **Weak spots in automation.** Any local app can start a lid session or stop one through the URL scheme. ntfy alerts go to a public topic with no token or custom server.
10. **No revenue model.** MIT and free. Tips are the realistic ceiling.

**Next steps, in order:**
1. Owner: run acceptance tests 1–6 on the M4 on battery and write the results here (about 1 hour).
2. Agent: fix the two CLI bugs above and bump `Info.plist` to 1.2, build 3 (about 30 minutes).
3. Owner: build and release v1.2, so the download has the sudoers fix and the shutdown countdown (about 20 minutes).
4. Owner: decide whether this is a public product or a personal tool. If public, join the Apple Developer Program ($99/yr).
5. Agent, after step 4: Developer ID signing with hardened runtime and notarization in `build.sh`, SHA-256 in the release notes, a Homebrew cask, and two README screenshots.
6. Agent: notify on refused starts, explain the `pmset` trade-off in Set Up, add accessibility labels, and use localized history dates.

## Status (2026-10-22, fixes from `CrtiQue_Oct21.md`)

Fixed in code on `main`, with tests where the logic changed (`swift test`: 36 pass). None of it has run on the M4 with the lid closed yet.

- B2: a cold-launched `--lid` CLI call checks setup itself instead of being refused.
- B3, B5: a failed restore notifies and moves the marker's deadline to now, so the failsafe retries every 30 s. The failsafe also restores at 10% or less on battery while the app runs. The app refreshes the installed `failsafe.sh` at launch, so Macs set up earlier get the fix.
- B4: the 2 h cap counts across back-to-back lid sessions.
- B6: every refused start notifies. Set Up says the sudoers rule covers any app running as the user.
- B7: upkeep rewrites the session's own marker. B8: every state write answers `refused`. B9: `status` exits 1 when the app's pid is gone.
- B10: sessions end on the wall clock (caffeinate's `-t` runs on uptime). B12: App Nap is off during a session.
- B11 (npm Claude runs as `node`): not verified, since there's no npm install here. Left as is.
- `CaffeinateManager` takes a `PowerControl`, so tests drive it with a fake and never call sudo or pmset.

**Still to run on the M4, on battery:** acceptance tests 1–6 above, plus:
- B3: remove the sudoers rule mid-session, stop, and check that the failsafe restores `SleepDisabled` within about 30 s.
- B5: let a lid session run below 10% with the app stopped (`kill -STOP`), and check that the failsafe restores.
- B10: start a 5-minute non-lid timer, sleep the Mac for 10 minutes, wake it, and check that the session ends within a second.
- B12: check that the lock on lid close still fires about 1 s after closing, with the popover closed.

## Status (2026-10-24, open items from Phases 1-4)

`swift test` and `./build.sh` pass after each change below. Nothing here has run with the lid closed.

**Phase 1:**
- The menu bar shows a laptop icon next to the countdown and battery % during a lid session (the spec asked for it; only the battery % was there).
- Acceptance test 5 now has its debug hook. During a lid session, run `defaults write com.abraar.caffeinateapp debugBatteryPercent -int 14` (fakes 14% on battery) or `defaults write com.abraar.caffeinateapp debugThermal -int 2` (fakes `.serious`). Within 30 s the session stops and restores sleep. Check `pmset -g | grep SleepDisabled`, then `defaults delete com.abraar.caffeinateapp debugBatteryPercent` (or `debugThermal`): while a key is set, lid mode refuses to start. The thermal reading now goes through `PowerControl`, so both stops have unit tests.
- From the 2026-10-19 next steps (step 6, the agent part): the menu bar item, the countdown, and the widget's icon-only lid and shutdown badges have accessibility labels. History dates follow the locale's 12 or 24 hour clock. The two ⚠️ warnings in Settings use an SF Symbol like the rest.

**Phase 2:** transcript FSEvents on every `~/.claude*/projects` plus `~/.codex/sessions`, the 15 s `ps` CPU-tree check, the 2 h cap, ntfy and local notifications were already in place. The one gap was "after N minutes idle (default 5)": N was fixed at 5. It's now a stepper (1-60 min) under *When agents go idle*, kept in `UserDefaults` (`agentIdleMinutes`), with a test. Still as before: B11 (npm Claude runs as `node`, so its CPU isn't counted) and config dirs created after a session starts aren't watched until the next session.

**Phase 3:** hotspot detection (`NWPathMonitor`, expensive or gateway `172.20.10.1`) and the opt-in auto-arm were already in place. Two gaps closed:
- The offline log recorded only a total. Each dropout is now kept, and the session summary and its notification say "offline 2m10s at 08:42, 30s at 08:50". The history line still shows the total. Tested.
- README tips: added that the hotspot stays on while the Mac stays connected, and that `tcpkeepalive` is already 1 (checked on this Mac).

Still for the owner: the auto-arm on a real iPhone hotspot (from the 2026-10-15 list).

**Phase 4, in the ranked order:**
1. Launch at login (`SMAppService.mainApp`): already in place.
2. Extend +15 min and Until HH:MM: already in place.
3. CLI and URL scheme: already in place.
4. Session history: lid sessions now also record how long the lid was really shut ("31m · lid closed 28m"). Records from older builds still load (tested). The closed time is counted from the 1 s tick, so it isn't unit-tested: a fake closed lid would make the test run `pmset displaysleepnow` and, 60 s after the session, `pmset sleepnow` on this Mac.
5. Pre-start battery estimate: already in place.
6. Keep awake while a process runs: already in place.
7. **Deferred to the owner:** a Shortcuts automation on joining the hotspot. It needs someone to check in the Shortcuts app on macOS 26 whether a Wi-Fi network trigger exists and runs without asking. If it does, the action is **Open URLs** with `caffeinate-my-mac://idle?lid=1`; it could then replace the in-app auto-arm.

**Still for the owner (needs the M4, the lid closed, a phone or a decision):**
- Acceptance tests 1-6 on battery. Test 5 can now use the `defaults` hook above.
- The 2026-10-22 hardware checks: B3, B5, B10, B12.
- From 2026-10-15: lock screen on a reopened lid on macOS 26, `pmset sleepnow` after a session ends with the lid shut, the auto-arm on a real hotspot, and the ntfy push.
- The Shortcuts trigger (Phase 4 item 7).
- Public product or personal tool (`../decision.md` lines 40 and 63 still disagree). Signing, notarization and a cask wait on it.
- The rebuilt app was not launched here: only `swift build`, `swift test` (40 pass) and `./build.sh`.
