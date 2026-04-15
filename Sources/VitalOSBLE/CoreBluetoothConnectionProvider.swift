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

    /// Strong references to peripheral delegates so they survive while discovery is in-flight.
    /// `CBPeripheral.delegate` is weak, so without this the delegate would be deallocated
    /// before the discovery callbacks fire.
    private var peripheralDelegates: [String: DiscoveryPeripheralDelegate] = [:]

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

        // Always retrieve via our own CBCentralManager so the peripheral is
        // associated with this manager. Peripherals registered from an external
        // scan belong to a different CBCentralManager and cannot be connected here.
        let retrieved = centralManager.retrievePeripherals(withIdentifiers: [uuid])
        guard let peripheral = retrieved.first else {
            throw VitalOsError.connectionFailed("Peripheral not found: \(deviceId)")
        }
        lock.lock()
        knownPeripherals[deviceId] = peripheral
        lock.unlock()

        logger.info("[\(deviceId)] Connecting (peripheral state: \(String(describing: peripheral.state.rawValue)))...")

        // Wait for CBCentralManager to connect
        let connected = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CBPeripheral, Error>) in
            lock.lock()
            connectionContinuations[deviceId] = continuation
            lock.unlock()
            centralManager.connect(peripheral, options: nil)
        }

        logger.info("[\(deviceId)] BLE connected, starting service discovery...")
        connectionStateStreams[deviceId]?.yield(.connected)
        bondStateStreams[deviceId]?.yield(.bonded)

        // Discover VitalOS service and characteristics
        let (writeChar, indicateChar) = try await discoverCharacteristics(peripheral: connected)

        let mtu = connected.maximumWriteValueLength(for: .withoutResponse) + 3
        logger.info("[\(deviceId)] Service discovery complete, MTU=\(mtu)")

        return CoreBluetoothTransport(
            peripheral: connected,
            writeCharacteristic: writeChar,
            indicateCharacteristic: indicateChar
        )
    }

    public func disconnect(deviceId: String) async throws {
        lock.lock()
        guard let peripheral = knownPeripherals[deviceId] else {
            logger.info("[\(deviceId)] Disconnect: no known peripheral")
            lock.unlock()
            return
        }

        let pendingDiscovery = discoveryCallbacks.removeValue(forKey: deviceId)
        peripheralDelegates.removeValue(forKey: deviceId)
        let pendingConnection = connectionContinuations.removeValue(forKey: deviceId)
        lock.unlock()

        if pendingConnection != nil {
            logger.info("[\(deviceId)] Disconnect: cancelling pending connection continuation")
            pendingConnection?.resume(throwing: VitalOsError.connectionFailed("Disconnected"))
        }
        if pendingDiscovery != nil {
            logger.info("[\(deviceId)] Disconnect: cancelling pending service discovery")
            pendingDiscovery?(.failure(VitalOsError.connectionFailed("Disconnected during discovery")))
        }

        let state = peripheral.state
        logger.info("[\(deviceId)] Disconnect: peripheral state=\(String(describing: state.rawValue))")

        if state == .connected {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                disconnectContinuations[deviceId] = continuation
                lock.unlock()
                centralManager.cancelPeripheralConnection(peripheral)
            }
        } else if state == .connecting {
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
        let deviceId = peripheral.identifier.uuidString
        logger.info("[\(deviceId)] Starting service discovery for service \(self.serviceUUID)")

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = DiscoveryPeripheralDelegate(provider: self)

            lock.lock()
            peripheralDelegates[deviceId] = delegate
            discoveryCallbacks[deviceId] = { result in
                switch result {
                case .success(let chars): continuation.resume(returning: chars)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            lock.unlock()

            peripheral.delegate = delegate
            peripheral.discoverServices([serviceUUID])
        }
    }

    fileprivate func handleServiceDiscovery(peripheral: CBPeripheral, error: Error?) {
        let deviceId = peripheral.identifier.uuidString

        if let error {
            logger.error("[\(deviceId)] didDiscoverServices error: \(error.localizedDescription)")
            completeDiscovery(for: deviceId, result: .failure(error))
            return
        }

        let serviceUUIDs = peripheral.services?.map(\.uuid.uuidString) ?? []
        logger.info("[\(deviceId)] didDiscoverServices: \(serviceUUIDs)")

        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            logger.error("[\(deviceId)] VitalOS service \(self.serviceUUID) not found in discovered services")
            completeDiscovery(for: deviceId, result: .failure(VitalOsError.serviceDiscoveryFailed("VitalOS service not found")))
            return
        }

        logger.info("[\(deviceId)] Found VitalOS service, discovering characteristics...")
        peripheral.discoverCharacteristics([writeCharUUID, indicateCharUUID], for: service)
    }

    fileprivate func handleCharacteristicDiscovery(peripheral: CBPeripheral, service: CBService, error: Error?) {
        let deviceId = peripheral.identifier.uuidString

        if let error {
            logger.error("[\(deviceId)] didDiscoverCharacteristics error: \(error.localizedDescription)")
            completeDiscovery(for: deviceId, result: .failure(error))
            return
        }

        let charUUIDs = service.characteristics?.map(\.uuid.uuidString) ?? []
        logger.info("[\(deviceId)] didDiscoverCharacteristics: \(charUUIDs)")

        guard let writeChar = service.characteristics?.first(where: { $0.uuid == writeCharUUID }),
              let indicateChar = service.characteristics?.first(where: { $0.uuid == indicateCharUUID }) else {
            logger.error("[\(deviceId)] Required characteristics not found (need write=\(self.writeCharUUID), indicate=\(self.indicateCharUUID))")
            completeDiscovery(for: deviceId, result: .failure(VitalOsError.serviceDiscoveryFailed("Required characteristics not found")))
            return
        }

        completeDiscovery(for: deviceId, result: .success((writeChar, indicateChar)))
    }

    private func completeDiscovery(for deviceId: String, result: Result<(CBCharacteristic, CBCharacteristic), Error>) {
        lock.lock()
        let callback = discoveryCallbacks.removeValue(forKey: deviceId)
        peripheralDelegates.removeValue(forKey: deviceId)
        lock.unlock()

        switch result {
        case .success:
            logger.info("[\(deviceId)] Service discovery succeeded")
        case .failure(let error):
            logger.error("[\(deviceId)] Service discovery failed: \(error.localizedDescription)")
        }

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
        logger.error("[\(deviceId)] didFailToConnect: \(error?.localizedDescription ?? "unknown")")

        lock.lock()
        let continuation = connectionContinuations.removeValue(forKey: deviceId)
        let pendingDiscovery = discoveryCallbacks.removeValue(forKey: deviceId)
        peripheralDelegates.removeValue(forKey: deviceId)
        lock.unlock()

        continuation?.resume(throwing: VitalOsError.connectionFailed(error?.localizedDescription ?? "Connection failed"))
        pendingDiscovery?(.failure(VitalOsError.connectionFailed("Connection failed")))
        connectionStateStreams[deviceId]?.yield(.disconnected)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let deviceId = peripheral.identifier.uuidString
        logger.info("[\(deviceId)] didDisconnectPeripheral (error: \(error?.localizedDescription ?? "none"))")

        lock.lock()
        let disconnectCont = disconnectContinuations.removeValue(forKey: deviceId)
        let pendingConnection = connectionContinuations.removeValue(forKey: deviceId)
        let pendingDiscovery = discoveryCallbacks.removeValue(forKey: deviceId)
        peripheralDelegates.removeValue(forKey: deviceId)
        lock.unlock()

        pendingConnection?.resume(throwing: VitalOsError.connectionFailed("Disconnected unexpectedly"))
        pendingDiscovery?(.failure(VitalOsError.connectionFailed("Disconnected during discovery")))
        disconnectCont?.resume()

        connectionStateStreams[deviceId]?.yield(.disconnected)
        bondStateStreams[deviceId]?.yield(.none)
    }
}

// MARK: - Discovery Peripheral Delegate

private final class DiscoveryPeripheralDelegate: NSObject, CBPeripheralDelegate {
    private let logger = Logger(subsystem: "co.vitalos.ble", category: "DiscoveryDelegate")
    private weak var provider: CoreBluetoothConnectionProvider?

    init(provider: CoreBluetoothConnectionProvider) {
        self.provider = provider
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        logger.info("[\(peripheral.identifier.uuidString)] didDiscoverServices callback (error: \(error?.localizedDescription ?? "none"))")
        provider?.handleServiceDiscovery(peripheral: peripheral, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        logger.info("[\(peripheral.identifier.uuidString)] didDiscoverCharacteristics callback for service \(service.uuid) (error: \(error?.localizedDescription ?? "none"))")
        provider?.handleCharacteristicDiscovery(peripheral: peripheral, service: service, error: error)
    }
}
