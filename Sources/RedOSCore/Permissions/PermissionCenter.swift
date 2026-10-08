import Observation

@MainActor
@Observable
public final class PermissionCenter {
    public private(set) var statuses: [Permission: PermissionStatus] = [:]
    private let checker: any PermissionChecking

    public init(checker: any PermissionChecking = SystemPermissionChecker()) {
        self.checker = checker
        refresh()
    }

    public var allGranted: Bool {
        Permission.allCases.allSatisfy { status(of: $0) == .granted }
    }

    public func status(of permission: Permission) -> PermissionStatus {
        statuses[permission] ?? .notDetermined
    }

    public func refresh() {
        for permission in Permission.allCases {
            statuses[permission] = checker.status(of: permission)
        }
    }

    public func request(_ permission: Permission) async {
        statuses[permission] = await checker.request(permission)
    }
}
