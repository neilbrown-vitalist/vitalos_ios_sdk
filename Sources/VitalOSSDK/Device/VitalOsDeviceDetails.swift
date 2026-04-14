import Foundation

/// Identity and metadata for a VitalOS device.
public struct VitalOsDeviceDetails: Sendable {
    public var id: String
    public var name: String
    public var firmwareVersion: String
    public var deviceModel: Int
    public var color: Int
    public var rssi: Int

    public init(
        id: String,
        name: String,
        firmwareVersion: String = "0.0.1",
        deviceModel: Int = 0,
        color: Int = 0,
        rssi: Int = 0
    ) {
        self.id = id
        self.name = name
        self.firmwareVersion = firmwareVersion
        self.deviceModel = deviceModel
        self.color = color
        self.rssi = rssi
    }
}
