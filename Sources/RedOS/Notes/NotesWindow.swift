import AppKit
import RedOSCore
import SwiftUI

@MainActor
@Observable
final class NotesIslandModel {
    var isOpen = false
    /// Compact (timer and activity beside the camera) during the call; expanded on click and for the minutes.
    var isExpanded = false
    var notch = NotchGeometry()
}

/// The notes as a live activity in the notch: compact during the call, the live notes and the transcript on
/// click, the minutes at the end.
@MainActor
final class NotesWindowController {
    private static let compactWidth: CGFloat = 520
    private static let expandedSize = CGSize(width: 720, height: 640)

    private let taker: NoteTaker
    private let onStop: @MainActor () -> Void
    private let onCommand: @MainActor (String) -> Void
    private let model = NotesIslandModel()
    private var closing: Task<Void, Never>?
    private var shrinking: Task<Void, Never>?
    private lazy var panel: NSPanel = {
        let panel = NotesPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .notch
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let hosting = NSHostingController(rootView: NotesView(
            taker: taker, model: model, onStop: onStop, onCommand: onCommand,
            onExpand: { [weak self] in self?.setExpanded($0) },
            onClose: { [weak self] in self?.close() }
        ))
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        return panel
    }()

    /// `onCommand` runs a command as if typed ("send the minutes").
    init(taker: NoteTaker, onStop: @escaping @MainActor () -> Void, onCommand: @escaping @MainActor (String) -> Void) {
        self.taker = taker
        self.onStop = onStop
        self.onCommand = onCommand
    }

    func show() {
        closing?.cancel()
        closing = nil
        if !panel.isVisible {
            if let screen = NotchGeometry.screen { model.notch = NotchGeometry(screen: screen) }
            resize()
            panel.orderFrontRegardless()
        }
        model.isOpen = true
    }

    /// The window grows before the island and shrinks after it, so it never blocks clicks around a compact island.
    private func setExpanded(_ expanded: Bool) {
        guard expanded != model.isExpanded else { return }
        shrinking?.cancel()
        shrinking = nil
        if expanded {
            model.isExpanded = true
            resize()
            return
        }
        model.isExpanded = false
        shrinking = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            resize()
        }
    }

    private func resize() {
        let size = model.isExpanded ? Self.expandedSize : CGSize(width: Self.compactWidth, height: model.notch.height)
        panel.setContentSize(size)
        if let screen = NotchGeometry.screen { panel.pinToNotch(of: screen) }
    }

    private func close() {
        taker.dismiss()
        model.isOpen = false
        closing?.cancel()
        closing = Task { [weak self] in
            try? await Task.sleep(for: NotchMotion.closeDelay)
            guard let self, !Task.isCancelled else { return }
            closing = nil
            panel.orderOut(nil)
            setExpanded(false)
        }
    }
}

private final class NotesPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct NotesView: View {
    let taker: NoteTaker
    let model: NotesIslandModel
    let onStop: @MainActor () -> Void
    let onCommand: @MainActor (String) -> Void
    let onExpand: (Bool) -> Void
    let onClose: () -> Void

    var body: some View {
        NotchIsland(
            notch: model.notch, isOpen: model.isOpen, width: model.isExpanded ? 640 : 440,
            showsContent: model.isExpanded
        ) {
            leading
                .contentShape(.rect)
                .onTapGesture { onExpand(!model.isExpanded) }
        } trailing: {
            trailing
        } content: {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .onChange(of: taker.phase) {
            switch taker.phase {
            case .listening, .writingMinutes: onExpand(false)
            case .saved: onExpand(true)
            case .idle: onClose()
            }
        }
    }

    private var isSomeoneTalking: Bool {
        taker.hearing.values.contains { !$0.isEmpty }
    }

    @ViewBuilder
    private var leading: some View {
        HStack(spacing: 6) {
            switch taker.phase {
            case .listening:
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating)
                if let started = taker.started {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = Duration.seconds(context.date.timeIntervalSince(started))
                        Text(elapsed.formatted(.time(pattern: .hourMinuteSecond))).monospacedDigit()
                    }
                }
            case .writingMinutes:
                ProgressView().controlSize(.mini)
            case .saved, .idle:
                Image(systemName: "note.text").foregroundStyle(.orange)
                Text("Notes")
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white.opacity(0.85))
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 8) {
            if model.isExpanded {
                if taker.isListening {
                    Button("Stop", systemImage: "stop.fill", action: onStop)
                        .keyboardShortcut(".", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.mini)
                }
                Button("Close", systemImage: taker.isListening ? "chevron.up" : "xmark") {
                    if taker.isListening { onExpand(false) } else { onClose() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                if taker.isUpdatingNotes {
                    Image(systemName: "pencil.line")
                        .foregroundStyle(.orange)
                        .symbolEffect(.pulse, options: .repeating)
                }
                LevelBars(level: isSomeoneTalking ? nil : 0.08)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .contentShape(.rect)
        .onTapGesture { if !model.isExpanded { onExpand(true) } }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let warning = taker.warning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            switch taker.phase {
            case .idle:
                EmptyView()
            case .listening:
                live
            case .writingMinutes:
                ProgressView("Writing the minutes…").frame(maxWidth: .infinity, minHeight: 80)
            case .saved(let meeting):
                MinutesView(meeting: meeting).frame(maxHeight: 420)
                HStack {
                    Button("Email to Participants", systemImage: "envelope") {
                        onCommand(String(localized: "send the minutes"))
                    }
                    Button("Reminders for Action Items", systemImage: "checklist") {
                        onCommand(String(localized: "create reminders for the action items"))
                    }
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var live: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Let the participants know that you are taking notes.").font(.caption).foregroundStyle(.secondary)
            GroupBox {
                ScrollView {
                    if taker.notes.isEmpty {
                        Text("Notes appear after about a minute of talk.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        MarkdownText(markdown: taker.notes).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } label: {
                HStack {
                    Text("Live notes")
                    if taker.isUpdatingNotes { ProgressView().controlSize(.mini) }
                }
            }
            .frame(height: 230)
            GroupBox("Transcript") {
                TranscriptView(lines: taker.lines, hearing: taker.hearing)
            }
            .frame(height: 190)
        }
    }
}

private struct TranscriptView: View {
    let lines: [MeetingLine]
    let hearing: [MeetingLine.Speaker: String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.suffix(300).enumerated()), id: \.offset) { _, line in
                        row(line.speaker, line.text, final: true)
                    }
                    ForEach([MeetingLine.Speaker.others, .user], id: \.self) { speaker in
                        if let text = hearing[speaker], !text.isEmpty { row(speaker, text, final: false) }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: lines.count) { proxy.scrollTo("end") }
            .onChange(of: hearing) { proxy.scrollTo("end") }
        }
    }

    private func row(_ speaker: MeetingLine.Speaker, _ text: String, final: Bool) -> some View {
        (Text(verbatim: speaker.name + ": ").bold().foregroundStyle(speaker == .user ? .blue : .orange)
            + Text(verbatim: text).foregroundStyle(final ? .primary : .secondary))
            .font(.callout)
            .textSelection(.enabled)
    }
}

struct MinutesView: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                MarkdownText(markdown: meeting.minutes).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text(meeting.start.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                Spacer()
                Button("Copy with Transcript") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(meeting.markdown, forType: .string)
                }
            }
            .font(.callout)
        }
    }
}

/// Headings, list items and inline styles of the Markdown the models write.
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { line($1) }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func line(_ text: String) -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let indent = CGFloat(text.prefix { $0 == " " }.count / 2) * 14
        Group {
            if trimmed.hasPrefix("# ") {
                inline(String(trimmed.dropFirst(2))).font(.title3.bold())
            } else if trimmed.hasPrefix("##"), trimmed.drop(while: { $0 == "#" }).hasPrefix(" ") {
                inline(String(trimmed.drop { $0 == "#" }.dropFirst())).font(.headline).padding(.top, 4)
            } else if trimmed.isEmpty {
                Color.clear.frame(height: 2)
            } else if ["---", "***", "___"].contains(trimmed) {
                Divider()
            } else if let item = Self.listItem(trimmed) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "•")
                    inline(item)
                }
                .padding(.leading, indent)
            } else {
                inline(trimmed).padding(.leading, indent)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private static func listItem(_ line: String) -> String? {
        ["- ", "* ", "+ "].first { line.hasPrefix($0) }.map { _ in String(line.dropFirst(2)) }
    }

    /// The text without Markdown marks, for the voice.
    static func plain(_ markdown: String) -> String {
        markdown.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var text = line.trimmingCharacters(in: .whitespaces)
            if ["---", "***", "___"].contains(text) { return "" }
            text = String(text.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            text = listItem(text) ?? text
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            return (try? AttributedString(markdown: text, options: options)).map { String($0.characters) } ?? text
        }
        .joined(separator: "\n")
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        return Text(attributed)
    }
}
