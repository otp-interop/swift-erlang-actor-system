import Testing
import Distributed
import Foundation
@testable import ErlangActorSystem

@Suite("Erlang Actor System Tests", .serialized) struct ErlangActorSystemTests {
    @Test func connectActors() async throws {
        let cookie = UUID().uuidString
        
        let actorSystem1 = try await ErlangActorSystem(name: UUID().uuidString, cookie: cookie)
        let actorSystem2 = try await ErlangActorSystem(name: UUID().uuidString, cookie: cookie)
        try await actorSystem1.connect(to: actorSystem2.name)
        #expect(actorSystem1.remoteNodes.count == 1)
        #expect(actorSystem2.remoteNodes.count == 1)
    }
    
    @Test func remoteCall() async throws {
        distributed actor TestActor {
            typealias ActorSystem = ErlangActorSystem
            
            distributed func ping() -> String {
                return "pong"
            }
            
            distributed func greet(_ name: String) -> String {
                return "Hello, \(name)!"
            }
        }
        
        let cookie = UUID().uuidString
        
        let actorSystem1 = try await ErlangActorSystem(name: UUID().uuidString, cookie: cookie)
        let actorSystem2 = try await ErlangActorSystem(name: UUID().uuidString, cookie: cookie)
        try await actorSystem1.connect(to: actorSystem2.name)
        
        let actor = TestActor(actorSystem: actorSystem2)
        
        let remoteActor = try TestActor.resolve(id: actor.id, using: actorSystem1)
        
        await remoteActor.whenLocal { _ in
            #expect(Bool(false), "Remote actor should not be local")
        }
        
        #expect(try await remoteActor.ping() == "pong")
        #expect(try await remoteActor.greet("John Doe") == "Hello, John Doe!")
    }
    
    @StableNames
    distributed actor StableNameTestActor {
        typealias ActorSystem = ErlangActorSystem
        
        @StableName("ping")
        distributed func ping() -> String {
            return "pong"
        }
    }
    
    @Test func stableNameRemoteCall() async throws {
        let cookie = UUID().uuidString
        
        let actorSystem1 = try await ErlangActorSystem(name: UUID().uuidString, cookie: cookie)
        let actorSystem2 = try await ErlangActorSystem(name: UUID().uuidString, cookie: cookie)
        try await actorSystem1.connect(to: actorSystem2.name)
        
        let actor = StableNameTestActor(actorSystem: actorSystem2)
        
        let remoteActor = try StableNameTestActor.resolve(id: actor.id, using: actorSystem1)
        
        await remoteActor.whenLocal { _ in
            #expect(Bool(false), "Remote actor should not be local")
        }
        
        var encoder = actorSystem1.makeInvocationEncoder()
        try encoder.doneRecording()
        #expect(try await actorSystem1.remoteCall(
            on: remoteActor,
            target: RemoteCallTarget("ping"),
            invocation: &encoder,
            throwing: (any Error).self,
            returning: String.self
        ) == "pong")
    }
    
    @Test func remoteComputedProperty() async throws {
        distributed actor CounterActor {
            typealias ActorSystem = ErlangActorSystem
            
            private var _count: Int = 0
            
            distributed var count: Int {
                _count
            }
            
            distributed func increment() {
                _count += 1
            }
        }
        
        let cookie = UUID().uuidString
        
        let actorSystem1 = try await ErlangActorSystem(name: UUID().uuidString, cookie: cookie)
        let actorSystem2 = try await ErlangActorSystem(name: UUID().uuidString, cookie: cookie)
        try await actorSystem1.connect(to: actorSystem2.name)
        
        let actor = CounterActor(actorSystem: actorSystem1)
        #expect(try await actor.count == 0)
        try await actor.increment()
        #expect(try await actor.count == 1)
        
        let remote = try CounterActor.resolve(id: actor.id, using: actorSystem2)
        await remote.whenLocal { _ in
            #expect(Bool(false), "Remote actor should not be local")
        }
        
        #expect(try await remote.count == 1)
        try await remote.increment()
        #expect(try await remote.count == 2)
    }
    
    @StableNames
    distributed actor StableNameCounterActor {
        typealias ActorSystem = ErlangActorSystem
        
        private var _count: Int = 0
        
        @StableName("count")
        distributed var count: Int {
            _count
        }
        
        @StableName("increment")
        distributed func increment() {
            _count += 1
        }
    }
    
    @Test func stableNameRemoteComputedProperty() async throws {
        let cookie = UUID().uuidString
        
        let actorSystem1 = try await ErlangActorSystem(name: UUID().uuidString, cookie: cookie)
        let actorSystem2 = try await ErlangActorSystem(name: UUID().uuidString, cookie: cookie)
        try await actorSystem1.connect(to: actorSystem2.name)
        
        let actor = StableNameCounterActor(actorSystem: actorSystem1)
        #expect(try await actor.count == 0)
        try await actor.increment()
        #expect(try await actor.count == 1)
        
        let remote = try StableNameCounterActor.resolve(id: actor.id, using: actorSystem2)
        await remote.whenLocal { _ in
            #expect(Bool(false), "Remote actor should not be local")
        }
        
        var encoder = actorSystem2.makeInvocationEncoder()
        try encoder.doneRecording()
        #expect(try await actorSystem2.remoteCall(
            on: remote,
            target: RemoteCallTarget("count"),
            invocation: &encoder,
            throwing: (any Error).self,
            returning: Int.self
        ) == 1)
        
        encoder = actorSystem2.makeInvocationEncoder()
        try encoder.doneRecording()
        try await actorSystem2.remoteCallVoid(
            on: remote,
            target: RemoteCallTarget("increment"),
            invocation: &encoder,
            throwing: (any Error).self
        )
        
        encoder = actorSystem2.makeInvocationEncoder()
        try encoder.doneRecording()
        #expect(try await actorSystem2.remoteCall(
            on: remote,
            target: RemoteCallTarget("count"),
            invocation: &encoder,
            throwing: (any Error).self,
            returning: Int.self
        ) == 2)
    }
    
    @StableNames
    distributed actor ProcessGroupTestActor: HasRemoteCallAdapter {
        typealias ActorSystem = ErlangActorSystem
        
        nonisolated var remoteCallAdapter: ProcessGroupRemoteCallAdapter {
            .processGroup
        }
        
        @StableName("test")
        distributed func test() {
            
        }
    }
    
    @Test func processGroups() async throws {
        let cookie = UUID().uuidString
        let actorSystem1 = try await ErlangActorSystem(name: UUID().uuidString, cookie: cookie)
        let actorSystem2 = try await ErlangActorSystem(name: UUID().uuidString, cookie: cookie)
        
        try await ProcessGroups.start(using: actorSystem1)
        try await ProcessGroups.start(using: actorSystem2)
        
        try await actorSystem1.connect(to: actorSystem2.name)
        
        let system1actor1 = ProcessGroupTestActor(actorSystem: actorSystem1)
        try await system1actor1.join(group: "group_1")
        
        let system1actor2 = ProcessGroupTestActor(actorSystem: actorSystem1)
        try await system1actor2.join(group: "group_2")
        
        let system2actor1 = ProcessGroupTestActor(actorSystem: actorSystem2)
        try await system2actor1.join(group: "group_1")
        
        let system2actor2 = ProcessGroupTestActor(actorSystem: actorSystem2)
        try await system2actor2.join(group: "group_2")
        
        #expect(try await ProcessGroups.groups(using: actorSystem1) == ["group_1", "group_2"])
        #expect(try await ProcessGroups.groups(using: actorSystem2) == ["group_1", "group_2"])
        
        #expect(try await ProcessGroups.localMembers(group: "group_1", using: actorSystem1) == [system1actor1.id])
        #expect(try await ProcessGroups.localMembers(group: "group_2", using: actorSystem1) == [system1actor2.id])
        
        #expect(try await ProcessGroups.localMembers(group: "group_1", using: actorSystem2) == [system2actor1.id])
        #expect(try await ProcessGroups.localMembers(group: "group_2", using: actorSystem2) == [system2actor2.id])
        
        var members: Set<ErlangActorSystem.ActorID>
        repeat {
            members = try await ProcessGroups.members(group: "group_1", using: actorSystem1)
        } while members != [system1actor1.id, system2actor1.id]
        #expect(members == [system1actor1.id, system2actor1.id])
        
        for member in try await ProcessGroups.members(group: "group_2", using: actorSystem2) {
            let actor = try ProcessGroupTestActor.resolve(id: member, using: actorSystem2)
            try await actor.test()
        }
    }
    
    @StableNames
    distributed actor PubSubTest: HasRemoteCallAdapter {
        typealias ActorSystem = ErlangActorSystem
        
        nonisolated var remoteCallAdapter: some RemoteCallAdapter {
            .primitive
        }
        
        @StableName("hello_world")
        distributed func helloWorld() {
            print("Received hello world event")
        }
    }
    
    @Test func pubSub() async throws {
        let actorSystem = try await ErlangActorSystem(name: "swift", cookie: "LJTPNYYQIOIRKYDCWCQH")
        try await actorSystem.connect(to: "iex@DCKYRD-NMXCKatri")
        
        let actor = PubSubTest(actorSystem: actorSystem)
        
        let pubSub = try await PubSub(name: "test_pubsub", actorSystem: actorSystem)
        
        await pubSub.whenLocal {
            $0.subscribe(actor, to: "topic")
        }
        
        print("joined")
        
        try await pubSub.whenLocal { try await $0.broadcast(Term.atom("hello_world"), to: "topic") }
        
        try await Task.sleep(for: .seconds(1024))
    }
    
    @Resolvable
    @StableNames
    protocol CounterProtocol: DistributedActor, HasStableNames where ActorSystem == ErlangActorSystem {
        @StableName("count")
        distributed var count: Int { get }
        
        @StableName("increment")
        distributed func increment()
        
        @StableName("decrement")
        distributed func decrement()
    }
    
    @StableNames
    distributed actor Counter: CounterProtocol {
        var _count = 0
        
        @StableName("count")
        distributed var count: Int {
            _count
        }
        
        @StableName("increment")
        distributed func increment() {
            _count += 1
        }
        
        @StableName("decrement")
        distributed func decrement() {
            _count -= 1
        }
    }
    
    @Test func protocols() async throws {
        let cookie = UUID().uuidString
        let actorSystem1 = try await ErlangActorSystem(name: UUID().uuidString, cookie: cookie)
        let actorSystem2 = try await ErlangActorSystem(name: UUID().uuidString, cookie: cookie)
        
        try await actorSystem1.connect(to: actorSystem2.name)
        
        let local = Counter(actorSystem: actorSystem1)
        actorSystem1.register(local, name: "counter")
        
        let remote: some CounterProtocol = try $CounterProtocol.resolve(
            id: .name("counter", node: actorSystem1.name),
            using: actorSystem2
        )
        
        #expect(try await remote.count == 0)
        try await remote.increment()
        try await remote.increment()
        try await remote.increment()
        #expect(try await remote.count == 3)
        try await remote.decrement()
        #expect(try await remote.count == 2)
    }
}

import CErlInterface

/// ```elixir
/// {:forward_to_local, "<topic>", <message>, <dispatcher>}
/// ```
///
/// 'Elixir.Phoenix.PubSub'
struct PubSubRemoteCallAdapter: RemoteCallAdapter {
    let topic: String
    let primitive = PrimitiveRemoteCallAdapter()
    
    func encode(
        _ invocation: RemoteCallInvocation,
        for system: ActorSystem
    ) throws -> EncodedRemoteCall {
        let message = ErlangTermBuffer()
        message.newWithVersion()
        message.encode(tupleHeader: 4)
        _ = Data(topic.utf8).withUnsafeBytes {
            message.encode(binary: $0.baseAddress!, len: Int32($0.count))
        }
        
        message.append(try primitive.encode(invocation, for: system).message)
        
        message.encode(atom: "Elixir.Phoenix.PubSub")
        print(message)
        
        return EncodedRemoteCall(
            message: message,
            continuationAdapter: nil
        )
    }
    
    func decode(
        _ message: ErlangTermBuffer,
        for system: ActorSystem
    ) throws -> LocalCallInvocation {
        var index: Int32 = 0
        
        var version: Int32 = 0
        message.decode(version: &version, index: &index)
        
        var arity: Int32 = 0
        message.decode(tupleHeader: &arity, index: &index)
        
        message.skipTerm(index: &index) // :forward_to_local
        
        var type: UInt32 = 0
        var size: Int32 = 0
        message.getType(type: &type, size: &size, index: &index)
        let binary: UnsafeMutableRawPointer = .allocate(byteCount: Int(size), alignment: 0)
        var length: Int = 0
        message.decode(binary: binary, len: &length, index: &index)
        let topic = String(data: Data(bytes: binary, count: length), encoding: .utf8)!
        guard topic == self.topic else { throw PubSubError.unhandledTopic(topic) }
        
        let messageStart = index
        message.skipTerm(index: &index)
        
        return try primitive.decode(message[messageStart..<index], for: system)
    }
    
    enum PubSubError: Error {
        case unhandledTopic(String)
    }
}

extension RemoteCallAdapter where Self == ProcessGroupRemoteCallAdapter {
    static func pubSub(topic: String) -> ProcessGroupRemoteCallAdapter {
        .processGroup(PubSubRemoteCallAdapter(topic: topic))
    }
}

@StableNames
public distributed actor PubSub: HasRemoteCallAdapter {
    public typealias ActorSystem = ErlangActorSystem
    
    private let name: String
    private var subscribers = [String:Set<ActorSystem.ActorID>]()
    
    public nonisolated var remoteCallAdapter: ProcessGroupRemoteCallAdapter {
        .processGroup
    }
    
    public init(name: String, actorSystem: ActorSystem) async throws {
        self.name = name
        self.actorSystem = actorSystem
        
        try await self.join(
            scope: "Elixir.Phoenix.PubSub",
            group: "Elixir.\(name).Adapter"
        )
    }
    
    @StableName("forward_to_local")
    distributed func forwardToLocal(topic: String, message: Term, dispatcher: String) async throws {
        for subscriber in subscribers[topic] ?? [] {
            guard let actor = actorSystem.resolve(id: subscriber)
            else { continue }
            
            let remoteCallAdapter = (actor as? any HasRemoteCallAdapter)?.remoteCallAdapter ?? actorSystem.remoteCallAdapter
            let localCall = try remoteCallAdapter.decode(message.makeBuffer(), for: actorSystem)
            
            nonisolated(unsafe) let handler = ActorSystem.ResultHandler(
                sender: localCall.sender,
                resultHandlerAdapter: localCall.resultHandler,
                fileDescriptor: 0
            )
            
            let decoder = TermDecoder()
            nonisolated(unsafe) var invocationDecoder = ActorSystem.InvocationDecoder(
                buffer: localCall.arguments,
                decoder: decoder,
                index: 0
            )
            
            if let stableNamed = actor as? any HasStableNames {
                try! await stableNamed._executeStableName(
                    target: RemoteCallTarget(localCall.identifier),
                    invocationDecoder: &invocationDecoder,
                    handler: handler
                )
            } else {
                try await actorSystem.executeDistributedTarget(
                    on: actor,
                    target: RemoteCallTarget(localCall.identifier),
                    invocationDecoder: &invocationDecoder,
                    handler: handler
                )
            }
        }
    }
    
    public func subscribe<Act>(_ act: Act, to topic: String)
        where Act: DistributedActor, Act.ID == ActorSystem.ActorID
    {
        subscribers[topic, default: []].insert(act.id)
    }
    
    public func unsubscribe<Act>(_ act: Act, to topic: String)
        where Act: DistributedActor, Act.ID == ActorSystem.ActorID
    {
        subscribers[topic]?.remove(act.id)
    }
    
    public func localBroadcast<Act: DistributedActor>(
        to topic: String,
        as actorType: Act.Type = Act.self,
        _ body: @Sendable (Act) async throws -> ()
    ) async throws where Act.ID == ActorSystem.ActorID {
        for subscriber in subscribers["topic"] ?? [] {
            guard let actor = try actorSystem.resolve(id: subscriber, as: actorType)
            else { continue }
            try await body(actor)
        }
    }
    
    public func broadcast(
        _ message: some Encodable,
        to topic: String
    ) async throws {
        let encoder = TermEncoder()
        encoder.includeVersion = false
        let message = try Term(from: encoder.encode(message))
        
        try await forwardToLocal(topic: topic, message: message, dispatcher: "Elixir.Phoenix.PubSub")
        
        for member in try await ProcessGroups.remoteMembers(
            scope: "Elixir.Phoenix.PubSub",
            group: "Elixir.\(name).Adapter",
            using: actorSystem
        ) {
            print(member)
            let remote = try PubSub.resolve(id: member, using: actorSystem)
            try await remote.forwardToLocal(topic: topic, message: message, dispatcher: "Elixir.Phoenix.Pubsub")
        }
    }
}
