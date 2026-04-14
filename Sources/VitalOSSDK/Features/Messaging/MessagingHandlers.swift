import Foundation

/// Handles a raw message for a specific message key registered via
/// ``MessagingPlugin/registerEndpoint(_:handler:)``.
public typealias EndpointMessageHandler = @Sendable (_ requestId: String, _ payload: Data) async -> Data?

/// Supplies authentication credentials for proxied REST requests.
public typealias CredentialsProvider = @Sendable () async -> String?

/// Handles a raw (key-value bytes) message received from the watch.
public typealias RawMessageHandler = @Sendable (_ messageKey: String, _ payload: Data) async -> Data?

/// Handles a structured local request received from the watch.
public typealias LocalMessageHandler = @Sendable (_ request: LocalRequest) async -> LocalResponse
