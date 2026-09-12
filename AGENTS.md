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
| `main.swift` | The whole app. One file, deliberately. |
| `Info.plist` | Bundle declarations. Every key in it is load-bearing; the comments say why. |
| `config.example.json` | Seeded to `~/.config/browser-router/config.json` on install if none exists. |
| `install.sh` | The `curl \| sh` entry point. Also usable from a clone, and idempotent: re-running updates in place, `--no-default-prompt` skips the modal default-browser question for provisioning scripts. |
| `README.md` | User-facing docs and the measured footprint table. |

There is no test suite and no build system. Adding either needs a reason stronger than "projects usually have one".

## Verification

Compile, which is the only automatic check that exists:

```sh
xcrun swiftc -O -framework AppKit -o /tmp/br-check main.swift
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

These cost real time to find. Do not re-litigate them without new measurements.

- **AppKit cannot be dropped.** A Foundation-only build starts at 1.8 MB instead of 7.4 MB and never receives a link: LaunchServices holds the `GURL` event until the process checks in as an application, which only `NSApplication` does. A `CFRunLoop` draining `AEGetRegisteredMachPort()` was tried and the handler never fired.
- **The app must be a bundle declaring `http`/`https`,** because only that receives the Apple Event carrying the URL.
- **It cannot be an AppleScript applet.** The applet stub shows AppleScript's startup screen when another app launches it, so every link waited on a dialog.
- **Becoming the default browser needs `CFBundleDocumentTypes` for HTML,** not just URL schemes, or `setDefaultApplication` fails with `NSCocoaErrorDomain` 256.
- **Safari only produces a tab via scripting.** A plain open always makes a window, whatever the user's tab preferences say.
- **Apple Events go in-process,** via `NSAppleEventDescriptor`, never by shelling out to `osascript`. The subprocess cost ~26 MB and half the latency. The URL is event data, never interpolated into script text.
- **Editing `Info.plist` invalidates the signature.** Sign the assembled bundle, then `lsregister -f` it, or LaunchServices answers from its cache.
- **A link is never dropped.** An uninstalled browser, a broken config, a failed scripted open: each falls back one step, ending at a plain Safari open.

## Style

Comments explain *why*, and specifically why an obvious simpler thing does not work, because most of this file is workarounds for LaunchServices behavior. Do not add comments that restate the code. Keep prose unwrapped, one paragraph per line. No em-dashes.
