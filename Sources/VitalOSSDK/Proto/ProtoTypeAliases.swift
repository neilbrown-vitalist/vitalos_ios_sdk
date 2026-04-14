import Foundation
import SwiftProtobuf

// MARK: - Convenient typealiases for generated protobuf types
// Generated types use `VitalOSProtocol_` prefix from the proto package.
// These typealiases provide a cleaner API surface.

// vital_os.proto
public typealias CommandResponse = VitalOSProtocol_CommandResponse
public typealias VitalOSErrorCode = VitalOSProtocol_VitalOSErrorCode
public typealias SetEnvironment = VitalOSProtocol_SetEnvironment
public typealias GetDeviceInfoRequest = VitalOSProtocol_GetDeviceInfoRequest
public typealias DeviceInfo = VitalOSProtocol_DeviceInfo
public typealias GetUserProfileRequest = VitalOSProtocol_GetUserProfileRequest
public typealias UserProfile = VitalOSProtocol_UserProfile
public typealias ProtoEmpty = VitalOSProtocol_Empty

// settings.proto
public typealias SetTime = VitalOSProtocol_SetTime

// settings_configuration.proto
public typealias SettingsEntry = VitalOSProtocol_SettingsEntry
public typealias SettingsValue = VitalOSProtocol_SettingsValue

// messaging.proto
public typealias WatchRequest = VitalOSProtocol_WatchRequest
public typealias PhoneResponse = VitalOSProtocol_PhoneResponse
public typealias PhoneRequest = VitalOSProtocol_PhoneRequest
public typealias WatchResponse = VitalOSProtocol_WatchResponse
public typealias RawMessage = VitalOSProtocol_RawMessage
public typealias RestMessage = VitalOSProtocol_RestMessage
public typealias LocalMessage = VitalOSProtocol_LocalMessage

// health.proto
public typealias HealthSyncRequest = VitalOSProtocol_HealthSyncRequest
public typealias HealthDataUpload = VitalOSProtocol_HealthDataUpload
public typealias HealthSyncNotification = VitalOSProtocol_HealthSyncNotification
public typealias HealthDataNotification = VitalOSProtocol_HealthDataNotification

// sleep.proto
public typealias SleepSyncRequest = VitalOSProtocol_SleepSyncRequest
public typealias SleepUpdatedSinceRequest = VitalOSProtocol_SleepUpdatedSinceRequest
public typealias SleepDay = VitalOSProtocol_SleepDay
public typealias SleepDaySyncPayload = VitalOSProtocol_SleepDaySyncPayload
public typealias SleepSyncNotification = VitalOSProtocol_SleepSyncNotification
public typealias SleepDataNotification = VitalOSProtocol_SleepDataNotification

// streaming.proto
public typealias StreamDataChunk = VitalOSProtocol_StreamDataChunk
public typealias StreamDataChunkAck = VitalOSProtocol_StreamDataChunkAck
public typealias EndStream = VitalOSProtocol_EndStream
public typealias CancelStream = VitalOSProtocol_CancelStream
public typealias CancelReason = VitalOSProtocol_CancelReason

// local_messages.proto
public typealias LocalRequest = VitalOSProtocol_LocalRequest
public typealias LocalResponse = VitalOSProtocol_LocalResponse
