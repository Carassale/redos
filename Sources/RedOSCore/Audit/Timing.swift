import Foundation

/// Where a request spends its time, one line per event in `timing.log` (the system log needs admin rights
/// to read). Events and durations only, never the user's text.
public enum Timing {
    public static let url = URL.applicationSupportDirectory.appending(path: "RedOS/timing.log")
    private static let queue = DispatchQueue(label: "dev.redos.RedOS.timing")

    public static func note(_ event: String) {
        let line = Date.now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)) + " " + event + "\n"
        queue.async {
            let data = Data(line.utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    public static func since(_ start: ContinuousClock.Instant) -> String {
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return String(format: "%.2f", seconds)
    }
}
