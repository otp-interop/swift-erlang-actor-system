import SwiftSyntax
import SwiftSyntaxMacros

public struct RemoteDeclaration: BodyMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
        in context: some MacroExpansionContext
    ) throws -> [CodeBlockItemSyntax] {
        return [
            CodeBlockItemSyntax(item: .expr(ExprSyntax(FunctionCallExprSyntax(
                callee: DeclReferenceExprSyntax(
                    baseName: .identifier("fatalError")
                )
            ))))
        ]
    }
}
