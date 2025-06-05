import CErlInterface

extension Term {
    public struct Port: Sendable, Hashable, Codable {
        var port: erlang_port
        
        init(port: erlang_port) {
            self.port = port
        }
        
        public static func == (lhs: Self, rhs: Self) -> Bool {
            var lhs = lhs
            var rhs = rhs
            return ei_cmp_ports(&lhs.port, &rhs.port) == 0
        }
        
        public func hash(into hasher: inout Hasher) {
            hasher.combine(port.creation)
            hasher.combine(port.id)
            hasher.combine(Array(tuple: port.node, start: \.0))
        }
        
        public init(from decoder: any Decoder) throws {
            guard let decoder = decoder as? __TermDecoder
            else { fatalError("Port cannot be decoded outside of TermDecoder") }
            
            _ = try decoder.singleValueContainer()
            
            var port = erlang_port()
            ei_decode_port(decoder.buffer.buff, &decoder.index, &port)
            self.port = port
        }
        
        public func encode(to encoder: any Encoder) throws {
            guard let encoder = encoder as? __TermEncoder
            else { fatalError("Port cannot be encoded outside of TermEncoder") }
            
            _ = encoder.singleValueContainer()
            
            var port = self.port
            encoder.storage.push(ref: TermReference {
                $0.encode(port: &port)
            })
        }
    }
}
