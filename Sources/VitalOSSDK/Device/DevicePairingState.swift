import Foundation

/// Pairing (bonding) state of a ``VitalOsDevice``.
public enum DevicePairingState: Sendable {
    case notPaired
    case pairing
    case paired
}
