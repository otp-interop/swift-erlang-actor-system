import Distributed
import CErlInterface

/// An adapter that handles messages from a [process group](https://www.erlang.org/doc/apps/kernel/pg.html).
///
/// ## Joining/Leaving Groups
/// Use ``HasRemoteCallAdapter/join(scope:group:)`` to add an actor to a process group.
///
/// ```swift
/// myActor.join(group: "my_group")
/// ```
///
/// - Note: By default, the scope `pg` will be used.
///
/// Use ``HasRemoteCallAdapter/leave(scope:group:)`` to leave a group.
public struct ProcessGroupRemoteCallAdapter: RemoteCallAdapter {
    let adapter: any RemoteCallAdapter
    
    init(_ adapter: some RemoteCallAdapter) {
        self.adapter = adapter
    }
    
    public func encode(
        _ invocation: RemoteCallInvocation,
        for system: ActorSystem
    ) throws -> EncodedRemoteCall {
        try adapter.encode(invocation, for: system)
    }
    
    public func decode(
        _ message: ErlangTermBuffer,
        for system: ActorSystem
    ) throws -> LocalCallInvocation {
        try adapter.decode(message, for: system)
    }
}

extension RemoteCallAdapter where Self == ProcessGroupRemoteCallAdapter {
    public static var processGroup: Self { .init(.primitive) }
    public static func processGroup(_ adapter: some RemoteCallAdapter) -> Self { .init(adapter) }
}

extension HasRemoteCallAdapter where Self: DistributedActor, RemoteCallAdapterType == ProcessGroupRemoteCallAdapter, ActorSystem == ErlangActorSystem {
    /// Join this process to a group in a given scope.
    public func join(
        scope: String = "pg",
        group: String
    ) async throws {
        try await ProcessGroups.resolve(scope: scope, using: actorSystem) { pg in
            try await pg.joinLocal(group, process: self.id)
        }
    }
    
    /// Remove this process from a group in a given scope.
    public func leave(
        scope: String = "pg",
        group: String
    ) async throws {
        try await ProcessGroups.resolve(scope: scope, using: actorSystem) { pg in
            try await pg.leaveLocal(group, process: self.id)
        }
    }
}

@StableNames
public distributed actor ProcessGroups: HasRemoteCallAdapter {
    public typealias ActorSystem = ErlangActorSystem
    
    typealias Group = AtomTermEncoding
    
    public nonisolated var remoteCallAdapter: RemoteCallAdapterType {
        RemoteCallAdapterType()
    }
    
    public struct RemoteCallAdapterType: RemoteCallAdapter {
        let genServer = GenServerRemoteCallAdapter(Dispatcher())
        
        nonisolated(unsafe) static let termEncoder = {
            let encoder = TermEncoder()
            encoder.includeVersion = false
            return encoder
        }()
        
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
        
        public func encode(
            _ invocation: RemoteCallInvocation,
            for system: ActorSystem
        ) throws -> EncodedRemoteCall {
            switch invocation.identifier {
            case "discover", "join", "leave":
                let message = ErlangTermBuffer()
                message.newWithVersion()
                if invocation.arguments.isEmpty {
                    message.encode(atom: invocation.identifier)
                } else {
                    message.encode(tupleHeader: invocation.arguments.count + 1)
                    message.encode(atom: invocation.identifier)
                    
                    for argument in invocation.arguments {
                        message.append(try Self.termEncoder.encode(argument.value))
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
            
            switch String(cString: messageType, encoding: .utf8) {
            case "$gen_cast":
                let localCall = try genServer.decode(message, for: system)
                return localCall
            case let .some(identifier):
                index = tupleStartIndex
                message.skipTerm(index: &index)
                return LocalCallInvocation(
                    sender: nil,
                    identifier: identifier,
                    arguments: message[argumentsStartIndex...index],
                    resultHandler: nil
                )
            default:
                fatalError()
            }
        }
    }
    
    var state = State()
    let scope: String
    
    struct State: Codable {
        /// All locally joined groups
        var local: [ActorSystem.ActorID:[Group]] = [:]
        
        /// All remote joined groups
        var remote: [ActorSystem.ActorID:[Group:[ActorSystem.ActorID]]] = [:]
    }
    
    init(scope: String, actorSystem: ActorSystem) async throws {
        self.actorSystem = actorSystem
        
        self.scope = scope
        
        actorSystem.monitorNodes(self)
        
        // send "discover" to all nodes in the cluster
        try await broadcast(
            to: actorSystem.remoteNodes.withLock { $0.keys.map({ .name(scope, node: $0) }) }
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
    
    func leaveLocal(@AtomTermEncoding _ group: String, process: ActorSystem.ActorID) async throws {
        state.local[process]?.removeAll(where: { $0 == $group })
        try await broadcast(to: state.remote.keys) { remote in
            try await remote.leave(self.id, process, [$group])
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
    
    @StableName("discover")
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
    
    @StableName("sync")
    distributed func sync(_ peer: ActorSystem.ActorID, _ groups: [SyncGroup]) {
        self.state.remote[peer] = Dictionary(
            uniqueKeysWithValues: groups.map({
                ($0.$group, $0.processes.map({ .pid($0) }))
            })
        )
    }
    
    @StableName("join")
    distributed func join(_ peer: ActorSystem.ActorID, _ group: Group, _ process: ActorSystem.ActorID) async throws {
        self.state.remote[peer, default: [:]][group, default: []].insert(process, at: 0)
    }
    
    @StableName("leave")
    distributed func leave(_ peer: ActorSystem.ActorID, _ process: ActorSystem.ActorID, _ groups: [Group]) async throws {
        for group in groups {
            self.state.remote[peer, default: [:]][group, default: []].removeAll(where: { $0 == process })
        }
    }
}

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
        
        try container.encode(self.$group)
        try container.encode(self.processes)
    }
}

extension ProcessGroups {
    @discardableResult
    public static func start(
        scope: String = "pg",
        using actorSystem: ActorSystem
    ) async throws -> ProcessGroups? {
        try await resolve(scope: scope, using: actorSystem) { $0 }
    }
    
    /// List all local members of a group.
    public static func localMembers(
        scope: String = "pg",
        group: String,
        using actorSystem: ActorSystem
    ) async throws -> Set<ActorSystem.ActorID> {
        let group = AtomTermEncoding(wrappedValue: group)
        return try await resolve(scope: scope, using: actorSystem) { pg in
            Set(pg.state.local.filter({ $0.value.contains(group) }).keys)
        } ?? []
    }
    
    /// List all members of a group.
    public static func members(
        scope: String = "pg",
        group: String,
        using actorSystem: ActorSystem
    ) async throws -> Set<ActorSystem.ActorID> {
        let group = AtomTermEncoding(wrappedValue: group)
        return try await resolve(scope: scope, using: actorSystem) { pg in
            let local = Set(pg.state.local.filter({ $0.value.contains(group) }).keys)
            let remote = Set(pg.state.remote.values.flatMap({ $0[group, default: []] }))
            return local.union(remote)
        } ?? []
    }
    
    /// List all remote members of a group.
    public static func remoteMembers(
        scope: String = "pg",
        group: String,
        using actorSystem: ActorSystem
    ) async throws -> Set<ActorSystem.ActorID> {
        let group = AtomTermEncoding(wrappedValue: group)
        return try await resolve(scope: scope, using: actorSystem) { pg in
            return Set(pg.state.remote.values.flatMap({ $0[group, default: []] }))
        } ?? []
    }
    
    /// List all groups in the given scope.
    public static func groups(
        scope: String = "pg",
        using actorSystem: ActorSystem
    ) async throws -> Set<String> {
        return try await resolve(scope: scope, using: actorSystem) { pg in
            let local = Set(pg.state.local.flatMap(\.value).map(\.wrappedValue))
            let remote = Set(pg.state.remote.values.flatMap(\.keys).map(\.wrappedValue))
            return local.union(remote)
        } ?? []
    }
    
    /// Get or create a `ProcessGroups` instance with the given scope name.
    static func resolve<Result: Sendable>(
        scope: String,
        using actorSystem: ActorSystem,
        _ body: @Sendable (isolated ProcessGroups) async throws -> Result
    ) async throws -> Result? {
        let processGroups: ProcessGroups
        if let existingActor = try actorSystem.registeredNames[scope].flatMap({ try ProcessGroups.resolve(id: $0, using: actorSystem) }) {
            processGroups = existingActor
        } else {
            processGroups = try await ProcessGroups(scope: scope, actorSystem: actorSystem)
            actorSystem.register(processGroups, name: scope)
        }
        
        return try await processGroups.whenLocal(body)
    }
}

extension ProcessGroups: ErlangActorSystem.NodesMonitor {
    public func up(_ node: String) {
        guard let remote = try? ProcessGroups.resolve(id: .name(scope, node: node), using: actorSystem)
        else { return }
        Task {
            try await remote.discover(self.id)
        }
    }
    
    public func down(_ node: String) {
        return
    }
}
