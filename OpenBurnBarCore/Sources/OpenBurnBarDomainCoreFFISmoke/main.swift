import Foundation
import OpenBurnBarDomainCoreFFI

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("domain-core smoke failed: \(message)\n".utf8))
        exit(1)
    }
}

require(OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 2, "unexpected ABI version")
require(!OpenBurnBarDomainCoreFFI.domainCoreVersion().isEmpty, "empty crate version")

let fixtureURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../../tests/fixtures/domain-core/quota/v1/claude-statusline-input.json")
    .standardizedFileURL

let payload: Data
do {
    payload = try Data(contentsOf: fixtureURL)
} catch {
    FileHandle.standardError.write(Data("domain-core smoke failed: cannot read fixture: \(error)\n".utf8))
    exit(1)
}

let result = OpenBurnBarDomainCoreFFI.parseClaudeStatuslineQuota(payload: payload)
require(result.status == .parsed, "fixture did not parse")
require(result.snapshot.provider == "claudeCode", "unexpected provider")
require(
    result.snapshot.buckets.map(\.key) == [
        "claude-five_hour",
        "claude-seven_day",
        "claude-seven_day_opus"
    ],
    "unexpected bucket keys"
)
let fiveHourUtilization = result.snapshot.buckets[0].usedPercent
require(fiveHourUtilization != nil, "missing five-hour utilization")
require(abs((fiveHourUtilization ?? 0) - 42.5) < 0.000_001, "unexpected five-hour utilization")

print("domain-core native smoke passed")
