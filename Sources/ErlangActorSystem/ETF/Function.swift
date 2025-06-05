import CErlInterface
#if canImport(Glibc)
import Glibc
#endif

extension Term {
    /// A function that can be sent between nodes and executed on that node.
    public final class Function: @unchecked Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
        var fun: erlang_fun
        
        @MainActor private static var closures = [Term.PID: [(ErlangTermBuffer, Int32) throws -> ErlangTermBuffer]]()
        @MainActor static func call(
            callee: Term.PID,
            id: Int,
            arguments: sending ErlangTermBuffer,
            argumentsStartIndex: Int32
        ) async throws -> sending ErlangTermBuffer {
            try closures[callee]![id](arguments, argumentsStartIndex)
        }
        
        init(fun: erlang_fun) {
            self.fun = fun
        }
        
        private struct ArgumentList<
            each Argument: Decodable & Sendable
        >: Decodable, Sendable {
            let arguments: (repeat each Argument)
            
            init(from decoder: any Decoder) throws {
                var container = try decoder.unkeyedContainer()
                self.arguments = (
                    repeat try container.decode((each Argument).self)
                )
            }
        }
        
        /// Creates a closure that can be called from Elixir.
        ///
        /// Any closure you send to Elixir can be called an arbitrary number of
        /// times. As such, the closure will never be destroyed after init.
        ///
        /// - Warning: Closures do *not* support reentrancy. The remote node
        /// that calls the function will block until the closure returns.
        @MainActor public init<
            each Argument: Decodable & Sendable,
            each Result: Encodable & Sendable
        >(
            callee: Term.PID,
            _ action: sending @escaping (repeat each Argument) throws -> (repeat each Result)
        ) {
            let id = Self.closures.count
            
            Self.closures[callee, default: []].append({ buffer, startIndex in
                let arguments = try TermDecoder().decode(
                    ArgumentList<repeat each Argument>.self,
                    from: buffer,
                    startIndex: startIndex
                ).arguments
                
                let result = try action(repeat each arguments)
                
                let buffer = ErlangTermBuffer()
                buffer.newWithVersion()
                
                var resultCount = 0
                for _ in repeat (each Result).self {
                    resultCount += 1
                }
                
                switch resultCount {
                case 0:
                    buffer.encode(atom: "ok")
                case 1:
                    let encoder = TermEncoder()
                    encoder.options.includeVersion = false
                    for result in repeat (each result) {
                        buffer.append(try encoder.encode(result))
                    }
                default:
                    buffer.encode(tupleHeader: resultCount)
                    
                    let encoder = TermEncoder()
                    encoder.options.includeVersion = false
                    for result in repeat (each result) {
                        buffer.append(try encoder.encode(result))
                    }
                }
                
                return buffer
            })
            
            let annotation = 1
            
            var argumentCount = 0
            for _ in repeat (each Argument).self {
                argumentCount += 1
            }
            
            // `free_fun` frees the buffer for us, so we can create the buffer
            // here without the `ErlangTermBuffer` and not worry about lifecycle
            var freeVars = ei_x_buff()
            ei_x_new(&freeVars)
            
            // {annotation, bindings, local handler, external handler, %{}, clauses}
            ei_x_encode_tuple_header(&freeVars, 6)
            ei_x_encode_long(&freeVars, annotation)
            
            ei_x_encode_map_header(&freeVars, 1) // bindings
            ei_x_encode_atom(&freeVars, "_@1") // pid
            var pid = callee.pid
            ei_x_encode_pid(&freeVars, &pid)
            
            // {:value, &elixir.eval_local_handler/2}
            ei_x_encode_tuple_header(&freeVars, 2)
            ei_x_encode_atom(&freeVars, "value")
            let eval_local_handler = Function("elixir", "eval_local_handler", 2)
            ei_x_encode_fun(&freeVars, &eval_local_handler.fun)
            
            // {:value, &elixir.eval_external_handler/3}
            ei_x_encode_tuple_header(&freeVars, 2)
            ei_x_encode_atom(&freeVars, "value")
            let eval_external_handler = Function("elixir", "eval_external_handler", 3)
            ei_x_encode_fun(&freeVars, &eval_external_handler.fun)
            
            ei_x_encode_map_header(&freeVars, 0) // %{}
            
            ei_x_encode_list_header(&freeVars, 1) // clauses
            
            // encode Erlang AST for function clause
            func tupleAST(arity: Int, _ build: () -> ()) {
                ei_x_encode_tuple_header(&freeVars, 3)
                ei_x_encode_atom(&freeVars, "tuple")
                ei_x_encode_long(&freeVars, annotation)
                ei_x_encode_list_header(&freeVars, arity) // elements
                build()
                ei_x_encode_empty_list(&freeVars) // elements tail
            }
            
            func atomAST( _ atom: String) {
                ei_x_encode_tuple_header(&freeVars, 3)
                ei_x_encode_atom(&freeVars, "atom")
                ei_x_encode_long(&freeVars, annotation)
                ei_x_encode_atom(&freeVars, atom)
            }
            
            func varAST(_ name: String) {
                ei_x_encode_tuple_header(&freeVars, 3)
                ei_x_encode_atom(&freeVars, "var")
                ei_x_encode_long(&freeVars, annotation)
                ei_x_encode_atom(&freeVars, name)
            }
            
            /// - Note: You must encode another term to add to the list
            func consHeaderAST(lhs: () -> ()) {
                ei_x_encode_tuple_header(&freeVars, 4)
                ei_x_encode_atom(&freeVars, "cons")
                ei_x_encode_long(&freeVars, annotation)
                lhs()
            }
            
            // {:clause, ANNO, pattern, guard, body}
            ei_x_encode_tuple_header(&freeVars, 5)
            
            ei_x_encode_atom(&freeVars, "clause") // clause
            ei_x_encode_long(&freeVars, annotation)
            // pattern
            if argumentCount == 0 {
                ei_x_encode_empty_list(&freeVars)
            } else {
                ei_x_encode_list_header(&freeVars, argumentCount)
                for argument in 0..<argumentCount {
                    varAST("_arg@\(argument)")
                }
                ei_x_encode_empty_list(&freeVars) // tail
            }
            ei_x_encode_empty_list(&freeVars) // guard
            
            // send(pid, {:fn, :hello})
            // receive do res -> res end
            ei_x_encode_list_header(&freeVars, 2) // body
            
            // send(pid, {:fn, :hello})
            ei_x_encode_tuple_header(&freeVars, 4)
            ei_x_encode_atom(&freeVars, "call")
            ei_x_encode_long(&freeVars, annotation)
            
            ei_x_encode_tuple_header(&freeVars, 4)
            ei_x_encode_atom(&freeVars, "remote")
            ei_x_encode_long(&freeVars, annotation)
            
            atomAST("erlang")
            atomAST("send")
            
            ei_x_encode_list_header(&freeVars, 2) // args list
            
            varAST("_@1")
            // {:call, id, sender, [args...]}
            tupleAST(arity: 4) {
                atomAST("call")
                
                // {:integer, annotation, id}
                ei_x_encode_tuple_header(&freeVars, 3)
                ei_x_encode_atom(&freeVars, "integer")
                ei_x_encode_long(&freeVars, annotation)
                ei_x_encode_long(&freeVars, id)
                
                // self()
                ei_x_encode_tuple_header(&freeVars, 4)
                ei_x_encode_atom(&freeVars, "call")
                ei_x_encode_long(&freeVars, annotation)
                ei_x_encode_tuple_header(&freeVars, 4)
                ei_x_encode_atom(&freeVars, "remote")
                ei_x_encode_long(&freeVars, annotation)
                atomAST("erlang")
                atomAST("self")
                ei_x_encode_empty_list(&freeVars)
                
                // args
                if argumentCount == 0 {
                    ei_x_encode_tuple_header(&freeVars, 2)
                    ei_x_encode_atom(&freeVars, "nil")
                    ei_x_encode_long(&freeVars, annotation)
                } else {
                    for argument in 0..<argumentCount {
                        consHeaderAST {
                            varAST("_arg@\(argument)")
                        }
                    }
                    // cons tail
                    ei_x_encode_tuple_header(&freeVars, 2)
                    ei_x_encode_atom(&freeVars, "nil")
                    ei_x_encode_long(&freeVars, annotation)
                }
            }
            
            ei_x_encode_empty_list(&freeVars) // args list tail
            
            // receive do res -> res end
            ei_x_encode_tuple_header(&freeVars, 3)
            ei_x_encode_atom(&freeVars, "receive")
            ei_x_encode_long(&freeVars, annotation)
            
            ei_x_encode_list_header(&freeVars, 1) // clauses
            
            // {:clause, annotation, bindings, guard, body}
            ei_x_encode_tuple_header(&freeVars, 5)
            ei_x_encode_atom(&freeVars, "clause") // clause
            ei_x_encode_long(&freeVars, annotation)
            
            ei_x_encode_list_header(&freeVars, 1) // pattern
            varAST("_res@1")
            ei_x_encode_empty_list(&freeVars) // pattern tail
            
            ei_x_encode_empty_list(&freeVars) // guard
            
            ei_x_encode_list_header(&freeVars, 1) // body
            varAST("_res@1")
            ei_x_encode_empty_list(&freeVars) // receive body tail
            
            ei_x_encode_empty_list(&freeVars) // receive clauses tail
            
            ei_x_encode_empty_list(&freeVars) // body tail
            
            ei_x_encode_empty_list(&freeVars) // clauses tail
            
            self.fun = erlang_fun(
                arity: argumentCount,
                module: "erl_eval".tuple(),
                type: EI_FUN_CLOSURE,
                u: erlang_fun.__Unnamed_union_u(closure: erlang_fun.__Unnamed_union_u.__Unnamed_struct_closure(
                    md5: "".tuple(),
                    index: Int(pid.num),
                    old_index: 0,
                    uniq: id,
                    n_free_vars: 1,
                    pid: pid,
                    free_var_len: Int(freeVars.buffsz),
                    free_vars: freeVars.buff
                ))
            )
        }
        
        public init(
            _ module: String,
            _ function: String,
            _ arity: Int
        ) {
            self.fun = erlang_fun(
                arity: arity,
                module: module.tuple(),
                type: EI_FUN_EXPORT,
                u: .init(
                    exprt: .init(
                        func: strdup(function),
                        func_allocated: 0
                    )
                )
            )
        }
        
        deinit {
            free_fun(&fun)
        }
        
        public static func == (lhs: Function, rhs: Function) -> Bool {
            lhs.hashValue == rhs.hashValue
        }
        
        public func hash(into hasher: inout Hasher) {
            hasher.combine(fun.arity)
            hasher.combine(String(cString: [CChar](tuple: fun.module, start: \.0), encoding: .utf8))
            hasher.combine(fun.type)
            
            if fun.type == EI_FUN_CLOSURE {
                hasher.combine(fun.u.closure.free_var_len)
                hasher.combine(fun.u.closure.free_vars)
                hasher.combine(fun.u.closure.index)
                hasher.combine(fun.u.closure.n_free_vars)
                hasher.combine(fun.u.closure.old_index)
                hasher.combine(fun.u.closure.old_index)
                hasher.combine(fun.u.closure.uniq)
                hasher.combine(Array(tuple: fun.u.closure.md5, start: \.0))
                hasher.combine(PID(pid: fun.u.closure.pid))
            } else {
                hasher.combine(String(cString: fun.u.exprt.func, encoding: .utf8))
                hasher.combine(fun.u.exprt.func_allocated)
            }
        }
        
        public var debugDescription: String {
            description
        }
        
        public var description: String {
            let buffer = ErlangTermBuffer()
            var fun = fun
            buffer.encode(fun: &fun)
            return buffer.description
        }
    }
}

extension Term.Function: Codable {
    public convenience init(from decoder: any Decoder) throws {
        guard let decoder = decoder as? __TermDecoder
        else { fatalError("Function cannot be decoded outside of TermDecoder") }
        
        _ = try decoder.singleValueContainer()
        
        self.init(fun: erlang_fun())
        ei_decode_fun(decoder.buffer.buff, &decoder.index, &self.fun)
    }
    
    public func encode(to encoder: any Encoder) throws {
        guard let encoder = encoder as? __TermEncoder
        else { fatalError("Function cannot be decoded outside of TermEncoder") }
        
        _ = encoder.singleValueContainer()
        
        var fun = self.fun
        encoder.storage.push(ref: TermReference {
            $0.encode(fun: &fun)
        })
    }
}
