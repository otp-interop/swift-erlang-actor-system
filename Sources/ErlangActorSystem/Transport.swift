import Synchronization

public protocol Transport {
    typealias ListenSocket = Int32
    typealias AcceptSocket = Int32
    
    mutating func setup(name: String, cookie: String) async throws
    
    mutating func setup(
        hostName: String,
        aliveName: String,
        nodeName: String,
        ipAddress: String,
        cookie: String
    ) async throws
    
    var name: String { get }
    var cookie: String { get }
    var pid: Term.PID { get }
    
    mutating func listen(port: Int) async throws -> (socket: ListenSocket, port: Int)
    
    mutating func publish(port: Int) async throws
    
    mutating func accept(from listen: ListenSocket) async throws -> (socket: AcceptSocket, name: String)
    
    mutating func connect(to nodeName: String) async throws -> AcceptSocket
    
    mutating func connect(to ipAddress: String, port: Int) async throws -> AcceptSocket
    
    mutating func send(_ message: SendMessage, on socket: AcceptSocket) async throws
    
    func receive(on socket: AcceptSocket) throws -> ReceiveResult
    
    mutating func makePID() -> Term.PID
    mutating func makeReference() -> Term.Reference
}

/// This type only exists to make `ErlangTermBuffer` sendable. It is not sendable, and should not be
/// modified concurrently. However, `send(_:on:)` hands the value off to the `Transport`, so it should
/// be safe.
///
/// Ideally, we should be able to specify `sending ErlangTermBuffer` as an argument in a protocol.
/// However, there is a bug in Swift 6.1 (and possibly 6.2) that prevents this from working.
/// It looks like it has been fixed on `main` though, so we should be able to drop it in the next Swift version.
///
/// https://github.com/swiftlang/swift/issues/78588 (merged April 26, 2025)
public struct SendMessage: @unchecked Sendable {
    let content: ErlangTermBuffer
    let recipient: Recipient
    
    enum Recipient: Sendable {
        case pid(Term.PID)
        case name(String)
    }
}

public enum ReceiveResult {
    case tick
    case success(Message)
}

public struct Message {
    public let info: Info
    public let content: ErlangTermBuffer
    
    public struct Info: Sendable {
        public let kind: Kind
        public let sender: Term.PID
        public let recipient: Term.PID
        public let namedRecipient: String
        
        public init(
            kind: Kind,
            sender: Term.PID,
            recipient: Term.PID,
            namedRecipient: String
        ) {
            self.kind = kind
            self.sender = sender
            self.recipient = recipient
            self.namedRecipient = namedRecipient
        }
    }
    
    public enum Kind: Int, Sendable {
        case link = 1
        case send = 2
        case exit = 3
        case unlink = 4
        case nodeLink = 5
        case regSend = 6
        case groupLeader = 7
        case exit2 = 8
        case passThrough = 112
        
        case sendTraceToken = 12
        case exitTraceToken = 13
        case regSendTraceToken = 16
        case exit2TraceToken = 18
        case monitorProcess = 19
        case demonitorProcess = 20
        case monitorProcessExit = 21
        
        case unknown = -1
    }
    
    public init(
        info: Info,
        content: ErlangTermBuffer
    ) {
        self.info = info
        self.content = content
    }
}
