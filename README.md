# Claude Usage Widget

A tiny native macOS menu-bar app that shows your Claude Code subscription
usage (5-hour and weekly rolling limits) at a glance.

It reads the OAuth token(s) Claude Code already stores in your macOS
Keychain (`Claude Code-credentials*`, one entry per CLI profile) and polls
the same usage endpoint the Claude Code `/usage` view uses — no extra
login, no extra credentials.

## What it shows

- Menu bar: `⚡<5h%> · 🇼<7d%>` (turns to `⚠️` if either is ≥ 80%)
- Dropdown: per-profile breakdown with reset countdowns, a manual
  "Refresh Now", and "Quit"
- Profiles with no rolling limits (e.g. enterprise plans) show
  "no rolling limits on this plan" instead of blanks

## Build & install

Requires Xcode command line tools (`swiftc`, `iconutil`, `sips`,
`codesign`) on macOS 13+.

```sh
./build.sh
```

This compiles the app, bundles `AppIcon.icns`, ad-hoc signs it, and
installs `Claude Usage.app` to `~/Applications/`. Launch it from
Spotlight or Finder; quit it from its own menu bar dropdown.

To regenerate the app icon from scratch:

```sh
swift makeicon.swift icon_1024.png
mkdir AppIcon.iconset
# generate each required size into AppIcon.iconset (see Apple's iconset spec)
iconutil -c icns AppIcon.iconset -o AppIcon.icns
```

## CLI mode

```sh
./ClaudeUsage --once
```

Prints usage for each detected profile and exits — useful for testing
without launching the menu-bar UI.

## How it works

- `security dump-keychain` finds all `Claude Code-credentials*` service
  entries (one per Claude Code profile/config dir).
- For each entry with a non-expired `accessToken`, it calls
  `GET https://api.anthropic.com/api/oauth/usage` with
  `Authorization: Bearer <token>` and `anthropic-beta: oauth-2025-04-20`.
- The response's `five_hour` / `seven_day` windows (utilization % and
  reset time) are rendered in the menu bar and dropdown.

This is an unofficial endpoint used by the Claude Code CLI itself — it
may change without notice.
