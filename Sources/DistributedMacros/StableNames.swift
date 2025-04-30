import SwiftSyntax
import SwiftSyntaxMacros

public struct StableNames: MemberMacro, ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let stableNamed = declaration.memberBlock.members
            .compactMap({ (member) -> (StableNamed, StringLiteralExprSyntax)? in
                if let functionDecl = member.decl.as(FunctionDeclSyntax.self) {
                    guard case let .attribute(stableNameAttribute) = functionDecl.attributes.first(where: {
                        switch $0 {
                        case let .attribute(attribute):
                            let macroName = attribute.attributeName
                                .as(IdentifierTypeSyntax.self)?
                                .name.text
                            return macroName == "StableName" || macroName == "RemoteDeclaration"
                        default:
                            return false
                        }
                    }),
                          case let .argumentList(arguments) = stableNameAttribute.arguments,
                          let stableName = arguments.first?.expression.as(StringLiteralExprSyntax.self)
                    else { return nil }
                    return (.function(functionDecl), stableName)
                } else if let variableDecl = member.decl.as(VariableDeclSyntax.self) {
                    guard case let .attribute(stableNameAttribute) = variableDecl.attributes.first(where: {
                        switch $0 {
                        case let .attribute(attribute):
                            let macroName = attribute.attributeName
                                .as(IdentifierTypeSyntax.self)?
                                .name.text
                            return macroName == "StableName" || macroName == "RemoteDeclaration"
                        default:
                            return false
                        }
                    }),
                          case let .argumentList(arguments) = stableNameAttribute.arguments,
                          let stableName = arguments.first?.expression.as(StringLiteralExprSyntax.self)
                    else { return nil }
                    return (.variable(variableDecl), stableName)
                } else {
                    return nil
                }
            })
        
        let manglingMetatypes = TokenSyntax.identifier("_$")
        
        return [
            // struct _$ {}
            DeclSyntax(StructDeclSyntax(name: manglingMetatypes) {
                for (stableNamed, _) in stableNamed {
                    // struct function {}
                    StructDeclSyntax(name: .identifier(stableNamed.name.text)) {
                        if case let .function(functionDecl) = stableNamed {
                            let labeledArguments = functionDecl.signature.parameterClause.parameters
                                .filter({ $0.firstName.tokenKind != .wildcard })
                                .reversed()
                            if let first = labeledArguments.first
                            {
                                // nested labeled parameter structs
                                // struct labeledParameter1 {
                                //     struct labeledParameter2 { ... }
                                // }
                                labeledArguments.dropFirst().reduce(
                                    StructDeclSyntax(name: .identifier(first.firstName.text)) {}
                                ) { previousResult, parameter in
                                    StructDeclSyntax(name: .identifier(parameter.firstName.text)) {
                                        previousResult
                                    }
                                }
                            }
                        }
                    }
                }
            }),
            
            DeclSyntax(VariableDeclSyntax(
                modifiers: DeclModifierListSyntax {
                    DeclModifierSyntax(name: .keyword(.static))
                },
                .let,
                name: PatternSyntax(IdentifierPatternSyntax(
                    identifier: .identifier("mangledStableNames")
                )),
                type: TypeAnnotationSyntax(type: DictionaryTypeSyntax(
                    key: IdentifierTypeSyntax(name: .identifier("String")),
                    value: IdentifierTypeSyntax(name: .identifier("String"))
                )),
                initializer: InitializerClauseSyntax(
                    value: DictionaryExprSyntax {
                        for (stableNamed, stableName) in stableNamed {
                            DictionaryElementSyntax(
                                key: stableName,
                                value: FunctionCallExprSyntax(
                                    callee: DeclReferenceExprSyntax(
                                        baseName: .identifier("_mangle")
                                    )
                                ) {
                                    LabeledExprSyntax(
                                        label: "function",
                                        expression: MemberAccessExprSyntax(
                                            base: MemberAccessExprSyntax(
                                                base: DeclReferenceExprSyntax(baseName: manglingMetatypes),
                                                name: .identifier(stableNamed.name.text)
                                            ),
                                            name: .keyword(.self)
                                        )
                                    )
                                    LabeledExprSyntax(
                                        label: "functionContainer",
                                        expression: MemberAccessExprSyntax(
                                            base: DeclReferenceExprSyntax(baseName: manglingMetatypes),
                                            name: .keyword(.self)
                                        )
                                    )
                                    LabeledExprSyntax(
                                        label: "parameters",
                                        expression: stableNamed.parameters(manglingMetatypes: manglingMetatypes)
                                    )
                                    LabeledExprSyntax(
                                        label: "returnType",
                                        expression: MemberAccessExprSyntax(
                                            base: TypeExprSyntax(type: stableNamed.returnType.trimmed),
                                            name: .keyword(.self)
                                        )
                                    )
                                    LabeledExprSyntax(
                                        label: "sendingResult",
                                        expression: BooleanLiteralExprSyntax(literal: .keyword(.false))
                                    )
                                }
                            )
                        }
                    }
                )
            )),
            
            DeclSyntax(VariableDeclSyntax(
                modifiers: DeclModifierListSyntax {
                    DeclModifierSyntax(name: .keyword(.static))
                },
                .let,
                name: PatternSyntax(IdentifierPatternSyntax(
                    identifier: .identifier("stableMangledNames")
                )),
                type: TypeAnnotationSyntax(type: DictionaryTypeSyntax(
                    key: IdentifierTypeSyntax(name: .identifier("String")),
                    value: IdentifierTypeSyntax(name: .identifier("String"))
                )),
                initializer: InitializerClauseSyntax(
                    value: FunctionCallExprSyntax(callee: DeclReferenceExprSyntax(baseName: .identifier("Dictionary"))) {
                        LabeledExprSyntax(label: "uniqueKeysWithValues", expression: FunctionCallExprSyntax(
                            callee: MemberAccessExprSyntax(
                                base: DeclReferenceExprSyntax(baseName: .identifier("mangledStableNames")),
                                name: .identifier("map")
                            ),
                            trailingClosure: ClosureExprSyntax {
                                TupleExprSyntax {
                                    LabeledExprSyntax(expression: DeclReferenceExprSyntax(baseName: .identifier("$1")))
                                    LabeledExprSyntax(expression: DeclReferenceExprSyntax(baseName: .identifier("$0")))
                                }
                            }
                        ) {})
                    }
                )
            ))
        ]
    }
    
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        return [
            ExtensionDeclSyntax(
                extendedType: type,
                inheritanceClause: InheritanceClauseSyntax {
                    InheritedTypeSyntax(type: IdentifierTypeSyntax(name: .identifier("HasStableNames")))
                }
            ) {}
        ]
    }
    
    enum StableNamed {
        case function(FunctionDeclSyntax)
        case variable(VariableDeclSyntax)
        
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

