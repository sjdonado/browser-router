# BrowserRouter

The smallest possible default browser on macOS. Every link the system opens arrives here, is matched against a list of regexes in one JSON file, and is handed to the browser that rule names. No menu bar item, no UI, no background process, no daemon: the app exists only for the fraction of a second it takes to route a link, then exits.

```sh
curl -fsSL https://raw.githubusercontent.com/sjdonado/browser-router/main/install.sh | sh
```

That compiles it from source into `~/Applications/BrowserRouter.app`, writes a starting config if there is none, and asks macOS to make it the default browser. There is no DMG and no release binary on purpose: the whole thing is one Swift file, building it takes a few seconds, and a locally built ad-hoc signed bundle needs no notarization dance.

Re-running it updates an existing install in place. A provisioning script that runs on every pass wants `--no-default-prompt`, which skips the modal default-browser question:

```sh
curl -fsSL https://raw.githubusercontent.com/sjdonado/browser-router/main/install.sh | sh -s -- --no-default-prompt
```

An existing config is never overwritten, including when it is a symlink into a dotfiles repository.

Requires the Xcode command line tools (`xcode-select --install`) and macOS 13 or newer.

## Configuring

`~/.config/browser-router/config.json` (or `$XDG_CONFIG_HOME/browser-router/config.json`). It is read fresh on every link, so an edit takes effect on the next click. No rebuild, no restart.

```json
{
  "default": { "bundleID": "com.apple.Safari", "tab": true },
  "rules": [
    {
      "match": [
        "^https?://(localhost|127\\.0\\.0\\.1|0\\.0\\.0\\.0|\\[::1\\])(:\\d+)?(/|$)",
        "^https?://([^/]+\\.)?(pages|workers)\\.dev(/|$)"
      ],
      "browser": "net.imput.helium"
    },
    {
      "match": "^https?://(www\\.)?reddit\\.com/",
      "browser": "com.apple.Safari",
      "rewrite": { "pattern": "^https?://(www\\.)?reddit\\.com/", "with": "https://old.reddit.com/" }
    }
  ]
}
```

| Key | Meaning |
| --- | --- |
| `default` | Where a link goes when no rule matches. A bundle ID string, or an object with `bundleID` and `tab`. |
| `rules` | Checked in order, first match wins. |
| `rules[].match` | One regex or a list of them, case insensitive, tested against the whole URL (`NSRegularExpression`, ICU syntax). |
| `rules[].browser` | Bundle ID string, or `{ "bundleID": ..., "tab": true }`. |
| `rules[].rewrite` | Optional `{ "pattern", "with" }`. The URL is rewritten before opening; `with` is a template, so `$1` is the first capture group. |

`"tab": true` asks for scripted tab creation instead of a plain open, which is the only way to land a link in a tab of an existing window rather than a new window. It speaks Safari's scripting codes, so use it for Safari and leave it off elsewhere. macOS will ask once for permission to control that browser.

Find a bundle ID with `osascript -e 'id of app "Helium"'`.

A rule whose browser is not installed falls through to `default` rather than dropping the link, and a missing or unparseable config falls back to a Safari tab. A link is never lost.

Test a change without leaving the terminal:

```sh
open https://example.com     # default
open http://localhost:3000   # whatever rule matches
```

## Footprint

Measured on macOS 26, Apple silicon, with the config above.

| | |
| --- | --- |
| bundle on disk | 116 KB, three files |
| source | one file, ~280 lines |
| memory while routing a link | 7.4 MB private footprint, 31 MB RSS |
| memory at rest | none, there is no process |
| subprocesses | none |
| click to browser | ~0.2s, both paths |

RSS is the number Activity Monitor shows and most of it is shared AppKit pages counted against every process linking the framework; the private footprint is what this app actually costs, and it is gone as soon as the link is open.

### Where the 7.4 MB goes, and why it is the floor

Almost all of it is AppKit, and AppKit is not optional. A Foundation-only build starts at **1.8 MB**, and it never receives a single link: LaunchServices holds the `GURL` Apple Event until the process checks in as an application, and only `NSApplication` does that. This was tested, not assumed. A bundle that installed the same handler, pumped `AEGetRegisteredMachPort()` onto its own `CFRunLoop` and waited was launched correctly by LaunchServices and sat there until it timed out, the handler never firing.

So the routing itself is already free. What was not free, and is now gone, was the Safari path spawning `osascript` to create the tab: another process, ~26 MB RSS, for two Apple Events. Those events are now built with `NSAppleEventDescriptor` and sent in-process, which removed the subprocess entirely and roughly halved the time from click to tab. The URL travels as event data rather than script text, so a URL containing quotes cannot alter anything.

## Why not Finicky

Finicky does this routing from a JS config and costs **131 MB resident**, permanently, to run a handful of regexes and a default.

That is not its config's fault and there is nothing to tune. Finicky embeds JavaScriptCore, and the engine reserves its heap at launch: a cold start with no links handled measured 130.9 MB, of which 95.5 MB was 121 four-megabyte `rw-/rwx` arenas. There was no leak either. A process nine days old with about 200 links behind it measured *smaller*, 121 MB, because macOS had compressed the idle heap.

It also cost a hop. Finicky evaluated the URL in ~56 ms and then ran `open -b <the handler bundle id> <url>`, launching the app that did the actual work.

What is traded away for that: config is regex plus an optional rewrite, not arbitrary JavaScript. No matching on the opening application, no computed URLs, no config-side functions. If a routing decision needs code, this is the wrong tool.

## Gotchas

**Declaring the URL schemes is not enough to become the default browser.** `NSWorkspace.setDefaultApplication` fails with "The file couldn't be opened" (`NSCocoaErrorDomain` 256) until the bundle also claims to *view* HTML. `Info.plist` therefore declares `CFBundleDocumentTypes` for `public.html`, `public.xhtml` and `public.url` that the app never opens.

Isolated on a throwaway bundle rather than inferred: same binary, same ad-hoc signature, same `lsregister -f`, one key different. Without the document types the call failed; with them it returned OK. Re-register after editing `Info.plist`, or LaunchServices answers from what it cached.

**Setting `http` sets `https` too.** One call moves both, and calling again for the second scheme returns the same "file couldn't be opened" error even though the state is already correct. Set `http` and verify rather than looping over the pair.

**It cannot be an AppleScript applet.** Applets are wrapped in a stub that shows AppleScript's startup screen when another app launches them, so every link waited on a dialog. Deleting the run handler does not help: the stub is the problem, not the script.

**Safari is never opened directly.** LaunchServices gives it a new window for every externally opened URL whatever `AppleWindowTabbingMode` and Safari's own tab preference say. Scripted tab creation is the only thing that produces a tab, which is what `"tab": true` is for.

**Launching the app by hand has no UI.** It asks to become the default browser and quits. That is the only thing it can usefully do without a link.

## License

MIT, see [LICENSE](https://github.com/sjdonado/browser-router/blob/main/LICENSE).
