import Distributed

@attached(peer)
public macro StableName(_ name: StaticString, mangledName: StaticString? = nil) = #externalMacro(module: "DistributedMacros", type: "StableName")

@attached(
    extension,
    conformances: _HasStableNames,
    names: named(_executeStableName), named(_stableNames), named(RemoteActor)
)
@attached(peer, names: prefixed(_RemoteActorFor))
public macro StableNames() = #externalMacro(module: "DistributedMacros", type: "StableNames")

@attached(body)
public macro RemoteDeclaration(_ name: StaticString) = #externalMacro(module: "DistributedMacros", type: "RemoteDeclaration")

public protocol _HasStableNames: Actor {
    nonisolated func _executeStableName(
        target: RemoteCallTarget,
        invocationDecoder: inout ErlangActorSystem.InvocationDecoder,
        handler: ErlangActorSystem.ResultHandler
    ) async throws
    
    nonisolated var _stableNames: [String:String] { get }
}
