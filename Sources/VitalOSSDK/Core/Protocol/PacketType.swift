import Foundation

/// Defines the purpose of a BLE data packet.
/// Values must exactly match the device-side implementation.
public enum PacketType: UInt8, Sendable {
    case command  = 0
    case data     = 1
    case response = 2
    case ack      = 3
}
