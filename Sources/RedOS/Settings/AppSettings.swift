import Foundation
import RedOSCore

/// User settings in UserDefaults; API keys are stored separately in the Keychain.
struct AppSettings: Equatable {
    var systemOneModel: String
    var threshold: Double
    var jevURL: String
    var systemTwoProvider: SystemTwoProvider
    var systemTwoModel: String
    var copilotPath: String

    init(defaults: UserDefaults = .standard) {
        systemOneModel = defaults.string(forKey: "systemOne.model") ?? "gemma4:e4b-it-qat"
        threshold = defaults.object(forKey: "systemOne.threshold") as? Double ?? 0.5
        jevURL = defaults.string(forKey: "systemOne.jevURL") ?? ""
        systemTwoProvider = defaults.string(forKey: "systemTwo.provider").flatMap(SystemTwoProvider.init) ?? .ollama
        systemTwoModel = defaults.string(forKey: "systemTwo.model") ?? systemTwoProvider.defaultModel
        copilotPath = defaults.string(forKey: "systemTwo.copilotPath") ?? ""
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(systemOneModel, forKey: "systemOne.model")
        defaults.set(threshold, forKey: "systemOne.threshold")
        defaults.set(jevURL.isEmpty ? nil : jevURL, forKey: "systemOne.jevURL")
        defaults.set(systemTwoProvider.rawValue, forKey: "systemTwo.provider")
        defaults.set(systemTwoModel, forKey: "systemTwo.model")
        defaults.set(copilotPath, forKey: "systemTwo.copilotPath")
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
