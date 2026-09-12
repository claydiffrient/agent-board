import AgentBoardCore
import Foundation
import SwiftUI

enum Format {
    static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return String(format: "%dm %02ds", seconds / 60, seconds % 60) }
        return String(format: "%dh %02dm", seconds / 3600, (seconds % 3600) / 60)
    }

    static func elapsed(from start: Date, to end: Date = .now) -> String {
        elapsed(end.timeIntervalSince(start))
    }

    static func tokens(_ count: Int) -> String {
        if count < 1000 { return "\(count)" }
        if count < 1_000_000 { return String(format: "%.1fk", Double(count) / 1000) }
        return String(format: "%.2fM", Double(count) / 1_000_000)
    }

    static func cost(_ usd: Double) -> String {
        String(format: "$%.4f", usd)
    }

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

extension AgentSession {
    var displayShortId: String {
        shortId ?? String(sessionId.prefix(8))
    }

    func elapsedText(at now: Date) -> String {
        Format.elapsed(from: startedDate, to: endedDate ?? now)
    }
}

extension SessionState {
    var color: Color {
        switch self {
        case .starting: .orange
        case .running: .green
        case .idle: .blue
        case .blocked: .orange
        case .stopped: .secondary
        case .failed: .red
        case .completed: .teal
        }
    }
}

extension TaskColumn {
    var title: String {
        rawValue.capitalized
    }
}

func errorText(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? String(describing: error)
}

extension View {
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert(
            "Something went wrong",
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
