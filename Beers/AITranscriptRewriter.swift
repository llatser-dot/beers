import Foundation

struct AIRewriteSettings {
    var isEnabled: Bool
    var endpoint: String
    var model: String

    static let defaults = AIRewriteSettings(
        isEnabled: false,
        endpoint: "http://127.0.0.1:11434/v1/chat/completions",
        model: "gemma4:latest"
    )
}

enum AITranscriptRewriter {
    private final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    struct Request: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double
        let maxTokens: Int

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature
            case maxTokens = "max_tokens"
        }
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
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct ResponseMessage: Decodable {
        let content: String
    }

    /// Ollama's native chat API. Preferred over the OpenAI-compatible path
    /// because it can actually disable thinking (gemma4 etc. burn seconds of
    /// hidden reasoning through /v1/chat/completions) and keep the model
    /// resident between pours.
    struct OllamaRequest: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let think: Bool
        let options: Options
        let keepAlive: String

        struct Options: Encodable {
            let temperature: Double
            let numPredict: Int

            enum CodingKeys: String, CodingKey {
                case temperature
                case numPredict = "num_predict"
            }
        }

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, think, options
            case keepAlive = "keep_alive"
        }
    }

    struct OllamaResponse: Decodable {
        let message: ResponseMessage
        let doneReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case doneReason = "done_reason"
        }
    }

    private static let keepAlive = "30m"
    /// Rewrite API calls never follow redirects; every pour stays bound to the
    /// endpoint the user configured and, for remote origins, explicitly approved.
    private static let session = URLSession(
        configuration: .default,
        delegate: RedirectRefusingDelegate(),
        delegateQueue: nil
    )

    static func rewrite(
        _ text: String,
        mode: WritingMode,
        context: ActiveAppContext,
        settings: AIRewriteSettings
    ) async throws -> String {
        let (url, model) = try validated(settings)
        return try await complete(
            system: systemPrompt(mode: mode, context: context),
            user: text,
            url: url,
            model: model,
            temperature: 0.1,
            timeout: 12
        )
    }

    /// Command Mode: apply a spoken instruction to selected text.
    /// Ignores `isEnabled` — invoking Command Mode is explicit consent.
    static func applyInstruction(
        _ instruction: String,
        to text: String,
        settings: AIRewriteSettings
    ) async throws -> String {
        let (url, model) = try validated(settings)
        return try await complete(
            system: """
            You edit text. Apply the user's spoken instruction to the provided text.
            Return ONLY the edited text — no explanations, no preamble, no quotes, no code fences.
            Preserve meaning, names, numbers, URLs and formatting unless the instruction says otherwise.
            """,
            user: "INSTRUCTION: \(instruction)\n\nTEXT:\n\(text)",
            url: url,
            model: model,
            temperature: 0.2,
            timeout: 20
        )
    }

    /// Load the model while the user is still speaking. An Ollama-sized model
    /// can take 10s+ to page in cold — hiding that behind the recording is the
    /// difference between the configured endpoint landing inside the polish deadline
    /// and always losing to it.
    static func prewarm(settings: AIRewriteSettings) {
        guard let (url, model) = try? validated(settings) else { return }
        Task.detached(priority: .utility) {
            if let native = nativeChatURL(from: url) {
                // Empty messages = pure load request; returns once resident.
                var request = URLRequest(url: native)
                request.httpMethod = "POST"
                request.timeoutInterval = 60
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONEncoder().encode(
                    OllamaRequest(
                        model: model,
                        messages: [],
                        stream: false,
                        think: false,
                        options: .init(temperature: 0, numPredict: 1),
                        keepAlive: keepAlive
                    )
                )
                if let (_, response) = try? await session.data(for: request),
                   (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true {
                    llog("AITranscriptRewriter: prewarmed \(model)")
                    return
                }
            }
            // Not Ollama — a 1-token completion loads the model on any
            // OpenAI-compatible server.
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(
                Request(
                    model: model,
                    messages: [Message(role: "user", content: "Hi")],
                    temperature: 0,
                    maxTokens: 1
                )
            )
            _ = try? await session.data(for: request)
        }
    }

    private static func validated(_ settings: AIRewriteSettings) throws -> (URL, String) {
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: settings.endpoint),
              AIEndpointTrust.normalizedHost(from: settings.endpoint) != nil,
              !model.isEmpty else {
            throw URLError(.badURL)
        }
        try enforceEndpointTrust(url)
        return (url, model)
    }

    /// The specific remote origin the user approved via Brew Settings.
    private static let remoteEndpointAllowedOriginKey = "remoteEndpointAllowedOrigin"
    private static let remoteEndpointAllowedHostKey = "remoteEndpointAllowedHost"

    /// True when `host` is a loopback address that never leaves the machine.
    static func isLoopback(host: String?) -> Bool {
        AIEndpointTrust.isLoopback(host: host)
    }

    /// Convenience for the UI: is this endpoint string a loopback destination?
    static func isLoopbackEndpoint(_ endpoint: String) -> Bool {
        AIEndpointTrust.isLoopback(endpoint: endpoint)
    }

    static func approveRemoteEndpoint(_ endpoint: String) -> Bool {
        guard let origin = AIEndpointTrust.normalizedOrigin(from: endpoint),
              let host = AIEndpointTrust.normalizedHost(from: endpoint),
              !AIEndpointTrust.isLoopback(host: host) else { return false }
        UserDefaults.standard.set(origin, forKey: remoteEndpointAllowedOriginKey)
        return true
    }

    static func isRemoteEndpointAllowed(_ endpoint: String) -> Bool {
        guard let origin = AIEndpointTrust.normalizedOrigin(from: endpoint) else { return false }
        return UserDefaults.standard.string(forKey: remoteEndpointAllowedOriginKey) == origin
    }

    static func revokeRemoteEndpointApproval() {
        UserDefaults.standard.removeObject(forKey: remoteEndpointAllowedOriginKey)
        UserDefaults.standard.removeObject(forKey: remoteEndpointAllowedHostKey)
        // Remove the old global boolean so upgrades cannot accidentally restore
        // the pre-1.0 blanket approval behaviour.
        UserDefaults.standard.removeObject(forKey: "remoteEndpointAllowed")
    }

    /// The rewriter POSTs the user's dictation to this endpoint. Loopback is
    /// always allowed; a non-loopback (remote) origin is refused unless the user
    /// has explicitly consented to that exact scheme, host and port. Every path —
    /// polish, Command Mode, prewarm — flows through `validated`, so this one
    /// choke point covers them all.
    private static func enforceEndpointTrust(_ url: URL) throws {
        if isLoopback(host: url.host) { return }
        if isRemoteEndpointAllowed(url.absoluteString) { return }
        llog("AITranscriptRewriter: refusing non-loopback endpoint origin '\(AIEndpointTrust.normalizedOrigin(from: url.absoluteString) ?? "?")' — confirm this remote origin before any pour is sent")
        throw URLError(.userAuthenticationRequired)
    }

    private static func complete(
        system: String,
        user: String,
        url: URL,
        model: String,
        temperature: Double,
        timeout: TimeInterval
    ) async throws -> String {
        let messages = [
            Message(role: "system", content: system),
            Message(role: "user", content: user)
        ]
        // Roomy ceiling (~2× the input's tokens) so long dictations are never
        // clipped mid-sentence; hitting it still throws below.
        let maxTokens = max(300, user.count / 2)

        if let native = nativeChatURL(from: url) {
            var request = URLRequest(url: native)
            request.httpMethod = "POST"
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(
                OllamaRequest(
                    model: model,
                    messages: messages,
                    stream: false,
                    think: false,
                    options: .init(temperature: temperature, numPredict: maxTokens),
                    keepAlive: keepAlive
                )
            )
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                let decoded = try JSONDecoder().decode(OllamaResponse.self, from: data)
                return try finished(decoded.message.content, reason: decoded.doneReason)
            } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .cannotFindHost || error.code == .timedOut {
                throw error // compat path shares the host; don't fail twice
            } catch {
                llog("AITranscriptRewriter: native chat failed (\(error.localizedDescription)) — trying OpenAI-compatible endpoint")
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            Request(model: model, messages: messages, temperature: temperature, maxTokens: maxTokens)
        )

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let choice = decoded.choices.first else { throw URLError(.zeroByteResource) }
        return try finished(choice.message.content, reason: choice.finishReason)
    }

    /// A truncated rewrite is worse than no rewrite — never serve one.
    private static func finished(_ content: String, reason: String?) throws -> String {
        if reason == "length" { throw URLError(.dataLengthExceedsMaximum) }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw URLError(.zeroByteResource) }
        return trimmed
    }

    /// `http://host:port/v1/chat/completions` → `http://host:port/api/chat`.
    private static func nativeChatURL(from endpoint: URL) -> URL? {
        let openAIPath = "/v1/chat/completions"
        guard endpoint.path.hasSuffix(openAIPath),
              var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        comps.path = String(endpoint.path.dropLast(openAIPath.count)) + "/api/chat"
        return comps.url
    }

    private static func systemPrompt(mode: WritingMode, context: ActiveAppContext) -> String {
        """
        Rewrite dictated speech into final paste-ready text.
        Return only the rewritten text. Do not explain.
        Preserve names, numbers, URLs, email addresses, code identifiers, commands, and user intent.
        Remove filler words, false starts, and obvious transcription artifacts.
        Never summarise, condense or shorten: apart from removed filler and corrected restarts, \
        keep every sentence, so the output is nearly as long as the input. \
        Never drop the first or last sentence.
        Do not add facts or change meaning.
        Target app: \(context.name)
        Mode: \(mode.displayName)
        Mode guidance: \(mode.detail)
        """
    }
}
