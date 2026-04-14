import Foundation

/// Errors thrown by the VitalOS SDK.
public enum VitalOsError: Error, LocalizedError {
    case permissionDenied(String)
    case bluetoothUnavailable
    case connectionFailed(String, underlyingError: Error? = nil)
    case bondingFailed(String)
    case disconnected
    case serviceDiscoveryFailed(String)
    case requestTimedOut(commandId: Int)
    case deviceError(errorCode: Int, message: String)
    case unsupportedFeature
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let msg):       return "Permission denied: \(msg)"
        case .bluetoothUnavailable:            return "Bluetooth adapter is unavailable or turned off"
        case .connectionFailed(let msg, _):    return "Connection failed: \(msg)"
        case .bondingFailed(let msg):          return "Bonding failed: \(msg)"
        case .disconnected:                    return "Device is disconnected"
        case .serviceDiscoveryFailed(let msg): return "Service discovery failed: \(msg)"
        case .requestTimedOut(let id):         return "Request timed out for command 0x\(String(id, radix: 16, uppercase: true))"
        case .deviceError(_, let msg):         return "Device error: \(msg)"
        case .unsupportedFeature:              return "Feature is not supported on this device"
        case .unknown(let msg):                return msg
        }
    }
}
