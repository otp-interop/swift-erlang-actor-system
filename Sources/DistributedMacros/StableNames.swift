import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics
import SwiftSyntaxMacroExpansion

public struct StableNames: ExtensionMacro, PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        return []
    }
    
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        return [
            try ExtensionDeclSyntax(
                extendedType: type,
                inheritanceClause: declaration.is(ProtocolDeclSyntax.self)
                    ? nil
                    : InheritanceClauseSyntax {
                        InheritedTypeSyntax(type: IdentifierTypeSyntax(name: .identifier("HasStableNames")))
                    }
            ) {
                for decl in try hasStableNamesMembers(for: declaration, in: context) {
                    decl
                }
            }
        ]
    }
    
    static func hasStableNamesMembers(
        for declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // collect '@StableName' members
        let stableNamed = declaration.memberBlock.members
            .compactMap({ (member) -> (StableNamed, StringLiteralExprSyntax, StringLiteralExprSyntax?)? in
                if let functionDecl = member.decl.as(FunctionDeclSyntax.self) {
                    guard case let .attribute(stableNameAttribute) = functionDecl.attributes.first(where: {
                        switch $0 {
                        case let .attribute(attribute):
                            let macroName = attribute.attributeName
                                .as(IdentifierTypeSyntax.self)?
                                .name.text
                            return macroName == "StableName"
                        default:
                            return false
                        }
                    }),
                          case let .argumentList(arguments) = stableNameAttribute.arguments,
                          let stableName = arguments.first?.expression.as(StringLiteralExprSyntax.self)
                    else { return nil }
                    return (.function(functionDecl), stableName, arguments.indices.count > 1 ? arguments.last?.expression.as(StringLiteralExprSyntax.self) : nil)
                } else if let variableDecl = member.decl.as(VariableDeclSyntax.self) {
                    guard case let .attribute(stableNameAttribute) = variableDecl.attributes.first(where: {
                        switch $0 {
                        case let .attribute(attribute):
                            let macroName = attribute.attributeName
                                .as(IdentifierTypeSyntax.self)?
                                .name.text
                            return macroName == "StableName"
                        default:
                            return false
                        }
                    }),
                          case let .argumentList(arguments) = stableNameAttribute.arguments,
                          let stableName = arguments.first?.expression.as(StringLiteralExprSyntax.self)
                    else { return nil }
                    return (.variable(variableDecl), stableName, arguments.indices.count > 1 ? arguments.last?.expression.as(StringLiteralExprSyntax.self) : nil)
                } else {
                    return nil
                }
            })
        
        // check for duplicates
        for (index, (originalDecl, stableName, _)) in stableNamed.enumerated() {
            let duplicateNames = stableNamed
                .enumerated()
                .filter({
                    $0.offset > index
                    && $0.element.1.segments.description == stableName.segments.description
                })
            for duplicateName in duplicateNames {
                context.diagnose(
                    Diagnostic(
                        node: duplicateName.element.0.node,
                        message: MacroExpansionErrorMessage("Duplicate stable name '\(stableName.segments)'"),
                        notes: [
                            Note(
                                node: originalDecl.node,
                                message: MacroExpansionNoteMessage("previously declared here")
                            )
                        ]
                    )
                )
            }
        }
        
        /// ```swift
        /// nonisolated var _stableNames: [String:String] { get }
        /// ```
        let stableNames = VariableDeclSyntax(
            modifiers: [
                DeclModifierSyntax(name: .keyword(.public)),
                DeclModifierSyntax(name: .keyword(.nonisolated))
            ],
            bindingSpecifier: .keyword(.var)
        ) {
            PatternBindingSyntax(
                pattern: IdentifierPatternSyntax(identifier: .identifier("_stableNames")),
                typeAnnotation: TypeAnnotationSyntax(
                    type: DictionaryTypeSyntax(
                        key: IdentifierTypeSyntax(name: .identifier("String")),
                        value: IdentifierTypeSyntax(name: .identifier("String"))
                    )
                ),
                accessorBlock: AccessorBlockSyntax(accessors: .getter(CodeBlockItemListSyntax {
                    DictionaryExprSyntax(content: .elements(DictionaryElementListSyntax {
                        for (decl, stableName, _) in stableNamed {
                            switch decl {
                            case let .function(functionDecl):
                                DictionaryElementSyntax(
                                    key: StringLiteralExprSyntax(content: functionDecl.functionFullName),
                                    value: stableName
                                )
                            case let .variable(variableDecl):
                                DictionaryElementSyntax(
                                    key: StringLiteralExprSyntax(
                                        content: variableDecl
                                            .bindings
                                            .first!
                                            .pattern
                                            .as(IdentifierPatternSyntax.self)!
                                            .identifier
                                            .text
                                            + "()"
                                    ),
                                    value: stableName
                                )
                            }
                        }
                    }))
                }))
            )
        }
        
        /// ```swift
        /// nonisolated func _executeStableName(
        ///     target: RemoteCallTarget,
        ///     invocationDecoder: inout ErlangActorSystem.InvocationDecoder,
        ///     handler: ErlangActorSystem.ResultHandler
        /// ) async throws
        /// ```
        let executeStableName = FunctionDeclSyntax(
            modifiers: [
                DeclModifierSyntax(name: .keyword(.public)),
                DeclModifierSyntax(name: .keyword(.nonisolated))
            ],
            name: .identifier("_executeStableName"),
            signature: FunctionSignatureSyntax(
                parameterClause: FunctionParameterClauseSyntax {
                    FunctionParameterSyntax(
                        firstName: .identifier("target"),
                        type: IdentifierTypeSyntax(name: "RemoteCallTarget")
                    )
                    FunctionParameterSyntax(
                        firstName: .identifier("invocationDecoder"),
                        type: AttributedTypeSyntax(
                            specifiers: [.simpleTypeSpecifier(SimpleTypeSpecifierSyntax(specifier: .keyword(.inout)))],
                            baseType: MemberTypeSyntax(
                                baseType: IdentifierTypeSyntax(name: "ErlangActorSystem"),
                                name: .identifier("InvocationDecoder")
                            )
                        )
                    )
                    FunctionParameterSyntax(
                        firstName: .identifier("handler"),
                        type: MemberTypeSyntax(
                            baseType: IdentifierTypeSyntax(name: .identifier("ErlangActorSystem")),
                            name: .identifier("ResultHandler")
                        )
                    )
                },
                effectSpecifiers: FunctionEffectSpecifiersSyntax(
                    asyncSpecifier: .keyword(.async),
                    throwsClause: ThrowsClauseSyntax(
                        throwsSpecifier: .keyword(.throws)
                    )
                )
            )
        ) {
            SwitchExprSyntax(subject: MemberAccessExprSyntax(
                base: DeclReferenceExprSyntax(baseName: .identifier("target")),
                name: .identifier("identifier")
            )) {
                for (decl, stableName, _) in stableNamed {
                    SwitchCaseSyntax(
                        label: .case(
                            SwitchCaseLabelSyntax(
                                caseItems: [
                                    SwitchCaseItemSyntax(pattern: ExpressionPatternSyntax(expression: stableName))
                                ]
                            )
                        )
                    ) {
                        switch decl {
                        case let .function(functionDecl):
                            let callExpr = TryExprSyntax(
                                expression: AwaitExprSyntax(
                                    expression: FunctionCallExprSyntax(
                                        callee: DeclReferenceExprSyntax(
                                            baseName: functionDecl.name
                                        )
                                    ) {
                                        for parameter in functionDecl.signature.parameterClause.parameters {
                                            let decodeNext = FunctionCallExprSyntax(
                                                callee: MemberAccessExprSyntax(
                                                    base: DeclReferenceExprSyntax(
                                                        baseName: .identifier("invocationDecoder")
                                                    ),
                                                    name: .identifier("decodeNextArgument")
                                                )
                                            )
                                            switch parameter.firstName.tokenKind {
                                            case .wildcard:
                                                LabeledExprSyntax(
                                                    expression: decodeNext
                                                )
                                            default:
                                                LabeledExprSyntax(
                                                    label: parameter.firstName.trimmed.text,
                                                    expression: decodeNext
                                                )
                                            }
                                        }
                                    }
                                )
                            )
                            
                            if functionDecl.signature.returnClause == nil {
                                callExpr
                                TryExprSyntax(
                                    expression: AwaitExprSyntax(
                                        expression: FunctionCallExprSyntax(
                                            callee: MemberAccessExprSyntax(
                                                base: DeclReferenceExprSyntax(baseName: .identifier("handler")),
                                                name: .identifier("onReturnVoid")
                                            )
                                        )
                                    )
                                )
                            } else {
                                TryExprSyntax(
                                    expression: AwaitExprSyntax(
                                        expression: FunctionCallExprSyntax(
                                            callee: MemberAccessExprSyntax(
                                                base: DeclReferenceExprSyntax(baseName: .identifier("handler")),
                                                name: .identifier("onReturn")
                                            )
                                        ) {
                                            LabeledExprSyntax(label: "value", expression: callExpr)
                                        }
                                    )
                                )
                            }
                        case .variable:
                            let callExpr = TryExprSyntax(
                                expression: AwaitExprSyntax(
                                    expression: MemberAccessExprSyntax(
                                        base: DeclReferenceExprSyntax(baseName: .identifier("self")),
                                        name: decl.name
                                    )
                                )
                            )
                            
                            TryExprSyntax(
                                expression: AwaitExprSyntax(
                                    expression: FunctionCallExprSyntax(
                                        callee: MemberAccessExprSyntax(
                                            base: DeclReferenceExprSyntax(baseName: .identifier("handler")),
                                            name: .identifier("onReturn")
                                        )
                                    ) {
                                        LabeledExprSyntax(label: "value", expression: callExpr)
                                    }
                                )
                            )
                        }
                    }
                }
                
                // actorSystem.executeDistributedTarget(
                //     on: actor,
                //     target: RemoteCallTarget(localCall.identifier),
                //     invocationDecoder: &invocationDecoder,
                //     handler: handler
                // )
                SwitchCaseSyntax(label: .default(SwitchDefaultLabelSyntax())) {
                    TryExprSyntax(
                        expression: AwaitExprSyntax(
                            expression: FunctionCallExprSyntax(
                                callee: MemberAccessExprSyntax(
                                    base: DeclReferenceExprSyntax(baseName: .identifier("actorSystem")),
                                    name: .identifier("executeDistributedTarget")
                                )
                            ) {
                                LabeledExprSyntax(
                                    label: "on",
                                    expression: DeclReferenceExprSyntax(baseName: .identifier("self"))
                                )
                                LabeledExprSyntax(
                                    label: "target",
                                    expression: DeclReferenceExprSyntax(baseName: .identifier("target"))
                                )
                                LabeledExprSyntax(
                                    label: "invocationDecoder",
                                    expression: InOutExprSyntax(expression: DeclReferenceExprSyntax(baseName: .identifier("invocationDecoder")))
                                )
                                LabeledExprSyntax(
                                    label: "handler",
                                    expression: DeclReferenceExprSyntax(baseName: .identifier("handler"))
                                )
                            }
                        )
                    )
                }
            }
        }
        
        return [
            DeclSyntax(executeStableName),
            DeclSyntax(stableNames)
        ]
    }
    
    enum StableNamed {
        case function(FunctionDeclSyntax)
        case variable(VariableDeclSyntax)
        
        var node: Syntax {
            switch self {
            case .function(let functionDecl):
                Syntax(functionDecl)
            case .variable(let variableDecl):
                Syntax(variableDecl)
            }
        }
        
        var name: TokenSyntax {
            switch self {
            case .function(let functionDecl):
                return functionDecl.name
            case .variable(let variableDecl):
                return variableDecl.bindings.first!.pattern.as(IdentifierPatternSyntax.self)!.identifier
            }
        }
        
        func parameters(manglingMetatypes: TokenSyntax) -> ExprSyntax {
            switch self {
            case .function(let functionDecl):
                return ExprSyntax(ArrayExprSyntax(expressions: functionDecl.signature.parameterClause.parameters
                    .reduce(
                        (
                            [ExprSyntax](),
                            MemberAccessExprSyntax(
                                base: DeclReferenceExprSyntax(baseName: manglingMetatypes),
                                name: .identifier(functionDecl.name.text)
                            )
                        )
                    ) { (result, parameter) in
                        let (array, labelParent) = result
                        if parameter.firstName.tokenKind == .wildcard { // unlabeled
                            return (
                                array + [ExprSyntax(TupleExprSyntax {
                                    LabeledExprSyntax(
                                        label: "label",
                                        expression: NilLiteralExprSyntax()
                                    )
                                    LabeledExprSyntax(
                                        label: "labelParent",
                                        expression: NilLiteralExprSyntax()
                                    )
                                    LabeledExprSyntax(
                                        label: "type",
                                        expression: MemberAccessExprSyntax(
                                            base: TypeExprSyntax(type: parameter.type),
                                            name: .keyword(.self)
                                        )
                                    )
                                })],
                                labelParent
                            )
                        } else { // labeled
                            let label = MemberAccessExprSyntax(
                                base: labelParent,
                                name: .identifier(parameter.firstName.text)
                            )
                            return (
                                array + [ExprSyntax(TupleExprSyntax {
                                    LabeledExprSyntax(
                                        label: "label",
                                        expression: MemberAccessExprSyntax(
                                            base: label,
                                            name: .keyword(.self)
                                        )
                                    )
                                    LabeledExprSyntax(
                                        label: "labelParent",
                                        expression: MemberAccessExprSyntax(
                                            base: labelParent,
                                            name: .keyword(.self)
                                        )
                                    )
                                    LabeledExprSyntax(
                                        label: "type",
                                        expression: MemberAccessExprSyntax(
                                            base: TypeExprSyntax(type: parameter.type),
                                            name: .keyword(.self)
                                        )
                                    )
                                })],
                                label // make this label the new labelParent
                            )
                        }
                    }
                .0))
            case .variable:
                return ExprSyntax(ArrayExprSyntax(expressions: []))
            }
        }
        
        var returnType: TypeSyntax {
            switch self {
            case let .function(functionDecl):
                return functionDecl.signature.returnClause.flatMap({
                    $0.type
                }) ?? TypeSyntax(IdentifierTypeSyntax(name: .identifier("Void")))
            case let .variable(variableDecl):
                return variableDecl.bindings.first!.typeAnnotation!.type
            }
        }
    }
}

extension FunctionDeclSyntax {
    var functionFullName: String {
        var result = name.text
        result += "("
        
        for parameter in signature.parameterClause.parameters {
            result += parameter.firstName.text
            result += ":"
        }
        
        result += ")"
        
        return result
    }
}
