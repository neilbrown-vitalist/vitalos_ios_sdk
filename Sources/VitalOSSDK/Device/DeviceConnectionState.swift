import Foundation

/// Connection state of a ``VitalOsDevice``.
public enum DeviceConnectionState: Sendable {
    case disconnected
    case connecting
    case connected

    public var isConnected: Bool { self == .connected }
    public var isConnecting: Bool { self == .connecting }
}
