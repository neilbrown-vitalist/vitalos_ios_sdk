import Foundation
import Combine
import os

/// Internal implementation of ``VitalOsDevice``.
final class VitalOsDeviceImpl: VitalOsDevice, @unchecked Sendable {

    private let logger = Logger(subsystem: "co.vitalos.sdk", category: "VitalOsDeviceImpl")
    private let connectionProvider: BleConnectionProvider
    private let environment: String?

    let id: String
    private(set) var name: String
    private(set) var details: VitalOsDeviceDetails

    let connectionState = CurrentValueSubject<DeviceConnectionState, Never>(.disconnected)
    let pairingState = CurrentValueSubject<DevicePairingState, Never>(.notPaired)

    private let settingsPlugin = VitalOsSettingsPlugin()
    var settings: SettingsPlugin { settingsPlugin }

    private let pluginMap: [String: VitalOsPlugin]

    // Protocol stack — rebuilt on every connect
    private var transport: VitalOsTransportLayer?
    private var streamRouter: VitalOsStreamRouter?
    private var requestManager: VitalOsRequestManager?
    private var commandRouter: VitalOsCommandRouter?

    private var isStackInitialized = false
    private var isExplicitlyConnecting = false
    private var disposed = false

    private var connectionStateTask: Task<Void, Never>?
    private var bondStateTask: Task<Void, Never>?

    init(
        connectionProvider: BleConnectionProvider,
        id: String,
        initialName: String,
        plugins: [VitalOsPlugin],
        environment: String?
    ) {
        self.connectionProvider = connectionProvider
        self.id = id
        self.name = initialName
        self.details = VitalOsDeviceDetails(id: id, name: initialName)
        self.environment = environment

        var map: [String: VitalOsPlugin] = [settingsPlugin.id: settingsPlugin]
        for plugin in plugins { map[plugin.id] = plugin }
        self.pluginMap = map

        startObservingBondState()
    }

    private func startObservingBondState() {
        bondStateTask = Task { [weak self] in
            guard let self else { return }
            for await bleState in self.connectionProvider.bondState(deviceId: self.id) {
                switch bleState {
                case .bonded:  self.pairingState.send(.paired)
                case .bonding: self.pairingState.send(.pairing)
                case .none:    self.pairingState.send(.notPaired)
                }
            }
        }
    }

    func connect() async throws {
        guard !isExplicitlyConnecting else {
            logger.debug("[\(self.id)] Connect ignored: already connecting")
            return
        }
        guard connectionState.value != .connected || !isStackInitialized else {
            logger.debug("[\(self.id)] Connect ignored: already connected")
            return
        }

        isExplicitlyConnecting = true
        connectionState.send(.connecting)

        do {
            logger.info("[\(self.id)] Connecting...")
            let bleTransport = try await connectionProvider.connect(deviceId: id)

            let t = VitalOsTransportLayer(bleTransport: bleTransport)
            let sr = VitalOsStreamRouter(transport: t)
            let rm = VitalOsRequestManager(transport: t)
            let cr = VitalOsCommandRouter(transport: t, requestManager: rm, streamRouter: sr)

            self.transport = t
            self.streamRouter = sr
            self.requestManager = rm
            self.commandRouter = cr

            try await t.startListening()

            // 1. Settings plugin first
            do {
                await settingsPlugin.onDeviceConnected(device: self, router: cr, streamRouter: sr, requestManager: rm)
            } catch {
                logger.error("[\(self.id)] Settings plugin failed onDeviceConnected: \(error.localizedDescription)")
            }

            // 2. Set device clock
            do {
                try await settingsPlugin.setDeviceClock()
            } catch {
                logger.warning("[\(self.id)] setDeviceClock failed: \(error.localizedDescription)")
            }

            // 3. Fetch device info
            do {
                if let info = try await settingsPlugin.getDeviceInfo() {
                    let fw = info.firmwareVersion.isEmpty ? details.firmwareVersion : info.firmwareVersion
                    details = VitalOsDeviceDetails(
                        id: details.id,
                        name: details.name,
                        firmwareVersion: fw,
                        deviceModel: details.deviceModel,
                        color: Int(info.colorID),
                        rssi: details.rssi
                    )
                    logger.info("[\(self.id)] Device info: fw=\(info.firmwareVersion), sku=\(info.sku)")
                }
            } catch {
                logger.warning("[\(self.id)] getDeviceInfo failed: \(error.localizedDescription)")
            }

            // 4. User-provided plugins
            for plugin in pluginMap.values where plugin !== settingsPlugin {
                do {
                    if await plugin.isSupported(self) {
                        await plugin.onDeviceConnected(device: self, router: cr, streamRouter: sr, requestManager: rm)
                    } else {
                        logger.info("[\(self.id)] Plugin \(plugin.id) not supported, skipping")
                    }
                } catch {
                    logger.error("[\(self.id)] Plugin \(plugin.id) failed onDeviceConnected: \(error.localizedDescription)")
                }
            }

            // 5. Send environment
            if let env = environment, !env.isEmpty {
                do {
                    try await sendEnvironment(env, requestManager: rm)
                } catch {
                    logger.warning("[\(self.id)] Failed to send environment: \(error.localizedDescription)")
                }
            }

            isStackInitialized = true
            connectionState.send(.connected)
            logger.info("[\(self.id)] Connected and stack initialized")

            startObservingConnectionState()
        } catch {
            logger.error("[\(self.id)] Connection failed: \(error.localizedDescription)")
            await cleanupStack()
            connectionState.send(.disconnected)
            isExplicitlyConnecting = false
            if error is VitalOsError { throw error }
            throw VitalOsError.connectionFailed(error.localizedDescription, underlyingError: error)
        }

        isExplicitlyConnecting = false
    }

    private func startObservingConnectionState() {
        connectionStateTask?.cancel()
        connectionStateTask = Task { [weak self] in
            guard let self else { return }
            for await bleState in self.connectionProvider.connectionState(deviceId: self.id) {
                if bleState == .disconnected && !self.isExplicitlyConnecting && self.isStackInitialized {
                    self.logger.info("[\(self.id)] External disconnection detected")
                    await self.handleExternalDisconnect()
                }
            }
        }
    }

    private func handleExternalDisconnect() async {
        await cleanupStack()
        if !disposed {
            connectionState.send(.disconnected)
        }
    }

    func disconnect() async {
        logger.info("[\(self.id)] Disconnect requested")
        guard !isExplicitlyConnecting else {
            logger.warning("[\(self.id)] Disconnect called while connecting — ignoring")
            return
        }
        do {
            try await connectionProvider.disconnect(deviceId: id)
        } catch {
            logger.warning("[\(self.id)] Error during disconnect: \(error.localizedDescription)")
        }
        await cleanupStack()
        connectionState.send(.disconnected)
    }

    func unpair() async {
        logger.info("[\(self.id)] Unpairing")
        do {
            try await connectionProvider.removeBond(deviceId: id)
        } catch {
            logger.warning("[\(self.id)] Failed to remove bond: \(error.localizedDescription)")
        }
    }

    func dispose() async {
        guard !disposed else { return }
        disposed = true
        logger.debug("[\(self.id)] Disposing")
        await cleanupStack()
        connectionStateTask?.cancel()
        bondStateTask?.cancel()
        await settingsPlugin.dispose()
        for plugin in pluginMap.values where plugin !== settingsPlugin {
            await plugin.dispose()
        }
    }

    private func cleanupStack() async {
        logger.debug("[\(self.id)] Cleaning up protocol stack")
        await transport?.stopListening()

        if isStackInitialized {
            isStackInitialized = false
            commandRouter?.onDisconnection()
            commandRouter?.dispose()
            commandRouter = nil

            await settingsPlugin.onDeviceDisconnected(self)
            for plugin in pluginMap.values where plugin !== settingsPlugin {
                await plugin.onDeviceDisconnected(self)
            }

            streamRouter?.dispose()
            streamRouter = nil
            requestManager?.dispose()
            requestManager = nil
        } else {
            commandRouter?.dispose()
            commandRouter = nil
            streamRouter?.dispose()
            streamRouter = nil
            requestManager?.dispose()
            requestManager = nil
        }

        transport?.dispose()
        transport = nil
        connectionStateTask?.cancel()
        connectionStateTask = nil
    }

    func getPlugin<T: VitalOsPlugin>(_ type: T.Type) -> T? {
        pluginMap.values.first { $0 is T } as? T
    }

    func hasPlugin<T: VitalOsPlugin>(_ type: T.Type) -> Bool {
        pluginMap.values.contains { $0 is T }
    }

    private func sendEnvironment(_ env: String, requestManager: VitalOsRequestManager) async throws {
        var cmd = SetEnvironment()
        cmd.env = env
        try await requestManager.sendRequest(commandId: VitalOsCommand.sendEnvironmentData.rawValue, command: cmd)
    }
}
