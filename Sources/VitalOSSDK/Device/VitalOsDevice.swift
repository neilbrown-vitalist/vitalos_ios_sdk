import Foundation
import Combine

/// Represents a single VitalOS device.
///
/// All connection management, protocol stack construction, and plugin lifecycle
/// are handled internally. Consumers interact with features via typed plugins:
/// ```swift
/// let health: HealthPlugin = device.getPlugin()
/// let uploads = try await health.getHealthData(from: from, to: to)
/// ```
public protocol VitalOsDevice: AnyObject {

    var id: String { get }
    var name: String { get }
    var details: VitalOsDeviceDetails { get }

    /// Publishes the current connection state.
    var connectionState: CurrentValueSubject<DeviceConnectionState, Never> { get }

    /// Publishes the current pairing state.
    var pairingState: CurrentValueSubject<DevicePairingState, Never> { get }

    /// Direct accessor for the built-in ``SettingsPlugin``. Always present.
    var settings: SettingsPlugin { get }

    /// Establishes the BLE connection and initialises the protocol stack.
    func connect() async throws

    /// Disconnects from the device and tears down the protocol stack.
    func disconnect() async

    /// Removes Bluetooth pairing.
    func unpair() async

    /// Releases all resources. The device cannot be used after this call.
    func dispose() async

    /// Returns the plugin of the given type, or throws if not registered.
    func getPlugin<T: VitalOsPlugin>(_ type: T.Type) -> T?

    /// Returns `true` if a plugin of the given type is registered.
    func hasPlugin<T: VitalOsPlugin>(_ type: T.Type) -> Bool

    /// Factory method.
    static func create(
        connectionProvider: BleConnectionProvider,
        deviceId: String,
        name: String,
        plugins: [VitalOsPlugin],
        environment: String?
    ) -> VitalOsDevice
}

public extension VitalOsDevice {
    func getPlugin<T: VitalOsPlugin>() -> T? {
        getPlugin(T.self)
    }

    static func create(
        connectionProvider: BleConnectionProvider,
        deviceId: String,
        name: String = "VitalOS Device",
        plugins: [VitalOsPlugin] = [],
        environment: String? = nil
    ) -> VitalOsDevice {
        VitalOsDeviceImpl(
            connectionProvider: connectionProvider,
            id: deviceId,
            initialName: name,
            plugins: plugins,
            environment: environment
        )
    }
}
