import Foundation

/// All command IDs exchanged between the phone app and the VitalOS device.
/// Values must exactly match the device firmware definitions.
public enum VitalOsCommand: Int, CaseIterable, Sendable {

    // MARK: 0x01XX — System
    case setDeviceClock         = 0x0101
    case findDevice             = 0x0102
    case getUserProfile         = 0x0103
    case setUserProfile         = 0x0104
    case sendEnvironmentData    = 0x0105
    case getDeviceInfo          = 0x0106

    // MARK: 0x02XX — Notifications
    case sendNotificationMessage        = 0x0201
    case removeNotification             = 0x0202
    case sendNotificationActionResponse = 0x0203
    case removeNotificationActions      = 0x0204
    case requestLocalNotification       = 0x0205

    // MARK: 0x03XX — Settings
    case updateSettingsConfig       = 0x0301
    case getSetting                 = 0x0302
    case updateSetting              = 0x0303
    case getUpdatedSettingsEntries  = 0x0304
    case getUpdatedSettingsValues   = 0x0305

    // MARK: 0x04XX — Feature Install
    case beginFeatureInstall    = 0x0401
    case startFeatureStream     = 0x0402
    case commitFeatureInstall   = 0x0403
    case abortFeatureInstall    = 0x0404
    case getAppList             = 0x0405
    case featureInstallProgress = 0x0406

    // MARK: 0x05XX — Messaging
    case sendMessage              = 0x0501
    case messageResponse          = 0x0502
    case startApiResponseStream   = 0x0503
    case startApiRequestStream    = 0x0504
    case startMessageUploadStream = 0x0505

    // MARK: 0x06XX — Stream Control
    case cancelStream       = 0x0601
    case endStream          = 0x0602
    case sendDataChunkAck   = 0x0603

    // MARK: 0x07XX — Health & Sleep
    case syncHealthData             = 0x0701
    case syncSleepData              = 0x0702
    case healthDataNotification     = 0x0703
    case sleepDataNotification      = 0x0704
    case syncSleepDataUpdatedSince  = 0x0705
    case healthSyncNotification     = 0x0706
    case sleepSyncNotification      = 0x0707

    // MARK: 0x08XX — Activity
    case activityNotification           = 0x0801
    case getActivityFile                = 0x0802
    case setGpsData                     = 0x0803
    case getActivitiesCompletedBetween  = 0x0804

    // MARK: 0x09XX — Calendar
    case syncCalendarEvents     = 0x0901
    case requestCalendarSync    = 0x0902

    // MARK: 0x0AXX — Weather
    case syncWeatherHourlyForecast  = 0x0A01
    case syncWeatherDailyForecast   = 0x0A02
    case requestWeatherSync         = 0x0A03

    // MARK: 0x0BXX — Firmware
    case firmwareUpgradeNotification = 0x0B01
    case startFirmwareUpgrade        = 0x0B02
    case cancelFirmwareUpgrade       = 0x0B03

    // MARK: 0xFFXX — Debug
    case takeScreenshot     = 0xFF01
    case powerOff           = 0xFF02
    case enterDfu           = 0xFF03
    case setUsbStorage      = 0xFF04
    case handleGesture      = 0xFF05
    case prepareOta         = 0xFF06
    case getLogFileList     = 0xFF10
    case getLogFile         = 0xFF11
    case deleteLogFile      = 0xFF12
    case logFileCompleted   = 0xFF13

    // MARK: Lookup

    private static let byValue: [Int: VitalOsCommand] = {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.rawValue, $0) })
    }()

    public static func fromValue(_ value: Int) -> VitalOsCommand? {
        byValue[value]
    }
}
