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
                onDataChunk: { upload in self?.activeHealthSync?.appendChunk(upload) },
                onComplete: {
                    guard let self else { return }
                    self.healthSyncLock.lock()
                    guard let sync = self.activeHealthSync else {
                        self.healthSyncLock.unlock()
                        return
                    }
                    let resumed = sync.markComplete()
                    if resumed { self.activeHealthSync = nil }
                    self.healthSyncLock.unlock()
                    self.logger.info("Health sync notification complete (resumed=\(resumed), chunks=\(sync.chunkCount))")
                }
            )
        }

        router.registerNotificationHandler(commandId: VitalOsCommand.sleepSyncNotification.rawValue) { [weak self] in
            SleepSyncNotificationHandler(
                onDay: { day in self?.activeSleepSync?.appendDay(day) },
                onComplete: {
                    guard let self else { return }
                    self.sleepSyncLock.lock()
                    guard let sync = self.activeSleepSync else {
                        self.sleepSyncLock.unlock()
                        return
                    }
                    let resumed = sync.markComplete()
                    if resumed { self.activeSleepSync = nil }
                    self.sleepSyncLock.unlock()
                    self.logger.info("Sleep sync notification complete (resumed=\(resumed), days=\(sync.dayCount))")
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

        logger.info("Requesting health data (\(request.startTimestamp)...\(request.endTimestamp))")

        let response = try await rm.sendRequestAndWait(
            commandId: VitalOsCommand.syncHealthData.rawValue,
            command: request
        )

        logger.info("Health sync response: success=\(response.success), hasRecordCount=\(response.hasRecordCount), recordCount=\(response.recordCount)")

        if !response.success {
            throw VitalOsError.unknown("Health sync command failed: \(response.errorMessage)")
        }

        if response.hasRecordCount && response.recordCount == 0 {
            logger.info("Health sync: device reports 0 records")
            return []
        }

        return try await withThrowingTaskGroup(of: [HealthDataUpload].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    sync.setContinuation(continuation)
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

        logger.info("Requesting sleep data (commandId=0x\(String(commandId, radix: 16)))")

        let response = try await rm.sendRequestAndWait(commandId: commandId, command: command)

        logger.info("Sleep sync response: success=\(response.success), hasRecordCount=\(response.hasRecordCount), recordCount=\(response.recordCount)")

        if !response.success {
            throw VitalOsError.unknown("Sleep sync command failed: \(response.errorMessage)")
        }

        if response.hasRecordCount && response.recordCount == 0 {
            logger.info("Sleep sync: device reports 0 records")
            return []
        }

        return try await withThrowingTaskGroup(of: [SleepDay].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    sync.setContinuation(continuation)
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
        logger.info("Device disconnected — cancelling active syncs")
        cancelActiveSync()
        requestManager = nil
    }

    public func dispose() async {
        cancelActiveSync()
        requestManager = nil
    }

    private func cancelActiveSync() {
        activeHealthSync?.cancel(error: VitalOsError.disconnected)
        activeHealthSync = nil
        activeSleepSync?.cancel(error: VitalOsError.disconnected)
        activeSleepSync = nil
    }
}

// MARK: - Active Sync State

/// Thread-safe sync state that handles the race between the notification-driven
/// `markComplete()` and the response-driven `setContinuation()`.
///
/// The device may send the "complete" notification before the SDK processes
/// the command response and installs the continuation. `markComplete()` buffers
/// the signal so `setContinuation()` can resume immediately when it arrives.
private final class ActiveHealthSync {
    private let lock = NSLock()
    private var chunks: [HealthDataUpload] = []
    private var _continuation: CheckedContinuation<[HealthDataUpload], Error>?
    private var completed = false

    var chunkCount: Int { lock.withLock { chunks.count } }

    func appendChunk(_ upload: HealthDataUpload) {
        lock.lock()
        chunks.append(upload)
        lock.unlock()
    }

    func setContinuation(_ continuation: CheckedContinuation<[HealthDataUpload], Error>) {
        lock.lock()
        if completed {
            let result = chunks
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            _continuation = continuation
            lock.unlock()
        }
    }

    /// Returns `true` if the continuation was resumed, `false` if completion was buffered.
    @discardableResult
    func markComplete() -> Bool {
        lock.lock()
        completed = true
        if let cont = _continuation {
            _continuation = nil
            let result = chunks
            lock.unlock()
            cont.resume(returning: result)
            return true
        }
        lock.unlock()
        return false
    }

    func cancel(error: Error) {
        lock.lock()
        let cont = _continuation
        _continuation = nil
        lock.unlock()
        cont?.resume(throwing: error)
    }
}

/// Thread-safe sync state — see ``ActiveHealthSync`` for design rationale.
private final class ActiveSleepSync {
    private let lock = NSLock()
    private var days: [SleepDay] = []
    private var _continuation: CheckedContinuation<[SleepDay], Error>?
    private var completed = false

    var dayCount: Int { lock.withLock { days.count } }

    func appendDay(_ day: SleepDay) {
        lock.lock()
        days.append(day)
        lock.unlock()
    }

    func setContinuation(_ continuation: CheckedContinuation<[SleepDay], Error>) {
        lock.lock()
        if completed {
            let result = days
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            _continuation = continuation
            lock.unlock()
        }
    }

    /// Returns `true` if the continuation was resumed, `false` if completion was buffered.
    @discardableResult
    func markComplete() -> Bool {
        lock.lock()
        completed = true
        if let cont = _continuation {
            _continuation = nil
            let result = days
            lock.unlock()
            cont.resume(returning: result)
            return true
        }
        lock.unlock()
        return false
    }

    func cancel(error: Error) {
        lock.lock()
        let cont = _continuation
        _continuation = nil
        lock.unlock()
        cont?.resume(throwing: error)
    }
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
