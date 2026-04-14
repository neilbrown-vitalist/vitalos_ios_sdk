import Foundation

/// Manages the full BLE connection lifecycle for a VitalOS device.
///
/// Implementations are responsible for connecting to the device, negotiating MTU,
/// discovering the VitalOS GATT service and characteristics, and managing bonding.
///
/// The default CoreBluetooth implementation is in the `VitalOSBLE` target.
/// Integrators using their own BLE library can implement this protocol directly.
/// Use ``VitalOsProtocol`` for the required UUIDs.
public protocol BleConnectionProvider: AnyObject, Sendable {

    /// An `AsyncStream` of the BLE connection state for the given device.
    func connectionState(deviceId: String) -> AsyncStream<BleConnectionState>

    /// An `AsyncStream` of the bond (pairing) state for the given device.
    func bondState(deviceId: String) -> AsyncStream<BleBondState>

    /// Connects to the device, negotiates MTU, discovers VitalOS GATT service,
    /// and returns a ready-to-use ``BleTransport``.
    func connect(deviceId: String, requestedMtu: Int) async throws -> BleTransport

    /// Disconnects the BLE connection for the given device.
    func disconnect(deviceId: String) async throws

    /// Initiates Bluetooth pairing (bonding) with the given device.
    func createBond(deviceId: String) async throws

    /// Removes the Bluetooth bond for the given device.
    func removeBond(deviceId: String) async throws
}

public extension BleConnectionProvider {
    func connect(deviceId: String) async throws -> BleTransport {
        try await connect(deviceId: deviceId, requestedMtu: 512)
    }
}
