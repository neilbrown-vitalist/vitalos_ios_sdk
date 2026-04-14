import Foundation

/// Bluetooth bonding (pairing) state reported by the ``BleConnectionProvider``.
public enum BleBondState: Sendable {
    case none
    case bonding
    case bonded
}
