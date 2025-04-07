import Logging

import struct Foundation.Data
import struct Foundation.Date
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

/// Model Context Protocol server
public actor Server {
    /// The server configuration
    public struct Configuration: Hashable, Codable, Sendable {
        /// The default configuration.
        public static let `default` = Configuration(strict: false)

        /// The strict configuration.
        public static let strict = Configuration(strict: true)

        /// When strict mode is enabled, the server:
        /// - Requires clients to send an initialize request before any other requests
        /// - Rejects all requests from uninitialized clients with a protocol error
        ///
        /// While the MCP specification requires clients to initialize the connection
        /// before sending other requests, some implementations may not follow this.
        /// Disabling strict mode allows the server to be more lenient with non-compliant
        /// clients, though this may lead to undefined behavior.
        public var strict: Bool
    }

    /// Implementation information
    public struct Info: Hashable, Codable, Sendable {
        /// The server name
        public let name: String
        /// The server version
        public let version: String

        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }
    }

    /// Server capabilities
    public struct Capabilities: Hashable, Codable, Sendable {
        /// Resources capabilities
        public struct Resources: Hashable, Codable, Sendable {
            /// Whether the resource can be subscribed to
            public var subscribe: Bool?
            /// Whether the list of resources has changed
            public var listChanged: Bool?

            public init(
                subscribe: Bool? = nil,
                listChanged: Bool? = nil
            ) {
                self.subscribe = subscribe
                self.listChanged = listChanged
            }
        }

        /// Tools capabilities
        public struct Tools: Hashable, Codable, Sendable {
            /// Whether the server notifies clients when tools change
            public var listChanged: Bool?

            public init(listChanged: Bool? = nil) {
                self.listChanged = listChanged
            }
        }

        /// Prompts capabilities
        public struct Prompts: Hashable, Codable, Sendable {
            /// Whether the server notifies clients when prompts change
            public var listChanged: Bool?

            public init(listChanged: Bool? = nil) {
                self.listChanged = listChanged
            }
        }

        /// Logging capabilities
        public struct Logging: Hashable, Codable, Sendable {
            public init() {}
        }

        /// Logging capabilities
        public var logging: Logging?
        /// Prompts capabilities
        public var prompts: Prompts?
        /// Resources capabilities
        public var resources: Resources?
        /// Tools capabilities
        public var tools: Tools?

        public init(
            logging: Logging? = nil,
            prompts: Prompts? = nil,
            resources: Resources? = nil,
            tools: Tools? = nil
        ) {
            self.logging = logging
            self.prompts = prompts
            self.resources = resources
            self.tools = tools
        }
    }

    /// Server information
    private let serverInfo: Server.Info
    /// The server connection
    private var connection: (any Transport)?
    /// The server logger
    private var logger: Logger? {
        get async {
            await connection?.logger
        }
    }

    /// The server name
    public nonisolated var name: String { serverInfo.name }
    /// The server version
    public nonisolated var version: String { serverInfo.version }
    /// The server capabilities
    public var capabilities: Capabilities
    /// The server configuration
    public var configuration: Configuration

    /// Request handlers
    private var methodHandlers: [String: RequestHandlerBox] = [:]
    /// Notification handlers
    private var notificationHandlers: [String: [NotificationHandlerBox]] = [:]

    /// Whether the server is initialized
    private var isInitialized = false
    /// The client information
    private var clientInfo: Client.Info?
    /// The client capabilities
    private var clientCapabilities: Client.Capabilities?
    /// The protocol version
    private var protocolVersion: String?
    /// The list of subscriptions
    private var subscriptions: [String: Set<ID>] = [:]
    /// The task for the message handling loop
    private var task: Task<Void, Never>?

    public init(
        name: String,
        version: String,
        capabilities: Server.Capabilities = .init(),
        configuration: Configuration = .default
    ) {
        self.serverInfo = Server.Info(name: name, version: version)
        self.capabilities = capabilities
        self.configuration = configuration
    }

    /// Start the server
    /// - Parameters:
    ///   - transport: The transport to use for the server
    ///   - initializeHook: An optional hook that runs when the client sends an initialize request
    public func start(
        transport: any Transport,
        initializeHook: (@Sendable (Client.Info, Client.Capabilities) async throws -> Void)? = nil
    ) async throws {
        self.connection = transport
        registerDefaultHandlers(initializeHook: initializeHook)
        try await transport.connect()

        await logger?.info(
            "Server started", metadata: ["name": "\(name)", "version": "\(version)"])

        // Start message handling loop
        task = Task {
            do {
                let stream = await transport.receive()
                for try await data in stream {
                    if Task.isCancelled { break }  // Check cancellation inside loop

                    var requestID: ID?
                    do {
                        // Attempt to decode string data as AnyRequest or AnyMessage
                        let decoder = JSONDecoder()
                        if let request = try? decoder.decode(AnyRequest.self, from: data) {
                            try await handleRequest(request)
                        } else if let message = try? decoder.decode(AnyMessage.self, from: data) {
                            try await handleMessage(message)
                        } else {
                            // Try to extract request ID from raw JSON if possible
                            if let json = try? JSONDecoder().decode(
                                [String: Value].self, from: data),
                                let idValue = json["id"]
                            {
                                if let strValue = idValue.stringValue {
                                    requestID = .string(strValue)
                                } else if let intValue = idValue.intValue {
                                    requestID = .number(intValue)
                                }
                            }
                            throw MCPError.parseError("Invalid message format")
                        }
                    } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                        // Resource temporarily unavailable, retry after a short delay
                        try? await Task.sleep(for: .milliseconds(10))
                        continue
                    } catch {
                        await logger?.error(
                            "Error processing message", metadata: ["error": "\(error)"])
                        let response = AnyMethod.response(
                            id: requestID ?? .random,
                            error: error as? MCPError
                                ?? MCPError.internalError(error.localizedDescription)
                        )
                        try? await send(response)
                    }
                }
            } catch {
                await logger?.error(
                    "Fatal error in message handling loop", metadata: ["error": "\(error)"])
            }
            await logger?.info("Server finished", metadata: [:])
        }
    }

    /// Stop the server
    public func stop() async {
        task?.cancel()
        task = nil
        if let connection = connection {
            await connection.disconnect()
        }
        connection = nil
    }

    public func waitUntilCompleted() async {
        await task?.value
    }

    // MARK: - Registration

    /// Register a method handler
    @discardableResult
    public func withMethodHandler<M: Method>(
        _ type: M.Type,
        handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
    ) -> Self {
        methodHandlers[M.name] = TypedRequestHandler { (request: Request<M>) -> Response<M> in
            let result = try await handler(request.params)
            return Response(id: request.id, result: result)
        }
        return self
    }

    /// Register a notification handler
    @discardableResult
    public func onNotification<N: Notification>(
        _ type: N.Type,
        handler: @escaping @Sendable (Message<N>) async throws -> Void
    ) -> Self {
        let handlers = notificationHandlers[N.name, default: []]
        notificationHandlers[N.name] = handlers + [TypedNotificationHandler(handler)]
        return self
    }

    // MARK: - Sending

    /// Send a response to a request
    public func send<M: Method>(_ response: Response<M>) async throws {
        guard let connection = connection else {
            throw MCPError.internalError("Server connection not initialized")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let responseData = try encoder.encode(response)
        try await connection.send(responseData)
    }

    /// Send a notification to connected clients
    public func notify<N: Notification>(_ notification: Message<N>) async throws {
        guard let connection = connection else {
            throw MCPError.internalError("Server connection not initialized")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let notificationData = try encoder.encode(notification)
        try await connection.send(notificationData)
    }

    // MARK: -

    private func handleRequest(_ request: Request<AnyMethod>) async throws {
        await logger?.debug(
            "Processing request",
            metadata: [
                "method": "\(request.method)",
                "id": "\(request.id)",
            ])

        if configuration.strict {
            // The client SHOULD NOT send requests other than pings
            // before the server has responded to the initialize request.
            switch request.method {
            case Initialize.name, Ping.name:
                break
            default:
                try checkInitialized()
            }
        }

        // Find handler for method name
        guard let handler = methodHandlers[request.method] else {
            let error = MCPError.methodNotFound("Unknown method: \(request.method)")
            let response = AnyMethod.response(id: request.id, error: error)
            try await send(response)
            throw error
        }

        do {
            // Handle request and get response
            let response = try await handler(request)
            try await send(response)
        } catch {
            let mcpError = error as? MCPError ?? MCPError.internalError(error.localizedDescription)
            let response = AnyMethod.response(id: request.id, error: mcpError)
            try await send(response)
            throw error
        }
    }

    private func handleMessage(_ message: Message<AnyNotification>) async throws {
        await logger?.debug(
            "Processing notification",
            metadata: ["method": "\(message.method)"])

        if configuration.strict {
            // Check initialization state unless this is an initialized notification
            if message.method != InitializedNotification.name {
                try checkInitialized()
            }
        }

        // Find notification handlers for this method
        guard let handlers = notificationHandlers[message.method] else { return }

        // Convert notification parameters to concrete type and call handlers
        for handler in handlers {
            do {
                try await handler(message)
            } catch {
                await logger?.error(
                    "Error handling notification",
                    metadata: [
                        "method": "\(message.method)",
                        "error": "\(error)",
                    ])
            }
        }
    }

    private func checkInitialized() throws {
        guard isInitialized else {
            throw MCPError.invalidRequest("Server is not initialized")
        }
    }

    private func registerDefaultHandlers(
        initializeHook: (@Sendable (Client.Info, Client.Capabilities) async throws -> Void)?
    ) {
        // Initialize
        withMethodHandler(Initialize.self) { [weak self] params in
            guard let self = self else {
                throw MCPError.internalError("Server was deallocated")
            }

            guard await !self.isInitialized else {
                throw MCPError.invalidRequest("Server is already initialized")
            }

            // Validate protocol version
            guard Version.latest == params.protocolVersion else {
                throw MCPError.invalidRequest(
                    "Unsupported protocol version: \(params.protocolVersion)")
            }

            // Call initialization hook if registered
            if let hook = initializeHook {
                try await hook(params.clientInfo, params.capabilities)
            }

            // Set initial state
            await self.setInitialState(
                clientInfo: params.clientInfo,
                clientCapabilities: params.capabilities,
                protocolVersion: params.protocolVersion
            )

            // Send initialized notification after a short delay
            Task {
                try? await Task.sleep(for: .milliseconds(10))
                try? await self.notify(InitializedNotification.message())
            }

            return Initialize.Result(
                protocolVersion: Version.latest,
                capabilities: await self.capabilities,
                serverInfo: self.serverInfo,
                instructions: nil
            )
        }

        // Ping
        withMethodHandler(Ping.self) { _ in return Empty() }
    }

    private func setInitialState(
        clientInfo: Client.Info,
        clientCapabilities: Client.Capabilities,
        protocolVersion: String
    ) async {
        self.clientInfo = clientInfo
        self.clientCapabilities = clientCapabilities
        self.protocolVersion = protocolVersion
        self.isInitialized = true
    }
}
