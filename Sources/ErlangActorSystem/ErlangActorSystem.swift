import CErlInterface
import Distributed
import Synchronization
#if canImport(Glibc)
import Glibc
#endif

/// An actor system manages an Erlang C node, which can contain many processes
/// (actors).
public final class ErlangActorSystem: DistributedActorSystem, @unchecked Sendable {
    /// Info about the current message being handled by the actor system.
    ///
    /// This value is only set inside of distributed functions/accessors.
    @TaskLocal
    public static var messageInfo: Message.Info?
    
    /// The resolved node name.
    public var name: String {
        transport.name
    }
    
    /// The connection cookie set on this actor system.
    public var cookie: String {
        transport.cookie
    }
    
    var transport: any Transport
    
    private(set) var port: Int = 0
    
    private let processes = Mutex<[ActorID:any DistributedActor]>([:])
    private(set) var registeredNames = [String:ActorID]()
    
    let remoteNodes = Mutex<[String:(any Transport).AcceptSocket]>([:])
    private let remoteNodeReceiveLoops = Mutex<[(any Transport).AcceptSocket:Task<Void, Never>]>([:])
    
    private(set) var nodesMonitors = Set<ActorID>()
    
    private func nodeReady(_ node: (any Transport).AcceptSocket, name: String) async {
        self.remoteNodes.withLock {
            $0[name] = node
        }
        self.remoteNodeReceiveLoops.withLock {
            $0[node] = Task { [weak self] in
                while true {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    do {
                        switch try self.transport.receive(on: node) {
                        case .tick:
                            continue
                        case let .success(message):
                            try! await self.handleMessage(socket: node, message: message)
                        }
                    } catch {
                        continue
                    }
                }
            }
        }
        let monitors = self.processes.withLock { processes in
            nodesMonitors.compactMap({ monitor in
                processes[monitor] as? any NodesMonitor
            })
        }
        for monitor in monitors {
            await monitor.whenLocal { actor in
                actor.up(name)
            }
        }
    }
    
    public var pid: Term.PID {
        transport.pid
    }
    
    var acceptTask: Task<(), Never>?
    
    private var registerContinuation: CheckedContinuation<Void, any Error>?
    
    private let remoteCallContinuations = Mutex<[RemoteCallContinuation]>([])
    struct RemoteCallContinuation {
        let adapter: any ContinuationAdapter
        let continuation: CheckedContinuation<ErlangTermBuffer, any Error>
    }
    
    /// The ``RemoteCallAdapter`` to use for actors that don't specify their own.
    public let remoteCallAdapter: any RemoteCallAdapter
    
    /// Create an actor system with a short node name.
    public init(
        name: String,
        cookie: String,
        remoteCallAdapter: any RemoteCallAdapter = GenServerRemoteCallAdapter(),
        transport: any Transport = ErlInterfaceTransport()
    ) async throws {
        self.remoteCallAdapter = remoteCallAdapter
        
        self.transport = transport
        try await self.transport.setup(name: name, cookie: cookie)
        
        let (listen, port) = try await self.transport.listen(port: self.port)
        self.port = port
        
        try? await self.transport.publish(port: port)
        
        acceptTask = Task { [weak self] in
            while true {
                guard !Task.isCancelled else { return }
                guard let self else { continue }
                guard let (accept, nodeName) = try? await self.transport.accept(from: listen)
                else { continue }
                await self.nodeReady(accept, name: nodeName)
            }
        }
    }
    
    /// Create an actor system with a full name and IP address.
    public init(
        hostName: String,
        aliveName: String,
        nodeName: String,
        ipAddress: String,
        cookie: String,
        remoteCallAdapter: any RemoteCallAdapter = GenServerRemoteCallAdapter(),
        transport: any Transport = ErlInterfaceTransport()
    ) async throws {
        self.remoteCallAdapter = remoteCallAdapter
        
        self.transport = transport
        try await self.transport.setup(hostName: hostName, aliveName: aliveName, nodeName: nodeName, ipAddress: ipAddress, cookie: cookie)
        
        let (listen, port) = try await self.transport.listen(port: self.port)
        self.port = port
        
        try await self.transport.publish(port: port)
        
        acceptTask = Task { [weak self] in
            while true {
                guard !Task.isCancelled else { return }
                guard let self else { continue }
                guard let (accept, nodeName) = try? await self.transport.accept(from: listen)
                else { continue }
                await self.nodeReady(accept, name: nodeName)
            }
        }
    }
    
    deinit {
        self.acceptTask?.cancel()
        remoteNodeReceiveLoops.withLock {
            for task in $0.values {
                task.cancel()
            }
        }
    }
    
    /// Register a name for an actor.
    ///
    /// The actor system will forward messages for this name to the provided actor.
    public func register<Act: DistributedActor>(
        _ actor: Act,
        name: String
    ) where Act.ID == ActorID {
        registeredNames[name] = actor.id
    }
    
    private func pid(for id: ActorID) -> Term.PID {
        switch id {
        case let .pid(pid):
            return pid
        case .name:
            fatalError("Cannot resolve PID for remote node")
        }
    }
    
    /// The unique identifier for an actor.
    public enum ActorID: Hashable, Sendable, Codable, CustomDebugStringConvertible {
        case pid(Term.PID)
        case name(String, node: String)
        
        func encode(to buffer: ErlangTermBuffer) {
            switch self {
            case var .pid(pid):
                buffer.encode(pid: &pid.pid)
            case let .name(name, nodeName):
                buffer.encode(tupleHeader: 2)
                _ = name.withCString { name in
                    buffer.encode(atom: name)
                }
                _ = nodeName.withCString { nodeName in
                    buffer.encode(atom: nodeName)
                }
            }
        }
        
        public var debugDescription: String {
            switch self {
            case let .pid(pid):
                let buffer = ErlangTermBuffer()
                
                var pid = pid.pid
                buffer.encode(pid: &pid)
                
                return """
                pid(\(buffer.debugDescription))
                """
            case let .name(name, node):
                return "name(\(name), node: \(node))"
            }
        }
        
        public func encode(to encoder: any Encoder) throws {
            switch self {
            case let .pid(pid):
                var container = encoder.singleValueContainer()
                try container.encode(pid)
            case let .name(name, node):
                let context = encoder.userInfo[.termEncoderContext] as! TermEncoder.Context
                let oldStrategy = context.unkeyedContainerEncodingStrategy
                
                context.unkeyedContainerEncodingStrategy = .tuple
                
                var container = encoder.unkeyedContainer()
                
                context.unkeyedContainerEncodingStrategy = oldStrategy
                
                let oldStringStrategy = context.stringEncodingStrategy
                context.stringEncodingStrategy = .atom
                try container.encode(name)
                try container.encode(node)
                context.stringEncodingStrategy = oldStringStrategy
            }
        }
        
        public init(from decoder: any Decoder) throws {
            if let pid = try? decoder.singleValueContainer().decode(Term.PID.self) {
                self = .pid(pid)
            } else { // {name, node}
                var container = try decoder.unkeyedContainer()
                self = try .name(container.decode(String.self), node: container.decode(String.self))
            }
        }
    }
    
    public typealias SerializationRequirement = any Codable
    
    public struct InvocationEncoder: DistributedTargetInvocationEncoder {
        public typealias SerializationRequirement = any Codable
        
        let encoder: TermEncoder
        private(set) var arguments = [RemoteCallArgument<any Codable>]()
        
        init(encoder: TermEncoder) {
            self.encoder = encoder
        }
        
        public mutating func recordArgument<Value: Codable>(_ argument: RemoteCallArgument<Value>) throws {
            arguments.append(RemoteCallArgument(
                label: argument.label,
                name: argument.name,
                value: argument.value
            ))
        }
        
        public mutating func recordErrorType<E>(_ type: E.Type) throws where E : Error {
        }
        
        public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {
        }
        
        public mutating func recordReturnType<R: Codable>(_ type: R.Type) throws {
        }
        
        public mutating func doneRecording() throws {}
    }
    
    public struct InvocationDecoder: DistributedTargetInvocationDecoder {
        public typealias SerializationRequirement = Codable
        
        let buffer: ErlangTermBuffer
        let decoder: TermDecoder
        var index: Int32
        
        public init(buffer: ErlangTermBuffer, decoder: TermDecoder, index: Int32) {
            self.buffer = buffer
            self.decoder = decoder
            self.index = index
        }
        
        public mutating func decodeNextArgument<Argument: Codable>() throws -> Argument {
            defer { buffer.skipTerm(index: &index) }
            return try decoder.decode(Argument.self, from: buffer, startIndex: index)
        }
        
        public mutating func decodeGenericSubstitutions() throws -> [any Any.Type] {
            []
        }
        
        public mutating func decodeErrorType() throws -> (any Any.Type)? {
            nil
        }
        
        public mutating func decodeReturnType() throws -> (any Any.Type)? {
            nil
        }
    }
    
    public struct ResultHandler: DistributedTargetInvocationResultHandler {
        public typealias SerializationRequirement = any Codable
        
        let sender: Term.PID?
        let resultHandlerAdapter: (any ResultHandlerAdapter)?
        let transport: any Transport
        let socket: (any Transport).AcceptSocket
        
        public init(
            sender: Term.PID?,
            resultHandlerAdapter: (any ResultHandlerAdapter)?,
            transport: (any Transport),
            socket: (any Transport).AcceptSocket
        ) {
            self.sender = sender
            self.resultHandlerAdapter = resultHandlerAdapter
            self.transport = transport
            self.socket = socket
        }
        
        public func onReturn<Success: Codable>(value: Success) async throws {
            guard let sender,
                  let resultHandlerAdapter
            else { return }
            
            let encoder = TermEncoder()
            encoder.includeVersion = false
            let value = try encoder.encode(value)
            
            let buffer = try resultHandlerAdapter.encode(returning: value)
            
            try await transport.send(
                .init(content: buffer, recipient: .pid(sender)),
                on: socket
            )
        }
        
        public func onReturnVoid() async throws {
            guard let sender,
                  let resultHandlerAdapter
            else { return }
            
            let buffer = try resultHandlerAdapter.encodeVoid()
            
            try await transport.send(
                .init(content: buffer, recipient: .pid(sender)),
                on: socket
            )
        }
        
        public func onThrow<Err>(error: Err) async throws where Err : Error {
            guard let sender,
                  let resultHandlerAdapter
            else { return }
            
            var senderPID = sender.pid
            
            let buffer = try resultHandlerAdapter.encode(throwing: error)
            
            guard ei_send(
                socket,
                &senderPID,
                buffer.buff,
                buffer.index
            ) == 0
            else { throw ErlangActorSystemError.sendFailed }
        }
    }
    
    public func resolve<Act>(
        id: ActorID,
        as actorType: Act.Type
    ) throws -> Act? where Act : DistributedActor, Act.ID == ActorID {
        // if we return nil, this actor is on another node
        // and Swift will create a remote actor reference.
        return self.processes.withLock {
            $0[id] as? Act
        }
    }
    
    public func actorReady<Act>(_ actor: Act) where Act: DistributedActor, Act.ID == ActorID {
        self.processes.withLock {
            $0[actor.id] = actor
        }
    }
    
    public func remoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws -> Res where Act: DistributedActor, Err: Error, Act.ID == ActorID, Res: Codable {
        let targetIdentifier = (actor as? any HasStableNames)?._stableNames[
            String(target.description.split(separator: ".").last!)
        ] ?? target.identifier
        
        let remoteCallAdapter = (actor as? any HasRemoteCallAdapter)?.remoteCallAdapter ?? self.remoteCallAdapter
        
        let remoteCall = try remoteCallAdapter.encode(
            RemoteCallInvocation(
                identifier: targetIdentifier,
                arguments: invocation.arguments,
                returnType: returning
            ),
            for: self
        )
        
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ErlangTermBuffer, any Error>) in
            if let continuationAdapter = remoteCall.continuationAdapter {
                remoteCallContinuations.withLock { continuations in
                    continuations.append(RemoteCallContinuation(
                        adapter: continuationAdapter,
                        continuation: continuation
                    ))
                }
            }
            
            nonisolated(unsafe) let message = remoteCall.message
            Task { @Sendable in
                do {
                    try await self.send(message, to: actor.id)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
            }
            if remoteCall.continuationAdapter == nil {
                continuation.resume(returning: ErlangTermBuffer())
            }
        }
        
        return try TermDecoder().decode(Res.self, from: response)
    }
    
    public func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type
    ) async throws where Act: DistributedActor, Err: Error, Act.ID == ActorID {
        let targetIdentifier = (actor as? any HasStableNames)?._stableNames[
            String(target.description.split(separator: ".").last!)
        ] ?? target.identifier
        
        let remoteCallAdapter = (actor as? any HasRemoteCallAdapter)?.remoteCallAdapter ?? self.remoteCallAdapter
        
        let remoteCall = try remoteCallAdapter.encode(
            RemoteCallInvocation(
                identifier: targetIdentifier,
                arguments: invocation.arguments,
                returnType: nil
            ),
            for: self
        )
        
        _ = try await withCheckedThrowingContinuation { continuation in
            if let continuationAdapter = remoteCall.continuationAdapter {
                remoteCallContinuations.withLock {
                    $0.append(RemoteCallContinuation(
                        adapter: continuationAdapter,
                        continuation: continuation
                    ))
                }
            }
            
            nonisolated(unsafe) let message = remoteCall.message
            Task { @Sendable in
                do {
                    try await self.send(message, to: actor.id)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
            }
            
            if remoteCall.continuationAdapter == nil {
                continuation.resume(returning: ErlangTermBuffer())
            }
        }
    }
    
    public func assignID<Act>(_ actorType: Act.Type) -> ActorID where Act : DistributedActor, Act.ID == ActorID {
        let pid = self.transport.makePID()
        let id = ActorID.pid(pid)
        return id
    }
    
    public func resignID(_ id: ActorID) {
        _ = self.processes.withLock({
            $0.removeValue(forKey: id)
        })
        self.nodesMonitors.remove(id)
        for (name, value) in self.registeredNames where value == id {
            self.registeredNames.removeValue(forKey: name)
        }
    }
    
    public func makeInvocationEncoder() -> InvocationEncoder {
        let encoder = TermEncoder()
        encoder.includeVersion = false
        return InvocationEncoder(encoder: encoder)
    }
}

extension ErlangActorSystem {
    /// Establishes a connection between this node and a remote node.
    public func connect(to nodeName: String) async throws {
        let socket = try await self.transport.connect(to: nodeName)
        
        await self.nodeReady(socket, name: nodeName)
    }
    
    /// Establishes a connection between this node and a remote node.
    public func connect(to ip: String, port: Int) async throws {
        let socket = try await self.transport.connect(to: ip, port: port)
        
        await self.nodeReady(socket, name: "\(ip):\(port)")
    }
    
    func handleMessage(socket: (any Transport).AcceptSocket, message: Message) async throws {
        if message.info.recipient == self.pid {
            switch message.info.kind {
            case .link:
                break
            case .send:
                // handle `register` RPC response
                // {:rex, :yes}
                if let registerContinuation {
                    var index: Int32 = 0
                    var version: Int32 = 0
                    message.content.decode(version: &version, index: &index)
                
                    var arity: Int32 = 0
                    message.content.decode(tupleHeader: &arity, index: &index)
                    guard arity == 2 else {
                        registerContinuation.resume(throwing: ErlangActorSystemError.registerFailed)
                        return
                    }
                    var atom: [CChar] = [CChar](repeating: 0, count: Int(MAXATOMLEN))
                    message.content.decode(atom: &atom, index: &index)
                    
                    guard String(cString: atom, encoding: .utf8) == "rex" else {
                        registerContinuation.resume(throwing: ErlangActorSystemError.registerFailed)
                        return
                    }
                    atom = [CChar](repeating: 0, count: Int(MAXATOMLEN))
                    message.content.decode(atom: &atom, index: &index)
                    guard String(cString: atom, encoding: .utf8) == "yes" else {
                        registerContinuation.resume(throwing: ErlangActorSystemError.registerFailed)
                        return
                    }
                    
                    registerContinuation.resume()
                    return
                }
                
                // match to each awaiting continuation
                func handle(
                    _ buffer: sending ErlangTermBuffer,
                    continuations: inout [RemoteCallContinuation]
                ) {
                    for (index, continuation) in continuations.enumerated() {
                        nonisolated(unsafe) let result = continuation.adapter.decode(buffer)
                        switch result {
                        case let .success(result):
                            continuation.continuation.resume(returning: result)
                            continuations.remove(at: index)
                            return
                        case let .failure(error):
                            continuation.continuation.resume(throwing: error)
                            continuations.remove(at: index)
                            return
                        case .mismatch:
                            continue
                        }
                    }
                }
                remoteCallContinuations.withLock { remoteCallContinuations in
                    nonisolated(unsafe) let buffer = message.content
                    handle(buffer, continuations: &remoteCallContinuations)
                }
//                let matched = Atomic(false)
//                await withTaskGroup(of: Int?.self) { group in
//                    remoteCallContinuations.withLock { continuations in
//                        for (index, continuation) in continuations.enumerated() {
//                            nonisolated(unsafe) let buffer = message.content
//                            group.addTask { @Sendable in
//                                guard !matched.load(ordering: .relaxed) else { return nil }
//                                
//                                let result = continuation.adapter.decode(buffer)
//                                switch result {
//                                case .success(let buffer):
//                                    continuation.continuation.resume(returning: buffer)
//                                    if matched.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged {
//                                        return index
//                                    } else {
//                                        return nil
//                                    }
//                                case .failure(let error):
//                                    continuation.continuation.resume(throwing: error)
//                                    if matched.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged {
//                                        return index
//                                    } else {
//                                        return nil
//                                    }
//                                case .mismatch:
//                                    return nil
//                                }
//                            }
//                        }
//                    }
//                    for await match in group {
//                        guard let match else { continue }
//                        remoteCallContinuations.withLock {
//                            _ = $0.remove(at: match)
//                        }
//                        return
//                    }
//                }
            default:
                print("=== UNKNOWN ACTOR SYSTEM MESSAGE ===")
                print(message.content)
            }
        } else if let actor = self.registeredNames[message.info.namedRecipient]
            .flatMap({ id in self.processes.withLock({ $0[id] }) })
                    ?? self.processes.withLock({ $0[.pid(message.info.recipient)] })
        {
            let remoteCallAdapter = (actor as? any HasRemoteCallAdapter)?.remoteCallAdapter ?? self.remoteCallAdapter
            let localCall = try remoteCallAdapter.decode(message.content, for: self)
            
            let handler = ResultHandler(
                sender: localCall.sender,
                resultHandlerAdapter: localCall.resultHandler,
                transport: transport,
                socket: socket
            )
            
            let decoder = TermDecoder()
            var invocationDecoder = InvocationDecoder(
                buffer: localCall.arguments,
                decoder: decoder,
                index: 0
            )
            
            try! await ErlangActorSystem.$messageInfo.withValue(message.info) {
                if let stableNamed = actor as? any HasStableNames {
                    try await stableNamed._executeStableName(
                        target: RemoteCallTarget(localCall.identifier),
                        invocationDecoder: &invocationDecoder,
                        handler: handler
                    )
                } else {
                    try await self.executeDistributedTarget(
                        on: actor,
                        target: RemoteCallTarget(localCall.identifier),
                        invocationDecoder: &invocationDecoder,
                        handler: handler
                    )
                }
            }
        } else {
            print("=== UNKNOWN ACTOR MESSAGE ===")
            print(message.content)
        }
    }
}

extension ErlangActorSystem {
    public protocol NodesMonitor: DistributedActor where ActorSystem == ErlangActorSystem {
        func up(_ node: String)
        func down(_ node: String)
    }
    
    /// Calls a function whenever the nodes
    public func monitorNodes(_ monitor: some NodesMonitor) {
        nodesMonitors.insert(monitor.id)
    }
}

enum ErlangActorSystemError: Error {
    case initFailed
    case listenFailed
    case publishFailed
    
    case connectionFailed
    
    case remoteCallFailed
    case sendFailed
    
    case registerFailed
}

extension Term.Reference {
    public init(for system: ErlangActorSystem) {
        self = system.transport.makeReference()
    }
}

extension ErlangActorSystem {
    public func resolve(id: ActorID) -> (any DistributedActor)? {
        processes.withLock({ $0[id] })
    }
    
    public func send(_ message: sending ErlangTermBuffer, to id: ActorID) async throws {
        if self.processes.withLock({ $0.keys.contains(id) }) {
            fatalError("'send(_:to:)' can only be used with remote actor IDs")
        } else {
            switch id {
            case let .pid(pid):
                guard let nodeName = String(cString: [CChar](tuple: pid.pid.node, start: \.0), encoding: .utf8),
                      let node = self.remoteNodes.withLock({ $0[nodeName] })
                else {
                    throw ErlangActorSystemError.sendFailed
                }
                
                nonisolated(unsafe) let message = message
                try await self.transport.send(.init(content: message, recipient: .pid(pid)), on: node)
            case let .name(name, nodeName):
                guard let node = self.remoteNodes.withLock({ $0[nodeName] })
                else { throw ErlangActorSystemError.sendFailed }
                
                nonisolated(unsafe) let message = message
                try await self.transport.send(.init(content: message, recipient: .name(name)), on: node)
            }
        }
    }
}
