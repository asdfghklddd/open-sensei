import AppKit
import SwiftUI
import CoreServices

@main
enum OpenSenseiApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--diagnose") { Diagnostics.run(); return }
        if CommandLine.arguments.contains("--battery-report") {
            do {
                let report = try BatteryDetailsReader.read()
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                print(String(decoding: try encoder.encode(report), as: UTF8.self))
            } catch { fputs("Battery report unavailable: \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--profile-self") { Diagnostics.profile(); return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate, NSMenuItemValidation {
    private let monitor = Monitor()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var panel: NSPanel?
    private var expandedPanelFrame: NSRect?
    private var center: NSWindow?
    private let centerState = CenterState()
    private let tools = ToolsModel()
    private let fanControl = FanControl()
    private var observers: [NSObjectProtocol] = []
    private var sleepReasons = Set<String>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Reopening the app should reveal the existing instance.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.opensensei.app")
        if others.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "Open Sensei")
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Open Sensei · 点击查看 Mac 状态，右键打开菜单"
        }
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = true
        monitor.onUpdate = { [weak self] in
            guard let self else { return }
            // Reconcile actual window visibility as well as delegate notifications.
            // Transient popovers can disappear when focus changes without a close callback.
            monitor.setSurface("popover", visible: popover.isShown && popover.contentViewController?.view.window?.isVisible == true)
            updateCenterVisibility()
            if statusItem.button?.title != monitor.menuTitle { statusItem.button?.title = monitor.menuTitle }
            statusItem.button?.toolTip = "Open Sensei · \(monitor.cadenceLabel)\nCPU \(Format.percent(monitor.snapshot.cpu))% · 内存 \(Format.percent(monitor.snapshot.memoryUsed == nil ? nil : monitor.snapshot.memoryFraction))%"
        }
        setupMenu()
        observePower()
        fanControl.onRestore = { [weak self] in self?.monitor.requestRefresh([.fans]) }
        monitor.start()
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if CommandLine.arguments.contains("--profile-idle") || CommandLine.arguments.contains("--profile-idle-brief") {
            let brief = CommandLine.arguments.contains("--profile-idle-brief")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.measureUIPhase(brief ? "cold-idle-60s" : "idle-10min", seconds: brief ? 60 : 600) { NSApp.terminate(nil) }
            }
            return
        }
        if CommandLine.arguments.contains("--profile-ui") {
            profileUI(); return
        }
        if !launchedAtLogin {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.show() }
        }
    }

    // Development-only measurement. Runs the real UI, then closes all surfaces;
    // prints two summaries to stdout and exits, with no on-disk history.
    private func profileUI() {
        centerState.page = CommandLine.arguments.contains("--profile-battery") ? .hardware : .cooling
        openCenter()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.measureUIPhase("visible", seconds: 30) { [weak self] in
                guard let self else { return }
                self.center?.close(); self.popover.performClose(nil); self.hidePanel()
                self.monitor.setSurface("popover", visible: false)
                self.monitor.setSurface("center", visible: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.measureUIPhase("idle", seconds: 35) { NSApp.terminate(nil) }
                }
            }
        }
    }
    private func measureUIPhase(_ mode: String, seconds: Double, completion: @escaping () -> Void) {
        let start = ProcessInfo.processInfo.systemUptime, cpu = Diagnostics.cpuSeconds(), samples = monitor.sampleCount, counts = monitor.snapshot.work.totals
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let report: [String: Any] = ["mode": mode, "elapsed": elapsed, "cpuPercentOneCore": (Diagnostics.cpuSeconds() - cpu) / elapsed * 100,
                "memoryFootprintBytes": Hardware.ownMemory(), "samples": self.monitor.sampleCount - samples,
                "visible": self.monitor.visible, "cadence": self.monitor.cadenceLabel,
                "domainReads": Dictionary(uniqueKeysWithValues: self.monitor.snapshot.work.totals.map { ($0.key.rawValue, $0.value - (counts[$0.key] ?? 0)) })]
            if let json = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) { print(String(decoding: json, as: UTF8.self)); fflush(stdout) }
            completion()
        }
    }

    private func hostingController() -> NSViewController {
        NSHostingController(rootView: Dashboard(monitor: monitor, togglePin: { [weak self] in self?.togglePin() }, close: { [weak self] in self?.hidePanel() }, collapse: { [weak self] in self?.collapsePanel() }, openCenter: { [weak self] in self?.openCenter() }))
    }

    @objc private func toggle() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "显示面板", action: #selector(show), keyEquivalent: "").target = self
            menu.addItem(withTitle: "打开管理窗口", action: #selector(openCenter), keyEquivalent: "").target = self
            menu.addItem(withTitle: monitor.pinned ? "取消固定" : "固定悬浮面板", action: #selector(togglePin), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 Open Sensei", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        if monitor.pinned {
            if panel?.isVisible == true { hidePanel() } else { show() }
        } else if popover.isShown { popover.performClose(nil) } else { show() }
    }

    @objc private func show() {
        if monitor.pinned {
            if panel?.contentViewController == nil {
                if monitor.panelCollapsed {
                    panel?.contentViewController = NSHostingController(rootView: CollapsedPanelView(expand: { [weak self] in self?.expandPanel() }, hide: { [weak self] in self?.hidePanel() }))
                } else { panel?.contentViewController = hostingController() }
            }
            panel?.orderFrontRegardless()
            monitor.setSurface("panel", visible: !monitor.panelCollapsed)
        } else if let button = statusItem.button {
            if popover.contentViewController == nil { popover.contentViewController = hostingController() }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            monitor.setSurface("popover", visible: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func togglePin() {
        if monitor.pinned {
            panel?.orderOut(nil)
            panel = nil
            monitor.setSurface("panel", visible: false)
            monitor.pinned = false; monitor.panelCollapsed = false; expandedPanelFrame = nil
            popover.contentViewController = hostingController()
            show()
            return
        }
        let oldFrame = popover.contentViewController?.view.window?.frame
        popover.performClose(nil)
        monitor.pinned = true
        let controller = hostingController()
        let size = controller.view.fittingSize
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let origin = NSPoint(x: min(max(visible.minX, oldFrame?.minX ?? visible.maxX - size.width - 20), visible.maxX - size.width),
                             y: max(visible.minY, visible.maxY - size.height - 12))
        let window = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.hidesOnDeactivate = false
        controller.view.wantsLayer = true
        controller.view.layer?.cornerRadius = 20
        controller.view.layer?.masksToBounds = true
        window.delegate = self
        panel = window
        window.orderFrontRegardless()
        monitor.setSurface("panel", visible: !monitor.panelCollapsed)
    }

    private func collapsePanel() {
        guard let panel, !monitor.panelCollapsed else { return }
        expandedPanelFrame = panel.frame
        monitor.panelCollapsed = true
        monitor.setSurface("panel", visible: false)
        let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let x = panel.frame.midX < screen.midX ? screen.minX + 3 : screen.maxX - 47
        panel.contentViewController = NSHostingController(rootView: CollapsedPanelView(expand: { [weak self] in self?.expandPanel() }, hide: { [weak self] in self?.hidePanel() }))
        panel.setFrame(NSRect(x: x, y: min(max(screen.minY, panel.frame.midY - 58), screen.maxY - 117), width: 44, height: 117), display: true)
    }
    private func expandPanel() {
        guard let panel, monitor.panelCollapsed else { return }
        let controller = hostingController(), screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let size = controller.view.fittingSize
        let saved = expandedPanelFrame ?? NSRect(origin: panel.frame.origin, size: size)
        let origin = NSPoint(x: min(max(screen.minX, saved.minX), screen.maxX - size.width), y: min(max(screen.minY, saved.minY), screen.maxY - size.height))
        panel.contentViewController = controller
        monitor.panelCollapsed = false
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        monitor.setSurface("panel", visible: true)
    }
    private func hidePanel() {
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        monitor.setSurface("panel", visible: false)
    }
    func popoverWillShow(_ notification: Notification) { monitor.setSurface("popover", visible: true) }
    func popoverDidShow(_ notification: Notification) { monitor.setSurface("popover", visible: true) }
    func popoverDidClose(_ notification: Notification) {
        monitor.setSurface("popover", visible: false)
        DispatchQueue.main.async { [weak self] in
            guard let self, !popover.isShown else { return }
            // A hidden hosting view would still observe and rebuild for every sample.
            popover.contentViewController = nil
        }
    }

    @objc private func openCenter() {
        popover.performClose(nil)
        monitor.setSurface("popover", visible: false)
        if center == nil {
            let controller = NSHostingController(rootView: CenterView(monitor: monitor, state: centerState, tools: tools, fanControl: fanControl, processes: tools.processes, onPageChange: { [weak self] in self?.updateCenterVisibility() }))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 750), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Open Sensei"
            window.contentViewController = controller
            window.minSize = NSSize(width: 920, height: 690)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("OpenSenseiCenter")
            window.center()
            center = window
        }
        center?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateCenterVisibility()
    }
    private func updateCenterVisibility() {
        let domains: Set<MetricDomain>
        switch centerState.page {
        case .overview: domains = [.cpu, .memory, .network, .storage, .gpu, .thermal]
        case .hardware: domains = [.battery, .batteryTemperature, .cells, .storage]
        case .cooling: domains = [.thermal, .fans]
        case .activity: domains = [.network, .activity]
        case .efficiency: domains = [.selfUsage]
        default: domains = []
        }
        monitor.setSurface("center", visible: !domains.isEmpty && center?.isVisible == true && center?.isMiniaturized != true && center?.occlusionState.contains(.visible) == true, domains: domains)
    }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === panel {
            monitor.setSurface("panel", visible: !monitor.panelCollapsed && window.isVisible && window.occlusionState.contains(.visible))
        }
        updateCenterVisibility()
    }
    func windowDidMiniaturize(_ notification: Notification) { updateCenterVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { updateCenterVisibility() }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === center {
            monitor.setSurface("center", visible: false)
            tools.cancelAll()
            tools.releaseResults()
            DispatchQueue.main.async { [weak self] in self?.center = nil }
        }
    }
    private func observePower() {
        let notifications: [(Notification.Name, String, Bool)] = [
            (NSWorkspace.willSleepNotification, "sleep", true), (NSWorkspace.didWakeNotification, "sleep", false),
            (NSWorkspace.screensDidSleepNotification, "screen", true), (NSWorkspace.screensDidWakeNotification, "screen", false)
        ]
        for (name, reason, sleeping) in notifications {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if sleeping { self.fanControl.stop(); self.sleepReasons.insert(reason); self.tools.cancelAll() } else { self.sleepReasons.remove(reason) }
                    self.monitor.setAsleep(!self.sleepReasons.isEmpty)
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.monitor.dayChanged() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.monitor.updatePowerState() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.monitor.updatePowerState() }
        })
    }
    private func setupMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Open Sensei", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "打开管理窗口", action: #selector(openCenter), keyEquivalent: "0").target = self
        appMenu.addItem(withTitle: "恢复风扇自动调节", action: #selector(stopFans), keyEquivalent: ".").target = self
        appMenu.addItem(withTitle: "隐藏 Open Sensei", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Open Sensei", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; menu.addItem(editItem)
        let viewItem = NSMenuItem(title: "显示", action: nil, keyEquivalent: "")
        let views = NSMenu(title: "显示")
        for (index, page) in CenterPage.allCases.enumerated() {
            let item = views.addItem(withTitle: page.rawValue, action: #selector(selectPage(_:)), keyEquivalent: index < 9 ? String(index + 1) : "")
            item.tag = index; item.target = self
        }
        viewItem.submenu = views; menu.addItem(viewItem)
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        let windows = NSMenu(title: "窗口")
        windows.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windows; menu.addItem(windowItem)
        let helpItem = NSMenuItem(title: "帮助", action: nil, keyEquivalent: "")
        let help = NSMenu(title: "帮助")
        help.addItem(withTitle: "Open Sensei 使用说明", action: #selector(showHelp), keyEquivalent: "?").target = self
        helpItem.submenu = help; menu.addItem(helpItem)
        NSApp.helpMenu = help
        NSApp.mainMenu = menu
    }

    @objc private func selectPage(_ sender: NSMenuItem) {
        guard CenterPage.allCases.indices.contains(sender.tag) else { return }
        centerState.page = CenterPage.allCases[sender.tag]; openCenter()
    }
    @objc private func openSettings() { centerState.page = .settings; openCenter() }
    @objc private func showAbout() { NSApp.orderFrontStandardAboutPanel(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func showHelp() {
        let alert = NSAlert(); alert.messageText = "Open Sensei"
        alert.informativeText = "点击菜单栏图标查看实时数据。⌘0 打开管理窗口，⌘1–9 切换页面，⌘, 打开设置。\n\n温度与风扇页面可启动需管理员授权的临时散热会话。点击恢复自动，或按 ⌘. 结束会话。会话最长 30 分钟，不安装后台服务。\n\n默认不保留历史。收起面板后每 30 秒更新所选菜单栏指标，SMC 详细传感器暂停读取。"
        alert.addButton(withTitle: "好"); alert.runModal()
    }

    @objc private func stopFans() { fanControl.stop() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { item.action == #selector(stopFans) ? fanControl.busy : true }
    func applicationWillTerminate(_ notification: Notification) { fanControl.stop(); tools.cancelAll() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return true
    }
}
