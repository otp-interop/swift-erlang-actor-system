import Distributed

/// A type that can encode and decode remote calls for an actor.
public protocol RemoteCallAdapter {
    typealias ActorSystem = ErlangActorSystem
    typealias RemoteCallInvocation = ActorSystem.RemoteCallInvocation
    typealias LocalCallInvocation = ActorSystem.LocalCallInvocation
    
    func encode(
        _ invocation: RemoteCallInvocation,
        for system: ActorSystem
    ) throws -> EncodedRemoteCall
    
    func decode(
        _ message: ErlangTermBuffer,
        for system: ActorSystem
    ) throws -> LocalCallInvocation
}

/// A protocol that describes the ``RemoteCallAdapter`` to use for this actor.
public protocol HasRemoteCallAdapter {
    associatedtype RemoteCallAdapterType: RemoteCallAdapter
    
    /// The ``RemoteCallAdapter`` to use for this actor.
    ///
    /// If this is not set, the ``RemoteCallAdapter`` passed to
    /// ``ErlangActorSystem`` will be used instead.
    nonisolated var remoteCallAdapter: RemoteCallAdapterType { get }
}

extension ErlangActorSystem {
    public struct RemoteCallInvocation {
        public let identifier: String
        
        public let arguments: [RemoteCallArgument<any Codable>]
        
        public let returnType: Any.Type?
    }
    
    public struct LocalCallInvocation {
        public let sender: Term.PID?
        
        public let identifier: String
        
        public let arguments: ErlangTermBuffer
        
        public let resultHandler: (any ResultHandlerAdapter)?
        
        public init(
            sender: Term.PID?,
            identifier: String,
            arguments: ErlangTermBuffer,
            resultHandler: (any ResultHandlerAdapter)?
        ) {
            self.sender = sender
            self.identifier = identifier
            self.arguments = arguments
            self.resultHandler = resultHandler
        }
    }
}

public struct EncodedRemoteCall {
    public let message: ErlangTermBuffer
    public let continuationAdapter: (any ContinuationAdapter)?
    
    init(message: ErlangTermBuffer, continuationAdapter: (any ContinuationAdapter)?) {
        self.message = message
        self.continuationAdapter = continuationAdapter
    }
}

public protocol ResultHandlerAdapter {
    typealias Value = ErlangTermBuffer
    typealias Message = ErlangTermBuffer
    
    func encode(returning value: Value) throws -> Message
    func encodeVoid() throws -> Message
    func encode(throwing error: some Error) throws -> Message
}

public protocol ContinuationAdapter {
    func decode(_ message: ErlangTermBuffer) throws -> Result<ErlangTermBuffer, any Error>
}
