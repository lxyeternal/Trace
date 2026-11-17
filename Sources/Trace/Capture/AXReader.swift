import AppKit
import ApplicationServices

/// Reads the focused window of another app through the Accessibility API.
/// Requires the user to grant Trace access in System Settings.
enum AXReader {
    struct WindowInfo {
        var title = ""
        var path: String?
        var url: String?
    }

    private static let configureTimeout: Void = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }()

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to the Accessibility pane.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Reads the focused window. `previous` is the last result for the same
    /// app: while the title is unchanged its URL is reused, so the costly
    /// search through a browser's page runs only when the page changes.
    static func focusedWindow(pid: pid_t, isBrowser: Bool, telegramChat: Bool = false, previous: WindowInfo? = nil) -> WindowInfo {
        var info = WindowInfo()
        // Set on the system-wide element so the limit covers every element of
        // every app; set on an app element it would not reach its windows.
        _ = configureTimeout
        let app = AXUIElementCreateApplication(pid)

        guard let window = element(app, kAXFocusedWindowAttribute) else { return info }
        info.title = (telegramChat ? telegramChatTitle(in: window) : nil) ?? string(window, kAXTitleAttribute) ?? ""

        // Document-based apps expose the open file; Safari exposes the page URL here.
        if let document = string(window, kAXDocumentAttribute), let parsed = URL(string: document) {
            if parsed.isFileURL {
                info.path = parsed.path
            } else if parsed.scheme?.hasPrefix("http") == true {
                info.url = sanitize(parsed)
            }
        }
        if isBrowser, info.url == nil {
            if let previous, previous.url != nil, previous.title == info.title, !info.title.isEmpty {
                info.url = previous.url
            } else if let found = webAreaURL(in: window) {
                info.url = sanitize(found)
            }
        }
        return info
    }

    /// Keeps scheme, host and path. Query strings and fragments are dropped
    /// because they often carry tokens and search terms.
    private static func sanitize(_ url: URL) -> String? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.string
    }

    /// Chromium and Firefox put the page URL on the web content element, so
    /// look for it breadth-first with a hard cap on the work done.
    private static func webAreaURL(in window: AXUIElement) -> URL? {
        var queue = [window]
        var visited = 0
        // A page that is still loading can answer slowly or not at all; never
        // let one read hold up the next samples.
        let deadline = Date().addingTimeInterval(0.6)
        while !queue.isEmpty, visited < 400, Date() < deadline {
            let current = queue.removeFirst()
            visited += 1
            if string(current, kAXRoleAttribute) == "AXWebArea",
               let value = copy(current, "AXURL"), let url = value as? URL,
               url.scheme?.hasPrefix("http") == true {
                return url
            }
            if let children = copy(current, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return nil
    }

    // The native Telegram client exposes its chat header as an immediate
    // button with the chat name as its description and status as its value.
    static func telegramChatTitle(in window: AXUIElement) -> String? {
        guard let origin = position(of: window),
              let children = copy(window, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        let names = children.compactMap { child -> String? in
            guard string(child, kAXRoleAttribute) == kAXButtonRole,
                  let point = position(of: child), (0...80).contains(point.y - origin.y),
                  let status = string(child, kAXValueAttribute), !status.isEmpty,
                  let name = string(child, kAXDescriptionAttribute), !name.isEmpty,
                  !name.contains(where: { $0.isNewline }) else { return nil }
            return name
        }
        return names.count == 1 ? names[0] : nil
    }

    private static func position(of element: AXUIElement) -> CGPoint? {
        guard let raw = copy(element, kAXPositionAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(raw as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return status == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
