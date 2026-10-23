import AppKit
import RedOSCore

// MARK: - Running work, and corrections said meanwhile

extension CommandPanelController {
    /// Hides the panel and shows the HUD while the work drives the Mac; outputs (screen text, command
    /// results, the agent's summary) come back in the panel.
    func run(
        _ title: String, _ work: (_ onStep: @escaping StepHandler) async -> Result<String?, ActionError>
    ) async {
        model.state = .working
        hide(animated: false)
        hud.show(title)
        isDrivingMac = true
        beginCorrections(task: title)
        // Give focus back to the previous app before posting keyboard or mouse events.
        try? await Task.sleep(for: .milliseconds(150))
        let speech = speaksAnswers ? StreamedSpeech(speaker: speaker, locale: voice.locale) : nil
        let result = await AnswerStream.$sink.withValue(speech?.sink) {
            await work { [weak self] step, request in
                let line = CommandEngine.describe(request)
                self?.progress.append(line)
                self?.hud.update("\(step) · \(line)")
            }
        }
        let spokeWhileWriting = await speech?.finish(speaksRest: !Task.isCancelled) ?? false
        isDrivingMac = false
        hud.hide()
        if case .failure(.cancelled) = result, isReplacingWork { return }
        switch result {
        case .success(let output?):
            model.state = .idle
            show()
            model.state = .answer(.init(text: output))
            if !spokeWhileWriting { say(String(output.prefix(400))) }
        case .success(nil):
            model.text = ""
            model.state = .idle
            completedSilently += 1
        case .failure(.cancelled):
            model.state = .idle
            show()
            model.state = .message(ActionError.cancelled.localizedDescription, isError: false)
            sayPhrase("Stopped.")
        case .failure(let error):
            model.state = .idle
            show()
            fail(error.localizedDescription)
        }
    }

    /// Web research keeps the panel open with the current step; Esc or the kill switch stop it.
    func research(_ question: String, query: String) async {
        model.state = .working
        beginCorrections(task: question)
        switch await engine.runResearch(question, query: query) {
        case .success(let answer):
            model.state = .answer(.init(
                text: answer.text, sources: answer.sourceSites, image: answer.image, chart: answer.chart
            ))
            say(answer.text)
        case .failure(.cancelled):
            model.state = .idle
        case .failure(let error):
            fail(error.localizedDescription)
        }
    }

    /// Diagrams open in their own window; the panel keeps a button to reopen them.
    func diagram(_ request: String, description: String) async {
        model.state = .working
        beginCorrections(task: request)
        switch await engine.runDiagram(request, description: description) {
        case .success(let diagram):
            model.state = .answer(.init(text: diagram.title, diagram: diagram))
            openDiagram(diagram)
        case .failure(.cancelled):
            model.state = .idle
        case .failure(let error):
            fail(error.localizedDescription)
        }
    }

    /// While a spoken request runs, the microphone stays open with echo cancellation: "fermati",
    /// "no, a Luca" or "e poi apri Slack" change the work without starting over.
    func beginCorrections(task: String) {
        runningTask = task
        progress = []
        guard isVoiceCommand, voice.keepsListening, !isQuiet, listening == nil,
              SystemPermissionChecker().status(of: .microphone) == .granted
        else { return }
        isCorrecting = true
        openCorrectionMicrophone()
    }

    /// Push-to-talk or the wake word while RedOS works: the words are a correction, not a new command.
    func listenForCorrection(chime: Bool) {
        guard model.state == .working, listening == nil else { return }
        if chime { NSSound(named: "Tink")?.play() }
        isCorrecting = true
        openCorrectionMicrophone()
    }

    func openCorrectionMicrophone() {
        listener.onTranscript = { [weak self] text in
            guard let self, isCorrecting, !text.isEmpty else { return }
            hud.update("“\(text)”")
        }
        listener.onDownload = nil
        listening = Task { [listener, voice] in
            try? await listener.start(locale: voice.locale, cancelsEcho: true)
        }
        // Waits for words as long as the work lasts, then ends at the first pause.
        endpoint.start(
            transcript: { [listener] in listener.transcript },
            isSpeaking: { true },
            onPause: { [weak self] _ in self?.takeCorrection() }
        )
    }

    /// The correction was said: understand it and act.
    func takeCorrection() {
        guard isCorrecting, let opened = listening else { return }
        endpoint.cancel()
        listening = nil
        Task { [self] in
            await opened.value
            let text = await listener.stop().trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            guard isCorrecting else { return }
            guard !text.isEmpty else { return openCorrectionMicrophone() }
            let correction = await engine.classifyCorrection(text, task: runningTask ?? "", done: progress)
            guard isCorrecting else { return }
            apply(correction, said: text)
        }
    }

    func endCorrections() {
        guard isCorrecting else { return }
        isCorrecting = false
        endpoint.cancel()
        let stopping = listening
        listening?.cancel()
        listening = nil
        Task { [listener] in
            await stopping?.value
            await listener.cancel()
        }
    }

    private func apply(_ correction: Correction, said text: String) {
        switch correction {
        case .stop:
            pendingAdditions = []
            endCorrections()
            work?.cancel()
        case .modify:
            endCorrections()
            replaceWork(correction: text)
        case .add(let request):
            pendingAdditions.append(request)
            hud.update(String(localized: "Then: \(request)"))
            openCorrectionMicrophone()
        case .unrelated:
            openCorrectionMicrophone()
        }
    }

    /// Stops the running work, then System Two plans the task again with the correction.
    private func replaceWork(correction: String) {
        let task = runningTask ?? model.text
        let done = progress
        let old = work
        isReplacingWork = true
        old?.cancel()
        Task { [self] in
            await old?.value
            isReplacingWork = false
            model.text = correction
            model.state = .working
            show()
            start { [self, engine] in
                await handle(await engine.replan(task, done: done, correction: correction), input: correction)
            }
        }
    }

    /// The next request added while working; false when there is none or a confirmation is waiting.
    func runNextAddition() -> Bool {
        switch model.state {
        case .confirming, .confirmingPlan, .listening: return false
        default: break
        }
        guard !pendingAdditions.isEmpty else { return false }
        let next = pendingAdditions.removeFirst()
        let task = runningTask ?? ""
        model.text = next
        model.state = .working
        start { [self, engine] in
            await handle(await engine.resolveAddition(next, after: task), input: next)
        }
        return true
    }
}
