import erl_interface

public struct ErlInterfaceTransport: Transport {
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
        erl_interface.ei_init()
        
        self.backlog = backlog
    }
    
    public mutating func setup(name: String, cookie: String) throws {
        guard ei_connect_init(&node, name, cookie, UInt32(time(nil) + 1)) >= 0
        else { throw TransportError.initFailed }
    }
    
    public mutating func setup(
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
    
    public mutating func listen(port: Int) throws -> (socket: ListenSocket, port: Int) {
        var port = Int32(port)
        let listen = ei_listen(&node, &port, 5)
        guard listen > 0
        else { throw TransportError.listenFailed }
        return (socket: listen, port: Int(port))
    }
    
    public mutating func publish(port: Int) throws {
        guard ei_publish(&node, Int32(port)) != -1
        else { throw TransportError.publishFailed }
    }
    
    public mutating func accept(from listen: ListenSocket) throws -> (socket: AcceptSocket, name: String) {
        var conn = ErlConnect()
        let fileDescriptor = ei_accept(&node, listen, &conn)
        guard fileDescriptor >= 0,
              let nodeName = String(cString: [CChar](tuple: conn.nodename, start: \.0), encoding: .utf8)
        else { throw TransportError.acceptFailed }
        return (socket: fileDescriptor, name: nodeName)
    }
    
    public mutating func connect(to nodeName: String) throws -> AcceptSocket {
        let fileDescriptor = ei_connect(&node, strdup(nodeName))
        guard fileDescriptor >= 0
        else { throw TransportError.connectFailed }
        return fileDescriptor
    }
    
    public mutating func connect(to ipAddress: String, port: Int) throws -> AcceptSocket {
        var addr = in_addr()
        inet_aton(strdup(ipAddress), &addr)
        let fileDescriptor = ei_xconnect_host_port(&node, &addr, Int32(port))
        
        guard fileDescriptor >= 0
        else { throw TransportError.connectFailed }
        
        return fileDescriptor
    }
    
    public mutating func send(_ message: ErlangTermBuffer, to pid: Term.PID, on socket: AcceptSocket) throws {
        var pid = pid.pid
        guard ei_send(
            socket,
            &pid,
            message.buff,
            message.buffsz
        ) >= 0
        else { throw TransportError.sendFailed }
    }
    
    public mutating func send(_ message: ErlangTermBuffer, to name: String, on socket: AcceptSocket) throws {
        guard ei_reg_send(
            &self.node,
            socket,
            strdup(name),
            message.buff,
            message.index
        ) >= 0
        else { throw ErlangActorSystemError.sendFailed }
    }
    
    public mutating func makePID() -> Term.PID {
        var pid = erlang_pid()
        ei_make_pid(&node, &pid)
        return Term.PID(pid: pid)
    }
    
    public mutating func makeReference() -> Term.Reference {
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
