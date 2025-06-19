import CErlInterface

extension Term {
    public struct Reference: Sendable, Hashable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
        var ref: erlang_ref
        
        init(ref: erlang_ref) {
            self.ref = ref
        }
        
        public static func == (lhs: Self, rhs: Self) -> Bool {
            var lhs = lhs
            var rhs = rhs
            return ei_cmp_refs(&lhs.ref, &rhs.ref) == 0
        }
        
        public func hash(into hasher: inout Hasher) {
            hasher.combine(ref.creation)
            hasher.combine(ref.len)
            var n = ref.n
            withUnsafeBytes(of: &n) { pointer in
                hasher.combine(bytes: pointer)
            }
            var node = ref.node
            withUnsafeBytes(of: &node) { pointer in
                hasher.combine(bytes: pointer)
            }
        }
        
        public init(from decoder: any Decoder) throws {
            guard let decoder = decoder as? __TermDecoder
            else { fatalError("Reference cannot be decoded outside of TermDecoder") }
            
            _ = try decoder.singleValueContainer()
            
            var ref = erlang_ref()
            ei_decode_ref(decoder.buffer.buff, &decoder.index, &ref)
            self.ref = ref
        }
        
        public func encode(to encoder: any Encoder) throws {
            guard let encoder = encoder as? __TermEncoder
            else { fatalError("Reference cannot be encoded outside of TermEncoder") }
            
            _ = encoder.singleValueContainer()
            
            var ref = self.ref
            encoder.storage.push(ref: TermReference {
                $0.encode(ref: &ref)
            })
        }
        
        public var debugDescription: String {
            description
        }
        
        public var description: String {
            let buffer = ErlangTermBuffer()
            var ref = ref
            buffer.encode(ref: &ref)
            return buffer.description
        }
    }
}

extension Term.Reference {
    init(for node: UnsafeMutablePointer<ei_cnode>) {
        self.ref = erlang_ref()
        ei_make_ref(node, &ref)
    }
}
