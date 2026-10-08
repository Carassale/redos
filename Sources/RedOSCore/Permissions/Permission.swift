import Foundation

public enum Permission: String, CaseIterable, Identifiable, Sendable {
    case accessibility
    case microphone
    case screenRecording

    public var id: String { rawValue }

    public var settingsURL: URL {
        let anchor = switch self {
        case .accessibility: "Privacy_Accessibility"
        case .microphone: "Privacy_Microphone"
        case .screenRecording: "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

public enum PermissionStatus: Sendable, Equatable {
    case granted
    case denied
    case notDetermined
}

public protocol PermissionChecking: Sendable {
    func status(of permission: Permission) -> PermissionStatus
    func request(_ permission: Permission) async -> PermissionStatus
}
