# bowatch

**Native iOS + watchOS client for watchd — chat with Miyu from your wrist.**

The Apple Watch only had a web shell before: EventSource dies silently,
typing hurts, half the taps are just re-Authenticating. bowatch puts the
whole watchd API behind native SwiftUI instead.

## Features

| Watchd feature | iOS | watchOS |
| --- | :---: | :---: |
| Login / logout (cookie relay) | ✅ | ✅ |
| Streaming replies (2s polling backbone + live tool-call line) | ✅ | ✅ |
| History (last 40 turns, meta lines) | ✅ | ✅ |
| Session list / switch / create / delete | ✅ | ✅ |
| Model picker (51-entry catalog + per-session override) | ✅ | ✅ |
| Context compaction (normal + forced) | ✅ | ✅ |
| Reasoning blocks (on-demand fetch) | ✅ | ✅ |
| Inline reply images (authenticated) | ✅ | ✅ |
| Camera snapshot | ✅ | → |
| Context window usage meter | ✅ | ✅ |

## Architecture

- [`project.yml`](project.yml) — XcodeGen spec, no hand-written pbxproj
- [`Sources/Shared/`](Sources/Shared/) — `APIClient` + `ChatEngine`, one
  logic layer both targets import; only UI shells differ
- [`Sources/iOS/`](Sources/iOS/) / [`Sources/WatchApp/`](Sources/WatchApp/) —
  SwiftUI shells

The server base URL is user-configurable (default: the SakuraFrp nyat.app
tunnel), sessions persist via shared `HTTPCookieStorage`, so one login
survives launches on both devices independently.

## Build

Cloud (unsigned artifacts, no signing needed):

```sh
git push   # .github/workflows/build.yml runs xcodegen + xcodebuild on macos-14
```
Check the *Actions* tab — failures auto-write `errors.md` to the repo root.

Local (Xcode 15+, to install on a device):
```sh
brew install xcodegen && xcodegen generate
open bowatch.xcodeproj
# iOS target → run on iPhone; the watch target appears alongside in the simulator list
# Signing: your Apple ID (Personal Team) in Signing & Capabilities
```

## Server

bowatch talks to **watchd** — a tiny Python relay in front of the Miyu
daemon (`~/.miyu/watch/server.py`). All traffic goes through the relay's
`/watch/*` prefix; the app never touches the daemon directly.

## Status

v0 skeleton compiles against live watchd endpoints. Test device support and
streaming polish are next.

License: none yet — ask before reusing.
