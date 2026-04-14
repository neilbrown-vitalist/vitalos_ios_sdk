import Foundation
import CoreBluetooth
import VitalOSSDK
import os

/// ``BleTransport`` implementation using CoreBluetooth.
///
/// Wraps a connected `CBPeripheral` with the VitalOS write and indicate characteristics.
public final class CoreBluetoothTransport: NSObject, BleTransport, @unchecked Sendable {

    private let logger = Logger(subsystem: "co.vitalos.ble", category: "CoreBluetoothTransport")
    private let peripheral: CBPeripheral
    private let writeCharacteristic: CBCharacteristic
    private let indicateCharacteristic: CBCharacteristic

    private let _onDataReceived: AsyncStream<Data>
    private let dataContinuation: AsyncStream<Data>.Continuation

    private var peripheralDelegate: PeripheralDelegate?

    public var mtu: Int {
        peripheral.maximumWriteValueLength(for: .withoutResponse) + 3
    }

    public var onDataReceived: AsyncStream<Data> { _onDataReceived }

    public init(peripheral: CBPeripheral, writeCharacteristic: CBCharacteristic, indicateCharacteristic: CBCharacteristic) {
        self.peripheral = peripheral
        self.writeCharacteristic = writeCharacteristic
        self.indicateCharacteristic = indicateCharacteristic

        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self._onDataReceived = stream
        self.dataContinuation = continuation

        super.init()

        let delegate = PeripheralDelegate(continuation: continuation)
        self.peripheralDelegate = delegate
        peripheral.delegate = delegate
    }

    public func write(_ data: Data) async throws {
        peripheral.writeValue(data, for: writeCharacteristic, type: .withoutResponse)
    }

    public func enableIndications() async throws {
        peripheral.setNotifyValue(true, for: indicateCharacteristic)
        try await Task.sleep(nanoseconds: 100_000_000) // Brief pause for CCCD write
    }

    public func disableIndications() async throws {
        peripheral.setNotifyValue(false, for: indicateCharacteristic)
    }

    public func close() {
        dataContinuation.finish()
        peripheralDelegate = nil
    }
}

// MARK: - Peripheral Delegate

private final class PeripheralDelegate: NSObject, CBPeripheralDelegate {
    let continuation: AsyncStream<Data>.Continuation

    init(continuation: AsyncStream<Data>.Continuation) {
        self.continuation = continuation
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        continuation.yield(value)
    }
}
