import AppKit
import RedOSCore
import SwiftUI

/// The floating window next to the call: live notes on top, the transcript below, the minutes at the end.
@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
    private let taker: NoteTaker
    private let onStop: @MainActor () -> Void
    private let onCommand: @MainActor (String) -> Void
    private var panel: NSPanel?

    /// `onCommand` runs a command as if typed ("send the minutes").
    init(taker: NoteTaker, onStop: @escaping @MainActor () -> Void, onCommand: @escaping @MainActor (String) -> Void) {
        self.taker = taker
        self.onStop = onStop
        self.onCommand = onCommand
    }

    func show() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 640),
                styleMask: [.titled, .closable, .resizable, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.title = String(localized: "Notes")
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            let hosting = NSHostingController(rootView: NotesView(taker: taker, onStop: onStop, onCommand: onCommand))
            hosting.sizingOptions = []
            panel.contentViewController = hosting
            panel.setContentSize(NSSize(width: 420, height: 640))
            if let screen = NSScreen.main?.visibleFrame {
                panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 440, y: screen.maxY - 20))
            }
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }

    /// Closing the window while listening ends the notes, so nothing keeps listening unseen.
    func windowWillClose(_ notification: Notification) {
        if taker.isListening {
            onStop()
        } else {
            taker.dismiss()
        }
    }
}

private struct NotesView: View {
    let taker: NoteTaker
    let onStop: @MainActor () -> Void
    let onCommand: @MainActor (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let warning = taker.warning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            switch taker.phase {
            case .idle:
                Text("Say “prendi appunti” or use the menu to start.").foregroundStyle(.secondary)
                Spacer()
            case .listening:
                live
            case .writingMinutes:
                ProgressView("Writing the minutes…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .saved(let meeting):
                MinutesView(meeting: meeting)
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
        .padding(14)
        .frame(minWidth: 320, minHeight: 360)
    }

    private var header: some View {
        HStack {
            if taker.isListening, let started = taker.started {
                Image(systemName: "record.circle").foregroundStyle(.red).symbolEffect(.pulse, options: .repeating)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = Duration.seconds(context.date.timeIntervalSince(started))
                    Text(elapsed.formatted(.time(pattern: .hourMinuteSecond))).monospacedDigit()
                }
                Spacer()
                Button("Stop", action: onStop).keyboardShortcut(".", modifiers: .command)
            } else {
                Image(systemName: "note.text")
                Text("Notes").font(.headline)
                Spacer()
            }
        }
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
            .frame(maxHeight: .infinity)
            GroupBox("Transcript") {
                TranscriptView(lines: taker.lines, hearing: taker.hearing)
            }
            .frame(maxHeight: .infinity)
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
