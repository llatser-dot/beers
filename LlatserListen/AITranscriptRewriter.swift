import Foundation

struct AIRewriteSettings {
    var isEnabled: Bool
    var endpoint: String
    var model: String

    static let defaults = AIRewriteSettings(
        isEnabled: false,
        endpoint: "http://127.0.0.1:11434/v1/chat/completions",
        model: "llama3.2"
    )
}

enum AITranscriptRewriter {
    struct Request: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct Response: Decodable {
        let choices: [Choice]
    }

    struct Choice: Decodable {
        let message: ResponseMessage
    }

    struct ResponseMessage: Decodable {
        let content: String
    }

    static func rewrite(
        _ text: String,
        mode: WritingMode,
        context: ActiveAppContext,
        settings: AIRewriteSettings
    ) async throws -> String {
        guard settings.isEnabled else { return text }
        guard let url = URL(string: settings.endpoint), !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return text
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            Request(
                model: settings.model,
                messages: [
                    Message(role: "system", content: systemPrompt(mode: mode, context: context)),
                    Message(role: "user", content: text)
                ],
                temperature: 0.1
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let rewritten = decoded.choices.first?.message.content
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return rewritten.isEmpty ? text : rewritten
    }

    /// Command Mode: apply a spoken instruction to selected text.
    /// Ignores `isEnabled` — invoking Command Mode is explicit consent.
    static func applyInstruction(
        _ instruction: String,
        to text: String,
        settings: AIRewriteSettings
    ) async throws -> String {
        guard let url = URL(string: settings.endpoint),
              !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            Request(
                model: settings.model,
                messages: [
                    Message(role: "system", content: """
                    You edit text. Apply the user's spoken instruction to the provided text.
                    Return ONLY the edited text — no explanations, no preamble, no quotes, no code fences.
                    Preserve meaning, names, numbers, URLs and formatting unless the instruction says otherwise.
                    """),
                    Message(role: "user", content: "INSTRUCTION: \(instruction)\n\nTEXT:\n\(text)")
                ],
                temperature: 0.2
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let edited = decoded.choices.first?.message.content
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !edited.isEmpty else { throw URLError(.zeroByteResource) }
        return edited
    }

    private static func systemPrompt(mode: WritingMode, context: ActiveAppContext) -> String {
        """
        Rewrite dictated speech into final paste-ready text.
        Return only the rewritten text. Do not explain.
        Preserve names, numbers, URLs, email addresses, code identifiers, commands, and user intent.
        Remove filler words, false starts, and obvious transcription artifacts.
        Do not add facts or change meaning.
        Target app: \(context.name)
        Mode: \(mode.displayName)
        Mode guidance: \(mode.detail)
        """
    }
}
