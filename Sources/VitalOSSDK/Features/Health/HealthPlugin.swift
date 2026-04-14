import Foundation
import Combine

/// Public API for the VitalOS Health plugin.
/// Provides access to health and sleep data synchronisation from the device.
public protocol HealthPlugin: VitalOsPlugin {

    /// Emits a notification whenever the device has new health data available.
    var healthDataNotifications: AnyPublisher<HealthDataNotification, Never> { get }

    /// Emits a notification whenever the device has new sleep data available.
    var sleepDataNotifications: AnyPublisher<SleepDataNotification, Never> { get }

    /// Fetches aggregated health records from the device for the given time range.
    func getHealthData(from: Date, to: Date) async throws -> [HealthDataUpload]

    /// Fetches sleep data from the device for the given time range.
    func getSleepData(from: Date, to: Date) async throws -> [SleepDay]

    /// Fetches sleep data that has been updated since the given date.
    func getSleepDataUpdatedSince(_ updatedSince: Date) async throws -> [SleepDay]
}
