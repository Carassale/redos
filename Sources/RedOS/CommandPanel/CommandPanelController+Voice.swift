import AppKit
import RedOSCore

// MARK: - Voice and conversation

extension CommandPanelController {
    /// Push-to-talk pressed or wake word heard: listen and show the live transcript. `followUp` listens
    /// quietly after a spoken reply, cancelling RedOS's own voice, until the user talks or stays silent.
    func startListening(handsFree: Bool = false, followUp: Bool = false) {
        if model.isFollowingUp, !followUp {
            // Push-to-talk during a follow-up: keep the microphone that is already open.
            endFollowUp(keepsMicrophone: true)
            speaker.stop()
            model.state = .listening
            return
        }
        guard listening == nil, model.state != .working else { return }
        guard SystemPermissionChecker().status(of: .microphone) == .granted else {
            guard !followUp else { return }
            show()
            model.state = .message(ActionError.permissionMissing(.microphone).localizedDescription, isError: true)
            return
        }
        pendingConfirmation = shownConfirmation
        model.isFollowingUp = followUp
        if !followUp {
            speaker.stop()
            show()
            model.text = ""
            model.state = .listening
        }
        listener.onTranscript = { [weak self] text in self?.heard(text) }
        listener.onDownload = { [weak self] in
            self?.model.state = .message(String(localized: "Downloading the speech model…"), isError: false)
        }
        openMicrophone(followUp: followUp)
        guard handsFree || followUp else { return }
        if handsFree { NSSound(named: "Tink")?.play() }
        endpoint.start(
            transcript: { [listener] in listener.transcript },
            isSpeaking: { [speaker] in speaker.isSpeaking },
            onPause: { [weak self] heard in
                guard let self else { return }
                if heard || !model.isFollowingUp { stopListening() } else { endFollowUp() }
            }
        )
    }

    private var shownConfirmation: CommandPanelModel.State? {
        switch model.state {
        case .confirming, .confirmingPlan: model.state
        default: nil
        }
    }

    private func openMicrophone(followUp: Bool) {
        listening = Task { [weak self, listener, voice, model] in
            do {
                try await listener.start(locale: voice.locale, cancelsEcho: followUp)
                if !followUp, case .message = model.state { model.state = .listening }
            } catch {
                if followUp {
                    self?.endFollowUp()
                } else {
                    model.state = .message(error.localizedDescription, isError: true)
                }
            }
        }
    }

    /// Words during a follow-up interrupt RedOS and become the next request.
    private func heard(_ text: String) {
        if model.isFollowingUp, model.state != .listening {
            guard !text.isEmpty else { return }
            speaker.stop()
            model.state = .listening
        }
        model.text = text
    }

    /// Push-to-talk released or pause after the wake word: the transcript is submitted like a typed command.
    func stopListening() {
        guard let listening else { return }
        endpoint.cancel()
        model.isFollowingUp = false
        self.listening = nil
        start { [self] in
            await listening.value
            guard model.state == .listening else { return }
            // Dictation ends sentences with a period: "apri Safari." must still match the app name.
            var text = await listener.stop()
            if text.hasSuffix(".") { text.removeLast() }
            model.text = text
            guard !text.isEmpty else {
                model.state = .message(String(localized: "I didn't hear anything."), isError: true)
                return
            }
            isVoiceCommand = true
            if let pending = pendingConfirmation, let confirmed = ConfirmationReply.parse(text) {
                pendingConfirmation = nil
                model.state = pending
                if confirmed {
                    submit()
                } else {
                    cancel()
                }
                return
            }
            if ClosingReply.matches(text) {
                close(pending: pendingConfirmation)
                return
            }
            pendingConfirmation = nil
            model.state = .working
            await resolve(text)
        }
    }

    /// "Grazie", "basta così": the conversation is over (a pending confirmation is cancelled).
    private func close(pending: CommandPanelModel.State?) {
        pendingConfirmation = nil
        model.text = ""
        if let pending {
            model.state = pending
            cancel()
        } else {
            model.state = .idle
            hide()
        }
    }

    /// After a spoken reply the microphone stays open, so the user can go on without the wake word.
    func followUpIfUseful() {
        guard isVoiceCommand, voice.keepsListening, panel.isVisible else { return }
        switch model.state {
        case .answer, .message, .confirming, .confirmingPlan: startListening(followUp: true)
        case .idle, .listening, .working: break
        }
    }

    /// Silence after a reply, a typed command or Esc: close the microphone and keep what is on screen.
    func endFollowUp(keepsMicrophone: Bool = false) {
        guard model.isFollowingUp else { return }
        model.isFollowingUp = false
        endpoint.cancel()
        guard !keepsMicrophone else { return }
        pendingConfirmation = nil
        let stopping = listening
        listening?.cancel()
        listening = nil
        Task { [listener] in
            await stopping?.value
            await listener.cancel()
        }
    }

    /// The request and what came of it, so the next one can refer to it ("e domani?", "chiudila").
    func rememberTurn(silentBefore: Int) async {
        guard let request = currentRequest, let conversation = engine.conversation else { return }
        let reply: String
        switch model.state {
        case .answer(let answer): reply = answer.diagram.map { "Drew the diagram \"\($0.title)\"" } ?? answer.text
        case .message(let text, _): reply = text
        case .idle where completedSilently > silentBefore: reply = "Done: \(actionSummary ?? "")"
        case .idle, .listening, .working, .confirming, .confirmingPlan: return
        }
        currentRequest = nil
        await conversation.record(request, reply: reply)
    }
}
