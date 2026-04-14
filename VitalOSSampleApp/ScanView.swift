import SwiftUI
import CoreBluetooth
import VitalOSSDK
import VitalOSBLE

struct ScanView: View {
    @StateObject private var viewModel = ScanViewModel()

    var body: some View {
        NavigationStack {
            List {
                if viewModel.isScanning {
                    HStack {
                        ProgressView()
                        Text("Scanning...")
                            .foregroundStyle(.secondary)
                            .padding(.leading, 8)
                    }
                }

                ForEach(viewModel.discoveredDevices, id: \.identifier) { peripheral in
                    NavigationLink(value: peripheral) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(peripheral.name ?? "Unknown Device")
                                .font(.headline)
                            Text(peripheral.identifier.uuidString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("VitalOS Devices")
            .toolbar {
                Button(viewModel.isScanning ? "Stop" : "Scan") {
                    if viewModel.isScanning {
                        viewModel.stopScan()
                    } else {
                        viewModel.startScan()
                    }
                }
            }
            .navigationDestination(for: CBPeripheral.self) { peripheral in
                DeviceView(
                    peripheral: peripheral,
                    connectionProvider: viewModel.connectionProvider
                )
            }
        }
    }
}

// MARK: - ScanViewModel

final class ScanViewModel: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published var discoveredDevices: [CBPeripheral] = []
    @Published var isScanning = false

    let connectionProvider = CoreBluetoothConnectionProvider()
    private var centralManager: CBCentralManager!
    private let serviceUUID = CBUUID(string: VitalOsProtocol.serviceUUIDString)

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        guard centralManager.state == .poweredOn else { return }
        discoveredDevices.removeAll()
        isScanning = true
        centralManager.scanForPeripherals(withServices: [serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        centralManager.stopScan()
        isScanning = false
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn && isScanning {
            startScan()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if !discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredDevices.append(peripheral)
            connectionProvider.register(peripheral: peripheral)
        }
    }
}
