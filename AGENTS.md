# BrowserRouter agent guide

## What this project is for

One goal, and it is a constraint as much as a feature: **be the smallest, fastest possible default browser on macOS.** A link arrives, a regex decides where it goes, the process exits. Nothing stays resident.

Everything else is subordinate to that. When a change trades footprint or launch latency for a feature, the footprint wins and the feature does not land.

## Non-goals, and they are firm

Do not add: a menu bar item, a settings window, a preferences UI, an onboarding screen, an icon, a dock presence, a daemon or login item, an updater, telemetry, a scripting language for the config, a DMG or notarized release, a package manager formula, CI that builds artifacts, a Swift package manifest, or a dependency of any kind.

The app has no UI on purpose. The config is a file the user edits. Distribution is `git clone` plus `swiftc`, which is why there is no release pipeline to maintain.

If a request seems to need one of these, say so and propose the smaller version instead.

## Shape of the repository

| Path | What it is |
| --- | --- |
| `BrowserRouter/main.swift` | The whole app. One file, deliberately. |
| `BrowserRouter/Info.plist` | Bundle declarations. Every key in it is load-bearing; the comments say why. |
| `config.example.json` | Seeded to `~/.config/browser-router/config.json` on install if none exists. |
| `install.sh` | The `curl \| sh` entry point. Also usable from a clone, and idempotent: re-running updates in place, `--no-default-prompt` skips the modal default-browser question for provisioning scripts. |
| `README.md` | User-facing docs, the measured footprint table, and the platform gotchas. |

`BrowserRouter/` is the target directory an Xcode project would generate, so a project can be pointed at it later without moving files. There is no `.xcodeproj` and no `Package.swift`: the build is one `swiftc` line in `install.sh`.

There is no test suite and no build system. Adding either needs a reason stronger than "projects usually have one".

## Verification

Compile, which is the only automatic check that exists:

```sh
xcrun swiftc -O -framework AppKit -o /tmp/br-check BrowserRouter/main.swift
```

Shell and JSON:

```sh
sh -n install.sh
python3 -m json.tool config.example.json
```

Behavior is verified by routing real links. Install with `./install.sh`, then:

```sh
open https://example.com     # lands as a tab in the front Safari window, no new window
open http://localhost:3000   # lands in whatever the local-dev rule names
```

Confirm the Safari path with `osascript -e 'tell application "Safari" to get URL of current tab of front window'`, and confirm nothing was spawned with `ps -Ao comm | grep osascript` while a link routes. A new *window* instead of a tab means the scripted path failed and it fell back to a plain open.

Never claim a routing change works without opening a link. Compiling proves nothing about Apple Event delivery.

## Measuring, when a change claims to be cheaper

Numbers in the README are measured, not estimated. Reproduce them the same way or do not change them:

- **Private footprint**: temporarily write `task_info(TASK_VM_INFO)`'s `phys_footprint` to a file just before `NSApp.terminate`, install that build, route one link, read the file, then reinstall the clean binary. Do not ship the instrumentation.
- **Lifetime**: poll `pgrep -x BrowserRouter` around an `open`, from the moment the process appears to the moment it is gone.
- **Subprocesses**: sample `ps -Ao pid,rss,comm` in a tight loop while a link routes.

Report the method with the number. A footprint figure with no stated measurement point is not evidence.

## Constraints discovered the hard way

**The README's Footprint and Gotchas sections are the constraint list**, and they are measured rather than argued. Read them before proposing anything structural, and do not re-litigate them without new measurements. In short: AppKit cannot be dropped, the app must be a bundle declaring `http`/`https`, it cannot be an AppleScript applet, becoming the default browser needs `CFBundleDocumentTypes` for HTML, and a browser only produces a tab via scripting.

Two more that are build concerns rather than user-facing ones:

- **Apple Events go in-process,** via `NSAppleEventDescriptor`, never by shelling out to `osascript`. The subprocess cost ~26 MB and half the latency. The URL is event data, never interpolated into script text.
- **Editing `Info.plist` invalidates the signature.** Assemble the bundle, then sign it, then `lsregister -f` it, in that order, or LaunchServices answers from its cache.

## Style

Comments explain *why*, and specifically why an obvious simpler thing does not work, because most of this file is workarounds for LaunchServices behavior. Do not add comments that restate the code. Keep prose unwrapped, one paragraph per line. No em-dashes.
