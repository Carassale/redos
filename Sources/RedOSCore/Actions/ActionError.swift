import Foundation

public enum ActionError: Error, Equatable, LocalizedError {
    case unknownAction(String)
    case missingArgument(String)
    case invalidArgument(String, String)
    case permissionMissing(Permission)
    case failed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unknownAction(let id): String(localized: "Unknown action: \(id)")
        case .missingArgument(let name): String(localized: "Missing argument: \(name)")
        case .invalidArgument(let name, let value): String(localized: "Invalid value for \(name): \(value)")
        case .permissionMissing(let permission): String(localized: "Missing permission: \(permission.rawValue)")
        case .failed(let message): message
        case .cancelled: String(localized: "Stopped.")
        }
    }
}
