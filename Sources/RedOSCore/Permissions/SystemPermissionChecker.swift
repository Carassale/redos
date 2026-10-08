import ApplicationServices
import AVFoundation
import CoreGraphics

public struct SystemPermissionChecker: PermissionChecking {
    public init() {}

    public func status(of permission: Permission) -> PermissionStatus {
        switch permission {
        case .accessibility:
            AXIsProcessTrusted() ? .granted : .notDetermined
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .granted
            case .notDetermined: .notDetermined
            default: .denied
            }
        case .screenRecording:
            CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        }
    }

    public func request(_ permission: Permission) async -> PermissionStatus {
        switch permission {
        case .accessibility:
            // Literal key: kAXTrustedCheckOptionPrompt is a non-Sendable global under Swift 6.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options) ? .granted : .notDetermined
        case .microphone:
            return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        case .screenRecording:
            return CGRequestScreenCaptureAccess() ? .granted : .notDetermined
        }
    }
}
