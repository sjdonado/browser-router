// BrowserRouter: the default browser. Receives every link the system opens and
// routes it by destination, from one JSON file.
//
// Finicky did this before and cost 131MB resident to do it: it embeds
// JavaScriptCore to evaluate its config, and the engine reserves ~95MB of heap
// arenas at launch whatever the config contains. Measured on a cold start with no
// links handled, so there was nothing to tune. The routing itself is a list of
// regexes and a default, which is this file. Nothing stays resident: the process
// handles one URL and exits.
//
// It has to be an app bundle declaring http/https, because only that receives the
// Apple Event carrying the URL, and AppKit has to be the thing running: without
// NSApplication the launch event is never delivered. Measured, not assumed. A
// Foundation-only build that pumps AEGetRegisteredMachPort() itself starts at
// 1.8MB instead of 7.2MB and never receives the event, because LaunchServices
// holds it until the app checks in and only AppKit does that.
//
// Safari is never opened directly. LaunchServices gives it a new window for every
// externally opened URL, whatever AppleWindowTabbingMode and Safari's
// TabCreationPolicy say, and going through a router does not change that. Scripted
// tab creation is the only thing that produces a tab, hence the Apple Events
// below. They are sent in-process rather than through osascript, which is a 26MB
// subprocess for two events.

import AppKit
import Foundation

// MARK: - Config

// ~/.config/browser-router/config.json, read fresh on every link so editing it
// takes effect without a rebuild. A missing or broken file falls back to the
// built-in default rather than dropping the link.
private struct Browser {
    var bundleID: String
    var tab: Bool  // scripted tab creation (Safari), rather than a plain open
}

private struct Rule {
    var patterns: [NSRegularExpression]
    var browser: Browser
    var rewrite: (NSRegularExpression, String)?
}

private struct Config {
    var rules: [Rule]
    var fallback: Browser

    static let builtin = Config(rules: [], fallback: Browser(bundleID: "com.apple.Safari", tab: true))
}

private func configPath() -> String {
    let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        ?? NSHomeDirectory() + "/.config"
    return base + "/browser-router/config.json"
}

private func parseBrowser(_ any: Any?) -> Browser? {
    if let id = any as? String { return Browser(bundleID: id, tab: false) }
    guard let dict = any as? [String: Any], let id = dict["bundleID"] as? String else { return nil }
    return Browser(bundleID: id, tab: dict["tab"] as? Bool ?? false)
}

private func regex(_ pattern: String) -> NSRegularExpression? {
    try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
}

private func loadConfig() -> Config {
    guard let data = FileManager.default.contents(atPath: configPath()),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return .builtin }

    let fallback = parseBrowser(root["default"]) ?? Config.builtin.fallback
    let rules: [Rule] = (root["rules"] as? [[String: Any]] ?? []).compactMap { entry in
        guard let browser = parseBrowser(entry["browser"]) else { return nil }
        let raw = (entry["match"] as? [String]) ?? (entry["match"] as? String).map { [$0] } ?? []
        let patterns = raw.compactMap(regex)
        guard !patterns.isEmpty else { return nil }

        var rewrite: (NSRegularExpression, String)?
        if let r = entry["rewrite"] as? [String: Any],
           let pattern = r["pattern"] as? String, let with = r["with"] as? String,
           let compiled = regex(pattern) {
            rewrite = (compiled, with)
        }
        return Rule(patterns: patterns, browser: browser, rewrite: rewrite)
    }
    return Config(rules: rules, fallback: fallback)
}

// MARK: - Apple Events

private func code(_ s: StaticString) -> UInt32 {
    var v: UInt32 = 0
    s.withUTF8Buffer { for b in $0 { v = (v << 8) | UInt32(b) } }
    return v
}

// `tell app id X to activate`, then `make new tab at end of tabs of window 1 with
// properties {URL:url}`, then `set current tab of window 1 to it`. The URL travels
// as event data, never as script text, so a URL containing quotes cannot alter
// anything. Codes are Safari's (tab = bTab); a browser with different scripting
// codes wants "tab": false and a plain open.
private func openScriptedTab(_ url: String, bundleID: String) -> Bool {
    let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)

    func event(_ cls: StaticString, _ id: StaticString) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor.appleEvent(
            withEventClass: code(cls), eventID: code(id), targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }
    func send(_ e: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try e.sendEvent(options: [.waitForReply], timeout: 10)
    }

    // window 1
    let window = NSAppleEventDescriptor.record()
    window.setDescriptor(NSAppleEventDescriptor(typeCode: code("cwin")), forKeyword: code("want"))
    window.setDescriptor(NSAppleEventDescriptor(enumCode: code("indx")), forKeyword: code("form"))
    window.setDescriptor(NSAppleEventDescriptor(int32: 1), forKeyword: code("seld"))
    window.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: code("from"))
    guard let windowSpec = window.coerce(toDescriptorType: code("obj ")) else { return false }

    let make = event("core", "crel")
    make.setDescriptor(NSAppleEventDescriptor(typeCode: code("bTab")), forKeyword: code("kocl"))
    let properties = NSAppleEventDescriptor.record()
    properties.setDescriptor(NSAppleEventDescriptor(string: url), forKeyword: code("pURL"))
    make.setDescriptor(properties, forKeyword: code("prdt"))
    let at = NSAppleEventDescriptor.record()
    at.setDescriptor(NSAppleEventDescriptor(enumCode: code("end ")), forKeyword: code("kpos"))
    at.setDescriptor(windowSpec, forKeyword: code("kobj"))
    guard let insertion = at.coerce(toDescriptorType: code("insl")) else { return false }
    make.setDescriptor(insertion, forKeyword: code("insh"))

    do {
        _ = try send(event("misc", "actv"))
        let made = try send(make)
        let tab = made.forKeyword(code("----")) ?? made

        let current = NSAppleEventDescriptor.record()
        current.setDescriptor(NSAppleEventDescriptor(typeCode: code("prop")), forKeyword: code("want"))
        current.setDescriptor(NSAppleEventDescriptor(enumCode: code("prop")), forKeyword: code("form"))
        current.setDescriptor(NSAppleEventDescriptor(typeCode: code("cTab")), forKeyword: code("seld"))
        current.setDescriptor(windowSpec, forKeyword: code("from"))
        guard let currentSpec = current.coerce(toDescriptorType: code("obj ")) else { return true }

        let select = event("core", "setd")
        select.setDescriptor(currentSpec, forKeyword: code("----"))
        select.setDescriptor(tab, forKeyword: code("data"))
        _ = try send(select)
        return true
    } catch {
        // No window open yet is the common case: a plain open makes one.
        return false
    }
}

private func openDirectly(_ url: String, bundleID: String) -> Bool {
    guard let target = URL(string: url),
          let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    else { return false }

    // Synchronous, because the process exits as soon as this returns: an async
    // open would be cancelled with it. The semaphore waits for LaunchServices to
    // acknowledge the open, not for the page to load.
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    var launched = false
    let done = DispatchSemaphore(value: 0)
    NSWorkspace.shared.open([target], withApplicationAt: app, configuration: config) { _, error in
        launched = error == nil
        done.signal()
    }
    _ = done.wait(timeout: .now() + 10)
    return launched
}

private func open(_ url: String, in browser: Browser) -> Bool {
    if browser.tab, openScriptedTab(url, bundleID: browser.bundleID) { return true }
    return openDirectly(url, bundleID: browser.bundleID)
}

// MARK: - Routing

private func route(_ url: String) {
    let config = loadConfig()
    let full = NSRange(url.startIndex..<url.endIndex, in: url)

    for rule in config.rules where rule.patterns.contains(where: { $0.firstMatch(in: url, range: full) != nil }) {
        var target = url
        if let (pattern, with) = rule.rewrite {
            target = pattern.stringByReplacingMatches(in: url, range: full, withTemplate: with)
        }
        // A browser that fails to open falls through to the default rather than
        // dropping the link: an uninstalled browser should cost the split, not the
        // click.
        if open(target, in: rule.browser) { return }
        _ = open(target, in: config.fallback)
        return
    }
    if open(url, in: config.fallback) { return }
    _ = open(url, in: Config.builtin.fallback)
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var handledURL = false

    // The handler has to be registered before launch finishes: the URL event can
    // arrive as part of the launch itself.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    // Launched with no URL, which is what happens when it is opened from Finder or
    // by the installer. There is no UI, so the only useful thing it can do is ask
    // to become the default browser, which macOS answers with a prompt.
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard !self.handledURL else { return }
            let me = Bundle.main.bundleURL
            NSWorkspace.shared.setDefaultApplication(at: me, toOpenURLsWithScheme: "http") { _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            // The prompt is modal and owned by the system; give it time to be
            // answered before leaving.
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { NSApp.terminate(nil) }
        }
    }

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        handledURL = true
        guard let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else {
            NSApp.terminate(nil)
            return
        }
        route(url)
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Accessory: no Dock icon, no menu bar, nothing to focus.
app.setActivationPolicy(.accessory)
app.run()
