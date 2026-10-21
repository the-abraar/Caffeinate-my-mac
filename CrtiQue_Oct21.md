# Caffeinate-my-mac: independent critique, 2026-10-21

Reviewer: one agent working read-only. It reviewed `main` at `9924c9b` (version 1.2, build 3, not released). This is the first critique, so there is no baseline.
Evidence used: the code read in full, `swift build` and `swift test` (scratch build dir, 26 tests, 0 failures), `gh` release data, `codesign` and `spctl` on the installed app, the local `history.json`, and `pmset -g log`. Nothing was installed, no power settings were changed, and the app was not launched.

## 1. Verdict up front

- **What it is:** a native SwiftUI menu bar app that wraps `caffeinate` and, with a one-time sudoers rule, `pmset -a disablesleep`. It keeps a MacBook awake with the lid closed until a timer ends or until Claude Code and Codex go idle. Extras: a hotspot auto-arm, ntfy alerts, a CLI and URL scheme, a widget, and a LaunchAgent failsafe.
- **Who it is for:** right now, one person: the owner, commuting with agents running. Local history has 13 sessions, 4 of them lid sessions.
- **Continue?** Yes as a personal tool. It's small (about 1,700 lines of Swift), carefully built, and its safety design is better than most of the clones. Not yet as a public product. The only download (v1.1.0) is Gatekeeper-rejected, and its setup has a race that a same-user process could use to get root. Six commits of fixes sit unreleased. At least eight free or paid apps already sell "keep the lid closed while agents run".
- **My GTM readiness: 25%** (weighted 43, capped at 25). The scorecard says 30 (2026-10-19 review round, not a critique). I'm 5 points lower for one reason: what a stranger can download today is worse than what the scorecard scored. `main` is roughly a 30. The shipped zip has a root-escalation race at setup (`v1.1.0:LidControl.swift:47-53`), fails `spctl`, and its README tells users to strip quarantine. Cutting v1.2 (about 20 minutes of owner time) lifts the cap back to 30. Notarization plus written acceptance results would justify about 40.

## 2. Code and architecture

| Area | Assessment |
|---|---|
| Structure | Clean and appropriately small. `LidControl` (privileged ops, marker), `CaffeinateManager` (state machine, 586 lines), plus thin watchers (`AgentWatcher`, `NetworkWatcher`, `PowerInfo`, `Notifier`). A shell CLI and a shell failsafe. No dependencies. |
| Fit of choices | Good. Reusing `/usr/bin/caffeinate -w <pid>` means a crash leaves no assertion behind (`CaffeinateManager.swift:251`). A sudoers rule limited to 4 exact command lines is the minimum privilege that works (`LidControl.swift:11-14,32-35`). A marker file plus a LaunchAgent covers app death. Each choice is justified in `plan.md` from reading four reference repos. |
| Weak spot | `CaffeinateManager` is a god object: sessions, safety stops, hotspot auto-arm, history, shutdown, launch-at-login and state publishing all live in one `ObservableObject`, with about 25 mutable fields. That's why it has no tests (section 9). |
| Threading | Privileged and `pmset` calls run synchronously on the main thread in `start` (`:157`), `finish` (`:342`), `tick` upkeep (`:416`) and `powerChanged` (`:429`). The comment at `:415` says this is on purpose, to avoid racing `finish`. That's fair, but each call blocks the UI for 2-4 process spawns. |
| Dead code / duplication | Little. The `requestShutdownPermission` and `runSystemEvents` pair is fine. `LidControl.run` is reused as a general process runner by `AgentWatcher` and `PowerInfo`; it works but is misnamed. |
| Standards | There's no `CODING_STANDARDS.md` or `AGENTS.md` (template gap). The code follows its own conventions: comments explain why, not what, and `plan.md` keeps a dated status. Version strings are consistent in both plists (`Info.plist:16-18`, `WidgetInfo.plist:16-18`). |
| Build | `build.sh` builds a universal binary and signs it ad hoc, with no hardened runtime, no notarization, no zip or checksum step and no version check (`build.sh:28-31`). Releases are cut by hand. |

## 3. Bugs

Ranked by user harm. C = Confirmed (traced in code or reproduced), S = Suspected.

| # | Sev | Status | Where | Failure scenario | Fix sketch |
|---|---|---|---|---|---|
| B1 | High | C | Shipped `v1.1.0:Sources/CaffeinateApp/LidControl.swift:47-53` | The only public download writes the sudoers rule to a user-writable `$TMPDIR` file, checks it with `visudo`, then `install`s it as root. A same-user process can swap the file between check and install and get any sudoers rule, which is root without a password. `main` fixed this (`LidControl.swift:46-58` stages as root). The fix isn't released (`gh release list`: latest is v1.1.0, 2026-10-15). | Cut v1.2 now. Add "v1.1.0 setup race fixed" to the release notes. |
| B2 | Medium | C | `CaffeinateManager.swift:26,103,112-121,233` | `lidReady` starts `false` and is set only after an async check (4 × `sudo -n -l` plus `sysadminctl`). With the app not running, `caffeinate-my-mac commute` or `for 45m --lid` cold-launches it, and the URL is handled before the check finishes. The request is refused with "Set up lid mode first", so the CLI exits 1. This breaks the "agents start a session" use case whenever the app isn't already running. | In `handle(_:)` or `lidBlocker()`, call `LidControl.isReady()` synchronously when `lidReady` is false (it's a few ms), or queue URLs until `refreshSetup` completes. |
| B3 | Medium | C | `CaffeinateManager.swift:341-344` + `Resources/failsafe.sh:19-20` | If the restore fails when a lid session ends (for example the rule was removed or edited outside the app), the marker is kept "so the failsafe retries". But the failsafe exits early while the app's PID is alive and before `until`, which is session start + 2 h + 120 s. The app never retries. Result: `SleepDisabled=1` stays on for up to about 2 h after a battery-floor or thermal stop, in a bag. `disablesleep` also turns off macOS's own low-battery sleep, so the Mac can run flat. | When `restore` fails, rewrite the marker with `until=now` so the failsafe takes over at once, and retry from the app every 30 s. Notify loudly (ntfy too). |
| B4 | Medium | C | `CaffeinateManager.swift:67,151-157` | The "2-hour hard cap" applies per `start`, not per lid-closed stretch. Going from a lid session to a lid session keeps sleep disabled and resets `startDate`, so `lidDeadline` and the marker's `until` move forward too. Any local app, or the user, can call `caffeinate-my-mac://commute` every 45 min and keep the Mac lid-closed and awake indefinitely. README:39-40 and :97-98 promise "after 2 hours". Security impact is nil, since the NOPASSWD rule already allows `pmset -a disablesleep 1` directly. It's a safety-claim problem. | Keep the first lid start time while `keepLid` chains sessions, and cap against it. Or reword the README to "each session stops after 2 h". |
| B5 | Medium | C | `failsafe.sh` (whole file) | The failsafe only checks "app dead or past deadline". It has no battery or thermal check. If the app hangs (main thread blocked, see section 2) during a lid session, nothing enforces the 15% floor for up to 2 h, and macOS's low-battery sleep is off while `disablesleep` is set. | In `failsafe.sh`, also restore when `pmset -g batt` reads ≤ 10% on battery. That's a few lines of shell, testable with the existing fake-sudo harness. |
| B6 | Low-Med | C | `CaffeinateManager.swift:138-141,466-472` | Refusals are silent apart from the grey caption. Auto-commute on the hotspot can be refused (battery ≤ 15%, heat, sudo refused), and then nothing is notified. The user closes the lid expecting the usual "Commute mode on" alert, doesn't notice it's missing, and the Mac sleeps mid-agent. (Still open from the 2026-10-19 review, gap 7.) | `Notifier.send` on every refusal that comes from auto-commute or a URL. |
| B7 | Low | C | `LidControl.swift:178` | When `upkeep` finds the marker gone, it writes `Marker(prior: false)` with no `lpm`. If the failsafe restored early (app hung past its deadline, then recovered), the app re-disables sleep and Low Power Mode is never restored, so it stays on. | Keep the last marker in memory and rewrite it whole. |
| B8 | Low | C | `CaffeinateManager.swift:313-322,327-365` + `Resources/caffeinate-my-mac:57-69` | `caffeinate-my-mac while <pid>` for a process that exits right after the `kill(pid,0)` check: `finish` publishes state with the request id but no `refused` key. The CLI keeps polling and exits 3 ("No answer") instead of 0. | Always publish `refused: false` with the request id on accepted requests, including the finish path. |
| B9 | Low | C | `Resources/caffeinate-my-mac:84-86` | After a crash or `kill -9`, `state.plist` still holds an active `end`. `caffeinate-my-mac status` reports a live session until the app is relaunched. | Store the app PID in `state.plist`, and have `status` check it with `kill -0`. |
| B10 | Low | S | `CaffeinateManager.swift:251,397-399` | Non-lid session plus a manual lid close: the Mac sleeps. `caffeinate -t` most likely counts monotonic time, which stops during sleep, while `endDate` is wall-clock. After wake the UI shows `00:00` while `caffeinate` keeps running, and "Shut down when finished" fires late. Not tested (it needs a sleep cycle). | End the session from `tick()` when `endDate` has passed, rather than relying only on `caffeinate` exiting. |
| B11 | Low | S | `AgentWatcher.swift:37-38` | The CPU check matches the executable name `claude` or `codex`. An npm-installed Claude Code runs as `node`, so its long tool calls are missed. Transcript FSEvents still cover writes. On the other side, CPU is summed across every `claude` tree, so a dev server or MCP server left running under any session can keep "until agents idle" going until the cap. On this Mac, `ps` shows 3 `claude` processes (native installer), so the owner isn't affected. | Match `node` processes whose args contain `claude`, and ignore descendants older than the session or detached long-runners. Or accept it and document it. |
| B12 | Low | S | whole app | No `ProcessInfo.beginActivity` and no App Nap opt-out (`grep` finds none). The 1 s `Timer` that drives lid-close `displaysleepnow` (the lock) and the agents-idle check can be throttled while the popover is closed. The battery floor is safe, because it also fires from IOPS notifications. | `ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason:)` during lid sessions. |

The two CLI bugs listed in `plan.md` (2026-10-19) are fixed in code: `|| exit 3` at `Resources/caffeinate-my-mac:55` (test `testOpenFailureExitsThree`), and the request id at `:52-59` and `CaffeinateManager.swift:213,573` (test `testAnswerForAnotherRequestIsIgnored`).

## 4. Corner cases and failure modes

| Case | What happens | Status |
|---|---|---|
| Lid closed on battery, heat in a bag | Low Power Mode is turned on (`LidControl.swift:161,169`), the session stops at `thermalState >= .serious` (`CaffeinateManager.swift:433-439`) or at ≤ 15% (`:425-426`), with a 2 h cap. `.serious` is a late signal on Apple Silicon, so this is a last resort, as the README admits. No fan-speed or skin-temperature input. | Design OK, never measured in a bag |
| App quits normally | `applicationWillTerminate` → `finish("Quit")` → restore (`CaffeinateAppMain.swift:15-17`). | C |
| App killed (`kill -9`) or crashed | `caffeinate -w` dies with the app. The failsafe restores within 30 s (`failsafe.sh:19-31`). Tested only with a fake sudo; acceptance test 3 was never recorded. | Partly verified |
| App hung | The failsafe restores only after deadline + 120 s (up to about 2 h 2 min), with no battery check (B5). | Gap |
| Restore fails | Sleep can stay disabled for about 2 h (B3). | Gap |
| Reboot mid-session | `disablesleep` survives the reboot. The failsafe is a per-user LaunchAgent, so it runs only after login. A Mac that reboots in the bag (panic, update) sits at the login window with sleep disabled. On the next login it's fixed by `RunAtLoad`, and also by `launch()` (`CaffeinateManager.swift:89-93`). | S, not tested |
| Sleep/wake mid-timer (non-lid) | Countdown drift (B10). | S |
| Sudoers race / tampering | `main`: staged root-owned in `/etc/sudoers.d/*.new` (sudo ignores names containing a dot), checked with `visudo`, then `mv` (`LidControl.swift:49-54`). Safe. v1.1.0: race (B1). `failsafe.sh` is copied into the user's Application Support and run as that user, so tampering with it gains nothing. | main C safe; release unsafe |
| Agent detection | False negatives: npm Claude (B11), and model thinking time longer than 5 min with no writes and no CPU. False positives: any `.jsonl` write under any `~/.claude*/projects`, including a different, unrelated session, and long-lived children (B11). Config dirs created after `start()` aren't watched (`AgentWatcher.swift:82`). | S |
| Multiple sessions | One instance via `flock` in `$TMPDIR` (`CaffeinateAppMain.swift:27-28`). A new session replaces the old one. Two macOS users with fast user switching: user A's restore turns lid mode off under user B's session. Multi-user is explicitly out of scope in `plan.md`. | C by reading |
| URL scheme abuse | Any local app can open `start`, `commute`, `idle`, `while`, `extend` or `stop`. Values are range-checked (`URLCommand.swift:20,34`). Web pages need the browser's "open Caffeinate?" prompt. Worst cases: a hostile app sends `stop` during a commute and the Mac sleeps mid-agent, or chains `commute` past the cap (B4). `Ignored URL: <any string>` is written to the popover and `state.plist` (`CaffeinateManager.swift:216-218`). It's harmless text, but attacker-controlled. | C |
| Intel vs Apple Silicon | Universal binary (`build.sh:9`). The power-source re-apply targets an Apple Silicon quirk (`CaffeinateManager.swift:427-430`). Never run on Intel. | Unverified |
| macOS 13 vs latest | 13 is the declared minimum (`Package.swift:6`, `Info.plist:22`). The desktop widget needs 14 (README says so). Tested only on 26.6.2 (this Mac, Mac16,1). | Unverified on 13-15 |
| Unsigned Gatekeeper path | `spctl -a -vv /Applications/Caffeinate.app` → **rejected**. `codesign` shows `Signature=adhoc`, `TeamIdentifier=not set`. The README tells users to remove quarantine (`README.md:57-60`) for an app that then asks for an admin password. | C |
| Lock on lid close | `pmset displaysleepnow` on the clamshell edge (`CaffeinateManager.swift:400-405`), plus a warning if the screen lock delay isn't immediate. On this Mac `sysadminctl -screenLock status` → "immediate". Whether macOS 26 actually shows the lock screen when the lid is reopened during `SleepDisabled=1` is still unverified (`plan.md:17`). | Unverified |

**Field evidence (owner's Mac).** `history.json` has a 121-minute lid session on 2026-10-19 04:44 that ended "Completed". `pmset -g log` shows no sleep in that window, the Mac on AC at the start ("Using AC (Charge: 49)"), and then `Entering Sleep state due to 'Software Sleep pid=28947'` at 06:46:48. That's about 68 s after the session's end, which matches the app's 60 s `pmset sleepnow` fallback (`CaffeinateManager.swift:369-373`). So lid mode held for 2 h on AC, and the fallback was needed to put the Mac to sleep. I couldn't confirm that PID 28947 was `pmset`. Nothing is written in `plan.md`, and no run on battery is recorded. Acceptance tests 1-6 remain formally unrun.

## 5. Security and privacy

- **Privilege:** the NOPASSWD rule (`LidControl.swift:32-35`, confirmed present on this Mac via `sudo -n -l`) lets **any process running as the user** run `pmset -a disablesleep 1`, which persists across reboots. A script that does that leaves no marker, so the failsafe does nothing. The Set Up text says "Caffeinate may then run only …" (`ContentView.swift:323`), which is inaccurate: it isn't limited to Caffeinate. The README (`:80-81`) is closer ("lets your user run"), but it never spells out the consequence. Impact is limited (keeping the Mac awake), but say so.
- **Username injection:** allowlisted (`LidControl.swift:38-40`), and tested with a newline payload. Good.
- **Admin shell:** a fixed string with AppleScript quoting (`LidControl.swift:252-261`). The only variable is the validated username. Good.
- **Release integrity:** an ad-hoc signed zip with no checksum and no notarization. A user can't tell a tampered zip from the real one, and this app asks for an admin password. That's the biggest real-world security issue (B1 aside).
- **URL scheme:** see section 4. Acceptable once it's documented (README:182-184 does).
- **Privacy:** nothing leaves the Mac except optional ntfy.sh posts to a **public** topic. The README says so (`:158-159`). The topic is validated (`Notifier.swift:32-34`). Messages contain times and battery % only. `AgentWatcher` reads paths and event names, not transcript content, plus a `ps` listing. No telemetry, no accounts.

## 6. UI

- Everything is in one 320-pt popover: status card, configuration, settings, history, caption, Quit (`ContentView.swift:29-83`). It doesn't scroll. With Settings and History both expanded, it gets tall enough that on a 13" display at larger text sizes it can run off-screen (S, not measured).
- "SETTINGS & PREFERENCES" sits above a `DisclosureGroup("Settings")` (`:46-50`). That's a redundant double label.
- Warnings start with an emoji ⚠️ in text (`:329,337`) next to SF Symbol warnings elsewhere (`:88,273`). The style is inconsistent.
- In agent and process sessions, the big countdown and the menu bar show the **cap** (2:00:00 or 12:00:00), not a real end time (`:146`). It's explained only by a small caption, "the timer is the hard cap" (`:185`). The widget does the same (`CaffeinateWidget.swift:27-37`).
- History dates are a fixed `d MMM HH:mm` regardless of the 12/24-hour locale setting (`SessionHistory.swift:27`).
- The app icon exists. The README has no screenshots.

## 7. UX

| Workflow | Friction |
|---|---|
| Install | Download → Gatekeeper block → System Settings "Open Anyway" or a Terminal `xattr` command. Then Set Up asks for an admin password from an unidentified developer. The "Install (1 minute)" heading is optimistic. On macOS 15+ the Control-click Open bypass is gone. |
| Commute (happy path) | Good: one button, shown only when ready (`ContentView.swift:192-201`). Shutdown is hidden in lid mode (`:260`). |
| Agent kicks off a session via CLI | Fails if the app isn't already running (B2). Works if it is. Exit codes are documented. |
| Auto-commute on hotspot | It has to arm before the lid closes, and the only feedback is the notification. If it's refused, there's nothing (B6). The user has no way to confirm without opening the popover. |
| When things go wrong | Failures show as a grey caption under the history (`:66-69`), which is easy to miss. The restore-failure message tells the user to run `sudo pmset …` by hand (`CaffeinateManager.swift:343`). That's honest but scary. |
| Uninstall | Documented (README:215-218 plus the manual block :122-127). Revoke removes the rule and the agent. Good. |
| Notifications | The permission prompt fires at first launch with no context (`CaffeinateManager.swift:95`). |

## 8. Accessibility and performance

- **Accessibility:** no `accessibilityLabel` or hint anywhere (`grep` count 0). Labels with text read acceptably. The menu bar item is a symbol plus digits, and VoiceOver reads the symbol's default name. Status relies on text (AWAKE/IDLE) as well as colour, which is good. Red-on-red-tint warning text at caption2 size (`ContentView.swift:276-282`) is likely below contrast guidelines in light mode (S). There's no Dynamic Type concern on macOS, but the fixed 320 pt width truncates longer localized strings, and the app is English-only.
- **Performance:** light. A 1 s timer reads one IORegistry property and re-renders the label. `ps` runs every 15 s only while agent watching is on. Upkeep runs `pmset -g` every 30 s only in lid mode. After setup, the failsafe spawns `sh` every 30 s **forever** (`launchctl print` shows 2,034 runs on this Mac), even with no session. That's cheap, but it's a constant wakeup for a tool marketed as "lightweight". The agent could be loaded only during lid sessions. The section's "low-end Android, slow networks" lens doesn't apply: it's macOS only and network-free apart from ntfy.

## 9. Testing and verification

- `swift build`: OK. `swift test`: **26 XCTest cases pass** in about 20 s (the README and plan say 24; two CLI tests were added in `9924c9b`).
- **What they prove:** the sudoers body passes `visudo -c`. The install shell writes exactly that body. The username allowlist holds. `pmset` parsing, marker round-trip, `failsafe.sh` against a fake sudo (7 cases: dead app, reused PID, live app before and after the deadline, garbage values, sudo failure), CLI URL building and exit codes 1/2/3 including the request id, URL parsing, the agent CPU tree, battery estimate, hotspot detection, ntfy topic validation and the history line.
- **What they don't prove:** nothing tests `CaffeinateManager`, the actual state machine: lid-to-lid chaining, the restore paths, `extend` capping, `handle` echoing the request id, refusal paths, auto-commute, safety stops. B2-B4 and B8 all live there. Nothing exercises real `pmset`, and the acceptance tests 1-6 on a closed lid on battery are still not recorded (`plan.md:16,150`). There's no CI (no `.github/`), so the tests run only when someone remembers. The widget and the UI have no tests or snapshots.
- **Testability fix:** inject a `PowerControl` protocol (begin, end, upkeep, isReady) into `CaffeinateManager`. That's a small seam, and it makes B2-B4 unit-testable.

## 10. Deploy and operations

- **Distribution:** GitHub Releases by hand. v1.0.0 (2026-10-14, 1 download) and v1.1.0 (2026-10-15, **3 downloads**). Six commits since v1.1.0 are unreleased, including the root-race fix, display-sleep-by-default, the shutdown countdown and the CLI exit codes. The README admits this (`:17-19`). Fair, but the fixes still don't reach users.
- **Owner's own Mac** runs `/Applications/Caffeinate.app` **1.1** (`defaults read`, PID 15047). So even the only real user is on the unfixed build. The race only bites at Set Up, which has already run here, so the current exposure is low.
- **Signing:** ad hoc and Gatekeeper-rejected (verified). The owner decided on 2026-10-21 to enroll in the Apple Developer Program (`decision.md:63`). Note that `decision.md:40` still recommends "Personal tool … skip the $99", so the two rows contradict each other. Clean that up.
- **Update path:** none (no Sparkle, no Homebrew cask, no in-app version check). v1.1.0 users never learn about B1.
- **Rollback:** previous zips stay on Releases. The state files are forward-compatible (plain key=value marker, Codable history).
- **Monitoring:** none, which is appropriate for a local tool. The local `history.json` serves as the field log.
- **Store compliance:** not on the Mac App Store, and it can't be. A sandboxed app can't install sudoers rules (Amphetamine's App Store build needs a separate helper for the same reason). Fine for direct distribution once notarized.

## 11. Legal and compliance

- **License:** MIT (`LICENSE`), which covers the warranty disclaimer. There's a heat warning (README:107-108) and a force-quit warning. Good.
- **Name:** "Caffeinate" is Apple's own command name, and the App Store already has "Caffeinated" and similar apps. That's no immediate legal problem for a free GitHub tool, but it's a weak, confusable brand if this ever goes public or paid. The repo name "Caffeinate-my-mac" and the bundle ID are distinct enough.
- **Apple:** Developer ID and notarization are expected for distributing software that asks for admin rights. They aren't legally required, but Gatekeeper makes them a practical requirement. The README's quarantine-strip instruction is normal for hobby tools but bad practice for a security-sensitive one.
- **Privacy law (Bangladesh, and generally):** no personal data is collected or sent anywhere except the user-chosen ntfy topic, so no privacy policy is required for the GitHub release. One sentence in the README already covers ntfy's public topics.
- **Safety liability:** the product tells people to put a running laptop in a bag. The README warns about it, and the stops exist. B3 and B5 are the gaps between the warning and the code.

## 12. Market, demand and marketability

- **Who pays:** developers who run local coding agents and move around with a closed laptop. Small, but real and growing. Paid competitors exist, which proves some will pay (single-digit dollars, one-time).
- **Real demand for this repo:** 2 stars, 0 forks, 0 issues, 4 total release downloads. No posts, no launch. Market validation is essentially zero.
- **Competitors (web search, 2026-10-21):**

| Product | Model | Overlap |
|---|---|---|
| Amphetamine | Free, App Store | Timers, triggers, closed-display mode with its Power Protect helper; the category leader |
| KeepingYouAwake, Lungo, Theine | Free | Idle-sleep only (`caffeinate`-style); can't hold a closed lid on battery |
| Built-in `caffeinate` / `sudo pmset -a disablesleep 1` | Free | What this app wraps; restoring sleep afterwards is the hard part |
| Vigil | Product Hunt launch | Lid closed while Claude Code or agents run, sleeps when done, hooks-based agent detection; macOS 14+ |
| Latch | Free tier + $7.99 Pro | Lid closed, watches CPU and disk activity, sleeps when done |
| Hold My Lid | Paid (about $10-15) | Holds wake only while a watched agent works |
| Smart NoSleep | Free, MIT | Agent-aware lid mode; its author found that `disablesleep` kills low-battery sleep (relevant to B3/B5) |
| Sleepless (Aboudjem) | Free, MIT, macOS 26 | `pmset disablesleep` with auto-off timer and low-battery stop |
| Lidless | App | Heat pause, only-while-charging, low-battery cutoff, crash watchdog |
| Capsomnia | Free, OSS, **signed and notarized** | Caps Lock toggle, lid closed |
| adiab98/Awake, yatindma/Awake, pehqge/coffee | Free GitHub | Same `pmset` approach; adiab98/Awake was a design reference here |

Sources: [Sleepless](https://github.com/Aboudjem/Sleepless), [Capsomnia](https://www.producthunt.com/products/capsomnia), [Lidless](https://alternativeto.net/software/lidless/about/), [Vigil](https://hunted.space/product/vigil-16), [Latch](https://www.producthunt.com/p/latch-4/latch-5), [Hold My Lid](https://alternativeto.net/software/hold-my-lid/about/), [yatindma/Awake](https://github.com/yatindma/Awake), [coffee](https://awesome.ecosyste.ms/projects/github.com%2Fpehqge%2Fcoffee), [agents overnight guide](https://pasqualepillitteri.it/en/news/779/disable-laptop-sleep-lid-close-ai-agents).

- **Real differentiators:** the iPhone-hotspot auto-arm without Location permission (`NetworkWatcher.swift:12-14`), a failsafe that runs outside the app, Low Power Mode during the session, the CLI with exit codes, and a session history that shows the real battery cost. Those are good engineering, but none of them is a reason to switch on its own. The unsigned zip plus an admin prompt is a reason **not** to switch, next to notarized competitors.
- **Why users would switch:** they mostly wouldn't, today. The best pitch is "the safest lid-closed keep-awake: failsafe, battery and heat stops, open source, CLI for agents". It only works once it's notarized, and once B3/B5 make "safest" true.
- **Pricing:** MIT and free. Tips at most. Don't charge for this. The paid niche is crowded and cheap.
- **Claims vs. reality:** README:3-4 "even with the lid closed … then let it sleep": held for 2 h on AC in the field, never recorded on battery. README:39-40 "after 2 hours": bypassable (B4). README:45-46 "Lightweight … only the lid-mode failsafe check runs": true, but every 30 s forever. README:48 "Install (1 minute)": not with Gatekeeper. `ContentView.swift:323` "Caffeinate may then run only": the rule is for the user, not the app. The README *is* honest about the stale download (`:17-19`) and ntfy's public topics, which is better than most.

## 13. GTM % breakdown

| Dimension (weight) | Score | Why |
|---|---|---|
| Product works (25) | 6 | Timer, agent and lid sessions run on the owner's Mac (13 sessions; one 2 h lid session on AC held). Cold-launch CLI lid requests fail (B2). Acceptance tests on battery not recorded. |
| Quality and verification (15) | 5 | 26 passing tests and a good failsafe harness, but no tests of the state machine, no CI, no recorded device acceptance. |
| Security and privacy (15) | 4 | `main` is careful (exact-command sudoers, root staging, allowlist). The shipped zip has a root race (B1), and the release is unsigned. The user-wide NOPASSWD scope isn't disclosed in-app. |
| Legal and compliance (10) | 5 | MIT, warnings present, no data collection. A confusable name, and a quarantine-strip install for an admin-rights tool. |
| Market validation (15) | 1 | 2 stars, 4 downloads, no launch; at least 8 direct competitors, some paid and notarized. |
| Deploy and operations (10) | 2 | Manual releases, 6 days and a security fix behind `main`, no update path, Gatekeeper-rejected, no CI. |
| Claims honesty (10) | 6 | Upfront about the stale release and ntfy. Overstates the 2 h cap, the install time and the Set Up scope. |
| **Weighted** | **43** | 15 + 7.5 + 6 + 5 + 1.5 + 2 + 6 |
| **Cap** | **25** | The only downloadable build has a setup race that gives a same-user process root, and Gatekeeper rejects it. Cut v1.2 and the cap rises to 30. Add notarization and recorded acceptance tests 1-6, and it goes to about 40. |
| **Final** | **25%** | Compare: TRACON 30, Visit-Cox 30, ThrottleIQ 40, Suggest.Bike 55, Presswire 10. Engineering is in the upper half of the portfolio; GTM is in the lower half, because of distribution and demand, not code. |

## 14. What to cut or stop doing

- **Stop shipping nothing.** Six commits, including a security fix, have waited 6 days for a 20-minute release. Release on every fix that touches setup.
- **Cut "Shut down when finished" force-quit**, or drop the force. It's the most dangerous feature in the app (`CaffeinateManager.swift:536-545` force-terminates every regular app). It has nothing to do with the commute use case, and Amphetamine-style users don't expect data loss. A plain `shut down` that apps can cancel is safer.
- **Stop running the failsafe agent every 30 s when there's no session.** Load it at lid-session start (still `RunAtLoad`, for reboots) and boot it out at the end, or keep it but exit faster (it already exits on a missing marker).
- **Don't build more features** (more triggers, more notifiers, the libproc probe) until someone other than the owner uses it.
- **Resolve the `decision.md` contradiction** (`:40` personal tool and skip the $99, vs `:63` enroll, which also unblocks Caffeinate). Pick one story.
- **Drop the "Install (1 minute)" framing** until it's notarized.

## 15. Top 10 next actions

| # | Action | Value | Effort | Who |
|---|---|---|---|---|
| 1 | Build and publish v1.2 from `main` (the version is already 1.2 (3)). Note "fixes a setup race in v1.1.0" and add a SHA-256 to the notes. Install it on your own Mac. | Removes B1 from the only download | 20 min | Owner |
| 2 | Fix B2: synchronous `isReady()` when `lidReady` is false in `handle`/`lidBlocker`, plus a test. | Makes the agent/CLI use case work from a cold start | 30 min | Agent |
| 3 | Fix B3 and B5: on a failed restore, set the marker's `until` to now and retry; add a battery ≤ 10% check to `failsafe.sh`, with fake-sudo tests. | Closes the two ways the Mac can stay awake in a bag | 1-2 h | Agent |
| 4 | Run acceptance tests 1-6 **on battery** and write the results and dates in `plan.md`. Include "lock screen on reopened lid" on macOS 26. | Turns the headline feature from claimed into verified | 1 h | Owner |
| 5 | Developer ID signing, hardened runtime and `notarytool` with stapling in `build.sh`; remove the `xattr` instruction from the README. | The single biggest trust and adoption blocker | 2-3 h after enrollment | Agent + owner (credentials) |
| 6 | Notify on every refusal from auto-commute or a URL (B6). Fix the Set Up copy to say "any app running as you can toggle `disablesleep`". Explain the notification prompt before asking. | Fewer silent failures; honest consent | 1 h | Agent |
| 7 | Fix B4 (chain-aware 2 h cap) or reword the README; fix B7-B9. | Safety claim matches the code | 1-2 h | Agent |
| 8 | Add a `PowerControl` seam and `CaffeinateManager` unit tests (lid chaining, restore failure, extend cap, request echo), plus a GitHub Actions `swift test` on `macos-latest`. | Regression net for the riskiest code | 3-4 h | Agent |
| 9 | Homebrew cask plus a minimal update check (compare against the latest GitHub release at launch, and show a line in the popover). | Future security fixes actually reach users | 2 h | Agent |
| 10 | Decide public vs personal (fix `decision.md`). If public: README screenshots, a 30 s demo GIF of the commute flow, one post (r/macapps, HN "Show HN" with the agents angle), and a comparison table against Amphetamine, Latch and Sleepless. Re-score on real stars and downloads after 2 weeks. | First market signal | Half a day | Owner |
