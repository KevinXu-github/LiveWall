// LiveWall — a minimal, low-power looping video wallpaper for macOS.
//
// One looping AVQueuePlayer per distinct video (hardware HEVC/H.264 decode);
// displays showing the same video share a player. One borderless window per
// display sits just below the Finder desktop icons.
// Playback fully stops whenever nobody can see it:
//   • desktop covered by windows / full-screen apps (occlusion, per video)
//   • displays asleep, system asleep, screen locked
//   • Low Power Mode, or thermal state serious/critical
//   • (optional) running on battery
// Menu bar icon: Pause/Resume, Choose Video (all displays or one), Scaling,
// Pause on Battery, Start at Login, Quit. In Finder, Open With → LiveWall
// (or dropping a video on its icon) sets the video too.

import AppKit
import AVFoundation
import IOKit.ps
import ServiceManagement
import UniformTypeIdentifiers

final class WallWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A muted, endlessly looping player for one video file.
final class Loop {
    let player = AVQueuePlayer()
    private let looper: AVPlayerLooper

    init(url: URL) {
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .advance
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
    }

    func stop() {
        looper.disableLooping()
        player.pause()
        player.removeAllItems()
    }
}

extension NSScreen {
    /// Stable across reboots and reconnects, unlike CGDirectDisplayID.
    var uuid: String {
        let id = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "\(id)" }
        return CFUUIDCreateString(nil, u) as String
    }
}

final class LiveWall: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var loops: [URL: Loop] = [:]
    private var walls: [(window: WallWindow, video: URL)] = []
    private var statusItem: NSStatusItem!
    private var powerSource: CFRunLoopSource?

    // Playback gates
    private var userPaused = false
    private var screensAsleep = false
    private var systemAsleep = false
    private var locked = false
    private var onBattery = false

    // MARK: Settings

    private let defaults = UserDefaults.standard
    private var pauseOnBattery: Bool {
        get { defaults.bool(forKey: "pauseOnBattery") }
        set { defaults.set(newValue, forKey: "pauseOnBattery") }
    }
    private var fit: Bool {    // false: fill the screen (crop), true: fit (letterbox)
        get { defaults.bool(forKey: "fit") }
        set { defaults.set(newValue, forKey: "fit") }
    }
    // Bookmarks rather than paths, so a chosen video survives being moved or renamed.
    private var videoBookmark: Data? {
        get { defaults.data(forKey: "video") }
        set { defaults.set(newValue, forKey: "video") }
    }
    private var displayBookmarks: [String: Data] {    // display UUID → bookmark
        get { defaults.dictionary(forKey: "displayVideos") as? [String: Data] ?? [:] }
        set { defaults.set(newValue, forKey: "displayVideos") }
    }

    // MARK: Launch

    private var openingVideo = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if moveToApplicationsIfNeeded() { return }
        buildMenu()
        installObservers()
        registerLoginItemOnFirstRun()
        buildWindows()
        if walls.isEmpty && !openingVideo { chooseVideo() }    // first launch: no video yet
    }

    /// Finder's Open With → LiveWall, or a video dropped on the app's icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        openingVideo = true
        useVideo(url) { [self] bookmark in
            videoBookmark = bookmark
            displayBookmarks = [:]
        }
    }

    // MARK: Install location

    /// Opened from Downloads, login items break, so offer to move into Applications.
    /// Returns true when a copy there has been launched and this one is quitting.
    private func moveToApplicationsIfNeeded() -> Bool {
        let fm = FileManager.default
        let here = Bundle.main.bundleURL
        let userApps = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        guard here.pathExtension == "app",
              !["/Applications", userApps.path].contains(here.deletingLastPathComponent().path)
        else { return false }

        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Move LiveWall to your Applications folder?"
        a.informativeText = "It needs to be there to start when you log in."
        a.addButton(withTitle: "Move")
        a.addButton(withTitle: "Not Now")
        guard a.runModal() == .alertFirstButtonReturn else { return false }

        let dir = fm.isWritableFile(atPath: "/Applications") ? URL(fileURLWithPath: "/Applications") : userApps
        let dest = dir.appendingPathComponent("LiveWall.app")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
            try fm.copyItem(at: here, to: dest)
        } catch {
            alert("Couldn’t move LiveWall", error.localizedDescription)
            return false
        }
        // You already allowed this copy to open; don't make macOS ask again.
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", dest.path]
        try? xattr.run()
        xattr.waitUntilExit()

        for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        where other != .current { other.terminate() }    // an older copy already running

        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: dest, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }

    // MARK: Videos

    /// The video for displays without their own: launch argument, then the
    /// user's choice, then a wallpaper.* bundled in Resources.
    private func defaultVideo() -> URL? {
        if CommandLine.arguments.count > 1 {
            let u = URL(fileURLWithPath: CommandLine.arguments[1])
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        if let u = Self.resolve(videoBookmark) { return u }
        for ext in ["mp4", "mov", "m4v"] {
            if let u = Bundle.main.url(forResource: "wallpaper", withExtension: ext) { return u }
        }
        return nil
    }

    private func video(for screen: NSScreen) -> URL? {
        (Self.resolve(displayBookmarks[screen.uuid]) ?? defaultVideo())?.standardizedFileURL
    }

    private static func resolve(_ bookmark: Data?) -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        guard let u = try? URL(resolvingBookmarkData: bookmark, options: .withoutUI, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
    }

    /// Asks for a video, then uses it as `useVideo` does.
    private func pickVideo(_ message: String, save: @escaping (Data) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = message
        panel.allowedContentTypes = [.movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        useVideo(url, save: save)
    }

    /// Checks AVFoundation can play `url`, then hands its bookmark to `save` and rebuilds.
    private func useVideo(_ url: URL, save: @escaping (Data) -> Void) {
        Task { @MainActor in    // windows may only be touched on the main thread
            let playable = (try? await AVURLAsset(url: url).load(.isPlayable)) ?? false
            guard playable, let bookmark = try? url.bookmarkData() else {
                alert("LiveWall can’t play “\(url.lastPathComponent)”",
                      "Try an .mp4 or .mov encoded as H.264 or HEVC.")
                return
            }
            save(bookmark)
            buildWindows()
        }
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    // MARK: Windows

    private func buildWindows() {
        for wall in walls {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didChangeOcclusionStateNotification, object: wall.window)
            wall.window.orderOut(nil)
        }
        walls.removeAll()

        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        for screen in NSScreen.screens {
            guard let video = video(for: screen) else { continue }    // no window: never cover the desktop with black
            let loop = loops[video] ?? Loop(url: video)
            loops[video] = loop

            let w = WallWindow(contentRect: screen.frame, styleMask: [.borderless],
                               backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.level = level
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.ignoresMouseEvents = true
            w.isOpaque = true
            w.hasShadow = false
            w.backgroundColor = .black
            w.isReleasedWhenClosed = false
            w.animationBehavior = .none

            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            let layer = AVPlayerLayer(player: loop.player)
            layer.videoGravity = fit ? .resizeAspect : .resizeAspectFill
            layer.backgroundColor = NSColor.black.cgColor
            view.layer = layer          // layer-hosting view: no extra drawing work
            view.wantsLayer = true
            view.autoresizingMask = [.width, .height]
            w.contentView = view

            NotificationCenter.default.addObserver(
                self, selector: #selector(occlusionChanged),
                name: NSWindow.didChangeOcclusionStateNotification, object: w)

            w.orderFrontRegardless()
            walls.append((w, video))
        }

        // Release players no display shows any more.
        for (video, loop) in loops where !walls.contains(where: { $0.video == video }) {
            loop.stop()
            loops[video] = nil
        }
        evaluate()
    }

    @objc private func occlusionChanged() { evaluate() }

    // MARK: Observers

    private func installObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensAsleep = true; self?.evaluate() }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensAsleep = false; self?.evaluate() }
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemAsleep = true; self?.evaluate() }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemAsleep = false; self?.evaluate() }

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = true; self?.evaluate() }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = false; self?.evaluate() }

        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.evaluate() }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.evaluate() }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.buildWindows() }

        // Battery / AC changes
        onBattery = Self.isOnBattery()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<LiveWall>.fromOpaque(ctx).takeUnretainedValue()
            me.onBattery = LiveWall.isOnBattery()
            me.evaluate()
        }, ctx)?.takeRetainedValue() {
            powerSource = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
    }

    private static func isOnBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        else { return false }
        return type == kIOPSBatteryPowerValue
    }

    // MARK: Playback decision

    /// Why playback is stopped on every display, or nil if it may play.
    private var pauseReason: String? {
        let p = ProcessInfo.processInfo
        if userPaused { return "Paused" }
        if locked || screensAsleep || systemAsleep { return "Paused while locked or asleep" }
        if p.isLowPowerModeEnabled { return "Paused for Low Power Mode" }
        if p.thermalState == .serious || p.thermalState == .critical { return "Paused to let the Mac cool down" }
        if pauseOnBattery && onBattery { return "Paused on battery" }
        return nil
    }

    private func isVisible(_ video: URL) -> Bool {
        walls.contains { $0.video == video && $0.window.occlusionState.contains(.visible) }
    }

    private func evaluate() {
        let mayPlay = pauseReason == nil
        for (video, loop) in loops {
            if mayPlay && isVisible(video) {
                if loop.player.rate == 0 { loop.player.play() }
            } else if loop.player.rate != 0 {
                loop.player.pause()
            }
        }
        statusItem?.button?.image = NSImage(systemSymbolName: userPaused ? "pause.rectangle" : "play.rectangle",
                                           accessibilityDescription: "LiveWall")
    }

    // MARK: Menu bar

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        menuNeedsUpdate(menu)
    }

    /// Rebuilt each time it opens, so displays, videos and status are always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item(userPaused ? "Resume" : "Pause", #selector(togglePause)))
        if !userPaused { menu.addItem(label(status)) }
        menu.addItem(.separator())

        let screens = NSScreen.screens
        if screens.count == 1 {
            if let v = video(for: screens[0]) { menu.addItem(label(v.lastPathComponent)) }
            menu.addItem(item("Choose Video…", #selector(chooseVideo), key: "o"))
        } else {
            menu.addItem(item("Choose Video for All Displays…", #selector(chooseVideo), key: "o"))
            for screen in screens {
                let sub = NSMenu()
                if let v = video(for: screen) { sub.addItem(label(v.lastPathComponent)) }
                sub.addItem(item("Choose Video…", #selector(chooseDisplayVideo(_:)), for: screen.uuid))
                if displayBookmarks[screen.uuid] != nil {
                    sub.addItem(item("Use Same Video as Other Displays", #selector(resetDisplayVideo(_:)), for: screen.uuid))
                }
                menu.addItem(submenu(screen.localizedName, sub))
            }
        }
        let scaling = NSMenu()
        scaling.addItem(item("Fill Screen", #selector(setFill), on: !fit))
        scaling.addItem(item("Fit to Screen", #selector(setFit), on: fit))
        menu.addItem(submenu("Scaling", scaling))
        menu.addItem(.separator())

        menu.addItem(item("Pause on Battery", #selector(toggleBattery), on: pauseOnBattery))
        menu.addItem(item("Start at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LiveWall", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private var status: String {
        if let reason = pauseReason { return reason }
        if loops.isEmpty { return "No video chosen" }
        return loops.keys.contains(where: isVisible) ? "Playing" : "Paused while the desktop is covered"
    }

    private func item(_ title: String, _ action: Selector, key: String = "", on: Bool = false, for display: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        i.state = on ? .on : .off
        i.representedObject = display
        return i
    }

    private func label(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")    // no action: shown greyed out
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = menu
        return i
    }

    @objc private func togglePause() { userPaused.toggle(); evaluate() }
    @objc private func toggleBattery() { pauseOnBattery.toggle(); evaluate() }
    @objc private func setFill() { setScaling(fit: false) }
    @objc private func setFit() { setScaling(fit: true) }

    private func setScaling(fit: Bool) {
        self.fit = fit
        for wall in walls {
            (wall.window.contentView?.layer as? AVPlayerLayer)?.videoGravity = fit ? .resizeAspect : .resizeAspectFill
        }
    }

    @objc private func chooseVideo() {
        pickVideo("Choose a video to use as your wallpaper.") { [self] bookmark in
            videoBookmark = bookmark
            displayBookmarks = [:]
        }
    }

    @objc private func chooseDisplayVideo(_ sender: NSMenuItem) {
        guard let display = sender.representedObject as? String else { return }
        pickVideo("Choose a video for \(sender.parent?.title ?? "this display").") { [self] bookmark in
            displayBookmarks[display] = bookmark
        }
    }

    @objc private func resetDisplayVideo(_ sender: NSMenuItem) {
        guard let display = sender.representedObject as? String else { return }
        displayBookmarks[display] = nil
        buildWindows()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("LiveWall login item: \(error)") }
    }

    private func registerLoginItemOnFirstRun() {
        let key = "didOfferLoginItem"
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon
let delegate = LiveWall()
app.delegate = delegate
app.run()
