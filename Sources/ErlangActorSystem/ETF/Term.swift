import CErlInterface
import Observation
import Foundation

extension Array {
    init<Tuple>(tuple: Tuple, start: KeyPath<Tuple, Element>) {
        self = withUnsafePointer(to: tuple) { pointer in
            return [Element](UnsafeBufferPointer(
                start: pointer.pointer(to: start)!,
                count: MemoryLayout.size(ofValue: pointer.pointee) / MemoryLayout.size(ofValue: pointer.pointee[keyPath: start])
            ))
        }
    }
}

extension String {
    func tuple<each T: FixedWidthInteger>() -> (repeat each T) {
        var result: (repeat each T) = (repeat (each T).zero)
        withUnsafeMutableBytes(of: &result) { pointer in
            pointer.copyBytes(from: utf8.prefix(pointer.count))
        }
        return result
    }
}

/// A generic type that can be returned by an ``ErlangNode`` representing any
/// term.
public enum Term: Sendable, Hashable {
    case int(Int)
    case double(Double)
    
    case atom(String)
    
    case string(String)
    
    case ref(Reference)
    
    case port(Port)
    
    case pid(PID)
    
    case tuple([Term])
    
    case list([Term])
    
    case binary(Data)
    
    case bitstring(Data)
    
    case function(Function)
    
    case map([Term:Term])
    
    func encode(to buffer: ErlangTermBuffer, initializeBuffer: Bool = true) throws {
        if initializeBuffer {
            guard buffer.newWithVersion()
            else { throw TermError.encodingError }
        }
        
        switch self {
        case let .int(int):
            guard buffer.encode(long: int)
            else { throw TermError.encodingError }
        case let .double(double):
            guard buffer.encode(double: double)
            else { throw TermError.encodingError }
        case let .atom(atom):
            guard buffer.encode(atom: strdup(atom))
            else { throw TermError.encodingError }
        case var .ref(ref):
            guard buffer.encode(ref: &ref.ref)
            else { throw TermError.encodingError }
        case var .port(port):
            guard buffer.encode(port: &port.port)
            else { throw TermError.encodingError }
        case var .pid(pid):
            guard buffer.encode(pid: &pid.pid)
            else { throw TermError.encodingError }
        case let .tuple(terms):
            guard buffer.encode(tupleHeader: terms.count)
            else { throw TermError.encodingError }
            for term in terms {
                try term.encode(to: buffer, initializeBuffer: false)
            }
        case let .list(list) where list.isEmpty:
            guard buffer.encode(listHeader: list.count)
            else { throw TermError.encodingError }
        case let .list(list):
            guard buffer.encode(listHeader: list.count)
            else { throw TermError.encodingError }
            for term in list {
                try term.encode(to: buffer, initializeBuffer: false)
            }
            guard buffer.encodeEmptyList()
            else { throw TermError.encodingError }
        case let .binary(binary):
            guard binary.withUnsafeBytes({ pointer in
                buffer.encode(binary: pointer.baseAddress!, len: Int32(pointer.count))
            })
            else { throw TermError.encodingError }
        case let .bitstring(bitstring):
            guard bitstring.withUnsafeBytes({ pointer in
                buffer.encode(bitstring: pointer.baseAddress!, bitoffs: 0, bits: pointer.count * UInt8.bitWidth)
            })
            else { throw TermError.encodingError }
        case let .function(function):
            guard buffer.encode(fun: &function.fun)
            else { throw TermError.encodingError }
        case let .map(map):
            guard buffer.encode(mapHeader: map.count)
            else { throw TermError.encodingError }
            for (key, value) in map {
                try key.encode(to: buffer, initializeBuffer: false)
                try value.encode(to: buffer, initializeBuffer: false)
            }
        case let .string(string):
            guard buffer.encode(string: strdup(string))
            else { throw TermError.encodingError }
        }
    }
    
    public init(
        from buffer: ErlangTermBuffer
    ) throws {
        var index: Int32 = 0
        
        var version: Int32 = 0
        buffer.decode(version: &version, index: &index)
//        guard ei_decode_version(buffer.buff, &index, &version) == 0
//        else { throw TermError.decodingError(.missingVersion) }
        
        func decodeNext() throws -> Self {
            var type: UInt32 = 0
            var size: Int32 = 0
            buffer.getType(type: &type, size: &size, index: &index)
            
            switch Character(UnicodeScalar(type)!) {
            case "a", "b": // integer
                var int: Int = 0
                guard buffer.decode(long: &int, index: &index)
                else { throw TermError.decodingError(.badTerm) }
                return .int(int)
            case "c", "F": //  float
                var double: Double = 0
                guard buffer.decode(double: &double, index: &index)
                else { throw TermError.decodingError(.badTerm) }
                return .double(double)
            case "d", "s", "v": // atom
                var atom: [CChar] = [CChar](repeating: 0, count: Int(MAXATOMLEN))
                guard buffer.decode(atom: &atom, index: &index),
                      let string = String(cString: atom, encoding: .utf8)
                else { throw TermError.decodingError(.badTerm) }
                return .atom(string)
            case "e", "r", "Z": // ref
                var ref: erlang_ref = erlang_ref()
                guard buffer.decode(ref: &ref, index: &index)
                else { throw TermError.decodingError(.badTerm) }
                return .ref(.init(ref: ref))
            case "f", "Y", "x": // port
                var port: erlang_port = erlang_port()
                guard buffer.decode(port: &port, index: &index)
                else { throw TermError.decodingError(.badTerm) }
                return .port(.init(port: port))
            case "g", "X": // pid
                var pid = erlang_pid()
                guard buffer.decode(pid: &pid, index: &index)
                else { throw TermError.decodingError(.badTerm) }
                return .pid(.init(pid: pid))
            case "h", "i": // tuple
                var arity: Int32 = 0
                guard buffer.decode(tupleHeader: &arity, index: &index)
                else { throw TermError.decodingError(.badTerm) }
                return .tuple(try (0..<arity).map { _ in
                    try decodeNext()
                })
            case "k": // string
                let string: UnsafeMutablePointer<CChar> = .allocate(capacity: Int(size) + 1)
                defer { string.deallocate() }
                guard buffer.decode(string: string, index: &index)
                else { throw TermError.decodingError(.badTerm) }
                return .string(String(cString: string))
            case "l": // list
                var arity: Int32 = 0
                guard buffer.decode(listHeader: &arity, index: &index)
                else { throw TermError.decodingError(.badTerm) }
                let elements = try (0..<arity).map { _ in
                    try decodeNext()
                }
                // empty list header at the end
                guard buffer.decode(listHeader: &arity, index: &index),
                      arity == 0
                else { throw TermError.decodingError(.missingListEnd) }
                return .list(elements)
            case "j": // empty list
                var arity: Int32 = 0
                guard buffer.decode(listHeader: &arity, index: &index),
                      arity == 0
                else { throw TermError.decodingError(.badTerm) }
                return .list([])
            case "m": // binary
                let binary: UnsafeMutableRawPointer = .allocate(byteCount: Int(size), alignment: 0)
                var length: Int = 0
                guard buffer.decode(binary: binary, len: &length, index: &index)
                else { throw TermError.decodingError(.badTerm) }
                return .binary(Data(bytes: binary, count: length))
            case "M": // bit binary
                var pointer: UnsafePointer<CChar>?
                var bitOffset: UInt32 = 0
                var bits: Int = 0
                guard buffer.decode(bitstring: &pointer, bitoffsp: &bitOffset, nbitsp: &bits, index: &index)
                else { throw TermError.decodingError(.badTerm) }
                guard bitOffset == 0
                else { throw TermError.decodingError(.unsupportedBitOffset(bitOffset)) }
                return .bitstring(pointer.map {
                    Data(bytes: $0, count: bits / UInt8.bitWidth)
                } ?? Data())
            case "p", "u", "q": // function
                var fun: erlang_fun = erlang_fun()
                guard buffer.decode(fun: &fun, index: &index)
                else { throw TermError.decodingError(.badTerm) }
                return .function(.init(fun: fun))
            case "t": // map
                var arity: Int32 = 0
                guard buffer.decode(mapHeader: &arity, index: &index)
                else { throw TermError.decodingError(.badTerm) }
                return .map(Dictionary(uniqueKeysWithValues: try (0..<arity).map { _ in
                    let pair = (try decodeNext(), try decodeNext())
                    return pair
                }))
            case let type:
                throw TermError.decodingError(.unknownType(type))
            }
        }
        
        self = try decodeNext()
    }
    
    public func makeBuffer() throws -> ErlangTermBuffer {
        let buffer = ErlangTermBuffer()
        
        try encode(to: buffer)
        
        return buffer
    }
    
    enum TermError: Error {
        case encodingError
        case decodingError(DecodingError)
        
        enum DecodingError {
            case missingVersion
            case badTerm
            case unknownType(Character)
            
            case unsupportedBitOffset(UInt32)
            
            case missingListEnd
        }
    }
}

extension Term: Encodable {
    public func encode(to encoder: any Encoder) throws {
        fatalError("Term can only be encoded by 'TermEncoder'")
    }
}

extension Term: Decodable {
    public init(from decoder: any Decoder) throws {
        fatalError("Term can only be decoded by 'TermDecoder'")
    }
}
