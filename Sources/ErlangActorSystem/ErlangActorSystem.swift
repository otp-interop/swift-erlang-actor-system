import erl_interface
import Distributed
import Darwin

@attached(peer)
public macro StableName(_ name: StaticString) = #externalMacro(module: "DistributedMacros", type: "StableName")

@attached(
    extension,
    conformances: HasStableNames,
    names: named(mangledStableNames), named(stableMangledNames), named(_$), named(RemoteActor)
)
@attached(peer, names: prefixed(_RemoteActorFor))
public macro StableNames() = #externalMacro(module: "DistributedMacros", type: "StableNames")

@attached(body)
public macro RemoteDeclaration(_ name: StaticString) = #externalMacro(module: "DistributedMacros", type: "RemoteDeclaration")

public protocol HasStableNames {
    static var mangledStableNames: [String:String] { get }
    static var stableMangledNames: [String:String] { get }
}

//public protocol RemoteActorProtocol<ActorSystem>: DistributedActor where ActorSystem == ErlangActorSystem {
//    associatedtype RemoteActor: DistributedActor where RemoteActor.ActorSystem == Self.ActorSystem
//    static func _resolve(id: ErlangActorSystem.ActorID, using system: ErlangActorSystem) throws -> any DistributedActor
//}

//extension RemoteActorProtocol {
//    static func _resolve(id: ActorSystem.ActorID, using system: ActorSystem) throws -> any DistributedActor {
//        try _RemoteActorType.resolve(id: id, using: system)
//    }
//}

public extension HasStableNames {
    /// Creates a mangled function name for a distributed function.
    ///
    /// Mangling is described with the following grammar:
    /// ```
    /// entity-spec ::= decl-name label-list function-signature generic-signature? 'F'    // function
    /// decl-name ::= identifier
    /// label-list ::= ('_' | identifier)*   // '_' is inserted as placeholder for empty label,
    ///                                      // since the number of labels should match the number of parameters
    /// identifier // <identifier> is run-length encoded: the natural indicates how many characters follow.
    /// function-signature ::= result-type params-type async? sendable? throws? differentiable? function-isolation? sending-result? // results and parameters
    /// ```
    ///
    /// Metatypes are passed to this function instead of strings so we can use
    /// ``Swift/_mangledTypeName`` to compute an accurate mangled name for any
    /// given identifier.
    ///
    /// It is expected that structs be declared with an `__` prefix for all
    /// metatype arguments. Labeled arguments should also be nested within
    /// the previous labeled argument to enable substitutions in the mangled
    /// name.
    ///
    /// ```swift
    /// struct ManglingMetatypes {
    ///     // function(labeledParam1:labeledParam2:)
    ///     struct __function {
    ///         struct __labeledParam1 {
    ///             struct __labeledParam2 {}
    ///         }
    ///     }
    /// }
    /// ```
    ///
    /// The metatypes are then used to create the mangled name:
    ///
    /// ```swift
    /// _mangle(
    ///     function: function.self,
    ///     functionContainer: ManglingMetatypes.self,
    ///     parameters: [
    ///         (label: labeledParam1.self, labelParent: function.self, type: String.self),
    ///         (label: labeledParam2.self, labelParent: labeledParam1.self, type: Int.self)
    ///     ],
    ///     returnType: Void.self,
    ///     sendingResult: false
    /// )
    /// ```
    static func _mangle(
        function: Any.Type,
        functionContainer: Any.Type?,
        parameters: [(label: Any.Type?, labelParent: Any.Type?, type: Any.Type)],
        returnType: Any.Type,
        sendingResult: Bool
    ) -> String {
        // constants
        let distributedActorThunkTag = "TE" // distributed func
//        let distributedMethodAccessorTag = "TF" // distributed var
        let asyncTag = "Ya" // async -> T
        let throwsTag = "K" // throws -> T
        
        let mangledTypeName = _mangledTypeName(Self.self)!
        
        // function name as a type
        // the value will contain the run-length encoding
        let mangledFunctionName = _mangledTypeName(function)!
            .trimmingPrefix(_mangledTypeName(functionContainer ?? Self.self)!)
            .dropLast() // drop the decl kind suffix
        
        let hasLabeledParameters = parameters.contains(where: { $0.0 != nil })
        let mangledParameterTypes = parameters.count > 0
            ? parameters.enumerated()
                .map({
                    if $0.offset == 0 && (parameters.count > 1 || hasLabeledParameters) {
                        return "\(_mangledTypeName($0.element.type)!)_"
                    } else {
                        return _mangledTypeName($0.element.type)!
                    }
                })
                .joined(separator: "")
            : "y" // empty list
        let parameterLabels = (parameters.count > 0 && !hasLabeledParameters)
            ? "y" // empty list
            : parameters.map({
                if let label = $0.label,
                   let labelParent = $0.labelParent
                {
                    // the label will contain the run-length encoding
                    return _mangledTypeName(label)!
                        .trimmingPrefix(_mangledTypeName(labelParent)!)
                        .dropLast() // drop the decl kind suffix
                } else {
                    return "_"
                }
            }).joined(separator: "")
        
        let tupleParamsTag = parameters.count > 1 ? "t" : ""
        let sendingResultTag = sendingResult ? "YT" : "" // -> sending T
        
        let mangledReturn = returnType == Void.self
            ? "y"
            : _mangledTypeName(returnType)!
        
        return "$s\(mangledTypeName)\(mangledFunctionName)\(parameterLabels)\(mangledReturn)\(mangledParameterTypes)\(tupleParamsTag)\(asyncTag)\(throwsTag)\(sendingResultTag)F\(distributedActorThunkTag)"
    }
}

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
    
    var reservedProcesses = Set<ActorID>()
    var processes = [ActorID:any DistributedActor]()
    var registeredNames = [String:ActorID]()
    
    var remoteNodes = [String:RemoteNode]()
    
    public var pid: Term.PID {
        Term.PID(pid: node.`self`)
    }
    
    var acceptTask: Task<(), Never>?
    var messageTask: Task<(), Never>?
    
    private var registerContinuation: CheckedContinuation<Void, any Error>?
    
    private var remoteCallContinuations = [Term.Reference: CheckedContinuation<ErlangTermBuffer, any Error>]()
    
    public init(name: String, cookie: String) throws {
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
                guard fileDescriptor >= 0
                else { continue }
                self.remoteNodes[String(cString: [CChar](tuple: conn.nodename, start: \.0), encoding: .utf8)!] = RemoteNode(
                    fileDescriptor: fileDescriptor,
                    onReceive: handleMessage
                )
            }
        }
    }
    
    public init(hostname: String, alivename: String, nodename: String, ip: String, cookie: String) throws {
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
                guard fileDescriptor >= 0
                else { continue }
                self.remoteNodes[String(cString: [CChar](tuple: conn.nodename, start: \.0), encoding: .utf8)!] = RemoteNode(
                    fileDescriptor: fileDescriptor,
                    onReceive: handleMessage
                )
            }
        }
    }
    
    public func register<Act: DistributedActor>(
        _ actor: Act,
        name: String
    ) async throws where Act.ID == ActorID {
        registeredNames[name] = actor.id
        for remoteNode in remoteNodes.values {
            var pid = self.pid.pid
            
            // :global.register_name_external(name, self(), {:global, :cnode})
            let args = ErlangTermBuffer()
            args.encode(listHeader: 3)
            
            args.encode(atom: strdup(name))
            args.encode(pid: &pid)
            
            args.encode(tupleHeader: 2) // {:global, :cnode}
            args.encode(atom: "global")
            args.encode(atom: "cnode")
            
            args.encodeEmptyList() // tail
            
            try await withCheckedThrowingContinuation { continuation in
                registerContinuation = continuation
                
                guard ei_rpc_to(
                    &self.node,
                    remoteNode.fileDescriptor,
                    strdup("global"),
                    strdup("register_name_external"),
                    args.buff,
                    args.index
                ) == 0
                else { return continuation.resume(throwing: ErlangActorSystemError.registerFailed) }
            }
            registerContinuation = nil
        }
    }
    
    private func pid(for id: ActorID) -> Term.PID {
        switch id {
        case let .pid(pid):
            return pid
        case .name:
            fatalError("Cannot resolve PID for remote node")
        }
    }
    
    public enum ActorID: Hashable, Sendable, Decodable, CustomDebugStringConvertible {
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
        let buffer = ErlangTermBuffer()
        var argumentCount = 0
        
        init(encoder: TermEncoder) {
            self.encoder = encoder
            self.buffer.new()
        }
        
        public mutating func recordArgument<Value: Codable>(_ argument: RemoteCallArgument<Value>) throws {
            buffer.append(try encoder.encode(argument.value))
            argumentCount += 1
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
            try decoder.decode(Argument.self, from: buffer, startIndex: index)
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
        
        let sender: Term.PID
        let monitorReference: ErlangTermBuffer
        let fileDescriptor: Int32
        
        /// `{<ref>, <reply>}`
        func buffer(_ value: ErlangTermBuffer) -> ErlangTermBuffer {
            let result = ErlangTermBuffer()
            result.newWithVersion()
            
            result.encode(tupleHeader: 2)
            result.append(monitorReference)
            result.append(value)
            
            return result
        }
        
        public func onReturn<Success: Codable>(value: Success) async throws {
            var sender = sender.pid
            let encoder = TermEncoder()
            encoder.includeVersion = false
            let buffer = buffer(try encoder.encode(value))
            
            guard ei_send(
                fileDescriptor,
                &sender,
                buffer.buff,
                buffer.index
            ) == 0
            else { throw ErlangActorSystemError.sendFailed }
        }
        
        public func onReturnVoid() async throws {
            var sender = sender.pid
            
            let value = ErlangTermBuffer()
            value.encode(atom: "ok")
            
            let buffer = buffer(value)
            
            guard ei_send(
                fileDescriptor,
                &sender,
                buffer.buff,
                buffer.index
            ) == 0
            else { throw ErlangActorSystemError.sendFailed }
        }
        
        public func onThrow<Err>(error: Err) async throws where Err : Error {
            fatalError(error.localizedDescription)
        }
    }
    
    public func resolve<Act>(
        id: ActorID,
        as actorType: Act.Type
    ) throws -> Act? where Act : DistributedActor, Act.ID == ActorID {
        // if we return nil, this actor is on another node
        // and Swift will create a remote actor reference.
        return self.processes[id] as? Act
    }
    
    public func actorReady<Act>(_ actor: Act) where Act: DistributedActor, Act.ID == ActorID {
        self.processes[actor.id] = actor
    }
    
    public func remoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws -> Res where Act: DistributedActor, Err: Error, Act.ID == ActorID, Res: Codable {
        let message = ErlangTermBuffer()
        message.newWithVersion()
        // {:"$gen_call", {<from_pid>, <monitor_ref>}, <message>}
        message.encode(tupleHeader: 3)
        message.encode(atom: "$gen_call")
        
        var callReference = Term.Reference(for: &self.node)
        
        message.encode(tupleHeader: 2)
        var pid = self.pid.pid
        message.encode(pid: &pid)
        message.encode(listHeader: 2)
        message.encode(atom: "alias")
        message.encode(ref: &callReference.ref)
        message.encodeEmptyList()
        
        let targetIdentifier = (Act.self as? HasStableNames.Type)?.stableMangledNames[target.identifier]
            ?? target.identifier
        
        if invocation.argumentCount == 0 {
            message.encode(atom: targetIdentifier)
        } else {
            message.encode(tupleHeader: invocation.argumentCount + 1) // {:target, args...}
            message.encode(atom: targetIdentifier)
            message.append(invocation.buffer)
        }
        
        let response = try await withCheckedThrowingContinuation { continuation in
            remoteCallContinuations[callReference] = continuation
            
            switch actor.id {
            case let .pid(pid):
                guard let nodeName = String(cString: [CChar](tuple: pid.pid.node, start: \.0), encoding: .utf8),
                      let node = self.remoteNodes[nodeName]
                else { return continuation.resume(throwing: ErlangActorSystemError.remoteCallFailed) }
                var pid = pid.pid
                
                guard ei_send(
                    node.fileDescriptor,
                    &pid,
                    message.buff,
                    message.index
                ) >= 0
                else { return continuation.resume(throwing: ErlangActorSystemError.sendFailed) }
            case let .name(name, nodeName):
                guard let node = self.remoteNodes[nodeName]
                else { return continuation.resume(throwing: ErlangActorSystemError.remoteCallFailed) }
                
                guard ei_reg_send(
                    &self.node,
                    node.fileDescriptor,
                    strdup(name),
                    message.buff,
                    message.index
                ) >= 0
                else { return continuation.resume(throwing: ErlangActorSystemError.sendFailed) }
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
        let message = ErlangTermBuffer()
        message.newWithVersion()
        // {:"$gen_call", {<from_pid>, <monitor_ref>}, <message>}
        message.encode(tupleHeader: 3)
        message.encode(atom: "$gen_call")
        
        var callReference = Term.Reference(for: &self.node)
        
        message.encode(tupleHeader: 2)
        var pid = self.pid.pid
        message.encode(pid: &pid)
        message.encode(listHeader: 2)
        message.encode(atom: "alias")
        message.encode(ref: &callReference.ref)
        message.encodeEmptyList()
        
        let targetIdentifier = (Act.self as? HasStableNames.Type)?.stableMangledNames[target.identifier]
            ?? target.identifier
        
        if invocation.argumentCount == 0 {
            message.encode(atom: targetIdentifier)
        } else {
            message.encode(tupleHeader: invocation.argumentCount + 1) // {:target, args...}
            message.encode(atom: targetIdentifier)
            message.append(invocation.buffer)
        }
        
        _ = try await withCheckedThrowingContinuation { continuation in
            remoteCallContinuations[callReference] = continuation
            
            switch actor.id {
            case let .pid(pid):
                guard let nodeName = String(cString: [CChar](tuple: pid.pid.node, start: \.0), encoding: .utf8),
                      let node = self.remoteNodes[nodeName]
                else { return continuation.resume(throwing: ErlangActorSystemError.remoteCallFailed) }
                var pid = pid.pid
                
                guard ei_send(
                    node.fileDescriptor,
                    &pid,
                    message.buff,
                    message.index
                ) >= 0
                else { return continuation.resume(throwing: ErlangActorSystemError.sendFailed) }
            case let .name(name, nodeName):
                guard let node = self.remoteNodes[nodeName]
                else { return continuation.resume(throwing: ErlangActorSystemError.remoteCallFailed) }
                
                guard ei_reg_send(
                    &self.node,
                    node.fileDescriptor,
                    strdup(name),
                    message.buff,
                    message.index
                ) >= 0
                else { return continuation.resume(throwing: ErlangActorSystemError.sendFailed) }
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
        
        self.remoteNodes[nodeName] = connection
    }
    
    /// Establishes a connection between this node and a remote node.
    public func connect(to ip: String, port: Int) async throws {
        var addr = in_addr()
        inet_aton(strdup(ip), &addr)
        let fileDescriptor = ei_xconnect_host_port(&node, &addr, Int32(port))
        
        guard fileDescriptor >= 0
        else { throw ErlangActorSystemError.connectionFailed }
        
        let connection = RemoteNode(fileDescriptor: fileDescriptor, onReceive: handleMessage)
        
        self.remoteNodes["\(ip):\(port)"] = connection
    }
    
    func handleMessage(fileDescriptor: Int32, message: erlang_msg, buffer: ErlangTermBuffer) async throws {
        if Term.PID(pid: message.to) == self.pid {
            switch Int32(message.msgtype) {
            case ERL_LINK:
                break
            case ERL_SEND:
                var index: Int32 = 0
                var version: Int32 = 0
                buffer.decode(version: &version, index: &index)
                
                // handle `register` RPC response
                // {:rex, :yes}
                if let registerContinuation {
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
                
                // handle call responses
                // {[:alias, <ref>], <response>...}
                var arity: Int32 = 0
                var refArity: Int32 = 0
                var ref = erlang_ref()
                var atom: [CChar] = [CChar](repeating: 0, count: Int(MAXATOMLEN))
                if buffer.decode(tupleHeader: &arity, index: &index),
                   arity > 1,
                   buffer.decode(listHeader: &refArity, index: &index),
                   refArity == 2,
                   buffer.decode(atom: &atom, index: &index),
                   String(cString: atom, encoding: .utf8) == "alias",
                   buffer.decode(ref: &ref, index: &index),
                   buffer.decode(listHeader: &refArity, index: &index), // tail
                   let continuation = remoteCallContinuations[Term.Reference(ref: ref)]
                {
                    let responseStartIndex = index
                    for _ in 0..<Int(arity - 1) {
                        buffer.skipTerm(index: &index)
                    }
                    nonisolated(unsafe) let response = buffer[responseStartIndex...index]
                    continuation.resume(returning: response)
                } else {
                    print("=== UNEXPECTED ACTOR SYSTEM MESSAGE ===")
                    print(buffer)
                }
            default:
                print("=== UNKNOWN ACTOR SYSTEM MESSAGE ===")
                print(buffer)
            }
        } else if let actor = self.processes[.pid(Term.PID(pid: message.to))]
                    ?? self.registeredNames[String(cString: Array(tuple: message.toname, start: \.0), encoding: .utf8)!]
                        .flatMap({ self.processes[$0] })
        {
            var index: Int32 = 0
            var version: Int32 = 0
            buffer.decode(version: &version, index: &index)
            
            // {:"$gen_call", {<from_pid>, <monitor_ref>}, <message>}
            // {:"$gen_cast", {<from_pid>, <monitor_ref>}, <message>}
            
            var arity: Int32 = 0
            var atom: [CChar] = [CChar](repeating: 0, count: Int(MAXATOMLEN))
            if buffer.decode(tupleHeader: &arity, index: &index),
               arity == 3,
               buffer.decode(atom: &atom, index: &index),
               let messageKind = String(cString: atom, encoding: .utf8)
            {
                switch messageKind {
                case "$gen_call":
                    buffer.decode(tupleHeader: &arity, index: &index) // {<from_pid>, <monitor_ref>}
                    var sender = erlang_pid()
                    buffer.decode(pid: &sender, index: &index)
                    let monitorStartIndex = index
                    buffer.skipTerm(index: &index)
                    let monitorReference = buffer[monitorStartIndex...index]
                    
                    var messageType: UInt32 = 0
                    var size: Int32 = 0
                    buffer.getType(type: &messageType, size: &size, index: &index)
                    
                    let targetIdentifier: String
                    switch Character(UnicodeScalar(messageType)!) {
                    case "d", "s", "v": // no arguments call
                        var target: [CChar] = [CChar](repeating: 0, count: Int(MAXATOMLEN))
                        buffer.decode(atom: &target, index: &index)
                        
                        targetIdentifier = String(cString: target, encoding: .utf8)!
                    case "h" where size > 0,
                         "i" where size > 0: // tuple arguments
                        buffer.decode(tupleHeader: &size, index: &index)
                        var target: [CChar] = [CChar](repeating: 0, count: Int(MAXATOMLEN))
                        buffer.decode(atom: &target, index: &index)
                        
                        targetIdentifier = String(cString: target, encoding: .utf8)!
                    default:
                        print("=== UNSUPPORTED GEN_CALL MESSAGE ===")
                        print(buffer)
                        return
                    }
                    
                    let handler = ResultHandler(
                        sender: Term.PID(pid: sender),
                        monitorReference: monitorReference,
                        fileDescriptor: fileDescriptor
                    )
                    
                    let decoder = TermDecoder()
                    var invocationDecoder = InvocationDecoder(
                        buffer: buffer,
                        decoder: decoder,
                        index: index
                    )
                    
                    let mangledTarget = (type(of: actor) as? HasStableNames.Type)?.mangledStableNames[targetIdentifier] ?? targetIdentifier
                    
                    try! await self.executeDistributedTarget(
                        on: actor,
                        target: RemoteCallTarget(mangledTarget),
                        invocationDecoder: &invocationDecoder,
                        handler: handler
                    )
                case "$gen_cast":
                    fatalError("not implemented")
                default:
                    print("=== UNKNOWN MESSAGE ===")
                    print(buffer)
                }
            } else {
                print("=== UNKNOWN MESSAGE ===")
                print(buffer)
            }
        } else {
            var index: Int32 = 0
            var version: Int32 = 0
            buffer.decode(version: &version, index: &index)
            
            // {<call_reference>, <response>}
            var arity: Int32 = 0
            var callReference = erlang_ref()
            if buffer.decode(tupleHeader: &arity, index: &index),
               arity == 2,
               buffer.decode(ref: &callReference, index: &index),
               let continuation = remoteCallContinuations[Term.Reference(ref: callReference)]
            {
                let responseStartIndex = index
                buffer.skipTerm(index: &index)
                nonisolated(unsafe) let subBuffer = buffer[responseStartIndex...index]
                continuation.resume(returning: subBuffer)
            } else {
                print("=== UNKNOWN ACTOR MESSAGE ===")
                print(buffer)
            }
        }
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
