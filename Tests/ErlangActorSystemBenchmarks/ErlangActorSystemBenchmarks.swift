import Distributed
import ErlangActorSystem

@main
struct ErlangActorSystemBenchmarks {
    static let clock = ContinuousClock()
    
    static let n = 100_000
    
    static func main() async throws {
        let actorSystem1 = try await ErlangActorSystem(name: "a", cookie: "cookie")
        let actorSystem2 = try await ErlangActorSystem(name: "b", cookie: "cookie")
        try await actorSystem1.connect(to: actorSystem2.name)
        
        let actors = await benchmark(label: "create \(n) actors") {
            var actors = [PingPongActor]()
            for _ in 0..<n {
                let actor = PingPongActor(actorSystem: actorSystem1)
                actors.append(actor)
            }
            return actors
        }
        
        let remoteActors = try actors.map { localActor in
            try PingPongActor.resolve(id: localActor.id, using: actorSystem2)
        }
        
        try await benchmark(label: "ping \(n) remote actors") {
            try await withThrowingDiscardingTaskGroup { group in
                for actor in remoteActors {
                    group.addTask {
                        _ = try await actor.ping()
                    }
                }
            }
        }
    }
    
    static func benchmark<T>(
        label: String,
        _ block: @Sendable () async throws -> T
    ) async rethrows -> T {
        let start = clock.now
        let result = try await block()
        let duration = start.duration(to: .now)
        print("\(label) took \(duration)")
        return result
    }
}

@StableNames
distributed actor PingPongActor: HasRemoteCallAdapter {
    typealias ActorSystem = ErlangActorSystem
    
    nonisolated var remoteCallAdapter: some RemoteCallAdapter {
        .genServer
    }
    
    @StableName("ping")
    distributed func ping() -> String {
        return "pong"
    }
}
