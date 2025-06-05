import CErlInterface

extension Term {
    /// A process identifier.
    public struct PID: Sendable, Hashable, Codable, CustomDebugStringConvertible, CustomStringConvertible {
        var pid: erlang_pid
        
        init(pid: erlang_pid) {
            self.pid = pid
        }
        
        public static func == (lhs: Self, rhs: Self) -> Bool {
            var lhs = lhs
            var rhs = rhs
            return ei_cmp_pids(&lhs.pid, &rhs.pid) == 0
        }
        
        public func hash(into hasher: inout Hasher) {
            hasher.combine(pid.creation)
            hasher.combine(pid.num)
            hasher.combine(pid.serial)
            hasher.combine(Array(tuple: pid.node, start: \.0))
        }
        
        public init(from decoder: any Decoder) throws {
            guard let decoder = decoder as? __TermDecoder
            else { fatalError("PID cannot be decoded outside of TermDecoder") }
            
            _ = try decoder.singleValueContainer()
            
            var pid = erlang_pid()
            ei_decode_pid(decoder.buffer.buff, &decoder.index, &pid)
            self.pid = pid
        }
        
        public func encode(to encoder: any Encoder) throws {
            guard let encoder = encoder as? __TermEncoder
            else { fatalError("PID cannot be encoded outside of TermEncoder") }
            
            _ = encoder.singleValueContainer()
            
            var pid = self.pid
            encoder.storage.push(ref: TermReference {
                $0.encode(pid: &pid)
            })
        }
        
        public var debugDescription: String {
            description
        }
        
        public var description: String {
            let buffer = ErlangTermBuffer()
            var pid = pid
            buffer.encode(pid: &pid)
            return buffer.description
        }
    }
}
