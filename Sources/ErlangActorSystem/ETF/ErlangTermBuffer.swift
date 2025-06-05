import CErlInterface
#if canImport(Glibc)
import Glibc
#endif

public final class ErlangTermBuffer {
    var buffer: ei_x_buff = ei_x_buff()
    
    var buff: UnsafeMutablePointer<CChar>! {
        buffer.buff
    }
    
    var buffsz: Int32 {
        buffer.buffsz
    }
    
    var index: Int32 {
        buffer.index
    }
    
    deinit {
        ei_x_free(&buffer)
    }
    
    subscript(_ range: ClosedRange<Int32>) -> ErlangTermBuffer {
        let subBuffer = ErlangTermBuffer()
        ei_x_append_buf(
            &subBuffer.buffer,
            buff.advanced(by: Int(range.lowerBound)),
            (range.upperBound - range.lowerBound) + 1
        )
        return subBuffer
    }
    
    subscript(_ range: PartialRangeFrom<Int32>) -> ErlangTermBuffer {
        let subBuffer = ErlangTermBuffer()
        ei_x_append_buf(
            &subBuffer.buffer,
            buff.advanced(by: Int(range.lowerBound)),
            buffsz - range.lowerBound
        )
        return subBuffer
    }
    
    subscript(_ range: Range<Int32>) -> ErlangTermBuffer {
        let subBuffer = ErlangTermBuffer()
        ei_x_append_buf(
            &subBuffer.buffer,
            buff.advanced(by: Int(range.lowerBound)),
            range.upperBound - range.lowerBound
        )
        return subBuffer
    }
}

extension ErlangTermBuffer: CustomDebugStringConvertible, CustomStringConvertible {
    public var debugDescription: String {
        description
    }
    
    public var description: String {
        guard buff != nil else { return "<uninitialized>" }
        
        var output: UnsafeMutablePointer<CChar>!
        defer { free(output) }
        
        var index: Int32 = 0
        
        var version: Int32 = 0
        ei_decode_version(buff, &index, &version)
        
        ei_s_print_term(&output, buff, &index)
        
        return String(cString: output, encoding: .utf8) ?? ""
    }
}

extension ErlangTermBuffer {
    @discardableResult
    func new() -> Bool {
        ei_x_new(&buffer) == 0
    }
    
    @discardableResult
    func newWithVersion() -> Bool {
        ei_x_new_with_version(&buffer) == 0
    }
}

extension ErlangTermBuffer {
    @discardableResult
    func append(_ other: ErlangTermBuffer) -> Bool {
        ei_x_append(&buffer, &other.buffer) == 0
    }
}

extension ErlangTermBuffer {
    @discardableResult
    func encode(boolean: Int32) -> Bool {
        ei_x_encode_boolean(&buffer, boolean) == 0
    }
    
    @discardableResult
    func encode(long: Int) -> Bool {
        ei_x_encode_long(&buffer, long) == 0
    }
    
    @discardableResult
    func encode(longlong: Int64) -> Bool {
        ei_x_encode_longlong(&buffer, longlong) == 0
    }
    
    @discardableResult
    func encode(ulong: UInt) -> Bool {
        ei_x_encode_ulong(&buffer, ulong) == 0
    }
    
    @discardableResult
    func encode(ulonglong: UInt64) -> Bool {
        ei_x_encode_ulonglong(&buffer, ulonglong) == 0
    }
    
    @discardableResult
    func encode(double: Double) -> Bool {
        ei_x_encode_double(&buffer, double) == 0
    }
    
    @discardableResult
    func encode(atom: UnsafePointer<CChar>) -> Bool {
        ei_x_encode_atom(&buffer, atom) == 0
    }

    @discardableResult
    func encode(ref: UnsafePointer<erlang_ref>) -> Bool {
        ei_x_encode_ref(&buffer, ref) == 0
    }

    @discardableResult
    func encode(port: UnsafePointer<erlang_port>) -> Bool {
        ei_x_encode_port(&buffer, port) == 0
    }

    @discardableResult
    func encode(pid: UnsafePointer<erlang_pid>) -> Bool {
        ei_x_encode_pid(&buffer, pid) == 0
    }

    @discardableResult
    func encode(tupleHeader arity: Int) -> Bool {
        ei_x_encode_tuple_header(&buffer, arity) == 0
    }
    
    @discardableResult
    func encode(listHeader arity: Int) -> Bool {
        ei_x_encode_list_header(&buffer, arity) == 0
    }
    
    @discardableResult
    func encodeEmptyList() -> Bool {
        ei_x_encode_empty_list(&buffer) == 0
    }
    
    @discardableResult
    func encode(binary: UnsafeRawPointer, len: Int32) -> Bool {
        ei_x_encode_binary(&buffer, binary, len) == 0
    }
    
    @discardableResult
    func encode(bitstring: UnsafeRawPointer, bitoffs: Int, bits: Int) -> Bool {
        ei_x_encode_bitstring(&buffer, bitstring, bitoffs, bits) == 0
    }
    
    @discardableResult
    func encode(fun: UnsafePointer<erlang_fun>) -> Bool {
        ei_x_encode_fun(&buffer, fun) == 0
    }
    
    @discardableResult
    func encode(mapHeader arity: Int) -> Bool {
        ei_x_encode_map_header(&buffer, arity) == 0
    }
    
    @discardableResult
    func encode(string: UnsafePointer<CChar>) -> Bool {
        ei_x_encode_string(&buffer, string) == 0
    }
}

extension ErlangTermBuffer {
    @discardableResult
    func getType(
        type: UnsafeMutablePointer<UInt32>,
        size: UnsafeMutablePointer<Int32>,
        index: UnsafePointer<Int32>
    ) -> Bool {
        ei_get_type(buffer.buff, index, type, size) == 0
    }
    
    @discardableResult
    func decode(version: UnsafeMutablePointer<Int32>, index: UnsafeMutablePointer<Int32>) -> Bool {
        ei_decode_version(buffer.buff, index, version) == 0
    }
    
    @discardableResult
    func decode(boolean: UnsafeMutablePointer<Int32>, index: UnsafeMutablePointer<Int32>) -> Bool {
        ei_decode_boolean(buffer.buff, index, boolean) == 0
    }
    
    @discardableResult
    func decode(long: UnsafeMutablePointer<Int>, index: UnsafeMutablePointer<Int32>) -> Bool {
        ei_decode_long(buffer.buff, index, long) == 0
    }
    
    @discardableResult
    func decode(longlong: UnsafeMutablePointer<Int64>, index: UnsafeMutablePointer<Int32>) -> Bool {
        ei_decode_longlong(buffer.buff, index, longlong) == 0
    }
    
    @discardableResult
    func decode(ulong: UnsafeMutablePointer<UInt>, index: UnsafeMutablePointer<Int32>) -> Bool {
        ei_decode_ulong(buffer.buff, index, ulong) == 0
    }
    
    @discardableResult
    func decode(ulonglong: UnsafeMutablePointer<UInt64>, index: UnsafeMutablePointer<Int32>) -> Bool {
        ei_decode_ulonglong(buffer.buff, index, ulonglong) == 0
    }
    
    @discardableResult
    func decode(double: UnsafeMutablePointer<Double>, index: UnsafeMutablePointer<Int32>) -> Bool {
        ei_decode_double(buffer.buff, index, double) == 0
    }
    
    @discardableResult
    func decode(atom: UnsafeMutablePointer<CChar>, index: UnsafeMutablePointer<Int32>) -> Bool {
        ei_decode_atom(buffer.buff, index, atom) == 0
    }

    @discardableResult
    func decode(ref: UnsafeMutablePointer<erlang_ref>, index: UnsafeMutablePointer<Int32>) -> Bool {
        ei_decode_ref(buffer.buff, index, ref) == 0
    }

    @discardableResult
    func decode(port: UnsafeMutablePointer<erlang_port>, index: UnsafeMutablePointer<Int32>) -> Bool {
        ei_decode_port(buffer.buff, index, port) == 0
    }

    @discardableResult
    func decode(pid: UnsafeMutablePointer<erlang_pid>, index: UnsafeMutablePointer<Int32>) -> Bool {
        ei_decode_pid(buffer.buff, index, pid) == 0
    }

    @discardableResult
    func decode(tupleHeader arity: UnsafeMutablePointer<Int32>, index: UnsafeMutablePointer<Int32>) -> Bool {
        ei_decode_tuple_header(buffer.buff, index, arity) == 0
    }
    
    @discardableResult
    func decode(listHeader arity: UnsafeMutablePointer<Int32>, index: UnsafeMutablePointer<Int32>) -> Bool {
        ei_decode_list_header(buffer.buff, index, arity) == 0
    }
    
    @discardableResult
    func decode(binary: UnsafeMutableRawPointer, len: UnsafeMutablePointer<Int>, index: UnsafeMutablePointer<Int32>) -> Bool {
        ei_decode_binary(buffer.buff, index, binary, len) == 0
    }
    
    @discardableResult
    func decode(
        bitstring pointer: UnsafeMutablePointer<UnsafePointer<CChar>?>,
        bitoffsp: UnsafeMutablePointer<UInt32>,
        nbitsp: UnsafeMutablePointer<Int>,
        index: UnsafeMutablePointer<Int32>
    ) -> Bool {
        ei_decode_bitstring(buffer.buff, index, pointer, bitoffsp, nbitsp) == 0
    }
    
    @discardableResult
    func decode(fun: UnsafeMutablePointer<erlang_fun>, index: UnsafeMutablePointer<Int32>) -> Bool {
        ei_decode_fun(buffer.buff, index, fun) == 0
    }
    
    @discardableResult
    func decode(mapHeader arity: UnsafeMutablePointer<Int32>, index: UnsafeMutablePointer<Int32>) -> Bool {
        ei_decode_map_header(buffer.buff, index, arity) == 0
    }
    
    @discardableResult
    func decode(string: UnsafeMutablePointer<CChar>, index: UnsafeMutablePointer<Int32>) -> Bool {
        ei_decode_string(buffer.buff, index, string) == 0
    }
    
    @discardableResult
    func skipTerm(index: UnsafeMutablePointer<Int32>) -> Bool {
        ei_skip_term(buffer.buff, index) == 0
    }
}
