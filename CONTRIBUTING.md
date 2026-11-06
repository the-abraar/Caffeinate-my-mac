# Contributing to Caffeinate

Caffeinate is a personal tool shared as is (see the README). Pull requests are welcome,
but reviews are best effort. Open work is tracked in GitHub issues; background is in
[plan.md](plan.md), especially the latest "Status" section.

## Set up, build and test

Needs macOS 13+ and Xcode (Swift 5.9+). No Apple Developer account.

```bash
swift test            # unit tests, the failsafe script and the CLI
./build.sh            # builds a universal, ad-hoc signed Caffeinate.app
./build.sh --install  # ...and copies it to /Applications
```

Tests never call `sudo` or change `pmset`: `CaffeinateManager` takes a `PowerControl`,
and tests pass a fake. Keep it that way. Never write a test that sleeps the Mac or
changes system power settings.

## Pick an issue

- Start with `good first issue` or `difficulty: easy`.
- Comment on the issue before you start, so two people don't do the same work.
- Anything that needs the owner's decision (signing, notarization, a Homebrew cask) is not open for PRs yet.

## Pull requests

- One issue per PR, with `Closes #N` in the description.
- `swift test` and `./build.sh` pass. New logic comes with a test in `Tests/CaffeinateAppTests/`.
- Say what you checked by hand (macOS version, Intel or Apple Silicon, lid open or closed).
- Lid mode and the sudoers rule are security-sensitive. Don't widen the sudoers rule,
  and explain any change to `LidControl.swift` or `Resources/failsafe.sh` in the PR.
- Keep the README in sync with any user-visible change.

By contributing you agree that your work is released under the MIT License.
