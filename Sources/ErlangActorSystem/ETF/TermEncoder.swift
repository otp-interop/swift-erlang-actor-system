import CErlInterface
import Foundation
#if canImport(Glibc)
import Glibc
#endif

// Based on `JSONEncoder` from `apple/swift-foundation`
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception

/// A type that encodes `Encodable` values into ``erlang/ErlangTermBuffer``.
///
/// Use property wrappers to customize how values are converted to Erlang terms:
///
/// - ``TermStringEncoding``
/// - ``TermUnkeyedContainerEncoding``
/// - ``TermKeyedContainerEncoding``
open class TermEncoder {
    open var userInfo: [CodingUserInfoKey: Any] {
        get { options.userInfo }
        set { options.userInfo = newValue }
    }
    
    open var includeVersion: Bool {
        get { options.includeVersion }
        set { options.includeVersion = newValue }
    }
    
    open var stringEncodingStrategy: StringEncodingStrategy {
        get { context.stringEncodingStrategy }
        set { context.stringEncodingStrategy = newValue }
    }
    
    open var unkeyedContainerEncodingStrategy: UnkeyedContainerEncodingStrategy {
        get { context.unkeyedContainerEncodingStrategy }
        set { context.unkeyedContainerEncodingStrategy = newValue }
    }
    
    open var keyedContainerEncodingStrategy: KeyedContainerEncodingStrategy {
        get { context.keyedContainerEncodingStrategy }
        set { context.keyedContainerEncodingStrategy = newValue }
    }
    
    var context: Context
    var options: Options
    
    struct Options {
        var userInfo: [CodingUserInfoKey: Any]
        var includeVersion: Bool
    }
    
    public init() {
        let context = Context()
        self.context = context
        self.options = .init(userInfo: [.termEncoderContext: context], includeVersion: true)
    }
    
    /// Encode `value` to ``erlang/ErlangTermBuffer``.
    open func encode<T: Encodable>(_ value: T) throws -> ErlangTermBuffer {
        if let term = value as? Term {
            let buffer = ErlangTermBuffer()
            if includeVersion {
                buffer.newWithVersion()
            } else {
                buffer.new()
            }
            try term.encode(to: buffer, initializeBuffer: false)
            return buffer
        } else {
            let encoder = __TermEncoder(options: self.options, context: self.context, codingPathDepth: 0)
            
            try value.encode(to: encoder)
            let valueBuffer = encoder.storage.popReference().backing.buffer
            
            let buffer = ErlangTermBuffer()
            if includeVersion {
                buffer.newWithVersion()
            } else {
                buffer.new()
            }
            buffer.append(valueBuffer)
            
            return buffer
        }
    }
}

extension CodingUserInfoKey {
    /// A reference to the ``TermEncoder/Context`` for customization.
    public static let termEncoderContext: CodingUserInfoKey = CodingUserInfoKey(rawValue: "$erlang_term_encoder_context")!
}

extension TermEncoder {
    public final class Context {
        public var stringEncodingStrategy: TermEncoder.StringEncodingStrategy = .binary
        public var unkeyedContainerEncodingStrategy: TermEncoder.UnkeyedContainerEncodingStrategy = .list
        public var keyedContainerEncodingStrategy: TermEncoder.KeyedContainerEncodingStrategy = .map
    }
    
    /// The strategy used to encode a ``Swift/String`` to an Erlang term.
    public enum StringEncodingStrategy {
        /// Encodes the string as a binary.
        ///
        /// > A binary is a bitstring where the number of bits is divisible by 8.
        /// > - [Binaries, strings, and charlists](https://hexdocs.pm/elixir/binaries-strings-and-charlists.html)
        case binary
        
        /// Encodes the string as an atom.
        ///
        /// > Atoms are constants whose values are their own name.
        /// >
        /// > [*Atom*](https://hexdocs.pm/elixir/Atom.html)
        case atom
        
        /// Encodes the string as a charlist.
        ///
        /// > A charlist is a list of integers where all the integers are valid code points.
        /// >
        /// > [*Binaries, strings, and charlists*](https://hexdocs.pm/elixir/binaries-strings-and-charlists.html)
        case charlist
    }
    
    /// The strategy used to encode unkeyed containers to an Erlang term.
    public enum UnkeyedContainerEncodingStrategy {
        /// Encodes the container as a list.
        case list
        
        /// Encodes the container as a tuple.
        case tuple
    }
    
    /// The strategy used to encode keyed containers to an Erlang term.
    public enum KeyedContainerEncodingStrategy {
        /// Encodes the container as a map.
        ///
        /// Provide a ``TermEncoder/StringEncodingStrategy`` to specify how keys
        /// should be encoded.
        case map(keyEncodingStrategy: StringEncodingStrategy)
        
        /// Encodes the container as a map with atom keys.
        public static var map: Self { .map(keyEncodingStrategy: .atom) }
        
        /// Encodes the container as a keyword list.
        ///
        /// The key will be encoded as an atom.
        ///
        /// > A keyword list is a list that consists exclusively of two-element tuples.
        /// >
        /// > [*Keyword*](https://hexdocs.pm/elixir/Keyword.html)
        case keywordList
    }
}

/// Customizes the ``TermEncoder/Context/stringEncodingStrategy`` for the
/// wrapped property.
@propertyWrapper
public struct AtomTermEncoding: Codable, Sendable, Hashable {
    public var wrappedValue: String
    
    public init(wrappedValue: String = "") {
        self.wrappedValue = wrappedValue
    }
    
    public init(from decoder: any Decoder) throws {
        self.wrappedValue = try decoder.singleValueContainer().decode(String.self)
    }
    
    public func encode(to encoder: any Encoder) throws {
        let context = encoder.userInfo[.termEncoderContext] as! TermEncoder.Context
        let oldStrategy = context.stringEncodingStrategy
        defer {
            context.stringEncodingStrategy = oldStrategy
        }
        context.stringEncodingStrategy = .atom
        
        var container = encoder.singleValueContainer()
        try container.encode(self.wrappedValue)
    }
    
    public var projectedValue: Self { self }
}

/// Customizes the ``TermEncoder/Context/stringEncodingStrategy`` for the
/// wrapped property.
@propertyWrapper
public struct BinaryTermEncoding: Codable, Sendable, Hashable {
    public var wrappedValue: String
    
    public init(wrappedValue: String = "") {
        self.wrappedValue = wrappedValue
    }
    
    public init(from decoder: any Decoder) throws {
        self.wrappedValue = try decoder.singleValueContainer().decode(String.self)
    }
    
    public func encode(to encoder: any Encoder) throws {
        let context = encoder.userInfo[.termEncoderContext] as! TermEncoder.Context
        let oldStrategy = context.stringEncodingStrategy
        defer {
            context.stringEncodingStrategy = oldStrategy
        }
        context.stringEncodingStrategy = .binary
        
        var container = encoder.singleValueContainer()
        try container.encode(self.wrappedValue)
    }
    
    public var projectedValue: Self { self }
}

/// Customizes the ``TermEncoder/Context/stringEncodingStrategy`` for the
/// wrapped property.
@propertyWrapper
public struct CharlistTermEncoding: Codable, Sendable, Hashable {
    public var wrappedValue: String
    
    public init(wrappedValue: String = "") {
        self.wrappedValue = wrappedValue
    }
    
    public init(from decoder: any Decoder) throws {
        self.wrappedValue = try decoder.singleValueContainer().decode(String.self)
    }
    
    public func encode(to encoder: any Encoder) throws {
        let context = encoder.userInfo[.termEncoderContext] as! TermEncoder.Context
        let oldStrategy = context.stringEncodingStrategy
        defer {
            context.stringEncodingStrategy = oldStrategy
        }
        context.stringEncodingStrategy = .charlist
        
        var container = encoder.singleValueContainer()
        try container.encode(self.wrappedValue)
    }
    
    public var projectedValue: Self { self }
}

/// Customizes the ``TermEncoder/Context/unkeyedContainerEncodingStrategy`` for
/// the wrapped property.
///
/// - Warning: This will affect all child encodings.
@propertyWrapper
public struct ListTermEncoding<Value> {
    public var wrappedValue: Value
    
    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }
    
    public var projectedValue: Self { self }
}

extension ListTermEncoding: Sendable where Value: Sendable {}
extension ListTermEncoding: Equatable where Value: Equatable {}
extension ListTermEncoding: Hashable where Value: Equatable, Value: Hashable {}

extension ListTermEncoding: Encodable where Value: Encodable {
    public func encode(to encoder: any Encoder) throws {
        let context = encoder.userInfo[.termEncoderContext] as! TermEncoder.Context
        let oldStrategy = context.unkeyedContainerEncodingStrategy
        
        context.unkeyedContainerEncodingStrategy = .list
        defer { context.unkeyedContainerEncodingStrategy = oldStrategy }
        
        var container = encoder.singleValueContainer()
        
        try container.encode(self.wrappedValue)
    }
}

extension ListTermEncoding: Decodable where Value: Decodable {
    public init(from decoder: any Decoder) throws {
        self.wrappedValue = try decoder.singleValueContainer().decode(Value.self)
    }
}

/// Customizes the ``TermEncoder/Context/unkeyedContainerEncodingStrategy`` for
/// the wrapped property.
///
/// - Warning: This will affect all child encodings.
@propertyWrapper
public struct TupleTermEncoding<Value> {
    public var wrappedValue: Value
    
    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }
    
    public var projectedValue: Self { self }
}

extension TupleTermEncoding: Sendable where Value: Sendable {}
extension TupleTermEncoding: Equatable where Value: Equatable {}
extension TupleTermEncoding: Hashable where Value: Equatable, Value: Hashable {}

extension TupleTermEncoding: Encodable where Value: Encodable {
    public func encode(to encoder: any Encoder) throws {
        let context = encoder.userInfo[.termEncoderContext] as! TermEncoder.Context
        let oldStrategy = context.unkeyedContainerEncodingStrategy
        
        context.unkeyedContainerEncodingStrategy = .tuple
        defer { context.unkeyedContainerEncodingStrategy = oldStrategy }
        
        var container = encoder.singleValueContainer()
        
        try container.encode(self.wrappedValue)
    }
}

extension TupleTermEncoding: Decodable where Value: Decodable {
    public init(from decoder: any Decoder) throws {
        self.wrappedValue = try decoder.singleValueContainer().decode(Value.self)
    }
}

/// Customizes the ``TermEncoder/Context/keyedContainerEncodingStrategy`` for
/// the wrapped property.
///
/// - Note: This will use atom keys.
@propertyWrapper
public struct MapTermEncoding<Value> {
    public var wrappedValue: Value
    
    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }
    
    public var projectedValue: Self { self }
}

extension MapTermEncoding: Sendable where Value: Sendable {}
extension MapTermEncoding: Equatable where Value: Equatable {}
extension MapTermEncoding: Hashable where Value: Equatable, Value: Hashable {}

extension MapTermEncoding: Encodable where Value: Encodable {
    public func encode(to encoder: any Encoder) throws {
        let context = encoder.userInfo[.termEncoderContext] as! TermEncoder.Context
        let oldStrategy = context.keyedContainerEncodingStrategy
        defer {
            context.keyedContainerEncodingStrategy = oldStrategy
        }
        context.keyedContainerEncodingStrategy = .map(keyEncodingStrategy: .atom)
        
        var container = encoder.singleValueContainer()
        try container.encode(self.wrappedValue)
    }
}

extension MapTermEncoding: Decodable where Value: Decodable {
    public init(from decoder: any Decoder) throws {
        self.wrappedValue = try decoder.singleValueContainer().decode(Value.self)
    }
}

/// Customizes the ``TermEncoder/Context/keyedContainerEncodingStrategy`` for
/// the wrapped property.
@propertyWrapper
public struct KeywordListTermEncoding<Value> {
    public var wrappedValue: Value
    
    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }
    
    public var projectedValue: Self { self }
}

extension KeywordListTermEncoding: Sendable where Value: Sendable {}
extension KeywordListTermEncoding: Equatable where Value: Equatable {}
extension KeywordListTermEncoding: Hashable where Value: Equatable, Value: Hashable {}

extension KeywordListTermEncoding: Encodable where Value: Encodable {
    public func encode(to encoder: any Encoder) throws {
        let context = encoder.userInfo[.termEncoderContext] as! TermEncoder.Context
        let oldStrategy = context.keyedContainerEncodingStrategy
        defer {
            context.keyedContainerEncodingStrategy = oldStrategy
        }
        context.keyedContainerEncodingStrategy = .keywordList
        
        var container = encoder.singleValueContainer()
        try container.encode(self.wrappedValue)
    }
}

extension KeywordListTermEncoding: Decodable where Value: Decodable {
    public init(from decoder: any Decoder) throws {
        self.wrappedValue = try decoder.singleValueContainer().decode(Value.self)
    }
}

final class TermReference {
    var backing: Backing
    
    enum Backing {
        case buffer(ErlangTermBuffer)
        case list([TermReference], strategy: TermEncoder.UnkeyedContainerEncodingStrategy)
        case map([String:TermReference], strategy: TermEncoder.KeyedContainerEncodingStrategy)
        
        var buffer: ErlangTermBuffer {
            switch self {
            case let .buffer(buffer):
                return buffer
            case let .list(list, .list) where list.isEmpty:
                let buffer = ErlangTermBuffer()
                buffer.new()
                buffer.encodeEmptyList()
                return buffer
            case let .list(list, .list):
                let buffer = ErlangTermBuffer()
                buffer.new()
                buffer.encode(listHeader: list.count)
                for element in list {
                    buffer.append(element.backing.buffer)
                }
                buffer.encode(listHeader: 0) // tail
                return buffer
            case let .list(list, .tuple):
                let buffer = ErlangTermBuffer()
                buffer.new()
                buffer.encode(tupleHeader: list.count)
                for element in list {
                    buffer.append(element.backing.buffer)
                }
                return buffer
            case let .map(map, .map(keyEncodingStrategy)):
                let buffer = ErlangTermBuffer()
                buffer.new()
                buffer.encode(mapHeader: map.count)
                for (key, value) in map {
                    switch keyEncodingStrategy {
                    case .binary:
                        _ = Data(key.utf8).withUnsafeBytes { pointer in
                            buffer.encode(binary: pointer.baseAddress!, len: Int32(pointer.count))
                        }
                    case .atom:
                        buffer.encode(atom: key)
                    case .charlist:
                        _ = key.withCString { key in
                            buffer.encode(string: key)
                        }
                    }
                    
                    buffer.append(value.backing.buffer)
                }
                return buffer
            case let .map(map, .keywordList):
                let buffer = ErlangTermBuffer()
                buffer.new()
                buffer.encode(listHeader: map.count)
                for (key, value) in map {
                    buffer.encode(tupleHeader: 2)
                    buffer.encode(atom: key)
                    
                    buffer.append(value.backing.buffer)
                }
                buffer.encode(listHeader: 0) // tail
                return buffer
            }
        }
    }
    
    init(_ backing: Backing) {
        self.backing = backing
    }
    
    init(_ makeBuffer: (ErlangTermBuffer) throws -> ()) rethrows {
        let buffer = ErlangTermBuffer()
        buffer.new()
        try makeBuffer(buffer)
        self.backing = .buffer(buffer)
    }
    
    @inline(__always)
    var isMap: Bool {
        if case .map = backing {
            return true
        } else {
            return false
        }
    }
    
    @inline(__always)
    var isList: Bool {
        if case .list = backing {
            return true
        } else {
            return false
        }
    }
    
    /// Add a value to an ``Backing/map``.
    @inline(__always)
    func insert(_ value: TermReference, for key: CodingKey) {
        guard case .map(var map, let strategy) = backing else {
            preconditionFailure("Wrong term type")
        }
        map[key.stringValue] = value
        backing = .map(map, strategy: strategy)
    }

    /// Insert a value into an ``Backing/list``.
    @inline(__always)
    func insert(_ value: TermReference, at index: Int) {
        guard case .list(var list, let strategy) = backing else {
            preconditionFailure("Wrong term type")
        }
        list.insert(value, at: index)
        backing = .list(list, strategy: strategy)
    }

    /// Append a value to a ``Backing/list``.
    @inline(__always)
    func insert(_ value: TermReference) {
        guard case .list(var list, let strategy) = backing else {
            preconditionFailure("Wrong term type")
        }
        list.append(value)
        backing = .list(list, strategy: strategy)
    }

    /// `count` from an ``Backing/list`` or ``Backing/map``.
    @inline(__always)
    var count: Int {
        switch backing {
        case let .list(list, _): return list.count
        case let .map(map, _): return map.count
        default: preconditionFailure("Count does not apply to \(self)")
        }
    }

    @inline(__always)
    subscript(_ key: CodingKey) -> TermReference? {
        switch backing {
        case let .map(map, _):
            return map[key.stringValue]
        default:
            preconditionFailure("Wrong underlying term reference type")
        }
    }

    @inline(__always)
    subscript(_ index: Int) -> TermReference {
        switch backing {
        case let .list(list, _):
            return list[index]
        default:
            preconditionFailure("Wrong underlying term reference type")
        }
    }
}

/// The internal `Encoder` used by ``TermEncoder``.
class __TermEncoder: Encoder {
    var storage: _TermEncodingStorage
    
    var options: TermEncoder.Options
    var context: TermEncoder.Context
    
    var codingPath: [CodingKey]
    
    public var userInfo: [CodingUserInfoKey: Any] {
        self.options.userInfo
    }
    
    public var stringEncodingStrategy: TermEncoder.StringEncodingStrategy {
        self.context.stringEncodingStrategy
    }
    
    public var unkeyedContainerEncodingStrategy: TermEncoder.UnkeyedContainerEncodingStrategy {
        self.context.unkeyedContainerEncodingStrategy
    }
    
    public var keyedContainerEncodingStrategy: TermEncoder.KeyedContainerEncodingStrategy {
        self.context.keyedContainerEncodingStrategy
    }
    
    var codingPathDepth: Int = 0
    
    init(options: TermEncoder.Options, context: TermEncoder.Context, codingPath: [CodingKey] = [], codingPathDepth: Int) {
        self.options = options
        self.context = context
        self.storage = .init()
        self.codingPath = codingPath
        self.codingPathDepth = codingPathDepth
    }
    
    /// Returns whether a new element can be encoded at this coding path.
    ///
    /// `true` if an element has not yet been encoded at this coding path; `false` otherwise.
    var canEncodeNewValue: Bool {
        // Every time a new value gets encoded, the key it's encoded for is pushed onto the coding path (even if it's a nil key from an unkeyed container).
        // At the same time, every time a container is requested, a new value gets pushed onto the storage stack.
        // If there are more values on the storage stack than on the coding path, it means the value is requesting more than one container, which violates the precondition.
        //
        // This means that anytime something that can request a new container goes onto the stack, we MUST push a key onto the coding path.
        // Things which will not request containers do not need to have the coding path extended for them (but it doesn't matter if it is, because they will not reach here).
        return self.storage.count == self.codingPathDepth
    }
    
    public func container<Key>(keyedBy: Key.Type) -> KeyedEncodingContainer<Key> {
        let topRef: TermReference
        if self.canEncodeNewValue {
            topRef = self.storage.pushKeyedContainer(strategy: keyedContainerEncodingStrategy)
        } else {
            guard let ref = self.storage.refs.last, ref.isMap else {
                preconditionFailure(
                    "Attempt to push new keyed encoding container when already previously encoded at this path."
                )
            }
            topRef = ref
        }
        
        let container = _TermKeyedEncodingContainer<Key>(
            referencing: self, codingPath: self.codingPath, wrapping: topRef)
        return KeyedEncodingContainer(container)
    }
    
    public func unkeyedContainer() -> UnkeyedEncodingContainer {
        let topRef: TermReference
        if self.canEncodeNewValue {
            topRef = self.storage.pushUnkeyedContainer(strategy: unkeyedContainerEncodingStrategy)
        } else {
            guard let ref = self.storage.refs.last, ref.isList else {
                preconditionFailure(
                    "Attempt to push new unkeyed encoding container when already previously encoded at this path."
                )
            }
            topRef = ref
        }
        
        return _TermUnkeyedEncodingContainer(
            referencing: self, codingPath: self.codingPath, wrapping: topRef)
    }
    
    public func singleValueContainer() -> SingleValueEncodingContainer {
        self
    }
    
    /// Temporarily modifies the Encoder to use a new `[CodingKey]` path while encoding a nested value.
    ///
    /// The original path/depth is restored after `closure` completes.
    @inline(__always)
    func with<T>(path: [CodingKey]?, perform closure: () throws -> T) rethrows -> T {
        let oldPath = codingPath
        let oldDepth = codingPathDepth
        
        if let path {
            self.codingPath = path
            self.codingPathDepth = path.count
        }
        
        defer {
            if path != nil {
                self.codingPath = oldPath
                self.codingPathDepth = oldDepth
            }
        }
        
        return try closure()
    }
}

extension __TermEncoder {
    @inline(__always) fileprivate func wrap(_ value: Bool, codingPath: [any CodingKey]) throws -> TermReference {
        try TermReference {
            guard $0.encode(boolean: value ? 1 : 0)
            else { throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: codingPath, debugDescription: "Failed to encode \(value)")) }
        }
    }
    
    @inline(__always) fileprivate func wrap(_ value: Int, codingPath: [any CodingKey]) throws -> TermReference {
        try TermReference {
            guard $0.encode(long: value)
            else { throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: codingPath, debugDescription: "Failed to encode \(value)")) }
        }
    }
    
    @inline(__always) fileprivate func wrap(_ value: Int8, codingPath: [any CodingKey]) throws -> TermReference {
        try wrap(Int(value), codingPath: codingPath)
    }
    
    @inline(__always) fileprivate func wrap(_ value: Int16, codingPath: [any CodingKey]) throws -> TermReference {
        try wrap(Int(value), codingPath: codingPath)
    }
    
    @inline(__always) fileprivate func wrap(_ value: Int32, codingPath: [any CodingKey]) throws -> TermReference {
        try wrap(Int(value), codingPath: codingPath)
    }
    
    @inline(__always) fileprivate func wrap(_ value: Int64, codingPath: [any CodingKey]) throws -> TermReference {
        try TermReference {
            guard $0.encode(longlong: value)
            else { throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: codingPath, debugDescription: "Failed to encode \(value)")) }
        }
    }
    
    @inline(__always) fileprivate func wrap(_ value: UInt, codingPath: [any CodingKey]) throws -> TermReference {
        try TermReference {
            guard $0.encode(ulong: value)
            else { throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: codingPath, debugDescription: "Failed to encode \(value)")) }
        }
    }
    
    @inline(__always) fileprivate func wrap(_ value: UInt8, codingPath: [any CodingKey]) throws -> TermReference {
        try wrap(UInt(value), codingPath: codingPath)
    }
    
    @inline(__always) fileprivate func wrap(_ value: UInt16, codingPath: [any CodingKey]) throws -> TermReference {
        try wrap(UInt(value), codingPath: codingPath)
    }
    
    @inline(__always) fileprivate func wrap(_ value: UInt32, codingPath: [any CodingKey]) throws -> TermReference {
        try wrap(UInt(value), codingPath: codingPath)
    }
    
    @inline(__always) fileprivate func wrap(_ value: UInt64, codingPath: [any CodingKey]) throws -> TermReference {
        try TermReference {
            guard $0.encode(ulonglong: value)
            else { throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: codingPath, debugDescription: "Failed to encode \(value)")) }
        }
    }
    
    @inline(__always) fileprivate func wrap(_ value: String, codingPath: [any CodingKey]) throws -> TermReference {
        try TermReference { buffer in
            switch context.stringEncodingStrategy {
            case .binary:
                try Data(value.utf8).withUnsafeBytes { pointer in
                    guard buffer.encode(binary: pointer.baseAddress!, len: Int32(pointer.count))
                    else { throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: codingPath, debugDescription: "Failed to encode \(value)")) }
                }
            case .atom:
                guard buffer.encode(atom: value)
                else { throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: codingPath, debugDescription: "Failed to encode \(value)")) }
            case .charlist:
                try value.withCString { value in
                    guard buffer.encode(string: value)
                    else { throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: codingPath, debugDescription: "Failed to encode \(value)")) }
                }
            }
        }
    }
    
    @inline(__always) fileprivate func wrap(_ value: Double, codingPath: [any CodingKey]) throws -> TermReference {
        try TermReference {
            guard $0.encode(double: value)
            else { throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: codingPath, debugDescription: "Failed to encode \(value)")) }
        }
    }
    
    @inline(__always) fileprivate func wrap(_ value: Float, codingPath: [any CodingKey]) throws -> TermReference {
        try wrap(Double(value), codingPath: codingPath)
    }
    
    fileprivate func wrap(
        _ value: Encodable, for codingPath: [CodingKey],
        _ additionalKey: (some CodingKey)? = AnyCodingKey?.none
    ) throws -> TermReference {
        if let term = value as? Term {
            return try TermReference {
                try term.encode(to: $0)
            }
        } else {
            return try self._wrapGeneric({
                try value.encode(to: $0)
            }, for: codingPath, additionalKey)
            ?? .init(.map([:], strategy: keyedContainerEncodingStrategy))
        }
    }
    
    fileprivate func _wrapGeneric(
        _ encode: (__TermEncoder) throws -> Void, for codingPath: [CodingKey],
        _ additionalKey: (some CodingKey)? = AnyCodingKey?.none
    ) throws -> TermReference? {
        // The value should request a container from the __TermEncoder.
        let depth = self.storage.count
        do {
            try self.with(path: codingPath + (additionalKey.flatMap({ [$0] }) ?? [])) {
                try encode(self)
            }
        } catch {
            // If the value pushed a container before throwing, pop it back off to restore state.
            if self.storage.count > depth {
                let _ = self.storage.popReference()
            }

            throw error
        }

        // The top container should be a new container.
        guard self.storage.count > depth else {
            return nil
        }

        return self.storage.popReference()
    }
}

/// Storage for a ``__TermEncoder``.
struct _TermEncodingStorage {
    var refs = [TermReference]()
    
    init() {}
    
    var count: Int {
        return self.refs.count
    }
    
    mutating func pushKeyedContainer(strategy: TermEncoder.KeyedContainerEncodingStrategy) -> TermReference {
        let reference = TermReference(.map([:], strategy: strategy))
        self.refs.append(reference)
        return reference
    }
    
    mutating func pushUnkeyedContainer(strategy: TermEncoder.UnkeyedContainerEncodingStrategy) -> TermReference {
        let reference = TermReference(.list([], strategy: strategy))
        self.refs.append(reference)
        return reference
    }
    
    mutating func push(ref: __owned TermReference) {
        self.refs.append(ref)
    }
    
    mutating func popReference() -> TermReference {
        precondition(!self.refs.isEmpty, "Empty reference stack.")
        return self.refs.popLast().unsafelyUnwrapped
    }
}

/// Container for encoding an object.
private struct _TermKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    private let encoder: __TermEncoder

    private let reference: TermReference

    public var codingPath: [CodingKey]

    init(referencing encoder: __TermEncoder, codingPath: [CodingKey], wrapping ref: TermReference) {
        self.encoder = encoder
        self.codingPath = codingPath
        self.reference = ref
    }

    public mutating func encodeNil(forKey key: Key) throws {
        reference.insert(try TermReference {
            guard $0.encodeEmptyList()
            else {
                throw EncodingError.invalidValue(
                    Optional<Any>.none as Any,
                    EncodingError.Context(
                        codingPath: codingPath + [key],
                        debugDescription: "Failed to encode 'nil'"
                    )
                ) }
        }, for: key)
    }
    public mutating func encode(_ value: Bool, forKey key: Key) throws {
        reference.insert(try encoder.wrap(value, for: codingPath + [key]), for: key)
    }
    public mutating func encode(_ value: Int, forKey key: Key) throws {
        reference.insert(try encoder.wrap(value, for: codingPath + [key]), for: key)
    }
    public mutating func encode(_ value: Int8, forKey key: Key) throws {
        reference.insert(try encoder.wrap(value, for: codingPath + [key]), for: key)
    }
    public mutating func encode(_ value: Int16, forKey key: Key) throws {
        reference.insert(try encoder.wrap(value, for: codingPath + [key]), for: key)
    }
    public mutating func encode(_ value: Int32, forKey key: Key) throws {
        reference.insert(try encoder.wrap(value, for: codingPath + [key]), for: key)
    }
    public mutating func encode(_ value: Int64, forKey key: Key) throws {
        reference.insert(try encoder.wrap(value, for: codingPath + [key]), for: key)
    }
    public mutating func encode(_ value: UInt, forKey key: Key) throws {
        reference.insert(try encoder.wrap(value, for: codingPath + [key]), for: key)
    }
    public mutating func encode(_ value: UInt8, forKey key: Key) throws {
        reference.insert(try encoder.wrap(value, for: codingPath + [key]), for: key)
    }
    public mutating func encode(_ value: UInt16, forKey key: Key) throws {
        reference.insert(try encoder.wrap(value, for: codingPath + [key]), for: key)
    }
    public mutating func encode(_ value: UInt32, forKey key: Key) throws {
        reference.insert(try encoder.wrap(value, for: codingPath + [key]), for: key)
    }
    public mutating func encode(_ value: UInt64, forKey key: Key) throws {
        reference.insert(try encoder.wrap(value, for: codingPath + [key]), for: key)
    }
    
    public mutating func encode(_ value: String, forKey key: Key) throws {
        reference.insert(try encoder.wrap(value, for: codingPath + [key]), for: key)
    }

    public mutating func encode(_ value: Float, forKey key: Key) throws {
        reference.insert(try encoder.wrap(value, for: codingPath + [key]), for: key)
    }

    public mutating func encode(_ value: Double, forKey key: Key) throws {
        reference.insert(try encoder.wrap(value, for: codingPath + [key]), for: key)
    }

    public mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        let wrapped = try self.encoder.wrap(value, for: self.encoder.codingPath, key)
        reference.insert(wrapped, for: key)
    }

    public mutating func nestedContainer<NestedKey>(
        keyedBy keyType: NestedKey.Type, forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let containerKey = key
        let nestedRef: TermReference
        if let existingRef = self.reference[containerKey] {
            precondition(
                existingRef.isMap,
                "Attempt to re-encode into nested KeyedEncodingContainer<\(Key.self)> for key \"\(containerKey)\" is invalid: non-keyed container already encoded for this key"
            )
            nestedRef = existingRef
        } else {
            nestedRef = .init(.map([:], strategy: encoder.keyedContainerEncodingStrategy))
            self.reference.insert(nestedRef, for: containerKey)
        }

        let container = _TermKeyedEncodingContainer<NestedKey>(
            referencing: self.encoder, codingPath: self.codingPath + [key], wrapping: nestedRef)
        return KeyedEncodingContainer(container)
    }

    public mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let containerKey = key
        let nestedRef: TermReference
        if let existingRef = self.reference[containerKey] {
            precondition(
                existingRef.isList,
                "Attempt to re-encode into nested UnkeyedEncodingContainer for key \"\(containerKey)\" is invalid: keyed container/single value already encoded for this key"
            )
            nestedRef = existingRef
        } else {
            nestedRef = .init(.list([], strategy: encoder.unkeyedContainerEncodingStrategy))
            self.reference.insert(nestedRef, for: containerKey)
        }

        return _TermUnkeyedEncodingContainer(
            referencing: self.encoder, codingPath: self.codingPath + [key], wrapping: nestedRef)
    }

    public mutating func superEncoder() -> Encoder {
        fatalError("not supported")
    }

    public mutating func superEncoder(forKey key: Key) -> Encoder {
        fatalError("not supported")
    }
}

/// Container for encoding an array.
private struct _TermUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    private let encoder: __TermEncoder

    private let reference: TermReference

    var codingPath: [CodingKey]

    public var count: Int {
        self.reference.count
    }

    init(referencing encoder: __TermEncoder, codingPath: [CodingKey], wrapping ref: TermReference) {
        self.encoder = encoder
        self.codingPath = codingPath
        self.reference = ref
    }

    public mutating func encodeNil() throws {
        self.reference.insert(try TermReference {
            guard $0.encodeEmptyList()
            else {
                throw EncodingError.invalidValue(
                    Optional<Any>.none as Any,
                    EncodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "Failed to encode 'nil'"
                    )
                )
            }
        })
    }
    public mutating func encode(_ value: Bool) throws {
        self.reference.insert(try TermReference {
            guard $0.encode(boolean: value ? 1 : 0)
            else { throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: codingPath, debugDescription: "Failed to encode '\(value)'")) }
        })
    }
    public mutating func encode(_ value: Int) throws {
        self.reference.insert(try encoder.wrap(value, codingPath: codingPath))
    }
    public mutating func encode(_ value: Int8) throws {
        self.reference.insert(try encoder.wrap(value, codingPath: codingPath))
    }
    public mutating func encode(_ value: Int16) throws {
        self.reference.insert(try encoder.wrap(value, codingPath: codingPath))
    }
    public mutating func encode(_ value: Int32) throws {
        self.reference.insert(try encoder.wrap(value, codingPath: codingPath))
    }
    public mutating func encode(_ value: Int64) throws {
        self.reference.insert(try encoder.wrap(value, codingPath: codingPath))
    }
    public mutating func encode(_ value: UInt) throws {
        self.reference.insert(try encoder.wrap(value, codingPath: codingPath))
    }
    public mutating func encode(_ value: UInt8) throws {
        self.reference.insert(try encoder.wrap(value, codingPath: codingPath))
    }
    public mutating func encode(_ value: UInt16) throws {
        self.reference.insert(try encoder.wrap(value, codingPath: codingPath))
    }
    public mutating func encode(_ value: UInt32) throws {
        self.reference.insert(try encoder.wrap(value, codingPath: codingPath))
    }
    public mutating func encode(_ value: UInt64) throws {
        self.reference.insert(try encoder.wrap(value, codingPath: codingPath))
    }
    public mutating func encode(_ value: String) throws {
        self.reference.insert(try encoder.wrap(value, codingPath: codingPath))
    }
    public mutating func encode(_ value: Float) throws {
        self.reference.insert(try encoder.wrap(value, codingPath: codingPath))
    }
    public mutating func encode(_ value: Double) throws {
        self.reference.insert(try encoder.wrap(value, codingPath: codingPath))
    }

    public mutating func encode<T: Encodable>(_ value: T) throws {
        let wrapped = try self.encoder.wrap(
            value, for: self.encoder.codingPath,
            AnyCodingKey(stringValue: "Index \(self.count)", intValue: self.count))
        self.reference.insert(wrapped)
    }

    public mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type)
        -> KeyedEncodingContainer<NestedKey>
    {
        let key = AnyCodingKey(index: self.count)
        let nestedRef = TermReference(.map([:], strategy: encoder.keyedContainerEncodingStrategy))
        self.reference.insert(nestedRef)
        let container = _TermKeyedEncodingContainer<NestedKey>(
            referencing: self.encoder, codingPath: self.codingPath + [key], wrapping: nestedRef)
        return KeyedEncodingContainer(container)
    }

    public mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let key = AnyCodingKey(index: self.count)
        let nestedRef = TermReference(.list([], strategy: encoder.unkeyedContainerEncodingStrategy))
        self.reference.insert(nestedRef)
        return _TermUnkeyedEncodingContainer(
            referencing: self.encoder, codingPath: self.codingPath + [key], wrapping: nestedRef)
    }

    public mutating func superEncoder() -> Encoder {
        fatalError("not supported")
    }
}

/// Container for encoding a single value.
extension __TermEncoder: SingleValueEncodingContainer {
    private func assertCanEncodeNewValue() {
        precondition(
            self.canEncodeNewValue,
            "Attempt to encode value through single value container when previously value already encoded."
        )
    }
    
    public func encodeNil() throws {
        assertCanEncodeNewValue()
        self.storage.push(ref: try .init {
            guard $0.encodeEmptyList()
            else {
                throw EncodingError.invalidValue(
                    Optional<Any>.none as Any,
                    EncodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "Failed to encode 'nil'"
                    )
                )
            }
        })
    }
    
    public func encode(_ value: Bool) throws {
        assertCanEncodeNewValue()
        self.storage.push(ref: try wrap(value, codingPath: codingPath))
    }
    
    public func encode(_ value: Int) throws {
        assertCanEncodeNewValue()
        self.storage.push(ref: try wrap(value, codingPath: codingPath))
    }
    
    public func encode(_ value: Int8) throws {
        assertCanEncodeNewValue()
        self.storage.push(ref: try wrap(value, codingPath: codingPath))
    }
    
    public func encode(_ value: Int16) throws {
        assertCanEncodeNewValue()
        self.storage.push(ref: try wrap(value, codingPath: codingPath))
    }
    
    public func encode(_ value: Int32) throws {
        assertCanEncodeNewValue()
        self.storage.push(ref: try wrap(value, codingPath: codingPath))
    }
    
    public func encode(_ value: Int64) throws {
        assertCanEncodeNewValue()
        self.storage.push(ref: try wrap(value, codingPath: codingPath))
    }
    
    public func encode(_ value: UInt) throws {
        assertCanEncodeNewValue()
        self.storage.push(ref: try wrap(value, codingPath: codingPath))
    }
    
    public func encode(_ value: UInt8) throws {
        assertCanEncodeNewValue()
        self.storage.push(ref: try wrap(value, codingPath: codingPath))
    }
    
    public func encode(_ value: UInt16) throws {
        assertCanEncodeNewValue()
        self.storage.push(ref: try wrap(value, codingPath: codingPath))
    }
    
    public func encode(_ value: UInt32) throws {
        assertCanEncodeNewValue()
        self.storage.push(ref: try wrap(value, codingPath: codingPath))
    }
    
    public func encode(_ value: UInt64) throws {
        assertCanEncodeNewValue()
        self.storage.push(ref: try wrap(value, codingPath: codingPath))
    }
    
    public func encode(_ value: String) throws {
        assertCanEncodeNewValue()
        self.storage.push(ref: try wrap(value, codingPath: codingPath))
    }
    
    public func encode(_ value: Float) throws {
        assertCanEncodeNewValue()
        let wrapped = try self.wrap(value, codingPath: codingPath)
        self.storage.push(ref: wrapped)
    }
    
    public func encode(_ value: Double) throws {
        assertCanEncodeNewValue()
        let wrapped = try self.wrap(value, codingPath: codingPath)
        self.storage.push(ref: wrapped)
    }
    
    public func encode<T: Encodable>(_ value: T) throws {
        assertCanEncodeNewValue()
        try self.storage.push(ref: self.wrap(value, for: self.codingPath))
    }
}
