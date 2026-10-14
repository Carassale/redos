import Foundation

// MARK: - Corrections while working

extension CommandEngine {
    /// What the user said while `task` was running; without a classifier only clear phrases are understood.
    public func classifyCorrection(_ utterance: String, task: String, done: [String]) async -> Correction {
        guard let corrector else { return CorrectionClassifier.rule(for: utterance) ?? .unrelated }
        return await corrector.classify(utterance, task: task, done: done)
    }

    /// The task changed while it was running: System Two plans it again, knowing what was already started.
    public func replan(_ task: String, done: [String], correction: String) async -> Resolution {
        let started = done.isEmpty ? "nothing yet" : done.joined(separator: "; ")
        let input = """
            \(task)
            (While you were doing this, the user corrected it: "\(correction)". Already started: \(started). \
            Do the corrected request; skip steps that are already done and still right.)
            """
        await record(correction, nil, .answered, route: .systemTwo)
        return await escalate(input, to: assistant ?? planner, guess: nil, confidence: 1)
    }

    /// A request added while `task` was running ("chiudi anche Slack quando hai finito"), now that it is done.
    public func resolveAddition(_ request: String, after task: String) async -> Resolution {
        let input = "\(request)\n(The user asked for this while you were doing: \(task). That is done now.)"
        return await escalate(input, to: assistant ?? planner, guess: nil, confidence: 1)
    }
}
