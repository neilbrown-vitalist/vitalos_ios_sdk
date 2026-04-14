import Foundation

/// Base protocol for all VitalOS feature plugins.
///
/// Plugins are registered when creating a ``VitalOsDevice`` and are automatically
/// initialised and torn down as the connection state changes.
public protocol VitalOsPlugin: AnyObject {

    /// Unique identifier for this plugin. Must be stable across versions.
    var id: String { get }

    /// Called after the BLE connection and protocol stack are fully established.
    func onDeviceConnected(
        device: VitalOsDevice,
        router: CommandRouter,
        streamRouter: StreamRouter,
        requestManager: RequestManager
    ) async

    /// Returns `true` if this plugin is supported by the given device.
    /// Checked before ``onDeviceConnected``; returning `false` skips initialisation.
    func isSupported(_ device: VitalOsDevice) async -> Bool

    /// Called when the device disconnects. Cancel pending operations and release resources.
    func onDeviceDisconnected(_ device: VitalOsDevice) async

    /// Called when the device is disposed. Release all remaining resources.
    func dispose() async
}

public extension VitalOsPlugin {
    func isSupported(_ device: VitalOsDevice) async -> Bool { true }
}
