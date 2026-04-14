import Foundation

/// The central hub that routes all incoming messages to the correct handler.
public protocol CommandRouter: AnyObject {
    func registerHandler(commandId: Int, factory: @escaping @Sendable () -> FeatureCommandHandler)
    func registerNotificationHandler(commandId: Int, factory: @escaping @Sendable () -> NotificationHandler)
    func onDisconnection()
    func dispose()
}
