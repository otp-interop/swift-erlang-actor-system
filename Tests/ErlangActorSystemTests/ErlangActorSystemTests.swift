import Testing
import Distributed
import Foundation
@testable import ErlangActorSystem

@Suite("Erlang Actor System Tests", .serialized) struct ErlangActorSystemTests {
    @Test func connectActors() async throws {
        let cookie = UUID().uuidString
        
        let actorSystem1 = try ErlangActorSystem(name: UUID().uuidString, cookie: cookie)
        let actorSystem2 = try ErlangActorSystem(name: UUID().uuidString, cookie: cookie)
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
        }
        
        let cookie = UUID().uuidString
        
        let actorSystem1 = try ErlangActorSystem(name: UUID().uuidString, cookie: cookie)
        let actorSystem2 = try ErlangActorSystem(name: UUID().uuidString, cookie: cookie)
        try await actorSystem1.connect(to: actorSystem2.name)
        
        let actor = TestActor(actorSystem: actorSystem2)
        
        let remoteActor = try TestActor.resolve(id: actor.id, using: actorSystem1)
        
        await remoteActor.whenLocal { _ in
            #expect(Bool(false), "Remote actor should not be local")
        }
        
        #expect(try await remoteActor.ping() == "pong")
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
        
        let actorSystem1 = try ErlangActorSystem(name: UUID().uuidString, cookie: cookie)
        let actorSystem2 = try ErlangActorSystem(name: UUID().uuidString, cookie: cookie)
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
        
        let actorSystem1 = try ErlangActorSystem(name: UUID().uuidString, cookie: cookie)
        let actorSystem2 = try ErlangActorSystem(name: UUID().uuidString, cookie: cookie)
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
        
        let actorSystem1 = try ErlangActorSystem(name: UUID().uuidString, cookie: cookie)
        let actorSystem2 = try ErlangActorSystem(name: UUID().uuidString, cookie: cookie)
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
}
