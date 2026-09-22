import CodingUsageKit
import Foundation

// Claude Code passes the hook JSON on stdin. This process must exit 0 and print nothing:
// stdout on some events is injected into the model context.
let stdin = FileHandle.standardInput.readDataToEndOfFile()
try? ClaudeActivityHook.record(stdin)
