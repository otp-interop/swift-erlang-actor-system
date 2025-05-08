import erl_interface
import Distributed
import Synchronization

/// An actor system manages an Erlang C node, which can contain many processes
/// (actors).
public final class ErlangActorSystem: DistributedActorSystem, @unchecked Sendable {
    /// The resolved node name.
    public var name: String {
        String(
            cString: [CChar](tuple: node.thisnodename, start: \.0),
            encoding: .utf8
        )!
    }
    
    /// The connection cookie set on this actor system.
    public var cookie: String {
        String(
            cString: [CChar](tuple: node.ei_connect_cookie, start: \.0),
            encoding: .utf8
        )!
    }
    
    var node = ei_cnode()
    
    private(set) var port: Int32 = 0
    
    private(set) var reservedProcesses = Set<ActorID>()
    private let processes = Mutex<[ActorID:any DistributedActor]>([:])
    private(set) var registeredNames = [String:ActorID]()
    
    private(set) var remoteNodes = [String:RemoteNode]()
    private(set) var nodesMonitors = Set<ActorID>()
    private func nodeReady(_ node: RemoteNode, name: String) async {
        self.remoteNodes[name] = node
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
        Term.PID(pid: node.`self`)
    }
    
    var acceptTask: Task<(), Never>?
    var messageTask: Task<(), Never>?
    
    private var registerContinuation: CheckedContinuation<Void, any Error>?
    
    private var remoteCallContinuations = [RemoteCallContinuation]()
    struct RemoteCallContinuation {
        let adapter: any ContinuationAdapter
        let continuation: CheckedContinuation<ErlangTermBuffer, any Error>
    }
    
    /// The ``RemoteCallAdapter`` to use for actors that don't specify their own.
    let defaultRemoteCallAdapter: any RemoteCallAdapter
    
    /// Create an actor system with a short node name.
    public init(
        name: String,
        cookie: String,
        remoteCallAdapter: any RemoteCallAdapter = GenServerRemoteCallAdapter()
    ) throws {
        self.defaultRemoteCallAdapter = remoteCallAdapter
        
        erl_interface.ei_init()
        
        guard ei_connect_init(&node, name, cookie, UInt32(time(nil) + 1)) >= 0
        else { throw ErlangActorSystemError.initFailed }
        
        let listenDescriptor = ei_listen(&node, &port, 5)
        guard listenDescriptor > 0
        else { throw ErlangActorSystemError.listenFailed }
        
        guard ei_publish(&node, port) != -1
        else { throw ErlangActorSystemError.publishFailed }
        
        acceptTask = Task.detached { [weak self] in
            while true {
                guard let self else { continue }
                var conn = ErlConnect()
                let fileDescriptor = ei_accept(&node, listenDescriptor, &conn)
                guard fileDescriptor >= 0,
                      let nodeName = String(cString: [CChar](tuple: conn.nodename, start: \.0), encoding: .utf8)
                else { continue }
                let node = RemoteNode(
                    fileDescriptor: fileDescriptor,
                    onReceive: handleMessage
                )
                await self.nodeReady(node, name: nodeName)
            }
        }
    }
    
    /// Create an actor system with a full name and IP address.
    public init(
        hostname: String,
        alivename: String,
        nodename: String,
        ip: String,
        cookie: String,
        remoteCallAdapter: any RemoteCallAdapter = GenServerRemoteCallAdapter()
    ) throws {
        self.defaultRemoteCallAdapter = remoteCallAdapter
        
        erl_interface.ei_init()
        
        var addr = in_addr()
        inet_aton("127.0.0.1", &addr)
        guard ei_connect_xinit(
            &node,
            hostname,
            alivename,
            nodename,
            &addr,
            cookie,
            1
        ) >= 0
        else { throw ErlangActorSystemError.initFailed }
        
        let listenDescriptor = ei_listen(&node, &port, 5)
        guard listenDescriptor > 0
        else { throw ErlangActorSystemError.listenFailed }
        
        guard ei_publish(&node, port) != -1
        else { throw ErlangActorSystemError.publishFailed }
        
        acceptTask = Task.detached { [weak self] in
            while true {
                guard let self else { continue }
                var conn = ErlConnect()
                let fileDescriptor = ei_accept(&node, listenDescriptor, &conn)
                guard fileDescriptor >= 0,
                      let nodeName = String(cString: [CChar](tuple: conn.nodename, start: \.0), encoding: .utf8)
                else { continue }
                let node = RemoteNode(
                    fileDescriptor: fileDescriptor,
                    onReceive: handleMessage
                )
                await self.nodeReady(node, name: nodeName)
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
                buffer.encode(atom: strdup(name))
                buffer.encode(atom: strdup(nodeName))
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
                
                try container.encode(name)
                try container.encode(node)
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
        let fileDescriptor: Int32
        
        public func onReturn<Success: Codable>(value: Success) async throws {
            guard let sender,
                  let resultHandlerAdapter
            else { return }
            
            var senderPID = sender.pid
            
            let encoder = TermEncoder()
            encoder.includeVersion = false
            let value = try encoder.encode(value)
            
            let buffer = try resultHandlerAdapter.encode(returning: value)
            
            guard ei_send(
                fileDescriptor,
                &senderPID,
                buffer.buff,
                buffer.index
            ) == 0
            else { throw ErlangActorSystemError.sendFailed }
        }
        
        public func onReturnVoid() async throws {
            guard let sender,
                  let resultHandlerAdapter
            else { return }
            
            var senderPID = sender.pid
            
            let buffer = try resultHandlerAdapter.encodeVoid()
            
            guard ei_send(
                fileDescriptor,
                &senderPID,
                buffer.buff,
                buffer.index
            ) == 0
            else { throw ErlangActorSystemError.sendFailed }
        }
        
        public func onThrow<Err>(error: Err) async throws where Err : Error {
            guard let sender,
                  let resultHandlerAdapter
            else { return }
            
            var senderPID = sender.pid
            
            let buffer = try resultHandlerAdapter.encode(throwing: error)
            
            guard ei_send(
                fileDescriptor,
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
        let targetIdentifier = (actor as? any _HasStableNames)?._stableNames[
            String(target.description.split(separator: ".").last!)
        ] ?? target.identifier
        
        let remoteCallAdapter = (actor as? any HasRemoteCallAdapter)?.remoteCallAdapter ?? defaultRemoteCallAdapter
        
        let remoteCall = try remoteCallAdapter.encode(
            RemoteCallInvocation(
                identifier: targetIdentifier,
                arguments: invocation.arguments,
                returnType: returning
            ),
            for: self
        )
        
        let response = try await withCheckedThrowingContinuation { continuation in
            if let continuationAdapter = remoteCall.continuationAdapter {
                remoteCallContinuations.append(RemoteCallContinuation(
                    adapter: continuationAdapter,
                    continuation: continuation
                ))
            }
            
            switch actor.id {
            case let .pid(pid):
                guard let nodeName = String(cString: [CChar](tuple: pid.pid.node, start: \.0), encoding: .utf8),
                      let node = self.remoteNodes[nodeName]
                else { return continuation.resume(throwing: ErlangActorSystemError.remoteCallFailed) }
                var pid = pid.pid
                
                guard ei_send(
                    node.fileDescriptor,
                    &pid,
                    remoteCall.message.buff,
                    remoteCall.message.index
                ) >= 0
                else { return continuation.resume(throwing: ErlangActorSystemError.sendFailed) }
            case let .name(name, nodeName):
                guard let node = self.remoteNodes[nodeName]
                else { return continuation.resume(throwing: ErlangActorSystemError.remoteCallFailed) }
                
                guard ei_reg_send(
                    &self.node,
                    node.fileDescriptor,
                    strdup(name),
                    remoteCall.message.buff,
                    remoteCall.message.index
                ) >= 0
                else { return continuation.resume(throwing: ErlangActorSystemError.sendFailed) }
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
        let targetIdentifier = (actor as? any _HasStableNames)?._stableNames[
            String(target.description.split(separator: ".").last!)
        ] ?? target.identifier
        
        let remoteCallAdapter = (actor as? any HasRemoteCallAdapter)?.remoteCallAdapter ?? defaultRemoteCallAdapter
        
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
                remoteCallContinuations.append(RemoteCallContinuation(
                    adapter: continuationAdapter,
                    continuation: continuation
                ))
            }
            
            switch actor.id {
            case let .pid(pid):
                guard let nodeName = String(cString: [CChar](tuple: pid.pid.node, start: \.0), encoding: .utf8),
                      let node = self.remoteNodes[nodeName]
                else {
                    return continuation.resume(throwing: ErlangActorSystemError.remoteCallFailed)
                }
                var pid = pid.pid
                
                guard ei_send(
                    node.fileDescriptor,
                    &pid,
                    remoteCall.message.buff,
                    remoteCall.message.index
                ) >= 0
                else { return continuation.resume(throwing: ErlangActorSystemError.sendFailed) }
            case let .name(name, nodeName):
                guard let node = self.remoteNodes[nodeName]
                else { return continuation.resume(throwing: ErlangActorSystemError.remoteCallFailed) }
                
                guard ei_reg_send(
                    &self.node,
                    node.fileDescriptor,
                    strdup(name),
                    remoteCall.message.buff,
                    remoteCall.message.index
                ) >= 0
                else { return continuation.resume(throwing: ErlangActorSystemError.sendFailed) }
            }
            
            if remoteCall.continuationAdapter == nil {
                continuation.resume(returning: ErlangTermBuffer())
            }
        }
    }
    
    public func assignID<Act>(_ actorType: Act.Type) -> ActorID where Act : DistributedActor, Act.ID == ActorID {
        var pid = erlang_pid()
        ei_make_pid(&node, &pid)
        let id = ActorID.pid(Term.PID(pid: pid))
        self.reservedProcesses.insert(id)
        return id
    }
    
    public func resignID(_ id: ActorID) {
        self.reservedProcesses.remove(id)
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
    struct RemoteNode {
        let fileDescriptor: Int32
        let messageTask: Task<(), Never>
        
        init(fileDescriptor: Int32, onReceive: sending @escaping (Int32, erlang_msg, ErlangTermBuffer) async throws -> ()) {
            self.fileDescriptor = fileDescriptor
            self.messageTask = Task.detached {
                while true {
                    var message = erlang_msg()
                    let buffer = ErlangTermBuffer()
                    buffer.new()
                    
                    switch ei_xreceive_msg(fileDescriptor, &message, &buffer.buffer) {
                    case ERL_TICK:
                        continue
                    case ERL_ERROR:
                        continue
                    case ERL_MSG:
                        var index: Int32 = 0
                        ei_print_term(stdout, buffer.buff, &index)
                        try! await onReceive(fileDescriptor, message, buffer)
                    case let messageKind:
                        print("=== UNKNOWN MESSAGE KIND \(messageKind) ===")
                        print(message)
                        print(buffer)
                        continue
                    }
                }
            }
        }
    }
    
    /// Establishes a connection between this node and a remote node.
    public func connect(to nodeName: String) async throws {
        let fileDescriptor = ei_connect(&node, strdup(nodeName))
        
        guard fileDescriptor >= 0
        else { throw ErlangActorSystemError.connectionFailed }
        
        let connection = RemoteNode(fileDescriptor: fileDescriptor, onReceive: handleMessage)
        
        await self.nodeReady(connection, name: nodeName)
    }
    
    /// Establishes a connection between this node and a remote node.
    public func connect(to ip: String, port: Int) async throws {
        var addr = in_addr()
        inet_aton(strdup(ip), &addr)
        let fileDescriptor = ei_xconnect_host_port(&node, &addr, Int32(port))
        
        guard fileDescriptor >= 0
        else { throw ErlangActorSystemError.connectionFailed }
        
        let connection = RemoteNode(fileDescriptor: fileDescriptor, onReceive: handleMessage)
        
        await self.nodeReady(connection, name: "\(ip):\(port)")
    }
    
    func handleMessage(fileDescriptor: Int32, message: erlang_msg, buffer: ErlangTermBuffer) async throws {
        let recipient = Term.PID(pid: message.to)
        if recipient == self.pid {
            switch Int32(message.msgtype) {
            case ERL_LINK:
                break
            case ERL_SEND:
                // handle `register` RPC response
                // {:rex, :yes}
                if let registerContinuation {
                    var index: Int32 = 0
                    var version: Int32 = 0
                    buffer.decode(version: &version, index: &index)
                
                    var arity: Int32 = 0
                    buffer.decode(tupleHeader: &arity, index: &index)
                    guard arity == 2 else {
                        registerContinuation.resume(throwing: ErlangActorSystemError.registerFailed)
                        return
                    }
                    var atom: [CChar] = [CChar](repeating: 0, count: Int(MAXATOMLEN))
                    buffer.decode(atom: &atom, index: &index)
                    
                    guard String(cString: atom, encoding: .utf8) == "rex" else {
                        registerContinuation.resume(throwing: ErlangActorSystemError.registerFailed)
                        return
                    }
                    atom = [CChar](repeating: 0, count: Int(MAXATOMLEN))
                    buffer.decode(atom: &atom, index: &index)
                    guard String(cString: atom, encoding: .utf8) == "yes" else {
                        registerContinuation.resume(throwing: ErlangActorSystemError.registerFailed)
                        return
                    }
                    
                    registerContinuation.resume()
                    return
                }
                
                // match to each awaiting continuation
                continuationChecks: for (index, continuation) in remoteCallContinuations.enumerated() {
                    do {
                        nonisolated(unsafe) let result = try continuation.adapter.decode(buffer)
                        continuation.continuation.resume(with: result)
                        remoteCallContinuations.remove(at: index)
                        break continuationChecks
                    } catch {
                        continue
                    }
                }
            default:
                print("=== UNKNOWN ACTOR SYSTEM MESSAGE ===")
                print(buffer)
            }
        } else if let actor = self.registeredNames[String(cString: Array(tuple: message.toname, start: \.0), encoding: .utf8)!]
            .flatMap({ id in self.processes.withLock({ $0[id] }) })
                    ?? self.processes.withLock({ $0[.pid(recipient)] })
        {
            let remoteCallAdapter = (actor as? any HasRemoteCallAdapter)?.remoteCallAdapter ?? defaultRemoteCallAdapter
            let localCall = try remoteCallAdapter.decode(buffer, for: self)
            
            let handler = ResultHandler(
                sender: localCall.sender,
                resultHandlerAdapter: localCall.resultHandler,
                fileDescriptor: fileDescriptor
            )
            
            let decoder = TermDecoder()
            var invocationDecoder = InvocationDecoder(
                buffer: localCall.arguments,
                decoder: decoder,
                index: 0
            )
            
            if let stableNamed = actor as? any _HasStableNames {
                try! await stableNamed._executeStableName(
                    target: RemoteCallTarget(localCall.identifier),
                    invocationDecoder: &invocationDecoder,
                    handler: handler
                )
            } else {
                try! await self.executeDistributedTarget(
                    on: actor,
                    target: RemoteCallTarget(localCall.identifier),
                    invocationDecoder: &invocationDecoder,
                    handler: handler
                )
            }
        } else {
            print("=== UNKNOWN ACTOR MESSAGE ===")
            print(buffer)
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
        self.init(for: &system.node)
    }
}
