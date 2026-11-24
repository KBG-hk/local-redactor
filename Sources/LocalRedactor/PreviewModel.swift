import Combine
import Foundation
import RedactionCore

@MainActor
final class PreviewModel: ObservableObject {
    enum Intent: Equatable { case redact, restore }

    struct ManualMark: Sendable {
        let range: NSRange
        let everyOccurrence: Bool
    }

    let intent: Intent
    private(set) var mapID: String?
    private var nonce = ""
    private var job: Task<Void, Never>?

    @Published private(set) var source = ""
    @Published private(set) var preview: Preview?
    @Published private(set) var restoration: RestorePreview?
    @Published private(set) var issue: RedactionError?
    @Published private(set) var notice: String?
    @Published private(set) var manual: [ManualMark] = []
    @Published private(set) var busy = false
    @Published var includePrompt = false
    @Published var options = RedactionOptions() {
        didSet { if oldValue != options { analyze() } }
    }
    @Published var selection = NSRange(location: 0, length: 0)
    @Published var mode: RedactionMode = .oracle {
        didSet { if oldValue != mode { analyze() } }
    }

    init(intent: Intent) { self.intent = intent }

    var output: String {
        if let preview { return promptPrefix + preview.text }
        return restoration?.text ?? ""
    }

    var outputOffset: Int { promptPrefix.utf16.count }

    private var promptPrefix: String {
        guard intent == .redact, includePrompt else { return "" }
        switch mode {
        case .oracle:
            return "请分析以下 Oracle SQL 的性能，说明优先检查的执行计划环节，并在保持语义的前提下提出改写建议。请保留脱敏占位符和绑定变量。\n\nOracle SQL\n"
        case .log:
            return "请根据以下日志定位问题。指出关键错误、可能原因及验证顺序，区分已知事实与推测。请保留脱敏占位符。\n\n日志\n"
        }
    }

    var canCopy: Bool {
        !busy && issue == nil && notice == nil
            && (preview.map { !$0.highlights.isEmpty && $0.text != source } ?? false
                || (restoration?.replaced ?? 0) > 0)
    }

    var canMark: Bool {
        !busy && preview != nil && Redactor.canMark(selection, in: source)
    }

    func load(_ text: String?, restoreMap: RestoreMap? = nil) {
        reset()
        if intent == .restore, restoreMap == nil {
            notice = "本次还原映射已经过期或已清除。"
            return
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notice = "未读取到纯文本。请先复制文本，并检查系统是否允许读取剪贴板。"
            return
        }
        guard text.utf8.count <= Redactor.maxInputBytes else {
            notice = "文本超过 256 KiB。请分段复制。"
            return
        }

        source = text
        if intent == .restore, let restoreMap {
            mapID = restoreMap.id
            restore(restoreMap)
        } else {
            nonce = Redactor.makeNonce(for: text)
            analyze()
        }
    }

    func markSelection(everyOccurrence: Bool = false) {
        guard canMark else { return }
        manual.append(ManualMark(range: selection, everyOccurrence: everyOccurrence))
        selection = NSRange(location: 0, length: 0)
        analyze()
    }

    func undoMark() {
        guard !busy, !manual.isEmpty else { return }
        manual.removeLast()
        analyze()
    }

    func showNotice(_ message: String) { notice = message }

    func invalidateRestore() {
        guard intent == .restore else { return }
        reset()
        notice = "本次还原映射已经过期或已清除。"
    }

    func reset() {
        job?.cancel()
        job = nil
        busy = false
        preview = nil
        restoration = nil
        issue = nil
        notice = nil
        source = ""
        nonce = ""
        selection = NSRange(location: 0, length: 0)
        manual = []
        mapID = nil
    }

    private func analyze() {
        guard intent == .redact, !source.isEmpty else { return }
        let text = source
        let mode = mode
        let options = options
        let marks = manual
        let nonce = nonce
        start {
            let ranges = marks.flatMap { mark in
                mark.everyOccurrence ? Redactor.matchingRanges(for: mark.range, in: text) : [mark.range]
            }
            return .redact(try Redactor.prepare(text, mode: mode, options: options, manual: ranges, nonce: nonce))
        }
    }

    private func restore(_ map: RestoreMap) {
        let text = source
        start { .restore(try Redactor.restore(text, with: map)) }
    }

    private enum Outcome: Sendable {
        case redact(Preview), restore(RestorePreview), failed(RedactionError)
    }

    private func start(_ operation: @escaping @Sendable () throws -> Outcome) {
        job?.cancel()
        issue = nil
        notice = nil
        preview = nil
        restoration = nil
        busy = true
        job = Task { [weak self] in
            let work: Task<Outcome, Never> = Task.detached(priority: .userInitiated) {
                do {
                    return try operation()
                } catch let error as RedactionError {
                    return .failed(error)
                } catch {
                    return .failed(RedactionErrorForDisplay.processingFailed)
                }
            }
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard let self, !Task.isCancelled else { return }
            busy = false
            job = nil
            switch result {
            case .redact(let value): preview = value
            case .restore(let value): restoration = value
            case .failed(let value): issue = value
            }
        }
    }
}

private enum RedactionErrorForDisplay {
    static let processingFailed = RedactionError("处理失败。请重新载入文本。")
}
