import SwiftUI
import Combine
import CoreBluetooth
import VitalOSSDK
import VitalOSBLE

struct DeviceView: View {
    let peripheral: CBPeripheral
    let connectionProvider: CoreBluetoothConnectionProvider

    @StateObject private var viewModel: DeviceViewModel

    init(peripheral: CBPeripheral, connectionProvider: CoreBluetoothConnectionProvider) {
        self.peripheral = peripheral
        self.connectionProvider = connectionProvider
        _viewModel = StateObject(wrappedValue: DeviceViewModel(
            peripheral: peripheral,
            connectionProvider: connectionProvider
        ))
    }

    var body: some View {
        List {
            // Connection section
            Section("Connection") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(viewModel.connectionStateText)
                        .foregroundStyle(viewModel.connectionState == .connected ? .green : .secondary)
                }

                if viewModel.connectionState == .disconnected {
                    Button("Connect") {
                        Task { await viewModel.connect() }
                    }
                } else if viewModel.connectionState == .connected {
                    Button("Disconnect", role: .destructive) {
                        Task { await viewModel.disconnect() }
                    }
                } else {
                    HStack {
                        ProgressView()
                        Text("Connecting...")
                            .padding(.leading, 8)
                    }
                }
            }

            // Actions section
            if viewModel.connectionState == .connected {
                Section("Sync") {
                    Button("Health Data (7 days)") {
                        Task { await viewModel.syncHealthData() }
                    }
                    .disabled(viewModel.isLoading)

                    Button("Sleep Data (7 days)") {
                        Task { await viewModel.syncSleepData() }
                    }
                    .disabled(viewModel.isLoading)
                }
            }

            // Status / Error
            if viewModel.isLoading {
                Section {
                    HStack {
                        ProgressView()
                        Text(viewModel.statusMessage ?? "Loading...")
                            .padding(.leading, 8)
                    }
                }
            }

            if let error = viewModel.error {
                Section("Error") {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            // Health Records
            if !viewModel.healthRecords.isEmpty {
                Section("Health Records (\(viewModel.healthRecords.count))") {
                    ForEach(Array(viewModel.healthRecords.enumerated()), id: \.offset) { _, record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Steps: \(record.steps)")
                                .font(.subheadline)
                            HStack(spacing: 12) {
                                Text("HR: \(record.avgHeartRate) bpm")
                                Text("Cal: \(Int(record.activeCalories + record.passiveCalories))")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Sleep Days
            if !viewModel.sleepDays.isEmpty {
                Section("Sleep Days (\(viewModel.sleepDays.count))") {
                    ForEach(Array(viewModel.sleepDays.enumerated()), id: \.offset) { _, day in
                        if day.hasSummary {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Total: \(formatMs(day.summary.totalSleepMs))")
                                    .font(.subheadline)
                                HStack(spacing: 12) {
                                    Text("Deep: \(formatMs(day.summary.deepMs))")
                                    Text("REM: \(formatMs(day.summary.remMs))")
                                    Text("Light: \(formatMs(day.summary.lightMs))")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Sleep day (no summary)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(peripheral.name ?? "Device")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func formatMs(_ ms: Int64) -> String {
        let totalMinutes = ms / 60_000
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return "\(h)h \(m)m"
    }
}

// MARK: - DeviceViewModel

@MainActor
final class DeviceViewModel: ObservableObject {
    @Published var connectionState: DeviceConnectionState = .disconnected
    @Published var isLoading = false
    @Published var statusMessage: String?
    @Published var error: String?
    @Published var healthRecords: [VitalOSProtocol_HealthAggregatedDataEntry] = []
    @Published var sleepDays: [SleepDay] = []

    private let device: VitalOsDevice
    private let healthPlugin: VitalOsHealthPlugin
    private var cancellables = Set<AnyCancellable>()

    var connectionStateText: String {
        switch connectionState {
        case .disconnected: return "Disconnected"
        case .connecting:   return "Connecting..."
        case .connected:    return "Connected"
        }
    }

    init(peripheral: CBPeripheral, connectionProvider: CoreBluetoothConnectionProvider) {
        let messaging = VitalOsMessagingPlugin()
        let health = VitalOsHealthPlugin()
        self.healthPlugin = health

        self.device = VitalOsDeviceImpl(
            connectionProvider: connectionProvider,
            id: peripheral.identifier.uuidString,
            initialName: peripheral.name ?? "VitalOS Device",
            plugins: [messaging, health],
            environment: nil
        )

        device.connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionState = state
            }
            .store(in: &cancellables)
    }

    func connect() async {
        error = nil
        do {
            try await device.connect()
        } catch {
            self.error = "Connection failed: \(error.localizedDescription)"
        }
    }

    func disconnect() async {
        await device.disconnect()
        healthRecords = []
        sleepDays = []
    }

    func syncHealthData() async {
        guard connectionState == .connected else { return }
        isLoading = true
        error = nil
        statusMessage = "Syncing health data..."

        let to = Date()
        let from = to.addingTimeInterval(-7 * 24 * 60 * 60)

        do {
            let uploads = try await healthPlugin.getHealthData(from: from, to: to)
            let records = uploads.flatMap { $0.records }
            healthRecords = records
            statusMessage = "Synced \(records.count) health records"
        } catch {
            self.error = "Health sync failed: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func syncSleepData() async {
        guard connectionState == .connected else { return }
        isLoading = true
        error = nil
        statusMessage = "Syncing sleep data..."

        let to = Date()
        let from = to.addingTimeInterval(-7 * 24 * 60 * 60)

        do {
            let days = try await healthPlugin.getSleepData(from: from, to: to)
            sleepDays = days
            statusMessage = "Synced \(days.count) sleep days"
        } catch {
            self.error = "Sleep sync failed: \(error.localizedDescription)"
        }

        isLoading = false
    }
}
