import Foundation
import SwiftProtobuf
import os

/// Handles incoming `WatchRequest` messages from the watch (command ID 0x0501).
///
/// Mirrors the Flutter/Android `WatchRequestCommandHandler`: builds a `PhoneResponse`, wraps it
/// inside `CommandResponse.payload`, and returns the `CommandResponse` so the router sends
/// it as the RESPONSE packet.
final class WatchRequestCommandHandler: FeatureCommandHandler, @unchecked Sendable {

    private let logger = Logger(subsystem: "co.vitalos.sdk", category: "WatchRequestHandler")

    let commandId: Int
    private let credentialsProvider: CredentialsProvider?
    private let localMessageHandler: LocalMessageHandler?
    private let rawMessageHandler: RawMessageHandler?
    private let endpointHandlers: [String: EndpointMessageHandler]
    private let registeredEndpoints: Set<String>

    init(
        commandId: Int,
        credentialsProvider: CredentialsProvider?,
        localMessageHandler: LocalMessageHandler?,
        rawMessageHandler: RawMessageHandler?,
        endpointHandlers: [String: EndpointMessageHandler],
        registeredEndpoints: Set<String>
    ) {
        self.commandId = commandId
        self.credentialsProvider = credentialsProvider
        self.localMessageHandler = localMessageHandler
        self.rawMessageHandler = rawMessageHandler
        self.endpointHandlers = endpointHandlers
        self.registeredEndpoints = registeredEndpoints
    }

    func handle(payload: Data) async -> CommandResponse? {
        let watchRequest: WatchRequest
        do {
            watchRequest = try WatchRequest(serializedBytes: payload)
        } catch {
            logger.error("Failed to parse WatchRequest: \(error.localizedDescription)")
            var r = CommandResponse()
            r.success = false
            r.errorCode = .unknownError
            r.errorMessage = "Failed to parse WatchRequest: \(error.localizedDescription)"
            return r
        }

        let phoneResponse: PhoneResponse
        switch watchRequest.requestType {
        case .rest:
            phoneResponse = await handleRestRequest(watchRequest)
        case .local:
            phoneResponse = await handleLocalRequest(watchRequest)
        case .raw:
            phoneResponse = await handleRawRequest(watchRequest)
        case .none:
            phoneResponse = buildErrorResponse(requestId: watchRequest.requestID, message: "Unknown request type")
        }

        var commandResponse = CommandResponse()
        commandResponse.success = true
        commandResponse.payload = try! phoneResponse.serializedData()
        return commandResponse
    }

    // MARK: - Request handlers

    private func handleRestRequest(_ watchRequest: WatchRequest) async -> PhoneResponse {
        let rest = watchRequest.rest
        logger.debug("Processing REST request: \(rest.method.rawValue) \(rest.url)")

        if !registeredEndpoints.isEmpty && !registeredEndpoints.contains(where: { rest.url.contains($0) }) {
            logger.warning("Endpoint \(rest.url) not registered")
            return buildErrorResponse(requestId: watchRequest.requestID, message: "Endpoint not registered")
        }

        guard let url = URL(string: rest.url) else {
            return buildErrorResponse(requestId: watchRequest.requestID, message: "Invalid URL: \(rest.url)")
        }

        var urlRequest = URLRequest(url: url)
        let method: String
        switch rest.method {
        case .get:    method = "GET"
        case .post:   method = "POST"
        case .put:    method = "PUT"
        case .delete: method = "DELETE"
        case .patch:  method = "PATCH"
        default:      method = "GET"
        }
        urlRequest.httpMethod = method

        for (key, value) in rest.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        if rest.useAppAuth, let provider = credentialsProvider {
            if let auth = await provider() {
                urlRequest.setValue(auth, forHTTPHeaderField: "Authorization")
            }
        }

        if method != "GET" && method != "DELETE" && !rest.body.isEmpty {
            let bodyString = rest.body.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
            urlRequest.httpBody = bodyString.data(using: .utf8)
            urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            let httpResponse = response as? HTTPURLResponse
            var phoneResponse = PhoneResponse()
            phoneResponse.originalRequestID = watchRequest.requestID
            phoneResponse.success = (200..<300).contains(httpResponse?.statusCode ?? 0)
            phoneResponse.directPayload = data
            return phoneResponse
        } catch {
            return buildErrorResponse(requestId: watchRequest.requestID, message: "HTTP request failed: \(error.localizedDescription)")
        }
    }

    private func handleLocalRequest(_ watchRequest: WatchRequest) async -> PhoneResponse {
        let localRequest = watchRequest.local.request
        guard let handler = localMessageHandler else {
            logger.warning("No local message handler registered")
            return buildErrorResponse(requestId: watchRequest.requestID, message: "No local message handler registered")
        }
        let localResponse = await handler(localRequest)
        var phoneResponse = PhoneResponse()
        phoneResponse.originalRequestID = watchRequest.requestID
        phoneResponse.success = true
        phoneResponse.localResponse = localResponse
        return phoneResponse
    }

    private func handleRawRequest(_ watchRequest: WatchRequest) async -> PhoneResponse {
        let raw = watchRequest.raw
        if let endpointHandler = endpointHandlers[raw.messageKey] {
            let responseBytes = await endpointHandler(watchRequest.requestID, raw.payload)
            var phoneResponse = PhoneResponse()
            phoneResponse.originalRequestID = watchRequest.requestID
            phoneResponse.success = true
            if let responseBytes { phoneResponse.directPayload = responseBytes }
            return phoneResponse
        }
        if let handler = rawMessageHandler {
            let responsePayload = await handler(raw.messageKey, raw.payload)
            var phoneResponse = PhoneResponse()
            phoneResponse.originalRequestID = watchRequest.requestID
            phoneResponse.success = true
            if let responsePayload { phoneResponse.directPayload = responsePayload }
            return phoneResponse
        }
        logger.warning("No raw message handler registered for key: \(raw.messageKey)")
        return buildErrorResponse(requestId: watchRequest.requestID, message: "No raw message handler")
    }

    // MARK: - Helpers

    private func buildErrorResponse(requestId: String, message: String) -> PhoneResponse {
        var response = PhoneResponse()
        response.originalRequestID = requestId
        response.success = false
        response.errorMessage = message
        return response
    }
}
