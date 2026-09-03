import Cocoa
import CoreGraphics
import ImageIO
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Constants

enum K {
    static let enabled = "ShotPathEnabled"
    static let savedTarget = "ShotPathSavedTarget"
    static let savedLocation = "ShotPathSavedLocation"
    static let didModify = "ShotPathDidModifyDefaults"
    static let lastShot = "ShotPathLastShot"
    static let maxEdge: CGFloat = 1568
    static let domain = "com.apple.screencapture"
    static let retentionSeconds: TimeInterval = 24 * 60 * 60
}

let homeDir = FileManager.default.homeDirectoryForCurrentUser
let inboxURL = homeDir.appendingPathComponent("Library/Application Support/ShotPath/inbox")
let shotsURL = homeDir.appendingPathComponent("shots")

func log(_ s: String) {
    FileHandle.standardError.write(("[ShotPath] " + s + "\n").data(using: .utf8)!)
}

// MARK: - `defaults` shell wrapper

@discardableResult
func defaultsCmd(_ args: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let s = String(data: data, encoding: .utf8) ?? ""
    return (p.terminationStatus, s.trimmingCharacters(in: .whitespacesAndNewlines))
}

func readDefault(_ key: String) -> String? {
    let r = defaultsCmd(["read", K.domain, key])
    return r.status == 0 ? r.out : nil
}

// MARK: - Screenshot defaults management

enum ScreencaptureDefaults {
    /// Capture the user's pre-ShotPath settings once, so disable restores them exactly.
    static func snapshotOriginalIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: K.didModify) else { return }
        d.set(readDefault("target") ?? "", forKey: K.savedTarget)
        d.set(readDefault("location") ?? "", forKey: K.savedLocation)
    }

    static func applyEnabled() {
        try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        snapshotOriginalIfNeeded()
        defaultsCmd(["write", K.domain, "target", "file"])
        defaultsCmd(["write", K.domain, "location", inboxURL.path])
        UserDefaults.standard.set(true, forKey: K.didModify)
        log("defaults set: target=file location=\(inboxURL.path)")
    }

    static func applyDisabled() {
        let d = UserDefaults.standard
        guard d.bool(forKey: K.didModify) else {
            log("never modified defaults; leaving user settings untouched")
            return
        }
        let target = d.string(forKey: K.savedTarget) ?? ""
        let location = d.string(forKey: K.savedLocation) ?? ""
        if target.isEmpty {
            defaultsCmd(["delete", K.domain, "target"])
        } else {
            defaultsCmd(["write", K.domain, "target", target])
        }
        if location.isEmpty {
            defaultsCmd(["delete", K.domain, "location"])
        } else {
            defaultsCmd(["write", K.domain, "location", location])
        }
        d.set(false, forKey: K.didModify)
        log("defaults restored: target=\(target.isEmpty ? "<deleted>" : target) location=\(location.isEmpty ? "<deleted>" : location)")
    }
}

// MARK: - Image helpers

func loadCGImage(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func downscale(_ img: CGImage, maxEdge: CGFloat) -> CGImage {
    let w = CGFloat(img.width), h = CGFloat(img.height)
    let longer = max(w, h)
    guard longer > maxEdge else { return img }
    let scale = maxEdge / longer
    let nw = max(1, Int((w * scale).rounded()))
    let nh = max(1, Int((h * scale).rounded()))
    guard let ctx = CGContext(data: nil, width: nw, height: nh,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return img }
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: nw, height: nh))
    return ctx.makeImage() ?? img
}

@discardableResult
func writePNG(_ img: CGImage, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(dest, img, nil)
    return CGImageDestinationFinalize(dest)
}

func tokenEstimate(_ w: Int, _ h: Int) -> Int {
    Int(ceil(Double(w * h) / 750.0))
}

func copyPathToClipboard(_ path: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(path, forType: .string)
}

// MARK: - Inbox watcher

final class InboxWatcher {
    private var fd: CInt = -1
    private var source: DispatchSourceFileSystemObject?
    private var poll: Timer?
    private var inFlight = Set<String>()
    private let queue = DispatchQueue(label: "shotpath.watch")
    var onNewFile: ((URL) -> Void)?

    private let imageExts: Set<String> = ["png", "jpg", "jpeg", "tiff", "heic", "pdf", "gif"]

    func start() {
        stop()
        try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        fd = open(inboxURL.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .rename], queue: queue)
            src.setEventHandler { [weak self] in self?.scan() }
            src.setCancelHandler { [weak self] in
                if let f = self?.fd, f >= 0 { close(f) }
                self?.fd = -1
            }
            src.resume()
            source = src
        } else {
            log("could not open inbox for watching: \(inboxURL.path)")
        }
        // Belt-and-braces poll: vnode events on a directory can be coalesced.
        poll = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.queue.async { self?.scan() }
        }
        queue.async { [weak self] in self?.scan() }
        log("watching \(inboxURL.path)")
    }

    func stop() {
        poll?.invalidate(); poll = nil
        source?.cancel(); source = nil
    }

    private func scan() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: inboxURL,
                                                      includingPropertiesForKeys: [.fileSizeKey],
                                                      options: [.skipsHiddenFiles])
        else { return }
        for url in items {
            let name = url.lastPathComponent
            if name.hasPrefix(".") { continue }
            if !imageExts.contains(url.pathExtension.lowercased()) { continue }
            if inFlight.contains(name) { continue }
            inFlight.insert(name)
            queue.async { [weak self] in
                guard let self else { return }
                if self.waitUntilStable(url) {
                    DispatchQueue.main.async { self.onNewFile?(url) }
                }
                self.queue.asyncAfter(deadline: .now() + 1.0) { self.inFlight.remove(name) }
            }
        }
    }

    /// Returns true once the file size has been unchanged for 300 ms.
    private func waitUntilStable(_ url: URL) -> Bool {
        var lastSize: UInt64 = .max
        var stableFor: Double = 0
        let step = 0.1
        var waited: Double = 0
        while waited < 10.0 {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? NSNumber
            else { return false }
            let s = size.uint64Value
            if s == lastSize && s > 0 {
                stableFor += step
                if stableFor >= 0.3 { return true }
            } else {
                stableFor = 0
                lastSize = s
            }
            Thread.sleep(forTimeInterval: step)
            waited += step
        }
        return false
    }
}

// MARK: - Notifications

final class Notifier {
    static let shared = Notifier()
    private var authorized = false
    private let usable = Bundle.main.bundleIdentifier != nil

    /// Set by the app delegate so we always have visible feedback, even when
    /// User Notifications are unavailable (common for ad-hoc signed builds).
    var fallback: ((String) -> Void)?

    func requestAuthorization() {
        guard usable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, err in
            self.authorized = ok
            if let err { log("notifications unavailable (\(err.localizedDescription)); using menu bar fallback") }
        }
    }

    func post(_ title: String, _ body: String) {
        log("\(title) — \(body)")
        DispatchQueue.main.async { self.fallback?(body) }
        guard usable, authorized else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if let err { log("notification post error: \(err)") }
        }
    }
}

// MARK: - Crop window

final class CropView: NSView {
    var image: NSImage?
    var pixelSize: CGSize = .zero
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?

    override var isFlipped: Bool { false }

    func fittedImageRect() -> NSRect {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return bounds }
        let scale = min(bounds.width / pixelSize.width, bounds.height / pixelSize.height)
        let w = pixelSize.width * scale
        let h = pixelSize.height * scale
        return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    func selectionRect() -> NSRect? {
        guard let a = dragStart, let b = dragCurrent else { return nil }
        let r = NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
                       width: abs(a.x - b.x), height: abs(a.y - b.y))
        return (r.width < 3 || r.height < 3) ? nil : r.intersection(fittedImageRect())
    }

    /// Selection mapped into native image pixels, origin top-left (CGImage convention).
    func selectionInPixels() -> CGRect? {
        guard let sel = selectionRect() else { return nil }
        let ir = fittedImageRect()
        guard ir.width > 0 else { return nil }
        let s = pixelSize.width / ir.width
        let x = (sel.minX - ir.minX) * s
        let yFromBottom = (sel.minY - ir.minY) * s
        let w = sel.width * s
        let h = sel.height * s
        let yTop = pixelSize.height - yFromBottom - h
        return CGRect(x: x.rounded(), y: yTop.rounded(), width: w.rounded(), height: h.rounded())
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let ir = fittedImageRect()
        image?.draw(in: ir)
        if let sel = selectionRect() {
            NSColor(white: 0, alpha: 0.5).setFill()
            for r in [NSRect(x: ir.minX, y: ir.minY, width: ir.width, height: sel.minY - ir.minY),
                      NSRect(x: ir.minX, y: sel.maxY, width: ir.width, height: ir.maxY - sel.maxY),
                      NSRect(x: ir.minX, y: sel.minY, width: sel.minX - ir.minX, height: sel.height),
                      NSRect(x: sel.maxX, y: sel.minY, width: ir.maxX - sel.maxX, height: sel.height)] {
                if r.width > 0 && r.height > 0 { r.fill() }
            }
            NSColor.systemYellow.setStroke()
            let p = NSBezierPath(rect: sel)
            p.lineWidth = 2
            p.stroke()
        }
    }

    /// Test hook: set the drag endpoints directly, in view coordinates.
    func setDragForTesting(from a: NSPoint, to b: NSPoint) {
        dragStart = a
        dragCurrent = b
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
}

final class CropWindowController: NSWindowController {
    private let sourceURL: URL
    private let cropView = CropView()
    private var cg: CGImage!

    init?(url: URL) {
        guard let img = loadCGImage(url) else { return nil }
        self.sourceURL = url
        self.cg = img
        let maxW: CGFloat = 1100, maxH: CGFloat = 750
        let scale = min(1, min(maxW / CGFloat(img.width), maxH / CGFloat(img.height)))
        let w = max(320, CGFloat(img.width) * scale)
        let h = max(240, CGFloat(img.height) * scale)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h + 44),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Crop — \(url.lastPathComponent)"
        super.init(window: win)

        cropView.image = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
        cropView.pixelSize = CGSize(width: img.width, height: img.height)
        cropView.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "Drag a rectangle, then Crop & Copy Path.")
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.textColor = .secondaryLabelColor

        let cropBtn = NSButton(title: "Crop & Copy Path", target: self, action: #selector(doCrop))
        cropBtn.keyEquivalent = "\r"
        cropBtn.translatesAutoresizingMaskIntoConstraints = false
        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(doCancel))
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false

        let content = win.contentView!
        content.addSubview(cropView)
        content.addSubview(hint)
        content.addSubview(cropBtn)
        content.addSubview(cancelBtn)
        NSLayoutConstraint.activate([
            cropView.topAnchor.constraint(equalTo: content.topAnchor),
            cropView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            cropView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            cropView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -44),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            hint.centerYAnchor.constraint(equalTo: cropBtn.centerYAnchor),
            cropBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            cropBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            cancelBtn.trailingAnchor.constraint(equalTo: cropBtn.leadingAnchor, constant: -8),
            cancelBtn.centerYAnchor.constraint(equalTo: cropBtn.centerYAnchor),
        ])
        win.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func doCancel() { close() }

    @objc private func doCrop() {
        guard let rect = cropView.selectionInPixels(), rect.width >= 1, rect.height >= 1
        else { NSSound.beep(); return }
        if CropWindowController.writeCrop(cg, rect: rect, sourceURL: sourceURL) == nil {
            NSSound.beep()
            return
        }
        close()
    }

    /// Native-resolution crop -> ~/shots/<name>-crop.png, path on clipboard. Returns the URL.
    @discardableResult
    static func writeCrop(_ cg: CGImage, rect: CGRect, sourceURL: URL) -> URL? {
        guard let cropped = cg.cropping(to: rect) else { return nil }
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let out = shotsURL.appendingPathComponent("\(base)-crop.png")
        try? FileManager.default.createDirectory(at: shotsURL, withIntermediateDirectories: true)
        guard writePNG(cropped, to: out) else { return nil }
        copyPathToClipboard(out.path)
        let t = tokenEstimate(cropped.width, cropped.height)
        Notifier.shared.post("ShotPath",
                             "path copied (\(cropped.width)x\(cropped.height), ~\(t) tokens)")
        return out
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var enabledItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private let watcher = InboxWatcher()
    private var cropWC: CropWindowController?
    private var housekeepingTimer: Timer?

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: K.enabled) }
        set { UserDefaults.standard.set(newValue, forKey: K.enabled) }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        try? FileManager.default.createDirectory(at: shotsURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)

        UNUserNotificationCenter.current().delegate = self
        Notifier.shared.requestAuthorization()

        buildMenu()
        Notifier.shared.fallback = { [weak self] body in self?.flashStatus(body) }
        watcher.onNewFile = { [weak self] url in self?.handleNewScreenshot(url) }

        // Launch-time overrides, useful for scripted testing.
        if CommandLine.arguments.contains("--enable") { isEnabled = true }
        if CommandLine.arguments.contains("--disable") { isEnabled = false }

        // Reconcile persisted state -> system defaults.
        if isEnabled {
            ScreencaptureDefaults.applyEnabled()
            watcher.start()
        } else {
            ScreencaptureDefaults.applyDisabled()
        }
        refreshMenuState()

        housekeeping()
        housekeepingTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.housekeeping()
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        watcher.stop()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) {
        h([.banner, .list])
    }

    // MARK: Menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "ShotPath")
            btn.image?.isTemplate = true
        }
        let menu = NSMenu()
        enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        menu.addItem(enabledItem)
        menu.addItem(.separator())
        let crop = NSMenuItem(title: "Crop last shot…", action: #selector(cropLastShot), keyEquivalent: "")
        crop.target = self
        menu.addItem(crop)
        let open = NSMenuItem(title: "Open ~/shots", action: #selector(openShots), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func refreshMenuState() {
        enabledItem.state = isEnabled ? .on : .off
        if #available(macOS 13.0, *) {
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            loginItem.isHidden = true
        }
    }

    @objc private func toggleEnabled() {
        setEnabled(!isEnabled)
    }

    func setEnabled(_ on: Bool) {
        isEnabled = on
        if on {
            ScreencaptureDefaults.applyEnabled()
            watcher.start()
            Notifier.shared.post("ShotPath", "Enabled — screenshots become file paths.")
        } else {
            watcher.stop()
            ScreencaptureDefaults.applyDisabled()
            Notifier.shared.post("ShotPath", "Disabled — native screenshot behavior restored.")
        }
        refreshMenuState()
    }

    @objc private func openShots() {
        try? FileManager.default.createDirectory(at: shotsURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(shotsURL)
    }

    @objc private func cropLastShot() {
        guard let path = UserDefaults.standard.string(forKey: K.lastShot),
              FileManager.default.fileExists(atPath: path)
        else {
            let a = NSAlert()
            a.messageText = "No recent shot"
            a.informativeText = "Take a screenshot first."
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
            return
        }
        cropWC = CropWindowController(url: URL(fileURLWithPath: path))
        NSApp.activate(ignoringOtherApps: true)
        cropWC?.showWindow(nil)
        cropWC?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleLoginItem() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            log("login item error: \(error)")
        }
        refreshMenuState()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private var flashWork: DispatchWorkItem?

    /// Show the message next to the menu bar icon for a few seconds.
    private func flashStatus(_ text: String) {
        guard let btn = statusItem?.button else { return }
        flashWork?.cancel()
        btn.title = " " + text
        let w = DispatchWorkItem { [weak self] in self?.statusItem?.button?.title = "" }
        flashWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }

    // MARK: Pipeline

    private func handleNewScreenshot(_ url: URL) {
        guard let img = loadCGImage(url) else {
            log("could not decode \(url.lastPathComponent)")
            return
        }
        let scaled = downscale(img, maxEdge: K.maxEdge)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        var out = shotsURL.appendingPathComponent("\(fmt.string(from: Date())).png")
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) {
            out = shotsURL.appendingPathComponent("\(fmt.string(from: Date()))-\(n).png")
            n += 1
        }
        try? FileManager.default.createDirectory(at: shotsURL, withIntermediateDirectories: true)
        guard writePNG(scaled, to: out) else {
            log("failed writing \(out.path)")
            return
        }
        try? FileManager.default.removeItem(at: url)
        copyPathToClipboard(out.path)
        UserDefaults.standard.set(out.path, forKey: K.lastShot)
        let t = tokenEstimate(scaled.width, scaled.height)
        Notifier.shared.post("ShotPath",
                             "path copied (\(scaled.width)x\(scaled.height), ~\(t) tokens)")
    }

    // MARK: Housekeeping

    private func housekeeping() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: shotsURL,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles])
        else { return }
        let cutoff = Date().addingTimeInterval(-K.retentionSeconds)
        var removed = 0
        for u in items {
            guard let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { continue }
            if d < cutoff {
                try? fm.removeItem(at: u)
                removed += 1
            }
        }
        if removed > 0 { log("housekeeping removed \(removed) file(s) older than 24h") }
    }
}

// MARK: - Entry point

let args = CommandLine.arguments

if args.contains("--install-login-item") || args.contains("--uninstall-login-item") {
    if #available(macOS 13.0, *) {
        do {
            if args.contains("--install-login-item") {
                try SMAppService.mainApp.register()
                print("Registered ShotPath as a login item.")
            } else {
                try SMAppService.mainApp.unregister()
                print("Unregistered ShotPath login item.")
            }
        } catch {
            print("Login item error: \(error)")
            exit(1)
        }
    } else {
        print("Requires macOS 13 or newer.")
        exit(1)
    }
    exit(0)
}

if args.contains("--selftest-crop") {
    // Exercise the shipped CropView mapping: a 400x300 view showing a 4000x3000 image
    // (scale 10x), with a drag from (100,50) to (300,200) in view coords.
    let v = CropView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    v.pixelSize = CGSize(width: 4000, height: 3000)
    v.setDragForTesting(from: NSPoint(x: 100, y: 50), to: NSPoint(x: 300, y: 200))
    let ir = v.fittedImageRect()
    print("fittedImageRect: \(ir)")
    if let r = v.selectionInPixels() {
        print("selectionInPixels: x=\(r.minX) y=\(r.minY) w=\(r.width) h=\(r.height)")
        let expected = CGRect(x: 1000, y: 1000, width: 2000, height: 1500)
        print(r == expected ? "PASS (expected \(expected))" : "FAIL (expected \(expected))")
    } else {
        print("FAIL: no selection")
    }
    // End-to-end write path against a real file, if one was given.
    if let i = args.firstIndex(of: "--selftest-crop"), args.count > i + 1 {
        let src = URL(fileURLWithPath: args[i + 1])
        if let img = loadCGImage(src) {
            let r = CGRect(x: 0, y: 0, width: min(300, img.width), height: min(200, img.height))
            if let out = CropWindowController.writeCrop(img, rect: r, sourceURL: src) {
                print("wrote crop: \(out.path)")
            } else {
                print("FAIL: crop write failed")
            }
        } else {
            print("FAIL: could not load \(src.path)")
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
