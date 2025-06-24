import CErlInterface
import Foundation

/// An adapter that handles messages as a [`GenServer`](https://hexdocs.pm/elixir/GenServer.html).
///
/// ## Encoding
/// The invocation will be run through the provided
/// ``GenServerRemoteCallAdapter/Dispatcher`` to determine whether to send a
/// `cast` or `call` to the remote `GenServer`.
///
/// The message will then be encoded with the following format:
///
/// ```elixir
/// {:"$gen_cast", <message>}
/// # or
/// {:"$gen_call", {<from_pid>, <monitor_ref>}, <message>}
/// ```
public struct GenServerRemoteCallAdapter: RemoteCallAdapter {
    let dispatcher: any Dispatcher
    
    public init(_ dispatcher: any Dispatcher = .castVoid) {
        self.dispatcher = dispatcher
    }
    
    public func encode(
        _ invocation: RemoteCallInvocation,
        for system: ActorSystem
    ) throws -> EncodedRemoteCall {
        let message = ErlangTermBuffer()
        message.newWithVersion()
        
        switch dispatcher.dispatch(invocation) {
        case .call:
            // {:"$gen_call", {<from_pid>, <monitor_ref>}, <message>}
            message.encode(tupleHeader: 3)
            message.encode(atom: "$gen_call")
            
            var callReference = Term.Reference(for: system)
            
            message.encode(tupleHeader: 2)
            var pid = system.pid.pid
            message.encode(pid: &pid)
            message.encode(listHeader: 2)
            message.encode(atom: "alias")
            message.encode(ref: &callReference.ref)
            message.encodeEmptyList()
            
            if invocation.arguments.isEmpty {
                message.encode(atom: invocation.identifier)
            } else {
                message.encode(tupleHeader: invocation.arguments.count + 1) // {:target, args...}
                message.encode(atom: invocation.identifier)
                
                let encoder = TermEncoder()
                encoder.includeVersion = false
                for argument in invocation.arguments {
                    message.append(try encoder.encode(argument.value))
                }
            }
            
            return EncodedRemoteCall(
                message: message,
                continuationAdapter: CallContinuation(monitorReference: callReference)
            )
        case .cast:
            // {:"$gen_cast", <message>}
            message.encode(tupleHeader: 2)
            message.encode(atom: "$gen_cast")
            
            if invocation.arguments.isEmpty {
                message.encode(atom: invocation.identifier)
            } else {
                message.encode(tupleHeader: invocation.arguments.count + 1) // {:target, args...}
                message.encode(atom: invocation.identifier)
                
                let encoder = TermEncoder()
                encoder.includeVersion = false
                for argument in invocation.arguments {
                    message.append(try encoder.encode(argument.value))
                }
            }
            
            return EncodedRemoteCall(
                message: message,
                continuationAdapter: nil
            )
        }
    }
    
    public func decode(
        _ message: ErlangTermBuffer,
        for system: ActorSystem
    ) throws -> LocalCallInvocation {
        var index: Int32 = 0
        
        var version: Int32 = 0
        message.decode(version: &version, index: &index)
        
        var arity: Int32 = 0
        guard message.decode(tupleHeader: &arity, index: &index)
        else { throw DecodingError.dataCorrupted }
        
        var atom: [CChar] = [CChar](repeating: 0, count: Int(MAXATOMLEN))
        guard message.decode(atom: &atom, index: &index),
              let atom = String(cString: atom, encoding: .utf8),
              let dispatchFormat = DispatchFormat(rawValue: atom)
        else { throw DecodingError.dataCorrupted }
        
        switch dispatchFormat {
        case .cast:
            var messageType: UInt32 = 0
            var size: Int32 = 0
            message.getType(type: &messageType, size: &size, index: &index)
            
            switch Character(UnicodeScalar(messageType)!) {
            case "d", "s", "v": // no arguments call
                var target: [CChar] = [CChar](repeating: 0, count: Int(MAXATOMLEN))
                message.decode(atom: &target, index: &index)
                
                let identifier = String(cString: target, encoding: .utf8)!
                return LocalCallInvocation(
                    sender: nil,
                    identifier: identifier,
                    arguments: message[index...],
                    resultHandler: nil
                )
            case "h" where size > 0,
                 "i" where size > 0: // tuple arguments
                var tupleStartIndex = index
                
                message.decode(tupleHeader: &size, index: &index)
                var target: [CChar] = [CChar](repeating: 0, count: Int(MAXATOMLEN))
                message.decode(atom: &target, index: &index)
                
                let argumentsStartIndex = index
                message.skipTerm(index: &tupleStartIndex)
                let arguments = message[argumentsStartIndex...tupleStartIndex]
                
                let identifier = String(cString: target, encoding: .utf8)!
                return LocalCallInvocation(
                    sender: nil,
                    identifier: identifier,
                    arguments: arguments,
                    resultHandler: nil
                )
            default:
                throw DecodingError.dataCorrupted
            }
        case .call:
            message.decode(tupleHeader: &arity, index: &index) // {<from_pid>, <monitor_ref>}
            var senderPID = erlang_pid()
            message.decode(pid: &senderPID, index: &index)
            let monitorStartIndex = index
            message.skipTerm(index: &index)
            let monitorReference = message[monitorStartIndex..<index]
            
            let sender = Term.PID(pid: senderPID)
            let resultHandler = ResultHandler(
                sender: sender,
                monitorReference: monitorReference
            )
            
            var messageType: UInt32 = 0
            var size: Int32 = 0
            message.getType(type: &messageType, size: &size, index: &index)
            
            switch Character(UnicodeScalar(messageType)!) {
            case "d", "s", "v": // no arguments call
                var target: [CChar] = [CChar](repeating: 0, count: Int(MAXATOMLEN))
                message.decode(atom: &target, index: &index)
                
                let identifier = String(cString: target, encoding: .utf8)!
                return LocalCallInvocation(
                    sender: sender,
                    identifier: identifier,
                    arguments: message[index...],
                    resultHandler: resultHandler
                )
            case "h" where size > 0,
                 "i" where size > 0: // tuple arguments
                var tupleStartIndex = index
                
                message.decode(tupleHeader: &size, index: &index)
                var target: [CChar] = [CChar](repeating: 0, count: Int(MAXATOMLEN))
                message.decode(atom: &target, index: &index)
                
                let argumentsStartIndex = index
                message.skipTerm(index: &tupleStartIndex)
                let arguments = message[argumentsStartIndex...tupleStartIndex]
                
                let identifier = String(cString: target, encoding: .utf8)!
                return LocalCallInvocation(
                    sender: sender,
                    identifier: identifier,
                    arguments: arguments,
                    resultHandler: resultHandler
                )
            default:
                throw DecodingError.dataCorrupted
            }
        }
    }
    
    private struct CallContinuation: ContinuationAdapter {
        let monitorReference: Term.Reference
        
        /// `{<ref>, <result>}`
        public func decode(
            _ message: ErlangTermBuffer
        ) -> ContinuationMatch {
            var index: Int32 = 0
            
            var version: Int32 = 0
            message.decode(version: &version, index: &index)
            
            var arity: Int32 = 0
            guard message.decode(tupleHeader: &arity, index: &index),
                  arity == 2
            else { return .mismatch }
            
            // [:alias, #Reference]
            var refArity: Int32 = 0
            guard message.decode(listHeader: &refArity, index: &index),
                  refArity == 2
            else { return .mismatch }
            
            var aliasTermIndex = index
            var ref = erlang_ref()
            
            // #Reference
            guard message.skipTerm(index: &index),
                  message.decode(ref: &ref, index: &index),
                  Term.Reference(ref: ref) == monitorReference
            else { return .mismatch }
            
            // :alias
            let atom = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXATOMLEN))
            defer { atom.deallocate() }
            guard message.decode(atom: atom, index: &aliasTermIndex),
                  memcmp(atom, "alias", 6) == 0, // :alias
                  message.decode(listHeader: &refArity, index: &index) // tail
            else { return .mismatch }
            
            let responseStartIndex = index
            for _ in 0..<Int(arity - 1) {
                message.skipTerm(index: &index)
            }
            return .success(message[responseStartIndex...index])
        }
    }
    
    enum DecodingError: Error {
        case dataCorrupted
    }
    
    private struct ResultHandler: ResultHandlerAdapter {
        let sender: Term.PID
        let monitorReference: ErlangTermBuffer
        
        /// `{<ref>, <reply>}`
        func encode(returning value: Value) throws -> Self.Message {
            let result = ErlangTermBuffer()
            result.newWithVersion()
            
            result.encode(tupleHeader: 2)
            result.append(monitorReference)
            result.append(value)
            
            return result
        }
        
        /// `{<ref>, :ok}`
        func encodeVoid() throws -> Self.Message {
            let result = ErlangTermBuffer()
            result.newWithVersion()
            
            result.encode(tupleHeader: 2)
            result.append(monitorReference)
            result.encode(atom: "ok")
            
            return result
        }
        
        /// `{<ref>, {:error, "msg"}}`
        func encode(throwing error: some Error) throws -> Self.Message {
            let result = ErlangTermBuffer()
            result.newWithVersion()
            
            result.encode(tupleHeader: 2)
            result.append(monitorReference)
            
            result.encode(tupleHeader: 2)
            result.encode(atom: "error")
            _ = Data(error.localizedDescription.utf8).withUnsafeBytes({ pointer in
                result.encode(binary: pointer.baseAddress!, len: Int32(pointer.count))
            })
            
            return result
        }
    }
}

extension GenServerRemoteCallAdapter {
    /// A type that decides whether to send a `cast` or `call` message.
    public protocol Dispatcher {
        func dispatch(
            _ invocation: RemoteCallInvocation
        ) -> DispatchFormat
    }
    
    /// A `cast` or `call` message sent to a `GenServer`.
    public enum DispatchFormat: String {
        case cast = "$gen_cast"
        case call = "$gen_call"
    }
    
    /// A ``GenServerRemoteCallAdapter/Dispatcher`` that sends a `cast` when the
    /// return type of the invocation is ``Swift/Void``.
    public struct CastVoidDispatcher: Dispatcher {
        public func dispatch(
            _ invocation: RemoteCallInvocation
        ) -> DispatchFormat {
            switch invocation.returnType {
            case .none:
                return .cast
            case .some:
                return .call
            }
        }
    }
}

extension GenServerRemoteCallAdapter.Dispatcher where Self == GenServerRemoteCallAdapter.CastVoidDispatcher {
    /// A ``GenServerRemoteCallAdapter/Dispatcher`` that sends a `cast` when the
    /// return type of the invocation is ``Swift/Void``.
    public static var castVoid: Self { GenServerRemoteCallAdapter.CastVoidDispatcher() }
}

extension RemoteCallAdapter where Self == GenServerRemoteCallAdapter {
    public static var genServer: Self { .init() }
}
