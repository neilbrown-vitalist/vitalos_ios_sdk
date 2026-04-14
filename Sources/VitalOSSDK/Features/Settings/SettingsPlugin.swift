import Foundation
import Combine

/// Plugin providing device settings and system configuration.
///
/// The SettingsPlugin is a built-in plugin — it is always present on every ``VitalOsDevice``
/// and is initialised first on every connection. It automatically sends the device clock on
/// connect and fetches device info.
///
/// Access via ``VitalOsDevice/settings`` rather than ``VitalOsDevice/getPlugin(_:)``.
public protocol SettingsPlugin: VitalOsPlugin {

    /// Hot publisher that emits every `SettingsValue` pushed from the device.
    var settingsUpdates: AnyPublisher<SettingsValue, Never> { get }

    /// Sends the current time to the device.
    func setDeviceClock(time: Date) async throws

    /// Requests full device information (firmware version, SKU, serial, etc.).
    func getDeviceInfo() async throws -> DeviceInfo?

    /// Requests the user profile stored on the device.
    func getUserProfile() async throws -> UserProfile?

    /// Pushes a new user profile to the device.
    func setUserProfile(_ profile: UserProfile) async throws

    /// Sends a setting update to the device.
    func updateSetting(_ update: SettingsValue) async throws

    /// Returns the cached `SettingsEntry` for the given setting ID, or nil.
    func getSetting(settingId: String) -> SettingsEntry?
}

public extension SettingsPlugin {
    func setDeviceClock() async throws {
        try await setDeviceClock(time: Date())
    }
}
