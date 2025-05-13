import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct DistributedMacros: CompilerPlugin {
    var providingMacros: [Macro.Type] = [
        StableName.self,
        StableNames.self
    ]
}
