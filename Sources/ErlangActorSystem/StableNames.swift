@attached(peer)
public macro StableName(_ name: StaticString, mangledName: StaticString? = nil) = #externalMacro(module: "DistributedMacros", type: "StableName")

@attached(
    extension,
    conformances: HasStableNames,
    names: named(mangledStableNames), named(stableMangledNames), named(_$), named(RemoteActor)
)
@attached(peer, names: prefixed(_RemoteActorFor))
public macro StableNames() = #externalMacro(module: "DistributedMacros", type: "StableNames")

@attached(body)
public macro RemoteDeclaration(_ name: StaticString) = #externalMacro(module: "DistributedMacros", type: "RemoteDeclaration")

public protocol HasStableNames {
    static var mangledStableNames: [String:String] { get }
    static var stableMangledNames: [String:String] { get }
}

public extension HasStableNames {
    /// Creates a mangled function name for a distributed function.
    ///
    /// Mangling is described with the following grammar:
    /// ```
    /// entity-spec ::= decl-name label-list function-signature generic-signature? 'F'    // function
    /// decl-name ::= identifier
    /// label-list ::= ('_' | identifier)*   // '_' is inserted as placeholder for empty label,
    ///                                      // since the number of labels should match the number of parameters
    /// identifier // <identifier> is run-length encoded: the natural indicates how many characters follow.
    /// function-signature ::= result-type params-type async? sendable? throws? differentiable? function-isolation? sending-result? // results and parameters
    /// ```
    ///
    /// Metatypes are passed to this function instead of strings so we can use
    /// ``Swift/_mangledTypeName`` to compute an accurate mangled name for any
    /// given identifier.
    ///
    /// It is expected that structs be declared with an `__` prefix for all
    /// metatype arguments. Labeled arguments should also be nested within
    /// the previous labeled argument to enable substitutions in the mangled
    /// name.
    ///
    /// ```swift
    /// struct ManglingMetatypes {
    ///     // function(labeledParam1:labeledParam2:)
    ///     struct __function {
    ///         struct __labeledParam1 {
    ///             struct __labeledParam2 {}
    ///         }
    ///     }
    /// }
    /// ```
    ///
    /// The metatypes are then used to create the mangled name:
    ///
    /// ```swift
    /// _mangle(
    ///     function: function.self,
    ///     functionContainer: ManglingMetatypes.self,
    ///     parameters: [
    ///         (label: labeledParam1.self, labelParent: function.self, type: String.self),
    ///         (label: labeledParam2.self, labelParent: labeledParam1.self, type: Int.self)
    ///     ],
    ///     returnType: Void.self,
    ///     sendingResult: false
    /// )
    /// ```
    static func _mangle(
        function: Any.Type,
        functionContainer: Any.Type?,
        parameters: [(label: Any.Type?, labelParent: Any.Type?, type: Any.Type)],
        returnType: Any.Type,
        sendingResult: Bool
    ) -> String {
        // constants
        let distributedActorThunkTag = "TE" // distributed func
//        let distributedMethodAccessorTag = "TF" // distributed var
        let asyncTag = "Ya" // async -> T
        let throwsTag = "K" // throws -> T
        
        let mangledTypeName = _mangledTypeName(Self.self)!
        
        // function name as a type
        // the value will contain the run-length encoding
        let mangledFunctionName = _mangledTypeName(function)!
            .trimmingPrefix(_mangledTypeName(functionContainer ?? Self.self)!)
            .dropLast() // drop the decl kind suffix
        
        let hasLabeledParameters = parameters.contains(where: { $0.0 != nil })
        let mangledParameterTypes = parameters.count > 0
            ? parameters.enumerated()
                .map({
                    if $0.offset == 0 && (parameters.count > 1 || hasLabeledParameters) {
                        return "\(_mangledTypeName($0.element.type)!)_"
                    } else {
                        return _mangledTypeName($0.element.type)!
                    }
                })
                .joined(separator: "")
            : "y" // empty list
        let parameterLabels = (parameters.count > 0 && !hasLabeledParameters)
            ? "y" // empty list
            : parameters.map({
                if let label = $0.label,
                   let labelParent = $0.labelParent
                {
                    // the label will contain the run-length encoding
                    return _mangledTypeName(label)!
                        .trimmingPrefix(_mangledTypeName(labelParent)!)
                        .dropLast() // drop the decl kind suffix
                } else {
                    return "_"
                }
            }).joined(separator: "")
        
        let tupleParamsTag = parameters.count > 1 ? "t" : ""
        let sendingResultTag = sendingResult ? "YT" : "" // -> sending T
        
        let mangledReturn = returnType == Void.self
            ? "y"
            : _mangledTypeName(returnType)!
        
        return "$s\(mangledTypeName)\(mangledFunctionName)\(parameterLabels)\(mangledReturn)\(mangledParameterTypes)\(tupleParamsTag)\(asyncTag)\(throwsTag)\(sendingResultTag)F\(distributedActorThunkTag)"
    }
}
