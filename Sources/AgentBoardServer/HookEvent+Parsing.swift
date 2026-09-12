import Foundation

extension HookEvent {
    init?(body: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return nil
        }
        let notification = object["notification"] as? [String: Any]
        let toolInput = object["tool_input"] as? [String: Any]
        self.init(
            name: object["hook_event_name"] as? String ?? "",
            sessionId: object["session_id"] as? String ?? "",
            transcriptPath: object["transcript_path"] as? String,
            cwd: object["cwd"] as? String,
            toolName: object["tool_name"] as? String,
            toolCommand: toolInput?["command"] as? String,
            notificationType: object["notification_type"] as? String,
            notificationMessage: notification?["message"] as? String ?? object["message"] as? String,
            lastAssistantMessage: object["last_assistant_message"] as? String,
            rawJSON: String(decoding: body, as: UTF8.self)
        )
    }
}
