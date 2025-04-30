import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

public struct StableName: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        if let functionDecl = declaration.as(FunctionDeclSyntax.self) {
            guard functionDecl.modifiers.contains(where: {
                $0.name.tokenKind == .keyword(.distributed)
            })
            else {
                context.diagnose(Diagnostic(
                    node: functionDecl,
                    message: MacroExpansionErrorMessage("'StableName' can only be applied to distributed function declarations"),
                    fixIts: [
                        .replace(
                            message: MacroExpansionFixItMessage("Add 'distributed' modifier"),
                            oldNode: functionDecl,
                            newNode: functionDecl.with(
                                \.modifiers,
                                 [DeclModifierSyntax(name: .keyword(.distributed))] + functionDecl.modifiers.map(\.trimmed)
                            )
                        )
                    ]
                ))
                return []
            }
        } else if let variableDecl = declaration.as(VariableDeclSyntax.self) {
            guard variableDecl.modifiers.contains(where: {
                $0.name.tokenKind == .keyword(.distributed)
            })
            else {
                context.diagnose(Diagnostic(
                    node: variableDecl,
                    message: MacroExpansionErrorMessage("'StableName' can only be applied to distributed variable declarations"),
                    fixIts: [
                        .replace(
                            message: MacroExpansionFixItMessage("Add 'distributed' modifier"),
                            oldNode: variableDecl,
                            newNode: variableDecl.with(
                                \.modifiers,
                                [DeclModifierSyntax(name: .keyword(.distributed))] + variableDecl.modifiers
                            )
                        )
                    ]
                ))
                return []
            }
        } else {
            context.diagnose(Diagnostic(
                node: declaration,
                message: MacroExpansionErrorMessage("'StableName' can only be applied to distributed function or variable declarations")
            ))
            return []
        }
        
        return []
    }
}
