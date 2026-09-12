import Foundation

enum ObservedEvent: Sendable {
    case hook(event: String, sessionId: String, transcriptPath: String?)
    case mcpRequest(method: String)
    case mcpToolCall(name: String, arguments: String)
}

actor EventLog {
    private(set) var events: [ObservedEvent] = []

    func record(_ event: ObservedEvent) {
        events.append(event)
        let stamp = ISO8601DateFormatter().string(from: Date())
        print("[\(stamp)] \(event)")
    }

    func first(where predicate: @Sendable (ObservedEvent) -> Bool, timeout: Double) async -> ObservedEvent? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let found = events.first(where: predicate) { return found }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }
}
