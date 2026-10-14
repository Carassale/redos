import EventKit
import Foundation
import Observation
import RedOSCore
import RedOSVoice

/// Takes notes of a call: transcribes the user's voice (microphone) and the call (system audio) on this Mac,
/// keeps live notes with System Two and saves the minutes and the transcript. The audio is never stored.
@MainActor
@Observable
final class NoteTaker {
    enum Phase: Equatable {
        case idle
        case listening
        case writingMinutes
        case saved(Meeting)
    }

    private(set) var phase = Phase.idle
    private(set) var lines: [MeetingLine] = []
    /// The sentence each side is saying right now.
    private(set) var hearing: [MeetingLine.Speaker: String] = [:]
    private(set) var notes = ""
    private(set) var isUpdatingNotes = false
    private(set) var warning: String?
    private(set) var started: Date?

    @ObservationIgnored var client: (any ChatCompleting)?
    @ObservationIgnored var locale = Locale(identifier: "it_IT")
    @ObservationIgnored let store: MeetingStore
    @ObservationIgnored private let microphone = MicrophoneCapture()
    @ObservationIgnored private let systemAudio = SystemAudioCapture()
    @ObservationIgnored private let mine = StreamTranscriber()
    @ObservationIgnored private let theirs = StreamTranscriber()
    /// Lines already in the live notes.
    @ObservationIgnored private var summarized = 0
    @ObservationIgnored private var lastUpdate = ContinuousClock.now

    init(store: MeetingStore = MeetingStore()) {
        self.store = store
    }

    var isListening: Bool { phase == .listening }

    func start() async throws {
        guard phase != .listening, phase != .writingMinutes else { return }
        (lines, hearing, notes, warning, summarized, lastUpdate) = ([], [:], "", nil, 0, .now)
        started = .now
        phase = .listening
        connect(mine, as: .user)
        connect(theirs, as: .others)
        do {
            // Echo cancellation keeps the other people's voices (from the speakers) out of the microphone.
            try microphone.start(cancelsEcho: true, sink: try await mine.start(locale: locale))
        } catch {
            await mine.stop()
            phase = .idle
            throw error
        }
        do {
            try await systemAudio.start(sink: try await theirs.start(locale: locale))
        } catch {
            await theirs.stop()
            warning = String(
                localized: "Only your voice is transcribed: allow Screen Recording for RedOS to hear the call."
            )
        }
    }

    /// Writes and saves the minutes; nil when nothing was said.
    func stop() async -> Meeting? {
        guard phase == .listening, let started else { return nil }
        phase = .writingMinutes
        microphone.stop()
        await systemAudio.stop()
        await mine.stop()
        await theirs.stop()
        hearing = [:]
        guard !lines.isEmpty else {
            phase = .idle
            return nil
        }
        let event = Self.calendarTitle(at: started)
        var title = event ?? String(localized: "Call")
        var minutes = "# \(title)\n\n\(notes)"
        if let client {
            do {
                (title, minutes) = try await MeetingNotes(client: client).minutes(of: lines, notes: notes, title: event)
            } catch {
                warning = error.localizedDescription
            }
        }
        let meeting = Meeting(title: title, start: started, end: .now, minutes: minutes, transcript: lines)
        do {
            try await store.save(meeting)
        } catch {
            warning = error.localizedDescription
        }
        phase = .saved(meeting)
        return meeting
    }

    func dismiss() {
        guard phase != .listening, phase != .writingMinutes else { return }
        phase = .idle
    }

    private func connect(_ transcriber: StreamTranscriber, as speaker: MeetingLine.Speaker) {
        transcriber.onVolatile = { [weak self] text in self?.hearing[speaker] = text }
        transcriber.onFinal = { [weak self] text in
            guard let self else { return }
            lines.append(MeetingLine(speaker: speaker, text: text))
            updateNotesIfDue()
        }
    }

    private func updateNotesIfDue() {
        let pending = Array(lines[summarized...])
        let words = pending.reduce(0) { $0 + $1.text.split(separator: " ").count }
        guard let client, !isUpdatingNotes, isListening,
              MeetingNotes.isDue(newWords: words, since: ContinuousClock.now - lastUpdate)
        else { return }
        isUpdatingNotes = true
        Task {
            if let updated = try? await MeetingNotes(client: client).update(notes: notes, with: pending) {
                notes = updated
                summarized += pending.count
            }
            lastUpdate = .now
            isUpdatingNotes = false
        }
    }

    /// The calendar event going on when the call started, if RedOS may read the calendar (never asks).
    private static func calendarTitle(at date: Date) -> String? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let store = EKEventStore()
        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-3600), end: date.addingTimeInterval(900), calendars: nil
        )
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate <= date.addingTimeInterval(900) && $0.endDate >= date }
            .min { abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date)) }?
            .title
    }
}
