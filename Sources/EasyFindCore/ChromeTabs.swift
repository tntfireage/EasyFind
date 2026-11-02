import AppKit
import Foundation

public struct ChromeTab: Equatable {
    public let title: String
    public let url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

public enum ChromeTabParser {
    public static func parse(_ output: String) -> [ChromeTab] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { rawLine in
            // The title may itself contain a tab; the URL never does, so split at the last one.
            let line = String(rawLine)
            guard let separator = line.lastIndex(of: "\t") else { return nil }
            let title = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let url = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, URLTools.host(of: url) != nil else { return nil }
            return ChromeTab(title: title, url: url)
        }
    }
}

public protocol ChromeRunningProviding {
    func isChromeRunning() -> Bool
}

public struct SystemChromeRunningProvider: ChromeRunningProviding {
    public init() {}

    public func isChromeRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty
    }
}

public enum ChromeTabError: Error, LocalizedError {
    case notAuthorized
    case scriptFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Automation permission to control Google Chrome was denied."
        case .scriptFailed(let message):
            return "AppleScript failed: \(message)"
        }
    }
}

public final class ChromeTabCollector {
    public typealias ScriptRunner = () throws -> String

    private let runningProvider: ChromeRunningProviding
    private let runner: ScriptRunner

    public init(
        runningProvider: ChromeRunningProviding = SystemChromeRunningProvider(),
        runner: @escaping ScriptRunner = ChromeTabCollector.runAppleScript
    ) {
        self.runningProvider = runningProvider
        self.runner = runner
    }

    public func collect() throws -> [ChromeTab] {
        guard runningProvider.isChromeRunning() else { return [] }
        let output: String
        do {
            output = try runner()
        } catch let error as ChromeTabError {
            throw error
        } catch {
            throw ChromeTabError.scriptFailed(error.localizedDescription)
        }
        var seen = Set<String>()
        return ChromeTabParser.parse(output).filter { seen.insert($0.url).inserted }
    }

    public static func runAppleScript() throws -> String {
        // Chrome's dictionary defines a `tab` class, so the bare `tab` constant
        // resolves to that class instead of the TAB character. ASCII codes are
        // unambiguous and keep the title/URL separator intact.
        let source = """
        tell application "Google Chrome"
            set output to ""
            repeat with w in windows
                repeat with t in tabs of w
                    set output to output & (title of t) & (ASCII character 9) & (URL of t) & (ASCII character 10)
                end repeat
            end repeat
            return output
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            throw ChromeTabError.scriptFailed("could not create AppleScript")
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            if code == -1743 {
                throw ChromeTabError.notAuthorized
            }
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown AppleScript error"
            throw ChromeTabError.scriptFailed(message)
        }
        let output = result.stringValue ?? ""
        NSLog("EasyFind: AppleScript returned %d chars", output.count)
        return output
    }
}