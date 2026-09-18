import AppKit
import SwiftUI
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var item: NSStatusItem!
    let popover = NSPopover()
    let model = AppModel(demo: CommandLine.arguments.contains("--demo"))
    var settingsWindow: NSWindow?
    var loginWindow: NSWindow?
    var previewWindow: NSWindow?
    var notificationTokens: [NSObjectProtocol] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(CommandLine.arguments.contains("--preview-window") ? .regular : .accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = MenuBarMeterImage.make(fractions: [])
            button.imagePosition = .imageLeading
            button.target = self; button.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: UsagePopover(model: model, add: { [weak self] in self?.showLogin() }, settings: { [weak self] in self?.showSettings() }))
        model.onStatusChanged = { [weak self] in self?.updateItem() }
        model.onLoginRequested = { [weak self] in self?.showLogin() }
        let center = NSWorkspace.shared.notificationCenter
        notificationTokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.sleep() } })
        notificationTokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.wake() } })
        updateItem(); model.opened()
        if CommandLine.arguments.contains("--show") { togglePopover() }
        if CommandLine.arguments.contains("--settings") { showSettings() }
        if CommandLine.arguments.contains("--preview-window") {
            let controller = usageController(maxHeight: (NSScreen.main?.visibleFrame.height ?? 768) - 40)
            previewWindow = window(title: "Codex Usage Bar 미리보기", view: controller.rootView)
            NSApp.activate(ignoringOtherApps: true)
            previewWindow?.makeKeyAndOrderFront(nil)
        }
    }
    func updateItem() {
        let shown = model.menuBarAccounts
        item.button?.image = MenuBarMeterImage.make(fractions: shown.map(model.menuBarRemainingFraction))
        item.button?.title = model.disk.preferences.showMenuNumbers && !model.statusTitle.isEmpty ? " " + model.statusTitle : ""
        let meters = shown.map { account in
            let remaining = model.menuBarRemainingFraction(account).map { "\(Int(($0 * 100).rounded()))% 남음" } ?? "사용량 미확인"
            return "\(account.alias) \(remaining)"
        }.joined(separator: " · ")
        item.button?.toolTip = meters.isEmpty ? "Codex Usage Bar" : meters
        item.button?.setAccessibilityLabel("Codex 사용량 " + meters + (model.errors.isEmpty ? "" : " · 계정 조회 오류 있음"))
        if popover.isShown { resizePopover() }
        if let window = previewWindow, window.isVisible,
           let hosting = window.contentViewController as? NSHostingController<UsagePopover> {
            let controller = usageController(maxHeight: (window.screen?.visibleFrame.height ?? 768) - 40)
            hosting.rootView = controller.rootView
            let top = window.frame.maxY
            window.setContentSize(NSSize(width: 420, height: controller.rootView.height ?? 630))
            window.setFrameOrigin(NSPoint(x: window.frame.minX, y: max(window.screen?.visibleFrame.minY ?? 0, top - window.frame.height)))
        }
    }
    private func usageController(maxHeight: CGFloat) -> NSHostingController<UsagePopover> {
        func view(height: CGFloat? = nil, scrolling: Bool = false, compact: Bool = false) -> UsagePopover {
            UsagePopover(model: model, add: { [weak self] in self?.showLogin() }, settings: { [weak self] in self?.showSettings() }, height: height, scrollContent: scrolling, compact: compact)
        }
        let controller = NSHostingController(rootView: view())
        let proposal = NSSize(width: 420, height: 10_000)
        let available = max(320, maxHeight)
        var required = ceil(controller.sizeThatFits(in: proposal).height)
        let compact = required > available
        if compact {
            controller.rootView = view(compact: true)
            required = ceil(controller.sizeThatFits(in: proposal).height)
        }
        controller.rootView = view(height: min(required, available), scrolling: required > available, compact: compact)
        return controller
    }
    private func resizePopover() {
        let controller = usageController(maxHeight: (item.button?.window?.screen?.visibleFrame.height ?? 768) - 20)
        if let hosting = popover.contentViewController as? NSHostingController<UsagePopover> { hosting.rootView = controller.rootView }
        else { popover.contentViewController = controller }
        popover.contentSize = NSSize(width: 420, height: controller.rootView.height ?? 630)
    }
    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button {
            model.opened()
            NSApp.activate(ignoringOtherApps: true)
            resizePopover()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            settingsWindow = window(title: "Codex Usage Bar 설정", view: SettingsView(model: model, add: { [weak self] in self?.showLogin() }, usage: { [weak self] in self?.settingsWindow?.orderOut(nil); self?.togglePopover() }))
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
        if model.loginInProgress || model.pendingIdentity != nil { showLogin() }
    }
    func showLogin() {
        popover.performClose(nil)
        if loginWindow == nil {
            loginWindow = window(title: "Codex 계정 연결", view: LoginView(model: model, close: { [weak self] in self?.loginWindow?.close() }))
        }
        NSApp.activate(ignoringOtherApps: true); loginWindow?.makeKeyAndOrderFront(nil)
    }
    private func window<V: View>(title: String, view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false; window.contentViewController = NSHostingController(rootView: view)
        window.delegate = self; window.center(); return window
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === loginWindow { model.cancelLogin() }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
        for token in notificationTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }
}

private enum MenuBarMeterImage {
    static func make(fractions: [Double?]) -> NSImage {
        guard !fractions.isEmpty else {
            return NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Codex Usage Bar") ?? NSImage(size: NSSize(width: 18, height: 18))
        }
        let barWidth: CGFloat = 4.5
        let spacing: CGFloat = 2.5
        let meterHeight: CGFloat = 15
        let imageHeight: CGFloat = 18
        let width = CGFloat(fractions.count) * barWidth + CGFloat(max(0, fractions.count - 1)) * spacing
        let image = NSImage(size: NSSize(width: width, height: imageHeight), flipped: false) { _ in
            for (index, rawFraction) in fractions.enumerated() {
                let x = CGFloat(index) * (barWidth + spacing)
                let trackRect = NSRect(x: x, y: 1.5, width: barWidth, height: meterHeight)
                NSColor.black.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: trackRect, xRadius: 1.25, yRadius: 1.25).fill()
                guard let rawFraction else { continue }
                let fraction = min(1, max(0, rawFraction))
                let fillHeight = max(fraction > 0 ? 1.5 : 0, meterHeight * fraction)
                guard fillHeight > 0 else { continue }
                let fillRect = NSRect(x: x, y: 1.5, width: barWidth, height: fillHeight)
                NSColor.black.setFill()
                NSBezierPath(roundedRect: fillRect, xRadius: 1.25, yRadius: 1.25).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "계정별 Codex 남은 사용량"
        return image
    }
}
@main enum CodexUsageBarApp {
    @MainActor static func main() {
        umask(0o077)
        let app = NSApplication.shared
        let delegate = AppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
