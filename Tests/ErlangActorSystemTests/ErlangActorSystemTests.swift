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
        #expect(actorSystem1.remoteNodes.withLock { $0.count == 1 })
        #expect(actorSystem2.remoteNodes.withLock { $0.count == 1 })
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
