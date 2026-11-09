import Foundation
import os
import Testing
import UserNotifications
@testable import DesktopSupport

/// `UNUserNotificationCenter` の代わり。
private final class FakeUserNotificationCenter: UserNotificationCenterClient, @unchecked Sendable {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct State {
        var status: UNAuthorizationStatus = .notDetermined
        var statusAfterRequest: UNAuthorizationStatus?
        var authorizationError: Error?
        var addError: Error?
        var requestedOptions: [UNAuthorizationOptions] = []
        var addedRequests: [UNNotificationRequest] = []
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    var status: UNAuthorizationStatus {
        get { state.withLockUnchecked { $0.status } }
        set { state.withLockUnchecked { $0.status = newValue } }
    }
    var statusAfterRequest: UNAuthorizationStatus? {
        get { state.withLockUnchecked { $0.statusAfterRequest } }
        set { state.withLockUnchecked { $0.statusAfterRequest = newValue } }
    }
    var authorizationError: Error? {
        get { state.withLockUnchecked { $0.authorizationError } }
        set { state.withLockUnchecked { $0.authorizationError = newValue } }
    }
    var requestedOptions: [UNAuthorizationOptions] { state.withLockUnchecked { $0.requestedOptions } }
    var addedRequests: [UNNotificationRequest] { state.withLockUnchecked { $0.addedRequests } }

    func authorizationStatus() async -> UNAuthorizationStatus { status }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try state.withLockUnchecked { state in
            state.requestedOptions.append(options)
            if let error = state.authorizationError { throw error }
            if let next = state.statusAfterRequest { state.status = next }
            return state.status == .authorized
        }
    }

    func add(_ request: UNNotificationRequest) async throws {
        try state.withLockUnchecked { state in
            state.addedRequests.append(request)
            if let error = state.addError { throw error }
        }
    }
}

/// webtabinal `desktop/Tests/main.swift` の通知のケースを移したもの（spec: notifications「Delivery and activation」
/// 「User-initiated authorization」。tasks 3.3）。
@Suite struct NotificationServiceTests {
    @Test func authorizationStatusMapping() {
        let cases: [(UNAuthorizationStatus, DesktopNotificationPermission)] = [
            (.notDetermined, .default),
            (.denied, .denied),
            (.authorized, .granted),
            (.provisional, .granted),
            (UNAuthorizationStatus(rawValue: 4)!, .granted),
        ]
        for (status, expected) in cases {
            #expect(desktopNotificationPermission(for: status) == expected)
        }
    }

    @Test func authorizationRequestsAlertOnlyAndReturnsTheUpdatedStatus() async throws {
        let center = FakeUserNotificationCenter()
        center.statusAfterRequest = .authorized
        let service = NativeNotificationService(center: center)
        #expect(try await service.requestPermission() == .granted)
        #expect(center.requestedOptions == [[.alert]])

        center.authorizationError = FakeUserNotificationCenter.Failure(message: "boom")
        await #expect(throws: NativeNotificationServiceError.authorizationFailed("boom")) {
            _ = try await service.requestPermission()
        }
    }

    @Test func requestContentAndPermissionGate() async throws {
        let center = FakeUserNotificationCenter()
        center.status = .authorized
        let sequence = OSAllocatedUnfairLock(initialState: 0)
        let service = NativeNotificationService(center: center) {
            let n = sequence.withLock { $0 += 1; return $0 }
            return "tabghostty-test-\(n)"
        }

        try await service.show(sessionID: "session-1", title: "Build complete", body: "project ・ 4s")
        try await service.show(sessionID: "session-2", title: "Approval needed", body: "Codex is waiting")
        let requests = center.addedRequests
        #expect(requests.count == 2)
        #expect(requests[0].identifier != requests[1].identifier)
        let request = requests[0]
        #expect(request.identifier == "tabghostty-test-1")
        #expect(request.content.title == "Build complete")
        #expect(request.content.body == "project ・ 4s")
        #expect(request.content.userInfo["sid"] as? String == "session-1")
        #expect(request.content.sound == nil)
        #expect(request.trigger == nil)

        center.status = .denied
        do {
            try await service.show(sessionID: "session-3", title: "Ignored", body: "Denied")
            Issue.record("denied permission must reject scheduling")
        } catch {
            #expect(error.localizedDescription == "notification permission is denied")
        }
        #expect(center.addedRequests.count == 2)
    }

    // 既定の identifier は `tabghostty-` で始まる（WebTabinal.app の `webtabinal-` と区別する）。
    @Test func defaultIdentifiersUseTheTabghosttyPrefix() async throws {
        let center = FakeUserNotificationCenter()
        center.status = .authorized
        try await NativeNotificationService(center: center).show(sessionID: "s", title: "t", body: "b")
        #expect(center.addedRequests.first?.identifier.hasPrefix("tabghostty-") == true)
    }

    // バンドルの外では `UNUserNotificationCenter` を使わない（unsupported として扱い、出そうとすると失敗する）。
    @Test func outsideABundleNotificationsAreUnsupported() async throws {
        let bundle = try #require(Bundle(path: FileManager.default.temporaryDirectory.path))
        #expect(bundle.bundleIdentifier == nil)
        let service = NativeNotificationService.forCurrentProcess(bundle: bundle)
        #expect(await service.permission() == .unsupported)
        #expect(try await service.requestPermission() == .unsupported)
        await #expect(throws: NativeNotificationServiceError.permissionNotGranted(.unsupported)) {
            try await service.show(sessionID: "s", title: "t", body: "b")
        }
    }

    @Test func foregroundPresentationAndPendingActivation() {
        let options = foregroundNotificationPresentationOptions()
        #expect(options.contains(.banner))
        #expect(options.contains(.list))
        #expect(!options.contains(.sound))

        let coordinator = NotificationActivationCoordinator()
        var delivered: [String] = []
        coordinator.receive(sessionID: "first") { delivered.append($0) }
        coordinator.receive(sessionID: "last") { delivered.append($0) }
        // 選べる状態になるまで待つ。保留するのは最後の 1 つだけ。
        #expect(delivered.isEmpty)
        #expect(coordinator.pendingSessionID == "last")

        coordinator.markReady { delivered.append($0) }
        coordinator.markReady { delivered.append($0) }
        #expect(delivered == ["last"])
        coordinator.receive(sessionID: "loaded") { delivered.append($0) }
        #expect(delivered == ["last", "loaded"])

        // 接続し直している間は、また保留する。
        coordinator.markNotReady()
        coordinator.receive(sessionID: "reconnecting") { delivered.append($0) }
        #expect(delivered == ["last", "loaded"])
        coordinator.markReady { delivered.append($0) }
        #expect(delivered == ["last", "loaded", "reconnecting"])
    }
}
