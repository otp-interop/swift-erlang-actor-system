import Foundation
import CErlInterface

/// An adapter that handles messages as tuples or atoms.
///
/// ## Encoding
/// The message will be encoded as an `argument count + 1` arity tuple with the following format:
///
/// ```elixir
/// {:<target>, <args>...}
/// ```
///
/// If the call has no arguments, only an atom will be sent:
///
/// ```elixir
/// :<target>
/// ```
public struct PrimitiveRemoteCallAdapter: RemoteCallAdapter {
    nonisolated(unsafe) static let termEncoder = {
        let encoder = TermEncoder()
        encoder.includeVersion = false
        return encoder
    }()
    
    public init() {}
    
    public func encode(
        _ invocation: RemoteCallInvocation,
        for system: ActorSystem
    ) throws -> EncodedRemoteCall {
        let message = ErlangTermBuffer()
        message.newWithVersion()
        
        if invocation.arguments.isEmpty {
            message.encode(atom: invocation.identifier)
        } else {
            message.encode(tupleHeader: invocation.arguments.count + 1) // {:target, args...}
            message.encode(atom: invocation.identifier)
            
            for argument in invocation.arguments {
                message.append(try Self.termEncoder.encode(argument.value))
            }
        }
        
        return EncodedRemoteCall(
            message: message,
            continuationAdapter: nil
        )
    }
    
    public func decode(
        _ message: ErlangTermBuffer,
        for system: ActorSystem
    ) throws -> LocalCallInvocation {
        var index: Int32 = 0
        
        var version: Int32 = 0
        message.decode(version: &version, index: &index)
        
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
    }
    
    enum DecodingError: Error {
        case dataCorrupted
    }
}

extension RemoteCallAdapter where Self == PrimitiveRemoteCallAdapter {
    public static var primitive: Self { .init() }
}
