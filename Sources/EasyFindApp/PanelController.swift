import AppKit
import EasyFindCore
import os

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ResultCellView: NSTableCellView {
    let iconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1

        addSubview(iconView)
        for label in [titleLabel, subtitleLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class PanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private static let signposter = OSSignposter(subsystem: "com.local.easyfind", category: "launcher")

    private let index: SearchIndex
    private let store: Store
    private let panel: KeyPanel
    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var results: [IndexEntry] = []
    private var iconCache: [String: NSImage] = [:]
    private var keyMonitor: Any?
    private var liveSearchGeneration = 0
    private var liveSearchWorkItem: DispatchWorkItem?
    private var currentQuery = ""

    /// Reloaded from `config.json`; actions are resolved from here.
    var configuration: Configuration = .default
    var strings: Strings = Strings(language: .zh) {
        didSet { applyStrings() }
    }
    /// Called before the panel becomes visible (used to reload configuration).
    var onWillShow: (() -> Void)?

    init(index: SearchIndex, store: Store) {
        self.index = index
        self.store = store
        panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        buildContent()
        installKeyMonitor()
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    /// Modified Return never reaches the text-field delegate reliably, so handle it
    /// before the field sees the event.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible,
                  event.window === self.panel || NSApp.keyWindow === self.panel else {
                return event
            }
            // Let the input method finish composing before acting on Return/Escape.
            if let editor = self.searchField.currentEditor() as? NSTextView, editor.hasMarkedText() {
                return event
            }
            switch event.keyCode {
            case 36, 76: // Return, keypad Enter
                self.openSelected(modifiers: event.modifierFlags)
                return nil
            case 53: // Escape
                self.hide()
                return nil
            default:
                return event
            }
        }
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: - Presentation

    func show() {
        onWillShow?()
        let started = CFAbsoluteTimeGetCurrent()
        let interval = Self.signposter.beginInterval("panel-show")
        searchField.stringValue = ""
        refresh(query: "")
        positionPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        Self.signposter.endInterval("panel-show", interval)

        let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
        NSLog("EasyFind: panel shown in %.1f ms", elapsed)
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func reloadKeepingSelection() {
        let selected = tableView.selectedRow
        refresh(query: searchField.stringValue)
        if selected > 0, selected < results.count {
            selectRow(selected)
        }
    }

    private func positionPanel() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size
        let x = screen.midX - size.width / 2
        let y = screen.maxY - size.height - screen.height * 0.16
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Content

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.worksWhenModal = true
        panel.delegate = self
    }

    private func buildContent() {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = NSFont.systemFont(ofSize: 24)
        searchField.placeholderString = strings.searchPlaceholder
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(tableClicked(_:))
        tableView.focusRingType = .none
        tableView.allowsEmptySelection = true

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        effect.addSubview(searchField)
        effect.addSubview(separator)
        effect.addSubview(scrollView)
        effect.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -20),
            searchField.topAnchor.constraint(equalTo: effect.topAnchor, constant: 16),
            searchField.heightAnchor.constraint(equalToConstant: 38),

            separator.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
            separator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),

            scrollView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: effect.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: effect.centerYAnchor, constant: 20),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: effect.leadingAnchor, constant: 24)
        ])
    }

    // MARK: - Results

    private func refresh(query: String) {
        currentQuery = query
        liveSearchGeneration += 1
        let generation = liveSearchGeneration
        liveSearchWorkItem?.cancel()
        liveSearchWorkItem = nil

        results = index.search(query)
        tableView.reloadData()

        emptyLabel.isHidden = !results.isEmpty
        emptyLabel.stringValue = emptyText(for: query)

        if !results.isEmpty {
            selectRow(0)
        }
        scheduleLiveSearch(query: query, generation: generation)
    }

    /// Runs a debounced Spotlight filename search so files outside the indexed
    /// directories are still findable. Results are discarded when the query
    /// changes before they arrive.
    private func scheduleLiveSearch(query: String, generation: Int) {
        guard configuration.sync.files,
              let live = Self.liveQuery(for: query) else { return }
        let includeHidden = configuration.files.includeHidden

        let work = DispatchWorkItem { [weak self] in
            let hits = LiveFileSearch.search(query: live.text, mode: live.mode,
                                             includeHidden: includeHidden)
            DispatchQueue.main.async {
                guard let self, self.liveSearchGeneration == generation,
                      self.currentQuery == query else { return }
                self.mergeLiveResults(hits)
            }
        }
        liveSearchWorkItem = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func mergeLiveResults(_ hits: [IndexEntry]) {
        guard !hits.isEmpty else { return }
        let existing = Set(results.map(\.openTarget))
        let extra = hits.filter { !existing.contains($0.openTarget) }
        guard !extra.isEmpty else { return }

        let selected = tableView.selectedRow
        results.append(contentsOf: extra)
        tableView.reloadData()
        emptyLabel.isHidden = true
        if selected >= 0 {
            selectRow(selected)
        } else {
            selectRow(0)
        }
    }

    private static func liveQuery(for raw: String) -> (text: String, mode: LiveFileSearch.Mode)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("@") {
            let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (text, .files)
        }
        if trimmed.hasPrefix("~") {
            let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (text, .folders)
        }
        return (trimmed, .any)
    }

    private func emptyText(for query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return strings.emptyNoData }
        if trimmed == "~" { return strings.emptyNoFolders }
        if trimmed == "@" { return strings.emptyNoFiles }
        return strings.emptyNoResults
    }

    private func applyStrings() {
        searchField.placeholderString = strings.searchPlaceholder
        if !emptyLabel.isHidden {
            emptyLabel.stringValue = emptyText(for: searchField.stringValue)
        }
        tableView.reloadData()
    }

    private func selectRow(_ row: Int) {
        guard !results.isEmpty else { return }
        let clamped = min(max(row, 0), results.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: clamped), byExtendingSelection: false)
        tableView.scrollRowToVisible(clamped)
    }

    private func openSelected(modifiers: NSEvent.ModifierFlags = []) {
        let row = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
        guard row >= 0, row < results.count else { return }
        let entry = results[row]

        let modifier: ActionModifier = modifiers.contains(.option)
            ? .option
            : (modifiers.contains(.command) ? .command : .none)
        let action = configuration.actions.action(for: entry.kind, modifier: modifier)

        perform(action, for: entry)
        NSLog(
            "EasyFind: action %@ for %@ (modifiers=%lu)",
            action.rawValue,
            String(describing: entry.kind),
            modifiers.rawValue
        )
        recordOpen(for: entry)
        hide()
    }

    private func perform(_ action: OpenAction, for entry: IndexEntry) {
        switch action {
        case .open:
            openDefault(entry)
        case .copy:
            copyTarget(entry)
        case .terminal:
            switch entry.kind {
            case .folder:
                _ = openInPreferredTerminal(path: entry.openTarget)
            case .file:
                _ = openInPreferredTerminal(path: Self.parentDirectory(of: entry.openTarget))
            default:
                openDefault(entry)
            }
        case .finder:
            reveal(entry)
        }
    }

    private func openDefault(_ entry: IndexEntry) {
        switch entry.kind {
        case .app:
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: entry.openTarget),
                configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: nil
            )
        case .folder:
            NSWorkspace.shared.open(URL(fileURLWithPath: entry.openTarget))
        case .file:
            NSWorkspace.shared.open(URL(fileURLWithPath: entry.openTarget))
        default:
            if let url = URL(string: entry.openTarget) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func copyTarget(_ entry: IndexEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.openTarget, forType: .string)
    }

    private func reveal(_ entry: IndexEntry) {
        if entry.kind == .app || entry.kind == .file {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.openTarget)])
        } else {
            openDefault(entry)
        }
    }

    private func recordOpen(for entry: IndexEntry) {
        switch entry.kind {
        case .app:
            try? store.recordAppOpen(id: entry.id)
        case .folder:
            try? store.recordFolderOpen(id: entry.id)
        case .file:
            try? store.recordFileOpen(id: entry.id)
        default:
            if entry.id != 0 {
                try? store.recordOpen(id: entry.id)
            }
        }
    }

    /// Honors `terminal.application`: auto / iterm2 / terminal.
    private func openInPreferredTerminal(path: String) -> String {
        switch configuration.terminal.application {
        case "terminal":
            openInTerminal(path: path)
            return "terminal"
        case "iterm2":
            if openInITerm(path: path) {
                return "iterm2"
            }
            openInTerminal(path: path)
            return "terminal"
        default:
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil,
               openInITerm(path: path) {
                return "iterm2"
            }
            openInTerminal(path: path)
            return "terminal"
        }
    }

    private func openInITerm(path: String) -> Bool {
        let shellQuoted = Self.shellQuoted(path)
        let escaped = shellQuoted
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "iTerm2"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow
                write text ("cd \(escaped)" & (ASCII character 10))
            end tell
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return false }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            NSLog("EasyFind: iTerm2 AppleScript failed: \(errorInfo)")
            return false
        }
        return true
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func openInTerminal(path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", path]
        do {
            try process.run()
        } catch {
            NSLog("EasyFind: failed to open Terminal: \(error)")
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("result-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ResultCellView
            ?? ResultCellView(frame: .zero)
        cell.identifier = identifier

        guard row >= 0, row < results.count else { return cell }
        let entry = results[row]
        cell.titleLabel.stringValue = entry.displayName
        cell.subtitleLabel.stringValue = subtitle(for: entry)
        cell.iconView.image = icon(for: entry)
        return cell
    }

    private func icon(for entry: IndexEntry) -> NSImage? {
        if entry.kind == .app || entry.kind == .file {
            if let cached = iconCache[entry.openTarget] {
                return cached
            }
            let image = NSWorkspace.shared.icon(forFile: entry.openTarget)
            iconCache[entry.openTarget] = image
            return image
        }
        if entry.kind == .folder {
            return NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        }
        return NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    }

    private func subtitle(for entry: IndexEntry) -> String {
        if entry.isDeepLink {
            return entry.url ?? entry.host
        }
        switch entry.kind {
        case .history:
            return entry.visits > 0 ? "\(entry.host) · \(strings.visits(entry.visits))" : entry.host
        case .bookmark:
            let path = entry.url.map(Self.pathText) ?? ""
            return path.isEmpty ? entry.host : entry.host + path
        case .manual:
            return "\(entry.host) · \(strings.manualSubtitle)"
        case .app:
            return strings.appSubtitle
        case .folder:
            return entry.openTarget
        case .file:
            let parent = Self.abbreviatedPath(Self.parentDirectory(of: entry.openTarget))
            return entry.visits > 0 ? "\(parent) · \(strings.visits(entry.visits))" : parent
        }
    }

    private static func parentDirectory(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    private static func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private static func pathText(_ rawURL: String) -> String {
        guard let components = URLComponents(string: rawURL) else { return "" }
        let path = components.percentEncodedPath
        return path.removingPercentEncoding ?? path
    }

    @objc private func tableClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < results.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        openSelected(modifiers: [])
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        refresh(query: searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            selectRow(tableView.selectedRow - 1)
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            selectRow(tableView.selectedRow + 1)
            return true
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
             #selector(NSResponder.insertLineBreak(_:)):
            openSelected(modifiers: NSEvent.modifierFlags)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        default:
            return false
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}