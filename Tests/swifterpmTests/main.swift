import Foundation
import Testing

let exitCode: CInt = await Testing.__swiftPMEntryPoint()
Foundation.exit(exitCode)
