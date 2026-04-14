import Foundation

/// BLE protocol constants for the VitalOS device.
/// These UUIDs identify the GATT service and characteristics used for communication.
public enum VitalOsProtocol {
    public static let serviceUUIDString     = "49997669-7461-4C4F-5300-DE5167092147"
    public static let writeCharUUIDString   = "0000CA01-0000-1000-8000-00805F9B34FB"
    public static let indicateCharUUIDString = "0000CA02-0000-1000-8000-00805F9B34FB"
    public static let cccdUUIDString        = "00002902-0000-1000-8000-00805F9B34FB"

    /// Manufacturer-specific data company identifier for VitalOS devices.
    public static let manufacturerId: UInt16 = 0xF157
}
