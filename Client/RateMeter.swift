import Foundation

/// What the link is actually carrying: bytes and messages over the last two seconds.
struct RateMeter {
    static let window: TimeInterval = 2
    private var samples: [(time: TimeInterval, bytes: Int)] = []

    mutating func add(bytes: Int, at time: TimeInterval) {
        samples.append((time, bytes))
        samples.removeAll { time - $0.time > Self.window }
    }

    func rate(at time: TimeInterval) -> (megabitsPerSecond: Double, perSecond: Double) {
        let recent = samples.filter { time - $0.time <= Self.window }
        let bytes = recent.reduce(0) { $0 + $1.bytes }
        return (Double(bytes) * 8 / Self.window / 1e6, Double(recent.count) / Self.window)
    }
}
