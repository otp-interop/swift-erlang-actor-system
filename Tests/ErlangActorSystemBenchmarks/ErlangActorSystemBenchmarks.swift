import Distributed
import ErlangActorSystem

@main
struct ErlangActorSystemBenchmarks {
    static func main() async throws {
        let actorSystem = try await ErlangActorSystem(name: "benchmark", cookie: "cookie")
        
        var actors = [PingPongActor]()
        let clock = ContinuousClock()
        let start = clock.now
        
        for _ in 0..<1_000_000 {
            let actor = PingPongActor(actorSystem: actorSystem)
            actors.append(actor)
        }
        
        let result = start.duration(to: .now)
        print(result)
    }
}

distributed actor PingPongActor {
    typealias ActorSystem = ErlangActorSystem
    
    distributed func ping() -> String {
        return "pong"
    }
}
