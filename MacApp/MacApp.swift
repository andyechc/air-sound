import AppKit
import SwiftUI

@main
struct AirSoundMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The app lives in the menu bar: no windows, no Dock icon. The empty
        // Settings scene gives SwiftUI a valid scene graph without opening one.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = MacModel()
    private var panel: PanelController!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()

        panel = PanelController(model: model)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureStatusButton()

#if DEBUG
        if CommandLine.arguments.contains("-demo-server") {
            model.startDemoServer()
        }
        if let index = CommandLine.arguments.firstIndex(of: "-snapshot"),
           index + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[index + 1]
            prepareReviewAppearance()
            // Let the status item land in the menu bar, then show the real
            // dropdown and rasterize it: it is the app's only window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showPopoverForSnapshot(to: path)
            }
        }
#endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopSharing()
    }

    // MARK: - Menu bar

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        let image = NSImage(
            systemSymbolName: "dot.radiowaves.left.and.right",
            accessibilityDescription: "Air Sound")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        image?.isTemplate = true
        button.image = image
        button.toolTip = "Air Sound"
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("Air Sound")
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent
        let secondaryClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if secondaryClick {
            showStatusMenu()
        } else {
            NSApp.activate()
            panel.toggle(relativeTo: button)
        }
    }

    /// Right-click menu: the quick actions plus the only visible way out of an
    /// accessory app (there is no Dock icon or app menu to quit from).
    private func showStatusMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()
        let sharing = NSMenuItem(
            title: model.isStreaming ? "Stop sharing" : "Start sharing",
            action: #selector(toggleSharing),
            keyEquivalent: "")
        sharing.target = self
        menu.addItem(sharing)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Air Sound", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleSharing() {
        if model.isStreaming {
            model.stopSharing()
        } else {
            model.startSharing()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Accessory apps show no menu bar menus, but key equivalents still need a
    /// main menu: this is what makes ⌘C/⌘V work in the name and IP fields.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit Air Sound", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [
            ("Undo", Selector(("undo:")), "z"),
            ("Redo", Selector(("redo:")), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ] {
            editMenu.addItem(withTitle: title, action: selector, keyEquivalent: key)
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

#if DEBUG
    // MARK: - Screenshot support

    private func prepareReviewAppearance() {
        if CommandLine.arguments.contains("-light") {
            NSApp.appearance = NSAppearance(named: .aqua)
        } else if CommandLine.arguments.contains("-dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        for window in NSApplication.shared.windows {
            window.appearance = NSApp.appearance
        }
    }

    private func showPopoverForSnapshot(to path: String) {
        guard let button = statusItem.button else { return }
        NSApp.activate()
        panel.show(relativeTo: button)
        waitForPanel(to: path, attempt: 0)
    }

    private func waitForPanel(to path: String, attempt: Int) {
        guard attempt < 50 else { return }
        guard panel.isShown,
              let window = panel.window,
              let content = window.contentView,
              content.bounds.height > 1 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.waitForPanel(to: path, attempt: attempt + 1)
            }
            return
        }
        // The popover is its own window and does not inherit an appearance set
        // on NSApp after launch; pin it so -light/-dark shots are faithful.
        window.appearance = NSApp.appearance
        content.appearance = NSApp.appearance
        window.makeKey()
        window.makeFirstResponder(nil)
        window.display()
        CATransaction.flush()
        // One more runloop turn so SwiftUI finishes laying out the content that
        // just changed size (idle and streaming are different heights).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            Self.snapshot(view: content, to: path)
        }
    }

    /// Rasterizes the panel content at 2x. CALayer render draws the AppKit layer
    /// tree bottom-up, hence the explicit flip; the popover material is not part
    /// of the hosting view, so the window color is painted first.
    static func snapshot(view: NSView, to path: String) {
        guard let layer = view.layer else { return }
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let scale: CGFloat = 2
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        var background = NSColor.windowBackgroundColor.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.cgColor
        }
        context.setFillColor(background)
        context.fill(CGRect(origin: .zero, size: size))
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
#endif
}

/// Owns the NSPopover that shows the control panel under the menu bar icon.
@MainActor
final class PanelController {
    private let popover = NSPopover()
    private let hosting: NSHostingController<AnyView>
    private var sizeObservation: NSKeyValueObservation?

    init(model: MacModel) {
        hosting = NSHostingController(
            rootView: AnyView(
                ContentView()
                    .environment(model)
                    .frame(width: 460)))
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        // The popover does not follow NSHostingController's preferred size on
        // its own; without this it keeps the height from the first show and a
        // session that starts later gets a dead gap (or clipped content).
        sizeObservation = hosting.observe(\.preferredContentSize) { [weak self] controller, _ in
            let size = controller.preferredContentSize
            Task { @MainActor in self?.apply(size) }
        }
    }

    var isShown: Bool { popover.isShown }
    var window: NSWindow? { popover.contentViewController?.view.window }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            show(relativeTo: button)
        }
    }

    func show(relativeTo button: NSStatusBarButton) {
        syncSize()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Do not auto-focus the name field: a menu bar panel that opens with
        // its text selected reads as a glitch, and typing is one click away.
        popover.contentViewController?.view.window?.makeKey()
        popover.contentViewController?.view.window?.makeFirstResponder(nil)
    }

    private func syncSize() {
        hosting.view.layoutSubtreeIfNeeded()
        var size = hosting.preferredContentSize
        if size.height <= 0 { size = hosting.view.fittingSize }
        if size.height <= 0 { size = NSSize(width: 460, height: 360) }
        apply(size)
    }

    private func apply(_ size: NSSize) {
        guard size.width > 0, size.height > 0 else { return }
        let current = popover.contentSize
        if abs(current.width - size.width) > 0.5 || abs(current.height - size.height) > 0.5 {
            popover.contentSize = size
        }
    }
}
