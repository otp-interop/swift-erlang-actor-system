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
    
    mutating func send(_ message: ErlangTermBuffer, to pid: Term.PID, on socket: AcceptSocket) throws
    
    mutating func send(_ message: ErlangTermBuffer, to name: String, on socket: AcceptSocket) throws
    
    mutating func makePID() -> Term.PID
    mutating func makeReference() -> Term.Reference
}
