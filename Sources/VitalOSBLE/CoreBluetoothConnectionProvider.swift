import Foundation
import CoreBluetooth
import VitalOSSDK
import os

/// ``BleConnectionProvider`` implementation using CoreBluetooth.
///
/// Uses `CBCentralManager` to connect to VitalOS devices identified by their
/// CoreBluetooth peripheral UUID string. MTU is automatically negotiated by iOS.
///
/// Usage:
/// ```swift
/// let provider = CoreBluetoothConnectionProvider()
/// let device = VitalOsDevice.create(connectionProvider: provider, deviceId: peripheral.identifier.uuidString)
/// ```
public final class CoreBluetoothConnectionProvider: NSObject, BleConnectionProvider, @unchecked Sendable {

    private let logger = Logger(subsystem: "co.vitalos.ble", category: "CoreBluetoothConnectionProvider")
    private var centralManager: CBCentralManager!
    private var knownPeripherals: [String: CBPeripheral] = [:]

    private let serviceUUID = CBUUID(string: VitalOsProtocol.serviceUUIDString)
    private let writeCharUUID = CBUUID(string: VitalOsProtocol.writeCharUUIDString)
    private let indicateCharUUID = CBUUID(string: VitalOsProtocol.indicateCharUUIDString)

    private var connectionContinuations: [String: CheckedContinuation<CBPeripheral, Error>] = [:]
    private var disconnectContinuations: [String: CheckedContinuation<Void, Error>] = [:]
    private var discoveryCallbacks: [String: (Result<(CBCharacteristic, CBCharacteristic), Error>) -> Void] = [:]

    private var connectionStateStreams: [String: AsyncStream<BleConnectionState>.Continuation] = [:]
    private var bondStateStreams: [String: AsyncStream<BleBondState>.Continuation] = [:]

    private let lock = NSLock()

    public override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: DispatchQueue(label: "co.vitalos.ble.central"))
    }

    /// Registers a peripheral discovered from scanning so it can be connected to by UUID.
    public func register(peripheral: CBPeripheral) {
        lock.lock()
        knownPeripherals[peripheral.identifier.uuidString] = peripheral
        lock.unlock()
    }

    // MARK: - BleConnectionProvider

    public func connectionState(deviceId: String) -> AsyncStream<BleConnectionState> {
        let (stream, continuation) = AsyncStream<BleConnectionState>.makeStream()
        lock.lock()
        connectionStateStreams[deviceId] = continuation
        lock.unlock()

        // Emit current state
        if let peripheral = knownPeripherals[deviceId] {
            switch peripheral.state {
            case .connected:    continuation.yield(.connected)
            case .connecting:   continuation.yield(.connecting)
            default:            continuation.yield(.disconnected)
            }
        } else {
            continuation.yield(.disconnected)
        }

        return stream
    }

    public func bondState(deviceId: String) -> AsyncStream<BleBondState> {
        let (stream, continuation) = AsyncStream<BleBondState>.makeStream()
        lock.lock()
        bondStateStreams[deviceId] = continuation
        lock.unlock()
        // CoreBluetooth doesn't expose explicit bond state — report as bonded once connected
        continuation.yield(.none)
        return stream
    }

    public func connect(deviceId: String, requestedMtu: Int) async throws -> BleTransport {
        guard let uuid = UUID(uuidString: deviceId) else {
            throw VitalOsError.connectionFailed("Invalid device UUID: \(deviceId)")
        }

        let peripheral: CBPeripheral
        lock.lock()
        if let known = knownPeripherals[deviceId] {
            peripheral = known
        } else {
            let retrieved = centralManager.retrievePeripherals(withIdentifiers: [uuid])
            guard let found = retrieved.first else {
                lock.unlock()
                throw VitalOsError.connectionFailed("Peripheral not found: \(deviceId)")
            }
            knownPeripherals[deviceId] = found
            peripheral = found
        }
        lock.unlock()

        logger.info("Connecting to \(deviceId)...")

        // Wait for CBCentralManager to connect
        let connected = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CBPeripheral, Error>) in
            lock.lock()
            connectionContinuations[deviceId] = continuation
            lock.unlock()
            centralManager.connect(peripheral, options: nil)
        }

        connectionStateStreams[deviceId]?.yield(.connected)
        bondStateStreams[deviceId]?.yield(.bonded)

        // Discover VitalOS service and characteristics
        let (writeChar, indicateChar) = try await discoverCharacteristics(peripheral: connected)

        logger.info("Connected to \(deviceId), MTU=\(connected.maximumWriteValueLength(for: .withoutResponse) + 3)")

        return CoreBluetoothTransport(
            peripheral: connected,
            writeCharacteristic: writeChar,
            indicateCharacteristic: indicateChar
        )
    }

    public func disconnect(deviceId: String) async throws {
        lock.lock()
        guard let peripheral = knownPeripherals[deviceId] else {
            lock.unlock()
            return
        }
        lock.unlock()

        guard peripheral.state == .connected || peripheral.state == .connecting else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            disconnectContinuations[deviceId] = continuation
            lock.unlock()
            centralManager.cancelPeripheralConnection(peripheral)
        }

        connectionStateStreams[deviceId]?.yield(.disconnected)
    }

    public func createBond(deviceId: String) async throws {
        // CoreBluetooth handles pairing automatically when accessing encrypted characteristics
        logger.info("createBond is a no-op on iOS (handled by CoreBluetooth automatically)")
    }

    public func removeBond(deviceId: String) async throws {
        // CoreBluetooth doesn't expose bond removal programmatically
        logger.info("removeBond is not supported on iOS — user must unpair from Settings")
    }

    // MARK: - Service Discovery

    private func discoverCharacteristics(peripheral: CBPeripheral) async throws -> (CBCharacteristic, CBCharacteristic) {
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            discoveryCallbacks[peripheral.identifier.uuidString] = { result in
                switch result {
                case .success(let chars): continuation.resume(returning: chars)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            lock.unlock()

            let delegate = peripheral.delegate as? DiscoveryPeripheralDelegate ?? {
                let d = DiscoveryPeripheralDelegate(provider: self)
                peripheral.delegate = d
                return d
            }()
            peripheral.delegate = delegate
            peripheral.discoverServices([serviceUUID])
        }
    }

    fileprivate func handleServiceDiscovery(peripheral: CBPeripheral, error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            let err = error ?? VitalOsError.serviceDiscoveryFailed("VitalOS service not found")
            completeDiscovery(for: peripheral.identifier.uuidString, result: .failure(err))
            return
        }
        peripheral.discoverCharacteristics([writeCharUUID, indicateCharUUID], for: service)
    }

    fileprivate func handleCharacteristicDiscovery(peripheral: CBPeripheral, service: CBService, error: Error?) {
        guard error == nil else {
            completeDiscovery(for: peripheral.identifier.uuidString, result: .failure(error!))
            return
        }
        guard let writeChar = service.characteristics?.first(where: { $0.uuid == writeCharUUID }),
              let indicateChar = service.characteristics?.first(where: { $0.uuid == indicateCharUUID }) else {
            completeDiscovery(for: peripheral.identifier.uuidString, result: .failure(VitalOsError.serviceDiscoveryFailed("Required characteristics not found")))
            return
        }
        completeDiscovery(for: peripheral.identifier.uuidString, result: .success((writeChar, indicateChar)))
    }

    private func completeDiscovery(for deviceId: String, result: Result<(CBCharacteristic, CBCharacteristic), Error>) {
        lock.lock()
        let callback = discoveryCallbacks.removeValue(forKey: deviceId)
        lock.unlock()
        callback?(result)
    }
}

// MARK: - CBCentralManagerDelegate

extension CoreBluetoothConnectionProvider: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.info("Central manager state: \(String(describing: central.state.rawValue))")
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let deviceId = peripheral.identifier.uuidString
        logger.info("Connected to \(deviceId)")
        lock.lock()
        let continuation = connectionContinuations.removeValue(forKey: deviceId)
        lock.unlock()
        continuation?.resume(returning: peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let deviceId = peripheral.identifier.uuidString
        logger.error("Failed to connect to \(deviceId): \(error?.localizedDescription ?? "unknown")")
        lock.lock()
        let continuation = connectionContinuations.removeValue(forKey: deviceId)
        lock.unlock()
        continuation?.resume(throwing: VitalOsError.connectionFailed(error?.localizedDescription ?? "Connection failed"))
        connectionStateStreams[deviceId]?.yield(.disconnected)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let deviceId = peripheral.identifier.uuidString
        logger.info("Disconnected from \(deviceId)")

        lock.lock()
        let disconnectCont = disconnectContinuations.removeValue(forKey: deviceId)
        lock.unlock()

        if let disconnectCont {
            disconnectCont.resume()
        }

        connectionStateStreams[deviceId]?.yield(.disconnected)
        bondStateStreams[deviceId]?.yield(.none)
    }
}

// MARK: - Discovery Peripheral Delegate

private final class DiscoveryPeripheralDelegate: NSObject, CBPeripheralDelegate {
    private weak var provider: CoreBluetoothConnectionProvider?

    init(provider: CoreBluetoothConnectionProvider) {
        self.provider = provider
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        provider?.handleServiceDiscovery(peripheral: peripheral, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        provider?.handleCharacteristicDiscovery(peripheral: peripheral, service: service, error: error)
    }
}
