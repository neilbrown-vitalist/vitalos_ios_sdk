import Foundation

/// Public API for the VitalOS Messaging plugin.
/// Handles the WatchRequest ↔ PhoneResponse protocol, including REST proxying.
public protocol MessagingPlugin: VitalOsPlugin {

    /// Registers a handler for raw messages with `message_key == endpoint`.
    func registerEndpoint(_ endpoint: String, handler: @escaping EndpointMessageHandler)

    /// Removes a handler previously registered with ``registerEndpoint(_:handler:)``.
    func unregisterEndpoint(_ endpoint: String)

    /// Sends a `PhoneRequest` to the watch on SEND_MESSAGE (0x0501) and waits for the
    /// corresponding `WatchResponse`.
    func sendMessage(_ request: PhoneRequest) async throws -> WatchResponse

    /// Register a REST endpoint.
    func registerRestEndpoint(_ endpoint: String)

    /// Registers a ``CredentialsProvider`` to supply auth tokens for REST requests.
    func setCredentialsProvider(_ provider: @escaping CredentialsProvider)

    /// Registers a handler for structured local requests from the watch.
    func registerLocalMessageHandler(_ handler: @escaping LocalMessageHandler)

    /// Registers a handler for raw messages from the watch.
    func registerRawMessageHandler(_ handler: @escaping RawMessageHandler)
}
