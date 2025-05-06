import Distributed
import erl_interface

public struct ProcessGroupRemoteCallAdapter: RemoteCallAdapter {
    let genServer = GenServerRemoteCallAdapter()
    
    public func encode(
        _ invocation: RemoteCallInvocation,
        for system: ActorSystem
    ) throws -> EncodedRemoteCall {
        fatalError()
    }
    
    public func decode(
        _ message: ErlangTermBuffer,
        for system: ActorSystem
    ) throws -> LocalCallInvocation {
        var index: Int32 = 0
        var version: Int32 = 0
        message.decode(version: &version, index: &index)
        
        let tupleStartIndex = index
        var arity: Int32 = 0
        message.decode(tupleHeader: &arity, index: &index)
        
        var messageType: [CChar] = [CChar](repeating: 0, count: Int(MAXATOMLEN))
        message.decode(atom: &messageType, index: &index)
        
        let argumentsStartIndex = index
        
        index = tupleStartIndex
        message.skipTerm(index: &index)
        
        return LocalCallInvocation(
            sender: nil,
            identifier: String(cString: messageType, encoding: .utf8)!,
            arguments: message[argumentsStartIndex...index],
            resultHandler: nil
        )
    }
}

extension RemoteCallAdapter where Self == ProcessGroupRemoteCallAdapter {
    static var processGroup: Self { .init() }
}

extension HasRemoteCallAdapter where Self: DistributedActor, RemoteCallAdapterType == ProcessGroupRemoteCallAdapter, ActorSystem == ErlangActorSystem {
    public func join(
        group: String
    ) async throws {
        let processGroups: ProcessGroups
        if let existingActor = try actorSystem.registeredNames["pg"].flatMap({ try ProcessGroups.resolve(id: $0, using: actorSystem) }) {
            processGroups = existingActor
        } else {
            processGroups = try await ProcessGroups.makeInstance(using: actorSystem)
        }
        
        try await processGroups.whenLocal {
            try await $0.joinLocal(group, process: self.id)
        }
    }
}

@StableNames
private distributed actor ProcessGroups: HasRemoteCallAdapter {
    typealias ActorSystem = ErlangActorSystem
    
    typealias Group = AtomTermEncoding
    
    static func remoteCallAdapter(for actor: ProcessGroups) -> sending RemoteCallAdapterType {
        return RemoteCallAdapterType()
    }
    
    struct RemoteCallAdapterType: RemoteCallAdapter {
        let genServer = GenServerRemoteCallAdapter(Dispatcher())
        
        struct Dispatcher: GenServerRemoteCallAdapter.Dispatcher {
            func dispatch(
                _ invocation: GenServerRemoteCallAdapter.RemoteCallInvocation
            ) -> GenServerRemoteCallAdapter.DispatchFormat {
                switch invocation.identifier {
                case "sync":
                    return .cast
                default:
                    return .call
                }
            }
        }
        
        func encode(
            _ invocation: RemoteCallInvocation,
            for system: ActorSystem
        ) throws -> EncodedRemoteCall {
            switch invocation.identifier {
            case "discover", "join":
                let message = ErlangTermBuffer()
                message.newWithVersion()
                if invocation.arguments.isEmpty {
                    message.encode(atom: invocation.identifier)
                } else {
                    message.encode(tupleHeader: invocation.arguments.count + 1)
                    message.encode(atom: invocation.identifier)
                    
                    let encoder = TermEncoder()
                    encoder.includeVersion = false
                    for argument in invocation.arguments {
                        message.append(try encoder.encode(argument.value))
                    }
                }
                return EncodedRemoteCall(
                    message: message,
                    continuationAdapter: nil
                )
            case "sync":
                return try genServer.encode(invocation, for: system)
            default:
                fatalError("unsupported encoding \(invocation.identifier)")
            }
        }
        
        func decode(
            _ message: ErlangTermBuffer,
            for system: ActorSystem
        ) throws -> LocalCallInvocation {
            var index: Int32 = 0
            var version: Int32 = 0
            message.decode(version: &version, index: &index)
            
            let tupleStartIndex = index
            var arity: Int32 = 0
            message.decode(tupleHeader: &arity, index: &index)
            
            var messageType: [CChar] = [CChar](repeating: 0, count: Int(MAXATOMLEN))
            message.decode(atom: &messageType, index: &index)
            
            let argumentsStartIndex = index
            
            switch String(cString: messageType, encoding: .utf8) {
            case "$gen_cast":
                let localCall = try genServer.decode(message, for: system)
                return localCall
            case "discover":
                index = tupleStartIndex
                message.skipTerm(index: &index)
                return LocalCallInvocation(
                    sender: nil,
                    identifier: "discover",
                    arguments: message[argumentsStartIndex...index],
                    resultHandler: nil
                )
            case "join":
                index = tupleStartIndex
                message.skipTerm(index: &index)
                return LocalCallInvocation(
                    sender: nil,
                    identifier: "join",
                    arguments: message[argumentsStartIndex...index],
                    resultHandler: nil
                )
            default:
                fatalError("unhandled message sent to process group module")
            }
        }
    }
    
    var state = State()
    
    struct State: Codable {
        /// All locally joined groups
        var local: [ActorSystem.ActorID:[Group]] = [:]
        
        /// All remote joined groups
        var remote: [ActorSystem.ActorID:[Group]] = [:]
    }
    
    init(actorSystem: ActorSystem) async throws {
        self.actorSystem = actorSystem
        
        // send "discover" to all nodes in the cluster
        try await broadcast(
            to: actorSystem.remoteNodes.keys.map({ .name("pg", node: $0) })
        ) { remote in
            try await remote.discover(self.id)
        }
    }
    
    func joinLocal(@AtomTermEncoding _ group: String, process: ActorSystem.ActorID) async throws {
        state.local[process, default: []].append($group)
        try await broadcast(to: state.remote.keys) { remote in
            try await remote.join(self.id, $group, process)
        }
    }
    
    private func broadcast(
        to actors: some Sequence<ActorSystem.ActorID>,
        _ perform: (ProcessGroups) async throws -> ()
    ) async throws {
        for actorID in actors {
            let remote = try ProcessGroups.resolve(id: actorID, using: actorSystem)
            try await perform(remote)
        }
    }
    
    @StableName("discover", mangledName: "$s17ErlangActorSystem13ProcessGroups33_04D6C44C880EFB98E10FB3E6950B46F4LLC8discoveryyA2AC0B2IDOYaKFTE")
    distributed func discover(_ peer: ActorSystem.ActorID) async throws {
        let remote = try ProcessGroups.resolve(id: peer, using: actorSystem)
        let groups = self.state.local.reduce(into: [Group:[Term.PID]]()) { syncGroups, local in
            if case let .pid(pid) = local.key {
                for group in local.value {
                    syncGroups[group, default: []].append(pid)
                }
            }
        }
        try await remote.sync(self.id, groups.map({ SyncGroup(group: $0.key.wrappedValue, processes: $0.value) }))
    }
    
    @StableName("sync", mangledName: "$s17ErlangActorSystem13ProcessGroups33_04D6C44C880EFB98E10FB3E6950B46F4LLC4syncyyA2AC0B2IDO_SayAA9SyncGroupVGtYaKFTE")
    distributed func sync(_ peer: ActorSystem.ActorID, _ groups: [SyncGroup]) {
        self.state.remote[peer] = groups.map(\.$group)
    }
    
    @StableName("join", mangledName: "$s17ErlangActorSystem13ProcessGroups33_04D6C44C880EFB98E10FB3E6950B46F4LLC4joinyyA2AC0B2IDO_AA16AtomTermEncodingVAHtYaKFTE")
    distributed func join(_ peer: ActorSystem.ActorID, _ group: Group, _ process: ActorSystem.ActorID) async throws {
        fatalError()
    }
    
    static func makeInstance(using system: ActorSystem) async throws -> ProcessGroups {
        let processGroups = try await ProcessGroups(actorSystem: system)
        try await system.register(processGroups, name: "pg")
        return processGroups
    }
}

//extension ProcessGroups: HasExplicitDispatch {
//    nonisolated func executeDistributedTarget(
//        target: RemoteCallTarget,
//        invocationDecoder: inout ErlangActorSystem.InvocationDecoder,
//        handler: ErlangActorSystem.ResultHandler
//    ) async throws {
//        switch target.identifier {
//        case "discover":
//            try await self.discover(try invocationDecoder.decodeNextArgument())
//        case "sync":
//            try await self.sync(try invocationDecoder.decodeNextArgument(), try invocationDecoder.decodeNextArgument())
//        default:
//            fatalError()
//        }
//    }
//}

/// `{group(), [pid()]}`
struct SyncGroup: Codable {
    @AtomTermEncoding var group: String
    let processes: [Term.PID]
    
    init(@AtomTermEncoding group: String, processes: [Term.PID]) {
        self._group = _group
        self.processes = processes
    }
    
    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        self._group = try container.decode(AtomTermEncoding.self)
        self.processes = try container.decode([Term.PID].self)
    }
    
    func encode(to encoder: any Encoder) throws {
        let context = encoder.userInfo[.termEncoderContext] as! TermEncoder.Context
        let oldStrategy = context.unkeyedContainerEncodingStrategy
        
        context.unkeyedContainerEncodingStrategy = .tuple
        var container = encoder.unkeyedContainer()
        context.unkeyedContainerEncodingStrategy = oldStrategy
        
        try container.encode(self.group)
        try container.encode(self.processes)
    }
}
