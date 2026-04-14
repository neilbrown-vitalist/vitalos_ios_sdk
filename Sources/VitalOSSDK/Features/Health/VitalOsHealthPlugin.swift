import Foundation
import Combine
import SwiftProtobuf
import os

private let syncTimeoutNs: UInt64 = 30_000_000_000 // 30s

/// VitalOS Health plugin implementation.
///
/// Exposes:
/// - ``healthDataNotifications`` and ``sleepDataNotifications`` as Combine publishers.
/// - Suspend ``getHealthData(from:to:)``, ``getSleepData(from:to:)``, ``getSleepDataUpdatedSince(_:)`` for one-shot queries.
///
/// Bulk sync payloads are delivered via ``VitalOsCommand/healthSyncNotification`` and
/// ``VitalOsCommand/sleepSyncNotification``.
public final class VitalOsHealthPlugin: HealthPlugin, @unchecked Sendable {

    private let logger = Logger(subsystem: "co.vitalos.sdk", category: "VitalOsHealthPlugin")
    public let id = "co.vitalos.health"

    private let _healthNotifications = PassthroughSubject<HealthDataNotification, Never>()
    public var healthDataNotifications: AnyPublisher<HealthDataNotification, Never> {
        _healthNotifications.eraseToAnyPublisher()
    }

    private let _sleepNotifications = PassthroughSubject<SleepDataNotification, Never>()
    public var sleepDataNotifications: AnyPublisher<SleepDataNotification, Never> {
        _sleepNotifications.eraseToAnyPublisher()
    }

    private var requestManager: RequestManager?

    private let healthSyncLock = NSLock()
    private let sleepSyncLock = NSLock()

    // Active sync state — protected by the respective locks
    private var activeHealthSync: ActiveHealthSync?
    private var activeSleepSync: ActiveSleepSync?

    public init() {}

    // MARK: - VitalOsPlugin lifecycle

    public func onDeviceConnected(
        device: VitalOsDevice,
        router: CommandRouter,
        streamRouter: StreamRouter,
        requestManager: RequestManager
    ) async {
        self.requestManager = requestManager

        router.registerNotificationHandler(commandId: VitalOsCommand.healthDataNotification.rawValue) { [weak self] in
            HealthDataNotificationHandler(subject: self?._healthNotifications)
        }
        router.registerNotificationHandler(commandId: VitalOsCommand.sleepDataNotification.rawValue) { [weak self] in
            SleepDataNotificationHandler(subject: self?._sleepNotifications)
        }

        router.registerNotificationHandler(commandId: VitalOsCommand.healthSyncNotification.rawValue) { [weak self] in
            HealthSyncNotificationHandler(
                onDataChunk: { upload in self?.activeHealthSync?.chunks.append(upload) },
                onComplete: {
                    guard let self, let sync = self.activeHealthSync else { return }
                    self.activeHealthSync = nil
                    sync.continuation?.resume(returning: sync.chunks)
                    sync.continuation = nil
                }
            )
        }

        router.registerNotificationHandler(commandId: VitalOsCommand.sleepSyncNotification.rawValue) { [weak self] in
            SleepSyncNotificationHandler(
                onDay: { day in self?.activeSleepSync?.days.append(day) },
                onComplete: {
                    guard let self, let sync = self.activeSleepSync else { return }
                    self.activeSleepSync = nil
                    sync.continuation?.resume(returning: sync.days)
                    sync.continuation = nil
                }
            )
        }

        logger.info("Health plugin connected")
    }

    // MARK: - Health data

    public func getHealthData(from: Date, to: Date) async throws -> [HealthDataUpload] {
        healthSyncLock.lock()
        guard activeHealthSync == nil else {
            healthSyncLock.unlock()
            throw VitalOsError.unknown("Health sync already in progress")
        }
        let sync = ActiveHealthSync()
        activeHealthSync = sync
        healthSyncLock.unlock()

        defer {
            healthSyncLock.lock()
            if activeHealthSync === sync { activeHealthSync = nil }
            healthSyncLock.unlock()
        }

        guard let rm = requestManager else { throw VitalOsError.disconnected }

        var request = HealthSyncRequest()
        request.startTimestamp = Int64(from.timeIntervalSince1970 * 1000)
        request.endTimestamp = Int64(to.timeIntervalSince1970 * 1000)

        let response = try await rm.sendRequestAndWait(
            commandId: VitalOsCommand.syncHealthData.rawValue,
            command: request
        )

        if !response.success {
            throw VitalOsError.unknown("Health sync command failed: \(response.errorMessage)")
        }

        if response.hasRecordCount && response.recordCount == 0 {
            return []
        }

        return try await withThrowingTaskGroup(of: [HealthDataUpload].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    sync.continuation = continuation
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: syncTimeoutNs)
                throw VitalOsError.unknown("Health sync timed out waiting for data.")
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Sleep data

    public func getSleepData(from: Date, to: Date) async throws -> [SleepDay] {
        try await performSleepSync { request in
            request.startTimestamp = Int64(from.timeIntervalSince1970 * 1000)
            request.endTimestamp = Int64(to.timeIntervalSince1970 * 1000)
            return (VitalOsCommand.syncSleepData.rawValue, request)
        }
    }

    public func getSleepDataUpdatedSince(_ updatedSince: Date) async throws -> [SleepDay] {
        var request = SleepUpdatedSinceRequest()
        request.updatedSinceTs = Int64(updatedSince.timeIntervalSince1970 * 1000)
        return try await performSleepSyncWithCommand(
            commandId: VitalOsCommand.syncSleepDataUpdatedSince.rawValue,
            command: request
        )
    }

    private func performSleepSync(
        buildRequest: (inout SleepSyncRequest) -> (Int, SwiftProtobuf.Message)
    ) async throws -> [SleepDay] {
        var request = SleepSyncRequest()
        let (commandId, command) = buildRequest(&request)
        return try await performSleepSyncWithCommand(commandId: commandId, command: command)
    }

    private func performSleepSyncWithCommand(
        commandId: Int,
        command: SwiftProtobuf.Message
    ) async throws -> [SleepDay] {
        sleepSyncLock.lock()
        guard activeSleepSync == nil else {
            sleepSyncLock.unlock()
            throw VitalOsError.unknown("Sleep sync already in progress")
        }
        let sync = ActiveSleepSync()
        activeSleepSync = sync
        sleepSyncLock.unlock()

        defer {
            sleepSyncLock.lock()
            if activeSleepSync === sync { activeSleepSync = nil }
            sleepSyncLock.unlock()
        }

        guard let rm = requestManager else { throw VitalOsError.disconnected }

        let response = try await rm.sendRequestAndWait(commandId: commandId, command: command)

        if !response.success {
            throw VitalOsError.unknown("Sleep sync command failed: \(response.errorMessage)")
        }

        if response.hasRecordCount && response.recordCount == 0 {
            return []
        }

        return try await withThrowingTaskGroup(of: [SleepDay].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    sync.continuation = continuation
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: syncTimeoutNs)
                throw VitalOsError.unknown("Sleep sync timed out waiting for data.")
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Disconnect / Dispose

    public func onDeviceDisconnected(_ device: VitalOsDevice) async {
        logger.debug("Device disconnected")
        cancelActiveSync()
        requestManager = nil
    }

    public func dispose() async {
        cancelActiveSync()
        requestManager = nil
    }

    private func cancelActiveSync() {
        activeHealthSync?.continuation?.resume(throwing: VitalOsError.disconnected)
        activeHealthSync = nil
        activeSleepSync?.continuation?.resume(throwing: VitalOsError.disconnected)
        activeSleepSync = nil
    }
}

// MARK: - Active Sync State

private final class ActiveHealthSync {
    var chunks: [HealthDataUpload] = []
    var continuation: CheckedContinuation<[HealthDataUpload], Error>?
}

private final class ActiveSleepSync {
    var days: [SleepDay] = []
    var continuation: CheckedContinuation<[SleepDay], Error>?
}

// MARK: - Notification Handlers

private final class HealthDataNotificationHandler: NotificationHandler {
    private let subject: PassthroughSubject<HealthDataNotification, Never>?
    init(subject: PassthroughSubject<HealthDataNotification, Never>?) { self.subject = subject }

    func handle(payload: Data) async {
        guard let notification = try? HealthDataNotification(serializedBytes: payload) else { return }
        subject?.send(notification)
    }
}

private final class SleepDataNotificationHandler: NotificationHandler {
    private let subject: PassthroughSubject<SleepDataNotification, Never>?
    init(subject: PassthroughSubject<SleepDataNotification, Never>?) { self.subject = subject }

    func handle(payload: Data) async {
        guard let notification = try? SleepDataNotification(serializedBytes: payload) else { return }
        subject?.send(notification)
    }
}

private final class HealthSyncNotificationHandler: NotificationHandler {
    private let onDataChunk: (HealthDataUpload) -> Void
    private let onComplete: () -> Void

    init(
        onDataChunk: @escaping (HealthDataUpload) -> Void,
        onComplete: @escaping () -> Void
    ) {
        self.onDataChunk = onDataChunk
        self.onComplete = onComplete
    }

    func handle(payload: Data) async {
        guard let notification = try? HealthSyncNotification(serializedBytes: payload) else { return }
        switch notification.payload {
        case .data(let upload): onDataChunk(upload)
        case .complete:         onComplete()
        case .none: break
        }
    }
}

private final class SleepSyncNotificationHandler: NotificationHandler {
    private let onDay: (SleepDay) -> Void
    private let onComplete: () -> Void

    init(
        onDay: @escaping (SleepDay) -> Void,
        onComplete: @escaping () -> Void
    ) {
        self.onDay = onDay
        self.onComplete = onComplete
    }

    func handle(payload: Data) async {
        guard let notification = try? SleepSyncNotification(serializedBytes: payload) else { return }
        switch notification.payload {
        case .data(let dayPayload):
            if dayPayload.hasDay { onDay(dayPayload.day) }
        case .complete:
            onComplete()
        case .none: break
        }
    }
}
