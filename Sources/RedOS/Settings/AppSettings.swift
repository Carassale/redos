import Foundation
import RedOSCore

/// User settings in UserDefaults; API keys are stored separately in the Keychain.
struct AppSettings: Equatable {
    var systemOneModel: String
    var extractionModel: String
    var threshold: Double
    var jevURL: String
    var systemTwoProvider: SystemTwoProvider
    var systemTwoModel: String
    var copilotPath: String
    var voiceLocale: String
    var speaksAnswers: Bool

    init(defaults: UserDefaults = .standard) {
        systemOneModel = defaults.string(forKey: "systemOne.model") ?? "gemma4:e4b-it-qat"
        // Smaller model: argument extraction is generation-bound (eval: 0.44 s vs 0.79 s, same accuracy).
        extractionModel = defaults.string(forKey: "systemOne.extractionModel") ?? "gemma4:e2b-it-qat"
        threshold = defaults.object(forKey: "systemOne.threshold") as? Double ?? 0.5
        jevURL = defaults.string(forKey: "systemOne.jevURL") ?? ""
        systemTwoProvider = defaults.string(forKey: "systemTwo.provider").flatMap(SystemTwoProvider.init) ?? .ollama
        systemTwoModel = defaults.string(forKey: "systemTwo.model") ?? systemTwoProvider.defaultModel
        copilotPath = defaults.string(forKey: "systemTwo.copilotPath") ?? ""
        voiceLocale = defaults.string(forKey: "voice.locale") ?? Self.defaultVoiceLocale
        speaksAnswers = defaults.object(forKey: "voice.speaksAnswers") as? Bool ?? true
    }

    /// The Mac's language when it is Italian or English, otherwise US English.
    private static var defaultVoiceLocale: String {
        Locale.current.language.languageCode?.identifier == "it" ? "it_IT" : "en_US"
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(systemOneModel, forKey: "systemOne.model")
        defaults.set(extractionModel, forKey: "systemOne.extractionModel")
        defaults.set(threshold, forKey: "systemOne.threshold")
        defaults.set(jevURL.isEmpty ? nil : jevURL, forKey: "systemOne.jevURL")
        defaults.set(systemTwoProvider.rawValue, forKey: "systemTwo.provider")
        defaults.set(systemTwoModel, forKey: "systemTwo.model")
        defaults.set(copilotPath, forKey: "systemTwo.copilotPath")
        defaults.set(voiceLocale, forKey: "voice.locale")
        defaults.set(speaksAnswers, forKey: "voice.speaksAnswers")
    }

    func systemTwo(apiKey: String? = nil) -> SystemTwoConfiguration {
        SystemTwoConfiguration(
            provider: systemTwoProvider,
            model: systemTwoModel,
            apiKey: apiKey ?? Keychain.secret(for: systemTwoProvider.rawValue),
            copilotPath: copilotPath
        )
    }
}
