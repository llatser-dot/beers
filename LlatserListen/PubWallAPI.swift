import Foundation

struct PubWallAPIError: LocalizedError {
    let statusCode: Int
    let message: String
    let retryAfter: TimeInterval?

    var errorDescription: String? { message }
}

struct PubWallAPI {
    static let live: PubWallAPI = {
        guard let url = URL(string: "https://beers-pubwall.revivmedia.workers.dev") else {
            fatalError("The Pub Wall URL is invalid.")
        }
        return PubWallAPI(baseURL: url, session: PubWallSession.secure)
    }()

    let baseURL: URL
    var session: URLSession = .shared

    func leaderboard(limit: Int = 50) async throws -> PubWallLeaderboard {
        try await request(path: "/api/leaderboard?limit=\(limit)")
    }

    func usernameAvailable(_ username: String) async throws -> Bool {
        var components = URLComponents(url: baseURL.appending(path: "/api/username-available"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "username", value: username)]
        guard let url = components?.url else { throw URLError(.badURL) }
        let response: PubWallAvailability = try await request(url: url)
        return response.available
    }

    func register(username: String) async throws -> PubWallRegistration {
        try await request(path: "/api/register", method: "POST", body: ["username": username])
    }

    func profile(token: String) async throws -> PubWallProfile {
        try await request(path: "/api/me", token: token)
    }

    func sendClaim(email: String, token: String) async throws {
        let _: PubWallOK = try await request(
            path: "/api/claim",
            method: "POST",
            token: token,
            body: ["email": email]
        )
    }

    func verifyClaim(code: String, token: String) async throws {
        let _: PubWallOK = try await request(
            path: "/api/claim/verify",
            method: "POST",
            token: token,
            body: ["code": code]
        )
    }

    func sendPours(words: Int, pours: Int, token: String) async throws -> PubWallPoursResult {
        try await request(
            path: "/api/pours",
            method: "POST",
            token: token,
            body: ["words": words, "pours": pours]
        )
    }

    func backfill(words: Int, pours: Int, token: String) async throws -> PubWallPoursResult {
        try await request(
            path: "/api/backfill",
            method: "POST",
            token: token,
            body: ["words": words, "pours": pours]
        )
    }

    func beginRecovery(email: String, username: String) async throws {
        let _: PubWallOK = try await request(
            path: "/api/recover",
            method: "POST",
            body: ["email": email, "username": username]
        )
    }

    func verifyRecovery(email: String, username: String, code: String) async throws -> PubWallRecovery {
        try await request(
            path: "/api/recover/verify",
            method: "POST",
            body: ["email": email, "username": username, "code": code]
        )
    }

    func deleteAccount(token: String) async throws {
        let _: PubWallOK = try await request(path: "/api/me", method: "DELETE", token: token)
    }

    private func request<Response: Decodable>(
        path: String,
        method: String = "GET",
        token: String? = nil,
        body: [String: any Encodable]? = nil
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw URLError(.badURL)
        }
        return try await request(
            url: url,
            method: method,
            token: token,
            body: body
        )
    }

    private func request<Response: Decodable>(
        url: URL,
        method: String = "GET",
        token: String? = nil,
        body: [String: any Encodable]? = nil
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body.mapValues(AnyEncodable.init))
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let payload = try? JSONDecoder().decode(PubWallErrorPayload.self, from: data)
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw PubWallAPIError(
                statusCode: http.statusCode,
                message: payload?.error ?? "The Pub Wall returned \(http.statusCode).",
                retryAfter: retryAfter
            )
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

private enum PubWallSession {
    static let secure: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(
            configuration: configuration,
            delegate: RedirectRefusingDelegate(),
            delegateQueue: nil
        )
    }()

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
}

private struct PubWallErrorPayload: Decodable {
    let error: String
}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        encodeValue = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}
