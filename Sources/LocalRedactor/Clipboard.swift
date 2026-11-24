import AppKit

@MainActor
struct Clipboard {
    let pasteboard: NSPasteboard

    func read() -> String? { pasteboard.string(forType: .string) }

    func write(_ text: String) -> Bool {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        return pasteboard.setString(text, forType: .string)
    }
}
