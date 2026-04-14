import Foundation

/// A connected, ready-to-use VitalOS BLE byte pipe.
///
/// Abstracts the two VitalOS GATT characteristics (write + indicate) after the
/// BLE connection, MTU negotiation, and service discovery are complete.
/// Implementations are provided by ``BleConnectionProvider``.
public protocol BleTransport: AnyObject, Sendable {

    /// The currently negotiated MTU size for this connection.
    var mtu: Int { get }

    /// Raw bytes received from the device's indicate characteristic.
    var onDataReceived: AsyncStream<Data> { get }

    /// Writes `data` to the device's write characteristic (write-without-response).
    func write(_ data: Data) async throws

    /// Enables BLE indications on the indicate characteristic.
    func enableIndications() async throws

    /// Disables BLE indications on the indicate characteristic.
    func disableIndications() async throws

    /// Closes this transport and releases underlying resources.
    func close()
}
