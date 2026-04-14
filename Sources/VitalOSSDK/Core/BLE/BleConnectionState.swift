import Foundation

/// BLE connection state reported by the ``BleConnectionProvider``.
public enum BleConnectionState: Sendable {
    case disconnected
    case connecting
    case connected
}
