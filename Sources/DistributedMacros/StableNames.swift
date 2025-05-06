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
        if let protocolDecl = declaration.as(ProtocolDeclSyntax.self) {
            let actorName = TokenSyntax.identifier("_RemoteActorFor\(protocolDecl.name.text)")
            var actorDecl = ActorDeclSyntax(
                modifiers: [
                    DeclModifierSyntax(name: .keyword(.public)),
                    DeclModifierSyntax(name: .keyword(.distributed))
                ],
                name: actorName,
                inheritanceClause: InheritanceClauseSyntax {
                    InheritedTypeSyntax(type: IdentifierTypeSyntax(name: protocolDecl.name))
                    InheritedTypeSyntax(type: IdentifierTypeSyntax(name: .identifier("HasStableNames")))
                }
            ) {
                // create dummy implementations for all distributed functions
                for member in protocolDecl.memberBlock.members {
                    if let functionDecl = member.decl.as(FunctionDeclSyntax.self) {
                        functionDecl.with(\.body, CodeBlockSyntax {
                            FunctionCallExprSyntax(callee: DeclReferenceExprSyntax(baseName: .identifier("fatalError")))
                        })
                    } else if let variableDecl = member.decl.as(VariableDeclSyntax.self) {
                        variableDecl.with(\.bindings, PatternBindingListSyntax(variableDecl.bindings.map({
                            $0.with(\.accessorBlock, AccessorBlockSyntax(accessors: .getter(CodeBlockItemListSyntax {
                                FunctionCallExprSyntax(callee: DeclReferenceExprSyntax(baseName: .identifier("fatalError")))
                            })))
                        })))
                    }
                }
            }
            
            actorDecl.memberBlock.members.append(
                contentsOf: try hasStableNamesMembers(for: actorDecl, in: context)
                    .map({ MemberBlockItemSyntax(decl: $0) })
            )
            
            return [
                DeclSyntax(actorDecl)
            ]
        } else {
            return []
        }
    }
    
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        if let protocolDecl = declaration.as(ProtocolDeclSyntax.self) {
            return [
                ExtensionDeclSyntax(
                    extendedType: type
                ) {
                    TypeAliasDeclSyntax(
                        name: .identifier("RemoteActor"),
                        initializer: TypeInitializerClauseSyntax(
                            value: type.as(MemberTypeSyntax.self).flatMap({
                                TypeSyntax($0.with(\.name, .identifier("_RemoteActorFor\(protocolDecl.name.text)")))
                            }) ?? TypeSyntax(IdentifierTypeSyntax(name: .identifier("_RemoteActorFor\(protocolDecl.name.text)")))
                        )
                    )
                }
            ]
        } else {
            return [
                try ExtensionDeclSyntax(
                    extendedType: type,
                    inheritanceClause: InheritanceClauseSyntax {
                        InheritedTypeSyntax(type: IdentifierTypeSyntax(name: .identifier("HasStableNames")))
                    }
                ) {
                    for decl in try hasStableNamesMembers(for: declaration, in: context) {
                        decl
                    }
                }
            ]
        }
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
                            return macroName == "StableName" || macroName == "RemoteDeclaration"
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
                            return macroName == "StableName" || macroName == "RemoteDeclaration"
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
        
        // create structs used for mangling
        
        let manglingMetatypes = TokenSyntax.identifier("_$")
        
        let mangledStableNames = DictionaryExprSyntax {
            for (stableNamed, stableName, mangledName) in stableNamed {
                DictionaryElementSyntax(
                    key: stableName,
                    value: ExprSyntax(mangledName) ?? ExprSyntax(FunctionCallExprSyntax(
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
                    })
                )
            }
        }
        
        let stableMangledNames = DictionaryExprSyntax {
            if case let .elements(elements) = mangledStableNames.content {
                for element in elements {
                    element
                        .with(\.key, element.value)
                        .with(\.value, element.key)
                }
            }
        }
        
        return [
            // struct _$ {}
            DeclSyntax(StructDeclSyntax(name: manglingMetatypes) {
                for (stableNamed, _, mangledName) in stableNamed where mangledName == nil {
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
                    value: mangledStableNames
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
                    value: stableMangledNames
                )
            ))
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

