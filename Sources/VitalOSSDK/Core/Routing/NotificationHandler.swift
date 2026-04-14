import Foundation

/// Handles an incoming command from the device that requires no response.
/// Register instances via ``CommandRouter/registerNotificationHandler(commandId:factory:)``.
public protocol NotificationHandler: AnyObject {
    func handle(payload: Data) async
}
