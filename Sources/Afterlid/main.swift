// Afterlid: a menu-bar replacement for Caffeine that can also keep the Mac running
// with the lid closed, under conditions (plugged in, battery floor, temperature).
//
// Two independent features:
//   1. Keep awake (Caffeine): an IOKit power assertion that blocks idle sleep, with an
//      optional timer and an optional "keep display on".
//   2. Lid closed: flips macOS's system-wide `pmset disablesleep` switch, the only thing
//      that stops lid-close sleep without an external display. It runs only while its
//      conditions hold and is ALWAYS switched back off when they fail or the app quits,
//      so a forgotten toggle can never cook the Mac in a bag.

import AppKit
import IOKit.pwr_mgt
import IOKit.ps
import ServiceManagement

// MARK: - Settings

enum Key {
    static let awakeOn = "awakeOn"
    static let awakeUntil = "awakeUntil"
    static let keepDisplay = "keepDisplay"
    static let lidOn = "lidOn"
    static let lidOnlyOnPower = "lidOnlyOnPower"
    static let lidMinBattery = "lidMinBattery"
    static let lidPauseWhenHot = "lidPauseWhenHot"
    static let weDisabledSleep = "weDisabledSleep"
    static let activateOnLaunch = "activateOnLaunch"
    static let defaultMinutes = "defaultMinutes"
    static let welcomed = "welcomed"
    static let lidActiveNow = "lidActiveNow"      // written by the app, read by the CLI
    static let lidPausedBecause = "lidPausedBecause"
}

/// Posted by the CLI after it changes a setting, so the running app applies it at once.
let changedNote = Notification.Name("com.zivgin.afterlid.changed")

let defaults = UserDefaults.standard

// Defaults shared by the app AND the CLI (both read the same settings).
defaults.register(defaults: [
    Key.lidOnlyOnPower: true,
    Key.lidMinBattery: 25,
    Key.lidPauseWhenHot: true,
    Key.keepDisplay: false,
    Key.activateOnLaunch: false,
    Key.defaultMinutes: 0,
])

// MARK: - Power facts

struct PowerState {
    var onAC: Bool
    var batteryPercent: Int?   // nil on a Mac with no battery
}

func readPower() -> PowerState {
    let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let providing = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
    let onAC = providing == kIOPMACPowerKey
    var percent: Int?
    let list = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]
    for src in list {
        guard let desc = IOPSGetPowerSourceDescription(snapshot, src)?.takeUnretainedValue() as? [String: Any],
              let cur = desc[kIOPSCurrentCapacityKey] as? Int,
              let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
        percent = Int((Double(cur) / Double(max) * 100).rounded())
    }
    return PowerState(onAC: onAC, batteryPercent: percent)
}

// MARK: - The lid switch (pmset disablesleep), via a narrow sudoers rule

enum LidSwitch {
    static let sudoersPath = "/etc/sudoers.d/afterlid"

    /// Is the system-wide "never sleep, even on lid close" switch on right now?
    static func isOn() -> Bool {
        let out = run("/usr/bin/pmset", ["-g"]).output
        for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last == "1"
        }
        return false
    }

    /// Flip it without a password, using the one-time sudoers rule. False if not installed.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]).status == 0
    }

    static var helperInstalled: Bool { FileManager.default.fileExists(atPath: sudoersPath) }

    /// One-time setup: a sudoers rule that allows exactly `pmset -a disablesleep 0|1` and
    /// nothing else. Validated with visudo before install. Prompts for the admin password once.
    static func installHelper() -> Bool {
        let user = NSUserName()
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n"
        let tmp = NSTemporaryDirectory() + "afterlid.sudoers"
        do { try rule.write(toFile: tmp, atomically: true, encoding: .utf8) } catch { return false }
        let shell = "/usr/sbin/visudo -cf '\(tmp)' && /usr/bin/install -m 0440 -o root -g wheel '\(tmp)' '\(sudoersPath)'"
        let script = "do shell script \"\(shell)\" with administrator privileges with prompt \"Afterlid needs your password once to control lid-closed sleep.\""
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        try? FileManager.default.removeItem(atPath: tmp)
        return err == nil && helperInstalled
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    var idleAssertion: IOPMAssertionID = 0
    var displayAssertion: IOPMAssertionID = 0
    var timer: Timer?
    var lidActive = false          // is the switch actually on because of us
    var lidPauseReason: String?    // why lid mode is paused, if it is

    func applicationDidFinishLaunching(_ note: Notification) {
        // Caffeine-style: optionally start awake every launch, for the default duration.
        if defaults.bool(forKey: Key.activateOnLaunch) { startAwake(minutes: defaults.integer(forKey: Key.defaultMinutes)) }
        // Recover from a crash: if we left the switch on last time but the user's intent
        // is now off, put it back.
        if defaults.bool(forKey: Key.weDisabledSleep) && !defaults.bool(forKey: Key.lidOn) {
            LidSwitch.set(false)
            defaults.set(false, forKey: Key.weDisabledSleep)
        }
        // Caffeine-style clicks: left-click toggles keep-awake, right-click (or
        // ctrl/option-click) opens the menu.
        menu.delegate = self
        item.button?.target = self
        item.button?.action = #selector(iconClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // The CLI changed a setting: re-read and apply immediately.
        DistributedNotificationCenter.default().addObserver(forName: changedNote, object: nil, queue: .main) { [weak self] _ in
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
            self?.evaluate()
        }
        // React fast to plug/unplug and heat, and re-check every 20s regardless.
        NotificationCenter.default.addObserver(self, selector: #selector(evaluate),
            name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.evaluate() }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.evaluate() }
        evaluate()

        // First launch: a menu-bar app appears silently, so introduce it once.
        if !defaults.bool(forKey: Key.welcomed) && ProcessInfo.processInfo.environment["AFTERLID_SNAPSHOT"] == nil {
            showWelcome()
        }

        // Docs helper: AFTERLID_SNAPSHOT=<file> opens the menu on launch and writes the
        // icon's screen frame to <file>, so README screenshots can be captured by script.
        if let out = ProcessInfo.processInfo.environment["AFTERLID_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, let f = self.item.button?.window?.frame else { return }
                try? "\(Int(f.minX)) \(Int(f.maxY)) \(Int(f.width)) \(Int(f.height))".write(toFile: out, atomically: true, encoding: .utf8)
                self.item.menu = self.menu
                self.item.button?.performClick(nil)
                self.item.menu = nil
            }
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        // Never leave the Mac unable to sleep after we are gone.
        if lidActive || defaults.bool(forKey: Key.weDisabledSleep) {
            LidSwitch.set(false)
            defaults.set(false, forKey: Key.weDisabledSleep)
        }
        releaseAssertions()
    }

    // MARK: State machine

    @objc func evaluate() {
        // Keep awake: expire the timer if it ran out.
        if let until = defaults.object(forKey: Key.awakeUntil) as? Date, until <= Date() {
            defaults.set(false, forKey: Key.awakeOn)
            defaults.removeObject(forKey: Key.awakeUntil)
        }
        applyAssertions()

        // Lid closed: on only if wanted AND every condition holds.
        let wanted = defaults.bool(forKey: Key.lidOn)
        lidPauseReason = wanted ? pauseReason() : nil
        let shouldBeOn = wanted && lidPauseReason == nil
        if shouldBeOn {
            // Re-assert if anything else flipped it back off under us.
            if !lidActive || !LidSwitch.isOn() {
                if LidSwitch.set(true) {
                    lidActive = true
                    defaults.set(true, forKey: Key.weDisabledSleep)
                } else {
                    lidPauseReason = "needs one-time setup"
                    lidActive = false
                }
            }
        } else if lidActive || defaults.bool(forKey: Key.weDisabledSleep) {
            // Only undo a switch WE turned on; never touch one someone else set.
            LidSwitch.set(false)
            lidActive = false
            defaults.set(false, forKey: Key.weDisabledSleep)
        }
        defaults.set(lidActive, forKey: Key.lidActiveNow)
        defaults.set(lidPauseReason ?? "", forKey: Key.lidPausedBecause)
        refreshIcon()
    }

    func pauseReason() -> String? {
        let p = readPower()
        if defaults.bool(forKey: Key.lidOnlyOnPower) && !p.onAC { return "on battery" }
        let floor = defaults.integer(forKey: Key.lidMinBattery)
        if floor > 0, !p.onAC, let pct = p.batteryPercent, pct < floor { return "battery below \(floor)%" }
        if defaults.bool(forKey: Key.lidPauseWhenHot) {
            let t = ProcessInfo.processInfo.thermalState
            if t == .serious || t == .critical { return "Mac is running hot" }
        }
        return nil
    }

    func applyAssertions() {
        let awake = defaults.bool(forKey: Key.awakeOn)
        let display = awake && defaults.bool(forKey: Key.keepDisplay)
        setAssertion(&idleAssertion, on: awake, type: kIOPMAssertionTypePreventUserIdleSystemSleep)
        setAssertion(&displayAssertion, on: display, type: kIOPMAssertionTypePreventUserIdleDisplaySleep)
    }

    func setAssertion(_ id: inout IOPMAssertionID, on: Bool, type: String) {
        if on && id == 0 {
            IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Afterlid" as CFString, &id)
        } else if !on && id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
    }

    func releaseAssertions() {
        if idleAssertion != 0 { IOPMAssertionRelease(idleAssertion); idleAssertion = 0 }
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
    }

    func refreshIcon() {
        let awake = defaults.bool(forKey: Key.awakeOn)
        // Always the coffee cup, so the app is easy to spot: filled while it keeps the Mac awake
        // (or keeps it running with the lid closed), outline when idle. The lid state lives in the tooltip and menu.
        let name = (awake || lidActive) ? "cup.and.saucer.fill" : "cup.and.saucer"
        let base = NSImage(systemSymbolName: name, accessibilityDescription: "Afterlid")
            ?? NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: "Afterlid")
        if LidSwitch.helperInstalled {
            base?.isTemplate = true
            item.button?.image = base
        } else if let base {
            item.button?.image = withAlertDot(base)
        }
        item.button?.toolTip = statusText()
    }

    /// The menu-bar icon with a red dot in the corner: "something needs your approval".
    /// Drawn in a handler so the glyph follows light/dark menu bars like a template image.
    func withAlertDot(_ glyph: NSImage) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: false) { rect in
            let g = NSImage(size: size, flipped: false) { r in
                glyph.draw(in: r.insetBy(dx: 1, dy: 1))
                NSColor.labelColor.set()
                r.fill(using: .sourceAtop)
                return true
            }
            g.draw(in: rect)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 7, y: rect.maxY - 7, width: 7, height: 7)).fill()
            return true
        }
    }

    func statusText() -> String {
        var parts: [String] = []
        if defaults.bool(forKey: Key.awakeOn) {
            if let until = defaults.object(forKey: Key.awakeUntil) as? Date {
                parts.append("Awake until \(timeFmt.string(from: until))")
            } else { parts.append("Awake") }
        } else { parts.append("Sleeps normally") }
        if defaults.bool(forKey: Key.lidOn) {
            parts.append(lidActive ? "Lid closed: keeps running" : "Lid closed: paused (\(lidPauseReason ?? "?"))")
        }
        return parts.joined(separator: " · ")
    }

    let timeFmt: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        evaluate()
        menu.removeAllItems()
        if !LidSwitch.helperInstalled {
            let bar = NSMenuItem()
            bar.view = approvalBar()
            menu.addItem(bar)
            menu.addItem(.separator())
        }
        let status = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        // Keep awake
        let awake = defaults.bool(forKey: Key.awakeOn)
        menu.addItem(check("Keep Mac awake", awake, #selector(toggleAwake)))
        let dur = NSMenuItem(title: "Keep awake for", action: nil, keyEquivalent: "")
        let durMenu = NSMenu()
        for (title, mins) in durations {
            let i = NSMenuItem(title: title, action: #selector(awakeFor(_:)), keyEquivalent: "")
            i.tag = mins
            i.target = self
            durMenu.addItem(i)
        }
        dur.submenu = durMenu
        menu.addItem(dur)
        menu.addItem(check("Keep display on too", defaults.bool(forKey: Key.keepDisplay), #selector(toggleDisplay)))
        menu.addItem(.separator())

        // Lid closed
        menu.addItem(check(LidSwitch.helperInstalled ? "Keep running with lid closed" : "Keep running with lid closed (needs approval)",
                           defaults.bool(forKey: Key.lidOn), #selector(toggleLid)))
        let cond = NSMenuItem(title: "Lid-closed conditions", action: nil, keyEquivalent: "")
        let c = NSMenu()
        c.addItem(check("Only when plugged in", defaults.bool(forKey: Key.lidOnlyOnPower), #selector(toggleOnlyPower)))
        c.addItem(check("Pause when the Mac runs hot", defaults.bool(forKey: Key.lidPauseWhenHot), #selector(toggleHot)))
        c.addItem(.separator())
        let floorHeader = NSMenuItem(title: "On battery, pause below:", action: nil, keyEquivalent: "")
        floorHeader.isEnabled = false
        c.addItem(floorHeader)
        let floor = defaults.integer(forKey: Key.lidMinBattery)
        for pct in [0, 10, 20, 25, 30, 50] {
            let i = check(pct == 0 ? "  No battery limit" : "  \(pct)%", floor == pct, #selector(setFloor(_:)))
            i.tag = pct
            c.addItem(i)
        }
        cond.submenu = c
        menu.addItem(cond)
        menu.addItem(.separator())

        let pref = NSMenuItem(title: "Click the icon to keep awake for", action: nil, keyEquivalent: "")
        let prefMenu = NSMenu()
        let def = defaults.integer(forKey: Key.defaultMinutes)
        for (title, mins) in durations {
            let i = check(title, def == mins, #selector(setDefault(_:)))
            i.tag = mins
            prefMenu.addItem(i)
        }
        pref.submenu = prefMenu
        menu.addItem(pref)
        menu.addItem(check("Keep awake when Afterlid starts", defaults.bool(forKey: Key.activateOnLaunch), #selector(toggleActivateOnLaunch)))
        let welcome = NSMenuItem(title: "Welcome and setup…", action: #selector(showWelcome), keyEquivalent: "")
        welcome.target = self
        menu.addItem(welcome)
        menu.addItem(check("Launch at login", SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        // Own selector (not NSApplication.terminate) so macOS doesn't auto-add an icon that
        // shifts the whole last section to the right.
        let quit = NSMenuItem(title: "Quit Afterlid", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    let durations: [(String, Int)] = [("Indefinitely", 0), ("5 minutes", 5), ("10 minutes", 10), ("15 minutes", 15),
        ("30 minutes", 30), ("1 hour", 60), ("2 hours", 120), ("4 hours", 240), ("5 hours", 300), ("8 hours", 480)]

    @objc func iconClicked() {
        let e = NSApp.currentEvent
        let wantsMenu = e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true || e?.modifierFlags.contains(.option) == true
        if wantsMenu {
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else if defaults.bool(forKey: Key.awakeOn) {
            defaults.set(false, forKey: Key.awakeOn)
            defaults.removeObject(forKey: Key.awakeUntil)
            evaluate()
        } else {
            startAwake(minutes: defaults.integer(forKey: Key.defaultMinutes))
        }
    }

    func startAwake(minutes: Int) {
        defaults.set(true, forKey: Key.awakeOn)
        if minutes == 0 { defaults.removeObject(forKey: Key.awakeUntil) }
        else { defaults.set(Date().addingTimeInterval(TimeInterval(minutes * 60)), forKey: Key.awakeUntil) }
        evaluate()
    }

    @objc func setDefault(_ sender: NSMenuItem) { defaults.set(sender.tag, forKey: Key.defaultMinutes) }
    @objc func toggleActivateOnLaunch() { defaults.set(!defaults.bool(forKey: Key.activateOnLaunch), forKey: Key.activateOnLaunch) }

    /// A red, clickable bar: lid-closed mode cannot work until the one-time password
    /// approval is given. Clicking it opens the macOS password prompt.
    func approvalBar() -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 44))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.systemRed.cgColor
        v.layer?.cornerRadius = 6
        let b = NSButton(title: "", target: self, action: #selector(approveFromBar))
        b.isBordered = false
        b.attributedTitle = NSAttributedString(
            string: "Lid-closed mode needs approval\nClick to enter your password (one time)",
            attributes: [.foregroundColor: NSColor.white, .font: NSFont.boldSystemFont(ofSize: 12)])
        b.frame = v.bounds.insetBy(dx: 8, dy: 2)
        b.alignment = .left
        v.addSubview(b)
        return v
    }

    @objc func approveFromBar() {
        menu.cancelTracking()
        NSApp.activate(ignoringOtherApps: true)
        if LidSwitch.installHelper() { evaluate() }
    }

    func check(_ title: String, _ on: Bool, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        i.state = on ? .on : .off
        return i
    }

    // MARK: Actions

    @objc func toggleAwake() {
        let now = !defaults.bool(forKey: Key.awakeOn)
        defaults.set(now, forKey: Key.awakeOn)
        defaults.removeObject(forKey: Key.awakeUntil)
        evaluate()
    }

    @objc func awakeFor(_ sender: NSMenuItem) { startAwake(minutes: sender.tag) }

    @objc func toggleDisplay() { defaults.set(!defaults.bool(forKey: Key.keepDisplay), forKey: Key.keepDisplay); evaluate() }
    @objc func toggleOnlyPower() { defaults.set(!defaults.bool(forKey: Key.lidOnlyOnPower), forKey: Key.lidOnlyOnPower); evaluate() }
    @objc func toggleHot() { defaults.set(!defaults.bool(forKey: Key.lidPauseWhenHot), forKey: Key.lidPauseWhenHot); evaluate() }
    @objc func setFloor(_ sender: NSMenuItem) { defaults.set(sender.tag, forKey: Key.lidMinBattery); evaluate() }

    @objc func toggleLid() {
        let now = !defaults.bool(forKey: Key.lidOn)
        if now && !LidSwitch.helperInstalled {
            NSApp.activate(ignoringOtherApps: true)
            if !LidSwitch.installHelper() { return }   // user cancelled the password prompt
        }
        defaults.set(now, forKey: Key.lidOn)
        evaluate()
    }

    @objc func quitApp() { NSApp.terminate(nil) }

    // MARK: Welcome window

    var welcomeWindow: NSWindow?
    var setupButton: NSButton?
    var loginCheckbox: NSButton?

    /// One small window that explains the app and does the two setup steps: approve lid
    /// mode (the one-time password) and launch at login. Shown on first launch and from the menu.
    @objc func showWelcome() {
        if let w = welcomeWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 380),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Welcome to Afterlid"
        w.isReleasedWhenClosed = false

        let icon = NSImageView(image: NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 44, weight: .regular)
        icon.contentTintColor = .controlAccentColor

        let title = NSTextField(labelWithString: "Close the lid. Keep working.")
        title.font = .boldSystemFont(ofSize: 20)

        let body = NSTextField(wrappingLabelWithString:
            "Afterlid lives in your menu bar.\n\n" +
            "•  Click the icon to keep your Mac awake. Right-click for the menu.\n" +
            "•  Turn on \"Keep running with lid closed\" to keep working with the lid shut, no monitor needed. " +
            "It only runs while plugged in (you can change the conditions) and switches itself off when they fail.")
        body.font = .systemFont(ofSize: 13)

        let setup = NSButton(title: "", target: self, action: #selector(welcomeSetup))
        setup.bezelStyle = .rounded
        setupButton = setup
        let login = NSButton(checkboxWithTitle: "Launch Afterlid at login", target: self, action: #selector(welcomeLogin))
        loginCheckbox = login
        let done = NSButton(title: "Done", target: self, action: #selector(closeWelcome))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        refreshWelcome()

        let stack = NSStackView(views: [icon, title, body, setup, login, done])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 22, right: 28)
        stack.setCustomSpacing(22, after: body)
        body.preferredMaxLayoutWidth = 384
        w.contentView = stack
        w.center()
        welcomeWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        defaults.set(true, forKey: Key.welcomed)
    }

    func refreshWelcome() {
        let ready = LidSwitch.helperInstalled
        setupButton?.title = ready ? "✓ Lid mode is set up" : "Set up lid mode (asks for your password once)"
        setupButton?.isEnabled = !ready
        loginCheckbox?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func welcomeSetup() { if LidSwitch.installHelper() { evaluate() }; refreshWelcome() }
    @objc func welcomeLogin() { toggleLogin(); refreshWelcome() }
    @objc func closeWelcome() { welcomeWindow?.close() }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSSound.beep() }
    }
}

// MARK: - CLI
//
//   afterlid status
//   afterlid awake on [minutes]   |  afterlid awake off
//   afterlid lid on               |  afterlid lid off
//   afterlid display on|off       (keep the screen on too while awake)
//   afterlid only-on-power on|off |  afterlid battery-floor <pct>  |  afterlid pause-when-hot on|off
//
// Writes the setting, pokes the running app (launching it if needed), then prints the
// resulting status. Exit 0 on success, 2 on bad usage, 3 if lid mode needs its one-time
// password setup (do it once from the menu).

func cliStatus() -> String {
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    var lines: [String] = []
    if defaults.bool(forKey: Key.awakeOn) {
        if let until = defaults.object(forKey: Key.awakeUntil) as? Date {
            let f = DateFormatter(); f.timeStyle = .short
            lines.append("awake: on (until \(f.string(from: until)))")
        } else { lines.append("awake: on (indefinitely)") }
    } else { lines.append("awake: off") }
    lines.append("display: \(defaults.bool(forKey: Key.keepDisplay) ? "kept on" : "may sleep")")
    if defaults.bool(forKey: Key.lidOn) {
        let reason = defaults.string(forKey: Key.lidPausedBecause) ?? ""
        lines.append(LidSwitch.isOn() ? "lid: on (active, keeps running with lid closed)" : "lid: on but paused (\(reason.isEmpty ? "starting" : reason))")
    } else { lines.append("lid: off") }
    if !LidSwitch.helperInstalled { lines.append("lid setup: NOT approved yet (run `afterlid setup` or click the red bar in the menu)") }
    let p = readPower()
    lines.append("power: \(p.onAC ? "plugged in" : "battery")\(p.batteryPercent.map { ", \($0)%" } ?? "")")
    lines.append("conditions: only-on-power=\(defaults.bool(forKey: Key.lidOnlyOnPower) ? "on" : "off") battery-floor=\(defaults.integer(forKey: Key.lidMinBattery))% pause-when-hot=\(defaults.bool(forKey: Key.lidPauseWhenHot) ? "on" : "off")")
    lines.append("app: \(NSRunningApplication.runningApplications(withBundleIdentifier: "com.zivgin.afterlid").contains { $0.processIdentifier != getpid() } ? "running" : "not running")")
    return lines.joined(separator: "\n")
}

func runCLI(_ args: [String]) -> Int32 {
    func onOff(_ v: String?) -> Bool? { v == "on" ? true : v == "off" ? false : nil }
    let usage = "usage: afterlid status | setup | awake on [minutes] | awake off | lid on|off | display on|off | only-on-power on|off | battery-floor <pct> | pause-when-hot on|off"
    switch (args.first, args.dropFirst().first) {
    case ("setup", _):
        if LidSwitch.helperInstalled { print("already approved"); return 0 }
        guard LidSwitch.installHelper() else { print("not approved (cancelled)"); return 3 }
        DistributedNotificationCenter.default().postNotificationName(changedNote, object: nil, userInfo: nil, deliverImmediately: true)
        print("approved: lid-closed mode can now be switched on and off without a password"); return 0
    case ("status", _), (nil, _):
        print(cliStatus()); return 0
    case ("awake", let v):
        guard let on = onOff(v) else { print(usage); return 2 }
        defaults.set(on, forKey: Key.awakeOn)
        if on, args.count > 2, let mins = Int(args[2]), mins > 0 {
            defaults.set(Date().addingTimeInterval(TimeInterval(mins * 60)), forKey: Key.awakeUntil)
        } else { defaults.removeObject(forKey: Key.awakeUntil) }
    case ("lid", let v):
        guard let on = onOff(v) else { print(usage); return 2 }
        if on && !LidSwitch.helperInstalled {
            print("lid mode needs a one-time approval: run `afterlid setup` (opens the password prompt) or click the red bar in the Afterlid menu.")
            return 3
        }
        defaults.set(on, forKey: Key.lidOn)
    case ("display", let v):
        guard let on = onOff(v) else { print(usage); return 2 }
        defaults.set(on, forKey: Key.keepDisplay)
    case ("only-on-power", let v):
        guard let on = onOff(v) else { print(usage); return 2 }
        defaults.set(on, forKey: Key.lidOnlyOnPower)
    case ("pause-when-hot", let v):
        guard let on = onOff(v) else { print(usage); return 2 }
        defaults.set(on, forKey: Key.lidPauseWhenHot)
    case ("battery-floor", let v):
        guard let v, let pct = Int(v), (0...100).contains(pct) else { print(usage); return 2 }
        defaults.set(pct, forKey: Key.lidMinBattery)
    default:
        print(usage); return 2
    }
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    // Make sure the app is running to apply it, then poke it.
    if NSRunningApplication.runningApplications(withBundleIdentifier: "com.zivgin.afterlid").filter({ $0.processIdentifier != getpid() }).isEmpty {
        _ = LidSwitch.run("/usr/bin/open", ["-g", "/Applications/Afterlid.app"])
        Thread.sleep(forTimeInterval: 2)
    }
    DistributedNotificationCenter.default().postNotificationName(changedNote, object: nil, userInfo: nil, deliverImmediately: true)
    Thread.sleep(forTimeInterval: 1.5)
    print(cliStatus())
    return 0
}

let cliArgs = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn") }
if !cliArgs.isEmpty {
    exit(runCLI(cliArgs))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
