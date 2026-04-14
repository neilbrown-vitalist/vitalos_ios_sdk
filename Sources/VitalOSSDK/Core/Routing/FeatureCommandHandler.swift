import Foundation
import SwiftProtobuf

/// Handles an incoming command from the device that expects a response.
/// Register instances via ``CommandRouter/registerHandler(commandId:factory:)``.
public protocol FeatureCommandHandler: AnyObject {
    var commandId: Int { get }

    /// Handles the command and optionally returns a `CommandResponse` to send back.
    /// Return `nil` to send no response.
    func handle(payload: Data) async -> CommandResponse?
}
