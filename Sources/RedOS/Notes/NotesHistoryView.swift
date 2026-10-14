import AppKit
import RedOSCore
import SwiftUI

/// Saved minutes, newest first.
struct NotesHistoryView: View {
    let store: MeetingStore
    @State private var meetings: [Meeting] = []
    @State private var opened: Meeting?

    var body: some View {
        Form {
            Section {
                if meetings.isEmpty {
                    Text("Say “prendi appunti” during a call: the minutes appear here.").foregroundStyle(.secondary)
                }
                ForEach(meetings) { meeting in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(verbatim: meeting.title)
                            Text(verbatim: details(meeting)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open") { opened = meeting }
                        Button("Delete", role: .destructive) {
                            Task {
                                try? await store.delete(meeting.id)
                                await reload()
                            }
                        }
                    }
                    .controlSize(.small)
                }
            } footer: {
                Text("Transcripts stay on this Mac; the audio is never saved.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
        .sheet(item: $opened) { meeting in
            VStack(alignment: .leading) {
                MinutesView(meeting: meeting)
                HStack {
                    Spacer()
                    Button("Close") { opened = nil }.keyboardShortcut(.cancelAction)
                }
            }
            .padding()
            .frame(width: 560, height: 520)
        }
    }

    private func details(_ meeting: Meeting) -> String {
        let minutes = Int(meeting.end.timeIntervalSince(meeting.start) / 60)
        return meeting.start.formatted(date: .abbreviated, time: .shortened) + " · \(max(minutes, 1)) min · "
            + String(localized: "\(meeting.transcript.count) lines")
    }

    private func reload() async {
        meetings = await store.all()
    }
}
