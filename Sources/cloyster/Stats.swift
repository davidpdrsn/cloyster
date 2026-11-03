import Foundation

/// What the prototype exists to find out: how far windows fall behind, and which apps refuse sizes.
struct Stats {
    struct App {
        var writes = 0
        var lagMilliseconds: [Double] = []
        var refused = 0
    }

    var apps: [String: App] = [:]
    /// Distance in points between where a follower is and where it should be, sampled during drags.
    var drift: [Double] = []

    func report(coalesced: Int) -> String {
        var lines = ["app                       writes  lag p50/p95/max ms  refused"]
        for (name, app) in apps.sorted(by: { $0.key < $1.key }) {
            lines.append(
                name.padding(toLength: 26, withPad: " ", startingAt: 0)
                    + String(format: "%6d  ", app.writes)
                    + summary(app.lagMilliseconds).padding(toLength: 18, withPad: " ", startingAt: 0)
                    + String(format: "  %7d", app.refused)
            )
        }
        lines.append("writes skipped because a newer frame replaced them: \(coalesced)")
        lines.append("follower drift during drags, p50/p95/max pt: \(summary(drift)) (\(drift.count) samples)")
        return lines.joined(separator: "\n")
    }

    private func summary(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "-" }
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double { sorted[Int(Double(sorted.count - 1) * p)] }
        return String(format: "%.1f/%.1f/%.1f", percentile(0.5), percentile(0.95), sorted[sorted.count - 1])
    }
}
