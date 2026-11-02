import AppKit
import EasyFindCore

final class ManualEntryController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let urlField = NSTextField()
    private let aliasField = NSTextField()
    private let errorLabel = NSTextField(labelWithString: "")
    private let strings: Strings
    private let onSave: (String, String?) -> Void

    var onClose: (() -> Void)?

    init(strings: Strings, onSave: @escaping (String, String?) -> Void) {
        self.strings = strings
        self.onSave = onSave
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = strings.addAddressTitle
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildContent()
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(urlField)
    }

    private func buildContent() {
        let content = NSView()
        window.contentView = content

        let urlLabel = NSTextField(labelWithString: strings.urlLabel)
        urlLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)

        let aliasLabel = NSTextField(labelWithString: strings.aliasLabel)
        aliasLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)

        urlField.placeholderString = "https://example.com"
        aliasField.placeholderString = strings.aliasPlaceholder

        for field in [urlField, aliasField] {
            field.font = NSFont.systemFont(ofSize: 13)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }

        errorLabel.font = NSFont.systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        let cancelButton = NSButton(title: strings.cancelButton, target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        let saveButton = NSButton(title: strings.saveButton, target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let stack = NSStackView(views: [urlLabel, urlField, aliasLabel, aliasField, errorLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18)
        ])
    }

    @objc private func save() {
        guard let normalized = URLTools.normalizedURLString(urlField.stringValue) else {
            errorLabel.stringValue = strings.invalidURL
            errorLabel.isHidden = false
            NSSound.beep()
            window.makeFirstResponder(urlField)
            return
        }
        let alias = aliasField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(normalized, alias.isEmpty ? nil : alias)
        window.close()
    }

    @objc private func cancel() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}