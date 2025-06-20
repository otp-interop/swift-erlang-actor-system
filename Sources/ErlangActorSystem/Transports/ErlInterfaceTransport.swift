import CErlInterface
#if canImport(Glibc)
import Glibc
#endif

public final class ErlInterfaceTransport: Transport {
    private var node: ei_cnode = ei_cnode()
    
    public var name: String {
        String(
            cString: [CChar](tuple: node.thisnodename, start: \.0),
            encoding: .utf8
        )!
    }
    
    public var cookie: String {
        String(
            cString: [CChar](tuple: node.ei_connect_cookie, start: \.0),
            encoding: .utf8
        )!
    }
    
    public var pid: Term.PID {
        Term.PID(pid: node.`self`)
    }
    
    private let backlog: Int
    
    public init(
        backlog: Int = 5
    ) {
        self.backlog = backlog
    }
    
    public func setup(name: String, cookie: String) throws {
        guard ei_connect_init(&node, name, cookie, UInt32(time(nil) + 1)) >= 0
        else { throw TransportError.initFailed }
    }
    
    public func setup(
        hostName: String,
        aliveName: String,
        nodeName: String,
        ipAddress: String,
        cookie: String
    ) throws {
        var addr = in_addr()
        inet_aton(ipAddress, &addr)
        guard ei_connect_xinit(
            &node,
            hostName,
            aliveName,
            nodeName,
            &addr,
            cookie,
            UInt32(time(nil) + 1)
        ) >= 0
        else { throw TransportError.initFailed }
    }
    
    public func listen(port: Int) throws -> (socket: ListenSocket, port: Int) {
        var port = Int32(port)
        let listen = ei_listen(&node, &port, 5)
        guard listen > 0
        else { throw TransportError.listenFailed }
        return (socket: listen, port: Int(port))
    }
    
    public func publish(port: Int) throws {
        guard ei_publish(&node, Int32(port)) != -1
        else { throw TransportError.publishFailed }
    }
    
    public func accept(from listen: ListenSocket) throws -> (socket: AcceptSocket, name: String) {
        var conn = ErlConnect()
        let fileDescriptor = ei_accept(&node, listen, &conn)
        guard fileDescriptor >= 0,
              let nodeName = String(cString: [CChar](tuple: conn.nodename, start: \.0), encoding: .utf8)
        else { throw TransportError.acceptFailed }
        return (socket: fileDescriptor, name: nodeName)
    }
    
    public func connect(to nodeName: String) throws -> AcceptSocket {
        let fileDescriptor = nodeName.withCString { nodeName in
            ei_connect(&node, UnsafeMutablePointer(mutating: nodeName))
        }
        guard fileDescriptor >= 0
        else { throw TransportError.connectFailed }
        return fileDescriptor
    }
    
    public func connect(to ipAddress: String, port: Int) throws -> AcceptSocket {
        var addr = in_addr()
        _ = ipAddress.withCString { ipAddress in
            inet_aton(ipAddress, &addr)
        }
        let fileDescriptor = ei_xconnect_host_port(&node, &addr, Int32(port))
        
        guard fileDescriptor >= 0
        else { throw TransportError.connectFailed }
        
        return fileDescriptor
    }
    
    @MainActor
    public func send(_ message: SendMessage, on socket: AcceptSocket) async throws {
        switch message.recipient {
        case let .pid(pid):
            var pid = pid.pid
            guard ei_send(
                socket,
                &pid,
                message.content.buff,
                message.content.buffsz
            ) >= 0
            else { throw TransportError.sendFailed }
        case let .name(name):
            try name.withCString { name in
                guard ei_reg_send(
                    &self.node,
                    socket,
                    UnsafeMutablePointer(mutating: name),
                    message.content.buff,
                    message.content.index
                ) >= 0
                else { throw ErlangActorSystemError.sendFailed }
            }
        }
    }
    
    public func receive(on socket: AcceptSocket) throws -> ReceiveResult {
        var message = erlang_msg()
        let content = ErlangTermBuffer()
        content.new()
        
        switch ei_xreceive_msg(socket, &message, &content.buffer) {
        case ERL_TICK:
            return .tick
        case ERL_ERROR:
            throw ReceiveError.receiveFailed
        case ERL_MSG:
            return .success(Message(
                info: Message.Info(
                    kind: Message.Kind(rawValue: message.msgtype) ?? .unknown,
                    sender: Term.PID(pid: message.from),
                    recipient: Term.PID(pid: message.to),
                    namedRecipient: String(cString: Array(tuple: message.toname, start: \.0), encoding: .utf8)!
                ),
                content: content
            ))
        case let messageKind:
            throw ReceiveError.unknownMessageKind(messageKind)
        }
    }
    
    enum ReceiveError: Error {
        case receiveFailed
        case unknownMessageKind(Int32)
    }
    
    public func makePID() -> Term.PID {
        var pid = erlang_pid()
        ei_make_pid(&node, &pid)
        return Term.PID(pid: pid)
    }
    
    public func makeReference() -> Term.Reference {
        var ref = erlang_ref()
        ei_make_ref(&node, &ref)
        return Term.Reference(ref: ref)
    }
    
    enum TransportError: Error {
        case initFailed
        case listenFailed
        case publishFailed
        case acceptFailed
        case connectFailed
        case sendFailed
    }
}
