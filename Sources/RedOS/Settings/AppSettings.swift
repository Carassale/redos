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
    /// System Two stays on this Mac whatever the provider.
    var offlineOnly: Bool
    /// Cloud requests per day before switching to the local model; 0 = no limit.
    var dailyCloudLimit: Int
    /// Plans and the screen agent use System Two, and System One acts only when very sure.
    var prefersAccuracy: Bool
    var voiceLocale: String
    var speaksAnswers: Bool
    var wakeWordEnabled: Bool
    /// Minimum wake word score: lower hears more, but also triggers by mistake more often.
    var wakeWordThreshold: Double

    static let defaultSystemOneModel = "gemma4:e4b-it-qat"
    // Smaller model: argument extraction is generation-bound (eval: 0.44 s vs 0.79 s, same accuracy).
    static let defaultExtractionModel = "gemma4:e2b-it-qat"

    init(defaults: UserDefaults = .standard) {
        systemOneModel = defaults.string(forKey: "systemOne.model") ?? Self.defaultSystemOneModel
        extractionModel = defaults.string(forKey: "systemOne.extractionModel") ?? Self.defaultExtractionModel
        threshold = defaults.object(forKey: "systemOne.threshold") as? Double ?? 0.5
        jevURL = defaults.string(forKey: "systemOne.jevURL") ?? ""
        systemTwoProvider = defaults.string(forKey: "systemTwo.provider").flatMap(SystemTwoProvider.init) ?? .ollama
        systemTwoModel = defaults.string(forKey: "systemTwo.model") ?? systemTwoProvider.defaultModel
        copilotPath = defaults.string(forKey: "systemTwo.copilotPath") ?? ""
        offlineOnly = defaults.bool(forKey: "systemTwo.offlineOnly")
        dailyCloudLimit = defaults.integer(forKey: "systemTwo.dailyLimit")
        prefersAccuracy = defaults.object(forKey: "routing.prefersAccuracy") as? Bool ?? true
        voiceLocale = defaults.string(forKey: "voice.locale") ?? Self.defaultVoiceLocale
        speaksAnswers = defaults.object(forKey: "voice.speaksAnswers") as? Bool ?? true
        wakeWordEnabled = defaults.bool(forKey: "voice.wakeWord")
        wakeWordThreshold = defaults.object(forKey: "voice.wakeWordThreshold") as? Double ?? 0.5
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
        defaults.set(offlineOnly, forKey: "systemTwo.offlineOnly")
        defaults.set(dailyCloudLimit, forKey: "systemTwo.dailyLimit")
        defaults.set(prefersAccuracy, forKey: "routing.prefersAccuracy")
        defaults.set(voiceLocale, forKey: "voice.locale")
        defaults.set(speaksAnswers, forKey: "voice.speaksAnswers")
        defaults.set(wakeWordEnabled, forKey: "voice.wakeWord")
        defaults.set(wakeWordThreshold, forKey: "voice.wakeWordThreshold")
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
