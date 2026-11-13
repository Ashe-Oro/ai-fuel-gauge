import Foundation

@main
struct GrokFetcherTests {
    static func main() async throws {
        if CommandLine.arguments.contains("--live") {
            let reading = try await GrokFetcher().fetch()
            print("Live Grok: \(reading.percentUsed)% used; saved \(reading.loadedAt); resets \(String(describing: reading.resetDate))")
            return
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let scenarios: [String: String?] = [
            "valid": nil, "no-reset": nil, "over-limit": nil,
            "expired": "expired", "reset-passed": "expired", "too-old": "expired",
            "missing": "unavailable", "absent": "unavailable", "no-allowance": "unavailable",
            "wrong-account": "unavailable", "signed-out": "unavailable",
            "bad-schema": "unsupported", "bad-json": "unsupported",
            "negative": "unsupported", "future-reading": "unsupported"
        ]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for (name, expectedError) in scenarios {
            do {
                let reading = try GrokFetcher.read(directory: root.appendingPathComponent(name), now: now)
                precondition(expectedError == nil, "\(name) should fail")
                precondition(reading.percentUsed == (name == "over-limit" ? 123.4 : 12.34))
                precondition((reading.resetDate == nil) == (name == "no-reset"))
                precondition(reading.loadedAt == now.addingTimeInterval(-60))
            } catch let error as GrokFetcher.FetchError {
                precondition(expectedError == String(describing: error), "\(name): unexpected \(error)")
            }
        }
        print("Passed \(scenarios.count) Grok cache scenarios")
    }
}
