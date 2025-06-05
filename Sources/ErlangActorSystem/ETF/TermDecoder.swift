import CErlInterface
import Foundation

/// A type that decodes `Term` to a `Decodable` type.
open class TermDecoder {
    open var userInfo: [CodingUserInfoKey: Any] {
        get { options.userInfo }
        set { options.userInfo = newValue }
    }
    
    var options = Options()

    public struct Options {
        public var userInfo: [CodingUserInfoKey: Any] = [:]
        
        public init() {}
        
        public func userInfo(_ userInfo: [CodingUserInfoKey: Any]) -> Self {
            var copy = self
            copy.userInfo = userInfo
            return copy
        }
    }

    public init() {}

    open func decode<T: Decodable>(_ type: T.Type, from buffer: ErlangTermBuffer, startIndex: Int32 = 0) throws -> T {
        if type == Term.self {
            return try Term(from: buffer[startIndex...]) as! T
        } else {
            let decoder = __TermDecoder(
                userInfo: userInfo,
                from: buffer,
                codingPath: [],
                options: self.options,
                startIndex: startIndex
            )
            return try type.init(from: decoder)
        }
    }
}

final class __TermDecoder: Decoder {
    var buffer: ErlangTermBuffer
    
    var index: Int32

    let userInfo: [CodingUserInfoKey: Any]
    let options: TermDecoder.Options

    public var codingPath: [CodingKey]

    init(
        userInfo: [CodingUserInfoKey: Any],
        from buffer: ErlangTermBuffer,
        codingPath: [CodingKey],
        options: TermDecoder.Options,
        startIndex: Int32 = 0
    ) {
        self.userInfo = userInfo
        self.codingPath = codingPath
        self.buffer = buffer
        self.options = options
        self.index = startIndex
        var version: Int32 = 0
        buffer.decode(version: &version, index: &index)
    }

    func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key>
    where Key: CodingKey {
        var arity: Int32 = 0
        guard buffer.decode(mapHeader: &arity, index: &index)
        else {
            throw DecodingError.makeTypeMismatchError(
                type: [AnyHashable:Any].self,
                for: codingPath,
                in: self
            )
        }
        
        return KeyedDecodingContainer(
            try KeyedContainer<Key>(decoder: self, codingPath: codingPath, arity: arity)
        )
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        var type: UInt32 = 0
        var size: Int32 = 0
        guard buffer.getType(type: &type, size: &size, index: &index)
        else { throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: codingPath, debugDescription: "Unable to get type of term")) }
        
        let isTuple: Bool
        switch Character(UnicodeScalar(type)!) {
        case "h", "i": // tuple
            isTuple = true
        case "l", "j": // list
            isTuple = false
        default:
            throw DecodingError.makeTypeMismatchError(
                type: [Any].self,
                for: codingPath,
                in: self
            )
        }
        
        return try UnkeyedContainer(decoder: self, codingPath: codingPath, isTuple: isTuple)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        self
    }
}

extension __TermDecoder: SingleValueDecodingContainer {
    func decodeNil() -> Bool {
        var arity: Int32 = 0
        
        guard buffer.decode(listHeader: &arity, index: &index),
              arity == 0
        else { return false }
        
        return true
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        var bool: Int32 = 0
        guard buffer.decode(boolean: &bool, index: &index)
        else { throw DecodingError.makeTypeMismatchError(type: type, for: codingPath, in: self) }
        return bool == 1
    }

    func decode(_ type: String.Type) throws -> String {
        var _type: UInt32 = 0
        var size: Int32 = 0
        guard buffer.getType(type: &_type, size: &size, index: &index)
        else { throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Failed to get size of binary")) }
        
        switch Character(UnicodeScalar(_type)!) {
        case "d", "s", "v": // atom
            var atom: [CChar] = [CChar](repeating: 0, count: Int(MAXATOMLEN))
            guard buffer.decode(atom: &atom, index: &index)
            else { throw DecodingError.makeTypeMismatchError(type: type, for: codingPath, in: self) }
            return String(cString: atom, encoding: .utf8)!
        case "m": // binary
            let binary: UnsafeMutableRawPointer = .allocate(byteCount: Int(size), alignment: 0)
            defer { binary.deallocate() }
            var length: Int = 0
            guard buffer.decode(binary: binary, len: &length, index: &index)
            else { throw DecodingError.makeTypeMismatchError(type: type, for: codingPath, in: self) }
            
            guard let string = String(data: Data(bytes: binary, count: length), encoding: .utf8)
            else { throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Failed to decode binary to String")) }
            return string
        case "k": // string
            let string: UnsafeMutablePointer<CChar> = .allocate(capacity: Int(size) + 1)
            defer { string.deallocate() }
            guard buffer.decode(string: string, index: &index)
            else { throw DecodingError.makeTypeMismatchError(type: type, for: codingPath, in: self) }
            return String(cString: string)
        default:
            throw DecodingError.makeTypeMismatchError(type: type, for: codingPath, in: self)
        }
    }

    func decode(_ type: Double.Type) throws -> Double {
        var double: Double = 0
        
        guard buffer.decode(double: &double, index: &index)
        else { throw DecodingError.makeTypeMismatchError(type: type, for: codingPath, in: self) }
        
        return double
    }

    func decode(_ type: Float.Type) throws -> Float {
        return Float(try decode(Double.self))
    }

    func decode(_ type: Int.Type) throws -> Int {
        var int: Int = 0
        
        guard buffer.decode(long: &int, index: &index)
        else { throw DecodingError.makeTypeMismatchError(type: type, for: codingPath, in: self) }
        
        return int
    }

    func decode(_ type: Int8.Type) throws -> Int8 {
        Int8(try decode(Int.self))
    }

    func decode(_ type: Int16.Type) throws -> Int16 {
        Int16(try decode(Int.self))
    }

    func decode(_ type: Int32.Type) throws -> Int32 {
        Int32(try decode(Int.self))
    }

    func decode(_ type: Int64.Type) throws -> Int64 {
        var int: Int64 = 0
        
        guard buffer.decode(longlong: &int, index: &index)
        else { throw DecodingError.makeTypeMismatchError(type: type, for: codingPath, in: self) }
        
        return int
    }

    func decode(_ type: UInt.Type) throws -> UInt {
        var int: UInt = 0
        
        guard buffer.decode(ulong: &int, index: &index)
        else { throw DecodingError.makeTypeMismatchError(type: type, for: codingPath, in: self) }
        
        return int
    }

    func decode(_ type: UInt8.Type) throws -> UInt8 {
        UInt8(try decode(UInt.self))
    }

    func decode(_ type: UInt16.Type) throws -> UInt16 {
        UInt16(try decode(UInt.self))
    }

    func decode(_ type: UInt32.Type) throws -> UInt32 {
        UInt32(try decode(UInt.self))
    }

    func decode(_ type: UInt64.Type) throws -> UInt64 {
        var int: UInt64 = 0
        
        guard buffer.decode(ulonglong: &int, index: &index)
        else { throw DecodingError.makeTypeMismatchError(type: type, for: codingPath, in: self) }
        
        return int
    }

    func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
        if type == Term.self {
            let termStartIndex = index
            buffer.skipTerm(index: &index)
            return try Term(from: buffer[termStartIndex..<index]) as! T
        } else {
            return try type.init(from: self)
        }
    }
}

extension __TermDecoder {
    struct KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
        let decoder: __TermDecoder
        
        /// The index that starts each value.
        var valueStartIndices = [String:Int32]()
        
        var allKeys: [Key] {
            valueStartIndices.keys.compactMap(Key.init(stringValue:))
        }
        
        var codingPath: [any CodingKey]

        init(
            decoder: __TermDecoder,
            codingPath: [any CodingKey],
            arity: Int32
        ) throws {
            self.decoder = decoder
            self.codingPath = codingPath
            
            // get all of the keys, skipping the values
            for elementIndex in 0..<arity {
                let currentCodingPath = codingPath + [AnyCodingKey(intValue: Int(elementIndex))]
                
                // decode the key as an atom, string, or binary
                var type: UInt32 = 0
                var size: Int32 = 0
                guard decoder.buffer.getType(type: &type, size: &size, index: &decoder.index)
                else {
                    throw DecodingError.dataCorrupted(DecodingError.Context(
                        codingPath: currentCodingPath,
                        debugDescription: "Failed to get type of key"
                    ))
                }
                
                switch Character(UnicodeScalar(type)!) {
                case "d", "s", "v": // atom
                    var atom: [CChar] = [CChar](repeating: 0, count: Int(MAXATOMLEN))
                    guard decoder.buffer.decode(atom: &atom, index: &decoder.index)
                    else {
                        throw DecodingError.typeMismatch(
                            String.self,
                            .init(
                                codingPath: currentCodingPath,
                                debugDescription: "Expected atom key in map"
                            )
                        )
                    }
                    valueStartIndices[String(cString: atom, encoding: .utf8)!] = decoder.index
                case "k": // string
                    let string: UnsafeMutablePointer<CChar> = .allocate(capacity: Int(size) + 1)
                    defer { string.deallocate() }
                    guard decoder.buffer.decode(string: string, index: &decoder.index)
                    else {
                        throw DecodingError.typeMismatch(
                            String.self,
                            .init(
                                codingPath: currentCodingPath,
                                debugDescription: "Expected string key in map"
                            )
                        )
                    }
                    valueStartIndices[String(cString: string)] = decoder.index
                case "m": // binary
                    let binary: UnsafeMutableRawPointer = .allocate(byteCount: Int(size), alignment: 0)
                    defer { binary.deallocate() }
                    var length: Int = 0
                    guard decoder.buffer.decode(binary: binary, len: &length, index: &decoder.index),
                          let key = String(data: Data(bytes: binary, count: length), encoding: .utf8)
                    else {
                        throw DecodingError.typeMismatch(
                            String.self,
                            .init(
                                codingPath: currentCodingPath,
                                debugDescription: "Expected binary key in map"
                            )
                        )
                    }
                    valueStartIndices[key] = decoder.index
                default:
                    throw DecodingError.typeMismatch(
                        String.self,
                        .init(
                            codingPath: currentCodingPath,
                            debugDescription: "Expected atom, string, or binary key in map"
                        )
                    )
                }
                
                // skip the value
                decoder.buffer.skipTerm(index: &decoder.index)
            }
        }

        func contains(_ key: Key) -> Bool {
            return true
        }
        
        func withIndex<Result>(forKey key: Key, _ block: (__TermDecoder) throws -> Result) throws -> Result {
            let originalIndex = decoder.index
            let originalCodingPath = decoder.codingPath
            
            defer {
                decoder.index = originalIndex
                decoder.codingPath = originalCodingPath
            }
            
            guard let index = valueStartIndices[key.stringValue]
            else {
                throw DecodingError.keyNotFound(key, DecodingError.Context(codingPath: codingPath, debugDescription: "Key '\(key)' not found in map"))
            }
            decoder.index = index
            decoder.codingPath = codingPath + [key]
            
            return try block(decoder)
        }

        func decodeNil(forKey key: Key) throws -> Bool {
            guard valueStartIndices.keys.contains(key.stringValue)
            else { return true }
            return try withIndex(forKey: key) {
                $0.decodeNil()
            }
        }

        func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
            try withIndex(forKey: key) {
                try $0.decode(type)
            }
        }

        func decode(_ type: String.Type, forKey key: Key) throws -> String {
            try withIndex(forKey: key) {
                try $0.decode(type)
            }
        }

        func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
            try withIndex(forKey: key) {
                try $0.decode(type)
            }
        }

        func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
            try withIndex(forKey: key) {
                try $0.decode(type)
            }
        }

        func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
            try withIndex(forKey: key) {
                try $0.decode(type)
            }
        }

        func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
            try withIndex(forKey: key) {
                try $0.decode(type)
            }
        }

        func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
            try withIndex(forKey: key) {
                try $0.decode(type)
            }
        }

        func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
            try withIndex(forKey: key) {
                try $0.decode(type)
            }
        }

        func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
            try withIndex(forKey: key) {
                try $0.decode(type)
            }
        }

        func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
            try withIndex(forKey: key) {
                try $0.decode(type)
            }
        }

        func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
            try withIndex(forKey: key) {
                try $0.decode(type)
            }
        }

        func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
            try withIndex(forKey: key) {
                try $0.decode(type)
            }
        }

        func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
            try withIndex(forKey: key) {
                try $0.decode(type)
            }
        }

        func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
            try withIndex(forKey: key) {
                try $0.decode(type)
            }
        }

        func decode<T>(_ type: T.Type, forKey key: Key) throws -> T where T: Decodable {
            try withIndex(forKey: key) {
                try $0.decode(type)
            }
        }

        func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws
            -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey
        {
            try withIndex(forKey: key) {
                $0.codingPath.append(key)
                return try $0.container(keyedBy: type)
            }
        }

        func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
            try withIndex(forKey: key) {
                $0.codingPath.append(key)
                return try $0.unkeyedContainer()
            }
        }

        func superDecoder() throws -> any Decoder {
            fatalError("not supported")
        }

        func superDecoder(forKey key: Key) throws -> any Decoder {
            fatalError("not supported")
        }
    }
}

extension __TermDecoder {
    struct UnkeyedContainer: UnkeyedDecodingContainer {
        
        let decoder: __TermDecoder
        
        let isTuple: Bool

        let count: Int?
        var currentIndex: Int = 0
        var isAtEnd: Bool {
            self.currentIndex >= self.count!
        }
        var peekedValue: Any?
        
        var valueStartIndices: [Int32]

        var codingPath: [any CodingKey]
        var currentCodingPath: [any CodingKey] {
            codingPath + [AnyCodingKey(index: currentIndex)]
        }
        
        func with<T>(index: Int32, _ block: (__TermDecoder) throws -> T) rethrows -> T {
            let originalIndex = decoder.index
            let originalCodingPath = decoder.codingPath
            
            defer {
                decoder.index = originalIndex
                decoder.codingPath = originalCodingPath
            }
            
            decoder.index = index
            decoder.codingPath = currentCodingPath
            
            return try block(decoder)
        }

        init(
            decoder: __TermDecoder,
            codingPath: [CodingKey],
            isTuple: Bool
        ) throws {
            self.decoder = decoder
            self.isTuple = isTuple
            
            var arity: Int32 = 0
            if isTuple {
                guard decoder.buffer.decode(tupleHeader: &arity, index: &decoder.index)
                else {
                    throw DecodingError.makeTypeMismatchError(type: [Any].self, for: codingPath, in: decoder)
                }
            } else {
                guard decoder.buffer.decode(listHeader: &arity, index: &decoder.index)
                else {
                    throw DecodingError.makeTypeMismatchError(type: [Any].self, for: codingPath, in: decoder)
                }
            }
            self.count = Int(arity)
            
            self.codingPath = codingPath
            
            // find the start index of each element and skip to the end of the list
            self.valueStartIndices = []
            for _ in 0..<arity {
                valueStartIndices.append(decoder.index)
                decoder.buffer.skipTerm(index: &decoder.index)
            }
            if !isTuple && arity > 0 {
                // empty list header at the end
                var arity: Int32 = 0
                guard decoder.buffer.decode(listHeader: &arity, index: &decoder.index),
                      arity == 0
                else { throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: currentCodingPath, debugDescription: "Missing tail list header")) }
            }
        }

        @inline(__always)
        mutating func peek<T>(_ type: T.Type) throws -> T where T: Decodable {
            if let value = peekedValue as? T {
                return value
            }
            
            guard !isAtEnd
            else {
                var message = "Unkeyed container is at end."
                if T.self == UnkeyedContainer.self {
                    message = "Cannot get nested unkeyed container -- unkeyed container is at end."
                }
                if T.self == Decoder.self {
                    message = "Cannot get superDecoder() -- unkeyed container is at end."
                }

                throw DecodingError.valueNotFound(
                    type,
                    .init(
                        codingPath: codingPath,
                        debugDescription: message
                    )
                )
            }
            
            return try with(index: valueStartIndices[currentIndex]) {
                let nextValue = try $0.decode(T.self)
                peekedValue = nextValue
                return nextValue
            }
        }

        mutating func advance() throws {
            currentIndex += 1
            peekedValue = nil
        }

        mutating func decodeNil() throws -> Bool {
            let value = try self.peek(Array<Int>.self)
            return value.isEmpty
        }

        mutating func decode(_ type: Bool.Type) throws -> Bool {
            let value = try peek(type)
            try advance()
            return value
        }

        mutating func decode(_ type: String.Type) throws -> String {
            let value = try peek(type)
            try advance()
            return value
        }

        mutating func decode(_ type: Double.Type) throws -> Double {
            let value = try peek(type)
            try advance()
            return value
        }

        mutating func decode(_ type: Float.Type) throws -> Float {
            let value = try peek(type)
            try advance()
            return value
        }

        mutating func decode(_ type: Int.Type) throws -> Int {
            let value = try peek(type)
            try advance()
            return value
        }

        mutating func decode(_ type: Int8.Type) throws -> Int8 {
            return try type.init(decode(Int.self))
        }

        mutating func decode(_ type: Int16.Type) throws -> Int16 {
            return try type.init(decode(Int.self))
        }

        mutating func decode(_ type: Int32.Type) throws -> Int32 {
            return try type.init(decode(Int.self))
        }

        mutating func decode(_ type: Int64.Type) throws -> Int64 {
            return try type.init(decode(Int.self))
        }

        mutating func decode(_ type: UInt.Type) throws -> UInt {
            let value = try peek(type)
            try advance()
            return value
        }

        mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
            return try type.init(decode(UInt.self))
        }

        mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
            return try type.init(decode(UInt.self))
        }

        mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
            return try type.init(decode(UInt.self))
        }

        mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
            return try type.init(decode(UInt.self))
        }

        mutating func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
            let value = try peek(type)
            try advance()
            return value
        }

        mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws
            -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey
        {
            let container = try with(index: valueStartIndices[currentIndex]) {
                try $0.container(keyedBy: type)
            }
            try advance()
            return container
        }

        mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
            let container = try with(index: valueStartIndices[currentIndex]) {
                try $0.unkeyedContainer()
            }
            try advance()
            return container
        }

        mutating func superDecoder() throws -> any Decoder {
            fatalError("not supported")
        }
    }
}

extension DecodingError {
    fileprivate static func makeTypeMismatchError(
        type expectedType: Any.Type, for path: [CodingKey], in decoder: __TermDecoder
    ) -> DecodingError {
        var type: UInt32 = 0
        var size: Int32 = 0
        decoder.buffer.getType(type: &type, size: &size, index: &decoder.index)
        
        let typeName = switch Character(UnicodeScalar(type)!) {
        case "a", "b": // integer
            "integer"
        case "c", "F": //  float
            "float"
        case "d", "s", "v": // atom
            "atom"
        case "e", "r", "Z": // ref
            "ref"
        case "f", "Y", "x": // port
            "port"
        case "g", "X": // pid
            "pid"
        case "h", "i": // tuple
            "tuple"
        case "k": // string
            "string"
        case "l": // list
            "list"
        case "j": // empty list
            "empty list"
        case "m": // binary
            "binary"
        case "M": // bit binary
            "bit binary"
        case "p", "u", "q": // function
            "function"
        case "t": // map
            "map"
        case let type:
            String(type)
        }
        
        return DecodingError.typeMismatch(
            expectedType,
            .init(
                codingPath: path,
                debugDescription: "Expected to decode \(expectedType) but found \(typeName) instead."
            )
        )
    }
}
