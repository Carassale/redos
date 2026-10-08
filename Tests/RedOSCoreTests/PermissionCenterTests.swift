import Testing
@testable import RedOSCore

private struct FakeChecker: PermissionChecking {
    var granted: Set<Permission>

    func status(of permission: Permission) -> PermissionStatus {
        granted.contains(permission) ? .granted : .notDetermined
    }

    func request(_ permission: Permission) async -> PermissionStatus {
        .granted
    }
}

@MainActor
struct PermissionCenterTests {
    @Test func allGrantedRequiresEveryPermission() {
        let partial = PermissionCenter(checker: FakeChecker(granted: [.accessibility]))
        #expect(!partial.allGranted)

        let full = PermissionCenter(checker: FakeChecker(granted: Set(Permission.allCases)))
        #expect(full.allGranted)
    }

    @Test func requestUpdatesStatus() async {
        let center = PermissionCenter(checker: FakeChecker(granted: []))
        #expect(center.status(of: .microphone) == .notDetermined)

        await center.request(.microphone)
        #expect(center.status(of: .microphone) == .granted)
    }
}

@Test(arguments: Permission.allCases)
func settingsURLOpensPrivacyPane(_ permission: Permission) {
    #expect(permission.settingsURL.scheme == "x-apple.systempreferences")
}
