import Foundation
import Combine
import SwiftProtobuf
import os

/// Built-in implementation of ``SettingsPlugin``.
public final class VitalOsSettingsPlugin: SettingsPlugin, @unchecked Sendable {

    private let logger = Logger(subsystem: "co.vitalos.sdk", category: "VitalOsSettingsPlugin")
    public let id = "co.vitalos.settings"

    private var requestManager: RequestManager?
    private var settingsCache: [String: SettingsEntry] = [:]

    private let _settingsUpdates = PassthroughSubject<SettingsValue, Never>()
    public var settingsUpdates: AnyPublisher<SettingsValue, Never> {
        _settingsUpdates.eraseToAnyPublisher()
    }

    public init() {}

    public func onDeviceConnected(
        device: VitalOsDevice,
        router: CommandRouter,
        streamRouter: StreamRouter,
        requestManager: RequestManager
    ) async {
        self.requestManager = requestManager

        router.registerHandler(commandId: VitalOsCommand.updateSetting.rawValue) { [weak self] in
            SettingUpdateHandler(plugin: self)
        }

        logger.info("Settings plugin connected")
    }

    public func onDeviceDisconnected(_ device: VitalOsDevice) async {
        logger.debug("Settings plugin disconnected")
        requestManager = nil
    }

    public func dispose() async {
        requestManager = nil
        settingsCache.removeAll()
    }

    // MARK: - SettingsPlugin API

    public func setDeviceClock(time: Date = Date()) async throws {
        guard let rm = requestManager else {
            logger.warning("setDeviceClock: not connected")
            return
        }
        let tz = TimeZone.current
        let offsetSeconds = tz.secondsFromGMT(for: time)
        var command = SetTime()
        command.timestamp = Int64(time.timeIntervalSince1970 * 1000)
        command.timezoneID = tz.identifier
        command.timezoneOffset = Int32(offsetSeconds)
        try await rm.sendRequest(commandId: VitalOsCommand.setDeviceClock.rawValue, command: command)
        logger.debug("Device clock set to \(Int(time.timeIntervalSince1970 * 1000)) (tz=\(tz.identifier), offset=\(offsetSeconds)s)")
    }

    public func getDeviceInfo() async throws -> DeviceInfo? {
        guard let rm = requestManager else {
            logger.warning("getDeviceInfo: not connected")
            return nil
        }
        let response = try await rm.sendRequestAndWait(
            commandId: VitalOsCommand.getDeviceInfo.rawValue,
            command: GetDeviceInfoRequest()
        )
        return try DeviceInfo(serializedBytes: response.payload)
    }

    public func getUserProfile() async throws -> UserProfile? {
        guard let rm = requestManager else {
            logger.warning("getUserProfile: not connected")
            return nil
        }
        let response = try await rm.sendRequestAndWait(
            commandId: VitalOsCommand.getUserProfile.rawValue,
            command: GetUserProfileRequest()
        )
        return try UserProfile(serializedBytes: response.payload)
    }

    public func setUserProfile(_ profile: UserProfile) async throws {
        guard let rm = requestManager else {
            logger.warning("setUserProfile: not connected")
            return
        }
        try await rm.sendRequest(commandId: VitalOsCommand.setUserProfile.rawValue, command: profile)
    }

    public func updateSetting(_ update: SettingsValue) async throws {
        guard let rm = requestManager else {
            throw VitalOsError.disconnected
        }
        try await rm.sendRequest(commandId: VitalOsCommand.updateSetting.rawValue, command: update)
        applySettingsValue(update)
        _settingsUpdates.send(update)
    }

    public func getSetting(settingId: String) -> SettingsEntry? {
        settingsCache[settingId]
    }

    // MARK: - Internal

    fileprivate func handleSettingUpdate(_ value: SettingsValue) {
        applySettingsValue(value)
        _settingsUpdates.send(value)
    }

    private func applySettingsValue(_ value: SettingsValue) {
        guard var existing = settingsCache[value.settingID] else { return }
        switch value.value {
        case .boolValue(let v):   existing.value = .boolValue(v)
        case .intValue(let v):    existing.value = .intValue(v)
        case .stringValue(let v): existing.value = .stringValue(v)
        case .none: break
        }
        if value.lastUpdated > 0 { existing.lastUpdated = value.lastUpdated }
        settingsCache[value.settingID] = existing
    }
}

// MARK: - Incoming UPDATE_SETTING handler

private final class SettingUpdateHandler: FeatureCommandHandler {
    let commandId = VitalOsCommand.updateSetting.rawValue
    private weak var plugin: VitalOsSettingsPlugin?

    init(plugin: VitalOsSettingsPlugin?) {
        self.plugin = plugin
    }

    func handle(payload: Data) async -> CommandResponse? {
        do {
            let value = try SettingsValue(serializedBytes: payload)
            plugin?.handleSettingUpdate(value)
            var response = CommandResponse()
            response.success = true
            return response
        } catch {
            var response = CommandResponse()
            response.success = false
            response.errorMessage = error.localizedDescription
            return response
        }
    }
}
