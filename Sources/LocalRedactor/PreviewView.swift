import AppKit
import RedactionCore
import SwiftUI

struct PreviewView: View {
    @ObservedObject var model: PreviewModel
    let reload: () -> Void
    let copy: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if model.intent == .redact {
                HStack {
                    Picker("处理模式", selection: $model.mode) {
                        ForEach(RedactionMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 208)

                    Spacer()
                    Toggle("附带 AI 提问", isOn: $model.includePrompt)
                    Menu("隐私选项", systemImage: "slider.horizontal.3") {
                        Toggle("遮盖邮箱地址（可还原）", isOn: $model.options.emails)
                        Toggle("遮盖 URL 主机名（可还原）", isOn: $model.options.urlHosts)
                        if model.mode == .oracle {
                            Toggle("永久遮盖 SQL 字符串内容", isOn: $model.options.sqlStrings)
                        }
                    }
                    .fixedSize()
                    Button("重新读取剪贴板", systemImage: "arrow.clockwise", action: reload)
                }
            } else {
                HStack {
                    Text("从剪贴板读取 AI 回复").foregroundStyle(.secondary)
                    Spacer()
                    Button("重新读取剪贴板", systemImage: "arrow.clockwise", action: reload)
                }
                .font(.callout)
            }
            HStack(alignment: .top, spacing: 14) {
                pane(model.intent == .redact ? "原文" : "AI 回复", text: model.source, marks: inputMarks, selectable: true) {
                    if model.intent == .redact {
                        HStack(spacing: 6) {
                            Button("遮盖此处") { model.markSelection() }
                                .disabled(!model.canMark)
                            Button("遮盖所有同文") { model.markSelection(everyOccurrence: true) }
                                .disabled(!model.canMark)
                                .help("遮盖与选区完全相同的文本")
                            if !model.manual.isEmpty {
                                Button("撤销遮盖", action: model.undoMark).disabled(model.busy)
                            }
                        }
                        .controlSize(.small)
                    }
                }
                pane(outputTitle, text: model.output, marks: outputMarks, selectable: false) {
                    if model.busy {
                        ProgressView().controlSize(.small).accessibilityLabel("正在生成预览")
                    }
                }
            }
            feedback
            Divider()
            HStack {
                Text(model.intent == .redact ? "原文和映射仅在本机内存处理" : "还原结果含原始信息")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: dismiss).keyboardShortcut(.cancelAction)
                Button(copyTitle, action: copy)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canCopy)
            }
        }
        .padding(22)
        .frame(minWidth: 790, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var outputTitle: String {
        if model.intent == .restore { return "还原预览" }
        return model.includePrompt ? "AI 提问预览" : "脱敏预览"
    }

    private var copyTitle: String {
        if model.intent == .restore { return "复制还原文本" }
        return model.includePrompt ? "复制 AI 提问" : "复制脱敏文本"
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: model.intent == .redact ? "checkmark.shield.fill" : "arrow.uturn.backward")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 43, height: 43)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.intent == .redact ? "脱敏剪贴板" : "还原 AI 回复")
                    .font(.title2.weight(.semibold))
                Text(model.intent == .redact
                    ? "检查高亮和遗漏，再复制给 AI。"
                    : "检查还原结果，再复制到你的工作环境。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pane<T: View>(
        _ title: String, text: String, marks: [TextMark], selectable: Bool,
        @ViewBuilder action: () -> T
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 3)
                action()
            }
            .frame(height: 24)
            CodeView(text: text, marks: marks, accessibleTitle: title) { range in
                if selectable, model.intent == .redact, model.selection != range {
                    model.selection = range
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.quaternary, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inputMarks: [TextMark] {
        if let range = model.issue?.range { return [TextMark(range: range, color: .systemRed)] }
        return model.preview?.highlights.map { TextMark(range: $0.source, color: $0.category.color) } ?? []
    }

    private var outputMarks: [TextMark] {
        let offset = model.outputOffset
        return model.preview?.highlights.map {
            let shifted = NSRange(location: offset + $0.output.location, length: $0.output.length)
            return TextMark(range: shifted, color: $0.category.color)
        } ?? []
    }

    @ViewBuilder
    private var feedback: some View {
        if let issue = model.issue {
            Label(issue.message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                .font(.callout)
        } else if let notice = model.notice {
            Label(notice, systemImage: "info.circle").foregroundStyle(.secondary)
                .font(.callout)
        } else if let restoration = model.restoration {
            VStack(alignment: .leading, spacing: 5) {
                Label("已还原 \(restoration.replaced) 处", systemImage: "checkmark.circle")
                    .font(.callout.weight(.medium))
                if restoration.unknown > 0 || restoration.absent > 0 {
                    Text("无法识别 \(restoration.unknown) 处，本次未出现 \(restoration.absent) 个代号。请核对 AI 是否修改或移除了占位符。")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        } else if model.intent == .redact {
            VStack(alignment: .leading, spacing: 6) {
                if let preview = model.preview, preview.highlights.isEmpty {
                    Label("未发现可自动替换的内容。可以选中原文补遮盖。", systemImage: "info.circle")
                        .font(.callout)
                } else if let preview = model.preview {
                    let counts = Dictionary(grouping: preview.highlights, by: \.category).mapValues(\.count)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 9) {
                            ForEach(RedactionCore.Category.allCases.filter { counts[$0] != nil }) { category in
                                let color = Color(nsColor: category.color)
                                HStack(spacing: 4) {
                                    Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
                                    Text("\(category.label) \(counts[category, default: 0])")
                                }
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 5))
                            }
                        }
                        Text("将替换 \(preview.highlights.count) 处").font(.callout)
                    }
                }
                Text(model.mode == .oracle
                    ? "覆盖常见 SELECT 的对象和引用。请复核列名、普通字面量和未标记的内容。"
                    : "覆盖常见 IP 和凭据格式。请复核未标记的主机名、内部标识和其他凭据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension RedactionCore.Category {
    var color: NSColor {
        switch self {
        case .schema, .table: .systemBlue
        case .alias, .cte: .systemPurple
        case .ip, .host: .systemTeal
        case .email: .systemIndigo
        case .secret: .systemRed
        case .literal: .systemPink
        case .comment: .systemGray
        case .manual: .systemOrange
        }
    }
}

private struct TextMark: Equatable {
    let range: NSRange
    let color: NSColor
}

private struct CodeView: NSViewRepresentable {
    let text: String
    let marks: [TextMark]
    let accessibleTitle: String
    let selection: (NSRange) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(selection) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroller = NSScrollView()
        scroller.hasVerticalScroller = true
        scroller.autohidesScrollers = true
        scroller.borderType = .noBorder

        let editor = PreviewTextView()
        editor.delegate = context.coordinator
        editor.isEditable = false
        editor.isSelectable = true
        editor.isRichText = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 11, height: 10)
        editor.setAccessibilityLabel(accessibleTitle)
        scroller.documentView = editor
        return scroller
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let editor = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.selection = selection
        let newText = coordinator.text != text
        guard newText || coordinator.marks != marks else { return }
        let oldSelection = editor.selectedRange()
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.textColor,
            ]
        )
        for mark in marks where NSMaxRange(mark.range) <= attributed.length {
            attributed.addAttribute(.backgroundColor, value: mark.color.withAlphaComponent(0.23), range: mark.range)
        }
        coordinator.isUpdating = true
        editor.textStorage?.setAttributedString(attributed)
        if !newText, NSMaxRange(oldSelection) <= attributed.length { editor.setSelectedRange(oldSelection) }
        coordinator.isUpdating = false
        coordinator.text = text
        coordinator.marks = marks
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: String?
        var marks: [TextMark] = []
        var isUpdating = false
        var selection: (NSRange) -> Void

        init(_ selection: @escaping (NSRange) -> Void) { self.selection = selection }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating, let view = notification.object as? NSTextView else { return }
            selection(view.selectedRange())
        }
    }
}

private final class PreviewTextView: NSTextView {
    // All clipboard writes pass through the confirmed, device-only action.
    override func copy(_ sender: Any?) {}
}
