import AppKit
import RedactionCore
import SwiftUI

@MainActor
final class ApplicationController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let clipboard: Clipboard
    private let smokeTest: Bool
    private var statusItem: NSStatusItem?
    private var shortcutItem: NSMenuItem?
    private var shortcut = Shortcut.defaultValue
    private lazy var hotKey = HotKey { [weak self] in self?.openRedaction() }
    private var hotKeyActive = false

    private var window: NSWindow?
    private var lastMode = RedactionMode.oracle
    private var clipboardVersion: Int?
    private var model: PreviewModel?
    private var store = SessionStore()
    private var expiry: Task<Void, Never>?
    private var settingsOpen = false
    private let shortcutKey = "globalShortcut"

    init(clipboard: Clipboard, smokeTest: Bool) {
        self.clipboard = clipboard
        self.smokeTest = smokeTest
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        configureMenu()
        if smokeTest {
            Task { await runSmokeTest() }
        } else {
            shortcut = Shortcut(settings: UserDefaults.standard.dictionary(forKey: shortcutKey)) ?? .defaultValue
            hotKeyActive = hotKey.register(shortcut)
            updateMenu()
        }
    }

    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        expiry?.cancel()
        store.clear()
        model?.reset()
        hotKey.removeHandler()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        if let model, model.intent == .redact { lastMode = model.mode }
        model?.reset()
        clipboardVersion = nil
        closing.contentViewController = nil
        model = nil
        window = nil
    }

    private func configureMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "本地脱敏")
        item.button?.toolTip = "本地脱敏中转站"

        let menu = NSMenu(title: "本地脱敏")
        menu.autoenablesItems = false
        shortcutItem = addItem("脱敏剪贴板", action: #selector(openRedaction), menu: menu)
        addItem("还原 AI 回复", action: #selector(openRestoration), menu: menu)
        addItem("清除还原映射", action: #selector(clearSession), menu: menu)
        menu.addItem(.separator())
        addItem("设置全局快捷键…", action: #selector(recordShortcut), menu: menu)
        addItem("退出", action: #selector(quit), menu: menu)
        item.menu = menu
        statusItem = item
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector, menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func updateMenu() {
        shortcutItem?.title = hotKeyActive ? "脱敏剪贴板     \(shortcut.title)" : "脱敏剪贴板"
        statusItem?.button?.toolTip = hotKeyActive
            ? "本地脱敏（\(shortcut.title)）"
            : "本地脱敏（快捷键不可用，可在菜单中设置）"
    }

    @objc private func openRedaction() { present(.redact) }
    @objc private func openRestoration() { present(.restore) }

    private func present(_ intent: PreviewModel.Intent) {
        guard !settingsOpen else { return }
        if let window, let model, model.intent == intent {
            if clipboardVersion != clipboard.pasteboard.changeCount { reload() }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        window?.close()

        let model = PreviewModel(intent: intent)
        model.mode = lastMode
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 550),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isRestorable = false
        panel.contentMinSize = NSSize(width: 790, height: 480)
        panel.title = "本地脱敏中转站"
        panel.center()
        panel.contentViewController = NSHostingController(rootView: PreviewView(
            model: model,
            reload: { [weak self] in self?.reload() },
            copy: { [weak self] in self?.copyResult() },
            dismiss: { [weak self] in self?.window?.close() }
        ))

        self.window = panel
        self.model = model
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        reload()
    }

    private func reload() {
        guard let model else { return }
        clipboardVersion = clipboard.pasteboard.changeCount
        if model.intent == .restore {
            guard let map = store.current() else {
                model.invalidateRestore()
                return
            }
            model.load(clipboard.read(), restoreMap: map)
        } else {
            model.load(clipboard.read())
        }
    }

    private func copyResult() {
        guard let model, model.canCopy else { return }
        if model.intent == .restore, store.current()?.id != model.mapID {
            model.invalidateRestore()
            return
        }
        guard clipboard.write(model.output) else {
            model.showNotice("写入剪贴板失败。请重新载入文本后重试。")
            return
        }
        if let preview = model.preview {
            store.commit(preview.mapping)
            scheduleExpiry()
        }
        window?.close()
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        guard store.current() != nil else { return }
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: SessionStore.lifetime, clock: .continuous) }
            catch { return }
            self?.clearSession()
        }
    }

    @objc private func clearSession() {
        expiry?.cancel()
        expiry = nil
        store.clear()
        model?.invalidateRestore()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func recordShortcut() {
        guard !settingsOpen else { return }
        settingsOpen = true
        hotKey.unregister()
        defer { settingsOpen = false }

        let old = shortcut
        var candidate = old
        let alert = NSAlert()
        alert.messageText = "设置全局快捷键"
        alert.informativeText = "按下新组合键。使用至少两个修饰键，其中包括 ⌃ 或 ⌘，再加一个字母、数字或符号键。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "恢复默认")
        let label = NSTextField(labelWithString: old.title)
        label.frame.size = NSSize(width: 260, height: 32)
        label.alignment = .center
        label.font = .systemFont(ofSize: 19, weight: .semibold)
        alert.accessoryView = label

        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let recorded = Shortcut(event: event) else { return event }
            candidate = recorded
            label.stringValue = recorded.title
            return nil
        }
        NSApp.activate()
        let result = alert.runModal()
        if let monitor { NSEvent.removeMonitor(monitor) }
        switch result {
        case .alertFirstButtonReturn: shortcut = candidate
        case .alertThirdButtonReturn: shortcut = .defaultValue
        default: shortcut = old
        }

        hotKeyActive = hotKey.register(shortcut)
        if hotKeyActive, shortcut != old {
            UserDefaults.standard.set(shortcut.settings, forKey: shortcutKey)
        } else if !hotKeyActive, result != .alertSecondButtonReturn {
            shortcut = old
            hotKeyActive = hotKey.register(old)
            let conflict = NSAlert()
            conflict.messageText = "无法注册该快捷键"
            conflict.informativeText = "系统或其他应用可能已使用这个组合。可以选择其他组合，或从菜单打开预览。"
            conflict.runModal()
        }
        updateMenu()
    }

    private func runSmokeTest() async {
        let input = "SELECT a.id FROM DEMO.PRIVATE_TABLE a WHERE a.id = :id"
        guard clipboard.write(input) else { smokeFailure("fixture clipboard write") }
        let initialCount = clipboard.pasteboard.changeCount
        present(.redact)
        await awaitPreview()
        guard model?.canCopy == true, window?.isVisible == true else { smokeFailure("redaction preview") }
        guard clipboard.pasteboard.changeCount == initialCount else { smokeFailure("premature clipboard write") }
        window?.close()
        guard model == nil, clipboard.read() == input else { smokeFailure("cancel changed clipboard") }

        present(.redact)
        await awaitPreview()
        guard let outbound = model?.preview?.text, !outbound.contains("PRIVATE_TABLE") else {
            smokeFailure("expected Oracle masking")
        }
        copyResult()
        guard clipboard.read() == outbound, store.current()?.count == 3, model == nil else {
            smokeFailure("confirmed masked copy and mapping commit")
        }
        guard clipboard.write("AI suggests: \(outbound)") else { smokeFailure("fixture AI write") }
        present(.restore)
        await awaitPreview()
        guard model?.restoration?.text == "AI suggests: \(input)" else { smokeFailure("restore preview") }
        copyResult()
        guard clipboard.read() == "AI suggests: \(input)" else { smokeFailure("confirmed restored copy") }

        present(.restore)
        await awaitPreview()
        let beforeClear = clipboard.pasteboard.changeCount
        clearSession()
        copyResult()
        guard store.current() == nil, model?.output == "", model?.canCopy == false,
              clipboard.pasteboard.changeCount == beforeClear else {
            smokeFailure("clear invalidated restore preview")
        }
        window?.close()
        await verifyLogPreview()
        await verifyEnhancedPreview()
        verifyNetworkSandbox()
        guard hotKey.register(shortcut) || hotKey.register(.smokeTestValue) else {
            smokeFailure("global shortcut registration unavailable")
        }
        hotKey.unregister()
        clipboard.pasteboard.releaseGlobally()
        print("PASS AppKit menu and hotkey registration, confirmed clipboard writes, cancel, bulk manual marks, privacy options, prompt preview, restore, map clearing, outbound network denied")
        Darwin.exit(0)
    }

    private func verifyLogPreview() async {
        let input = "service=demo peer=192.0.2.8 password=fake-only"
        guard clipboard.write(input) else { smokeFailure("fixture log write") }
        present(.redact)
        guard let model else { smokeFailure("log preview window") }
        model.mode = .log
        await awaitPreview()
        guard model.canCopy, model.output.contains("REDACTED_SECRET") else { smokeFailure("log masking") }
        model.selection = (input as NSString).range(of: "demo")
        model.markSelection()
        await awaitPreview()
        guard model.output.contains("service=REDACTED "), model.manual.count == 1 else {
            smokeFailure("manual selection")
        }
        model.undoMark()
        await awaitPreview()
        guard model.output.contains("service=demo "), model.manual.isEmpty else { smokeFailure("undo selection") }

        let updated = "peer=192.0.2.9 clientSecret=sample-only"
        guard clipboard.write(updated) else { smokeFailure("updated clipboard") }
        present(.redact)
        await awaitPreview()
        guard model.source == updated, model.output.contains("clientSecret=REDACTED_SECRET") else {
            smokeFailure("shortcut refresh when clipboard changes")
        }

        window?.close()
    }

    private func verifyEnhancedPreview() async {
        let input = "service=cobalt owner=ops@example.test url=https://db.example.test:8443/health retry=cobalt"
        guard clipboard.write(input) else { smokeFailure("enhanced fixture write") }
        present(.redact)
        guard let model else { smokeFailure("enhanced preview window") }
        await awaitPreview()

        model.options = RedactionOptions(emails: true, urlHosts: true)
        await awaitPreview()
        guard let preview = model.preview, model.canCopy, preview.mapping.count == 2,
              !model.output.contains("ops@example.test"), !model.output.contains("db.example.test") else {
            smokeFailure("optional email and URL host masking")
        }

        model.selection = (input as NSString).range(of: "cobalt")
        model.markSelection(everyOccurrence: true)
        await awaitPreview()
        guard model.output.contains("service=REDACTED"), model.output.hasSuffix("retry=REDACTED"),
              model.manual.count == 1 else { smokeFailure("bulk selection masking") }
        model.undoMark()
        await awaitPreview()
        guard model.output == preview.text, model.manual.isEmpty else { smokeFailure("bulk undo") }

        model.includePrompt = true
        let prompted = model.output
        guard prompted.hasSuffix(preview.text), model.outputOffset > 0,
              prompted.contains("请根据以下日志定位问题") else { smokeFailure("prompt preview") }
        copyResult()
        guard clipboard.read() == prompted, store.current()?.count == 2 else {
            smokeFailure("prompt clipboard matches preview")
        }
        guard clipboard.write(preview.text) else { smokeFailure("restore fixture for optional rules") }
        present(.restore)
        await awaitPreview()
        guard self.model?.output == input else { smokeFailure("optional rule restore") }
        window?.close()

        present(.redact)
        guard let benchmarkModel = self.model, benchmarkModel.options == RedactionOptions(),
              !benchmarkModel.includePrompt else { smokeFailure("new preview defaults") }
        benchmarkModel.options = RedactionOptions(emails: true, urlHosts: true)
        let line = "2026-11-23T12:34:56Z ORA-12170 peer=192.0.2.8:1521 url=https://db.example.test owner=sample@example.test\n"
        let load = String(repeating: line, count: (100 * 1024) / line.utf8.count)
        guard clipboard.write(load) else { smokeFailure("large fixture write") }
        var samples: [Double] = []
        for _ in 0..<20 {
            let start = ContinuousClock.now
            reload()
            await awaitPreview()
            await Task.yield()
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
            let elapsed = start.duration(to: .now).components
            samples.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
        }
        let p95 = samples.sorted()[18]
        print(String(format: "Preview P95 %.1f ms (%d input bytes, %d runs)", p95, load.utf8.count, samples.count))
        guard benchmarkModel.canCopy, p95 <= 300 else { smokeFailure("preview latency budget") }
        window?.close()
    }

    private func verifyNetworkSandbox() {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        if socket < 0 {
            guard errno == EPERM || errno == EACCES else { smokeFailure("sandbox socket result") }
            return
        }
        defer { Darwin.close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(9).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == -1, errno == EPERM || errno == EACCES else { smokeFailure("outbound networking available") }
    }

    private func awaitPreview() async {
        for _ in 0..<200 {
            if model?.busy != true { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        smokeFailure("preview timed out")
    }

    private func smokeFailure(_ step: String) -> Never {
        FileHandle.standardError.write(Data("FAIL \(step)\n".utf8))
        clipboard.pasteboard.releaseGlobally()
        Darwin.exit(1)
    }
}
