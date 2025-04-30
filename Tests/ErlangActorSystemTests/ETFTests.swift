import Testing
import Foundation
@testable import ErlangActorSystem
import erl_interface

@Suite("Erlang Term Format Tests") struct ETFTests {
    @Test func codable() throws {
        struct A: Codable, Equatable {
            let int: Int
            let double: Double
            let string: String
            let ref: Term.Reference
            let port: Term.Port
            let pid: Term.PID
            let list: [Int]
            let binary: Data
            let function: Term.Function
            let map: [String:Int]
        }
        
        let value = A(
            int: 42,
            double: 3.14,
            string: "string",
            ref: Term.Reference(ref: erlang_ref()),
            port: Term.Port(port: erlang_port()),
            pid: Term.PID(pid: erlang_pid()),
            list: [1, 2, 3],
            binary: Data("binary".utf8),
            function: Term.Function("Elixir.IO", "puts", 1),
            map: ["a": 1, "b": 2, "c": 3]
        )
        
        let term = try TermEncoder().encode(value)
        let decoded = try TermDecoder().decode(A.self, from: term)
        #expect(decoded == value)
    }
    
    @Test func term() throws {
        let terms = [
            Term.int(42),
            Term.double(3.14),
            Term.string("string"),
            Term.atom("atom"),
            Term.ref(Term.Reference(ref: erlang_ref())),
            Term.port(Term.Port(port: erlang_port())),
            Term.pid(Term.PID(pid: erlang_pid())),
            Term.list([Term.int(1), Term.int(2), Term.int(3)]),
            Term.tuple([Term.int(1), Term.int(2), Term.int(3)]),
            Term.binary(Data("binary".utf8)),
            Term.map([Term.string("a"): Term.int(1), Term.string("b"): Term.int(2), Term.string("c"): Term.int(3)]),
        ]
        for term in terms {
            let buffer = try term.makeBuffer()
            let decoded = try Term(from: buffer)
            #expect(decoded == term)
        }
    }
}
