# VitalOS iOS SDK

Native Swift SDK for communicating with VitalOS devices over Bluetooth Low Energy.

## Package Structure

| Target | Description |
|---|---|
| `VitalOSSDK` | Core library: protocol types, packet framing, routing, plugins, device API |
| `VitalOSBLE` | CoreBluetooth implementation of `BleTransport` / `BleConnectionProvider` |

## Requirements

- iOS 15.0+ / macOS 12.0+
- Xcode 15+
- Swift 5.9+

## Installation

Add the package as a local dependency or via Git URL:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/your-org/vitalos-ios.git", from: "0.0.1"),
]
```

Or in Xcode: **File → Add Package Dependencies** and enter the repository URL.

## Quick Start

```swift
import VitalOSSDK
import VitalOSBLE

// 1. Create a connection provider
let connectionProvider = CoreBluetoothConnectionProvider()

// 2. Register discovered peripherals (from your CBCentralManager scan)
connectionProvider.register(peripheral: discoveredPeripheral)

// 3. Create plugins
let messaging = VitalOsMessagingPlugin()
let health = VitalOsHealthPlugin()

// 4. Create a device
let device = VitalOsDeviceImpl(
    connectionProvider: connectionProvider,
    id: peripheral.identifier.uuidString,
    initialName: peripheral.name ?? "VitalOS",
    plugins: [messaging, health],
    environment: nil
)

// 5. Connect
try await device.connect()

// 6. Sync health data
let uploads = try await health.getHealthData(from: sevenDaysAgo, to: Date())
let records = uploads.flatMap { $0.records }

// 7. Sync sleep data
let days = try await health.getSleepData(from: sevenDaysAgo, to: Date())
```

## Architecture

The SDK mirrors the Android SDK's layered architecture:

```
Consumer App
    ↓
VitalOsDevice (connect, plugins)
    ↓
CommandRouter / RequestManager / StreamRouter
    ↓
VitalOsTransportLayer (Packetizer ↔ Reassembler)
    ↓
BleTransport protocol
    ↓
CoreBluetoothTransport (VitalOSBLE target)
```

### Plugins

| Plugin | Description |
|---|---|
| `SettingsPlugin` | Built-in. Clock sync, device info, user profile, settings. |
| `MessagingPlugin` | REST proxying, local messages, raw endpoint routing. |
| `HealthPlugin` | Health and sleep data synchronisation. |

### Custom BLE Implementation

To use your own BLE library, implement `BleConnectionProvider` and `BleTransport` — the core SDK has no CoreBluetooth dependency.

## Sample App

The `VitalOSSampleApp/` directory contains a SwiftUI sample app that demonstrates scanning, connecting, and syncing health/sleep data. To use it, create an Xcode project that includes the sample app files and adds `VitalOSSDK` and `VitalOSBLE` as local package dependencies.

## Protobuf

Proto source files are in `Proto/`. Generated Swift types are checked in at `Sources/VitalOSSDK/Proto/`. To regenerate:

```bash
brew install swift-protobuf
protoc --swift_out=Sources/VitalOSSDK/Proto/ --swift_opt=Visibility=Public --proto_path=Proto/ Proto/*.proto
```
