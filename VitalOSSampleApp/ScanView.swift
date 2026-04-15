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
            .onDisappear {
                viewModel.stopScan()
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

    private static let manufacturerIdBytes: [UInt8] = [
        UInt8(VitalOsProtocol.manufacturerId & 0xFF),
        UInt8(VitalOsProtocol.manufacturerId >> 8)
    ]

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        guard centralManager.state == .poweredOn else {
            print("[ScanVM] Cannot scan — central state: \(centralManager.state.rawValue)")
            return
        }
        discoveredDevices.removeAll()
        isScanning = true
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        print("[ScanVM] Scanning for VitalOS devices (manufacturer ID 0x\(String(format: "%04X", VitalOsProtocol.manufacturerId)))")
    }

    func stopScan() {
        guard isScanning else { return }
        centralManager.stopScan()
        isScanning = false
        print("[ScanVM] Scanning stopped (\(discoveredDevices.count) devices found)")
    }

    private func isVitalOsDevice(_ advertisementData: [String: Any]) -> Bool {
        guard let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              mfgData.count >= 2 else { return false }
        return mfgData[0] == Self.manufacturerIdBytes[0]
            && mfgData[1] == Self.manufacturerIdBytes[1]
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("[ScanVM] Central state changed: \(central.state.rawValue)")
        if central.state == .poweredOn && isScanning {
            startScan()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard isVitalOsDevice(advertisementData) else { return }
        if !discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) {
            print("[ScanVM] Discovered: \(peripheral.name ?? "Unknown") (\(peripheral.identifier))")
            discoveredDevices.append(peripheral)
            connectionProvider.register(peripheral: peripheral)
        }
    }
}
