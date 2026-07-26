import Foundation

@MainActor
final class PubWallController: ObservableObject {
    @Published private(set) var profile: PubWallProfile?
    @Published private(set) var leaderboard = PubWallLeaderboard(
        leaderboard: [], totalPints: 0, totalWords: 0, drinkers: 0
    )
    @Published private(set) var isLoading = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var statusMessage: String?
    @Published var errorMessage: String?

    private enum DefaultsKey {
        static let pendingWords = "pubWall.pendingWords"
        static let pendingPours = "pubWall.pendingPours"
        static let pendingUserID = "pubWall.pendingUserID"
        static let backfilledUserID = "pubWall.backfilledUserID"
    }

    private enum SyncLimit {
        static let wordsPerBatch = 25_000
        static let poursPerBatch = 400
        static let backfillWords = 250_000
        static let backfillPours = 1_000
    }

    private let api: PubWallAPI
    private var token: String?
    private var isFlushing = false
    private var retryTask: Task<Void, Never>?
    private var initialWords = 0
    private var initialPours = 0

    init(api: PubWallAPI = .live) {
        self.api = api
        token = PubWallKeychain.token()
    }

    var hasCredential: Bool { token != nil }
    var isJoined: Bool { profile?.emailVerified == true }
    var needsVerification: Bool { profile != nil && profile?.emailVerified == false }

    func configureInitialHistory(words: Int, pours: Int) {
        initialWords = max(0, words)
        initialPours = max(0, pours)
    }

    func start() {
        Task { await refresh() }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        await refreshLeaderboard()
        guard let token else {
            profile = nil
            return
        }
        do {
            profile = try await api.profile(token: token)
            if isJoined {
                prepareQueue(for: profile!.userId)
                await backfillIfNeeded()
                await flushPending()
            }
        } catch let error as PubWallAPIError where error.statusCode == 401 {
            clearLocalAccount()
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    func checkUsername(_ username: String) async -> Bool? {
        do {
            return try await api.usernameAvailable(username)
        } catch let error as PubWallAPIError where error.statusCode == 400 {
            return false
        } catch {
            return nil
        }
    }

    func join(email: String, username: String) async -> Bool {
        isSubmitting = true
        errorMessage = nil
        statusMessage = nil
        defer { isSubmitting = false }

        do {
            let registration = try await api.register(username: username)
            try PubWallKeychain.save(token: registration.deviceToken)
            token = registration.deviceToken
            profile = try await api.profile(token: registration.deviceToken)
            try await api.sendClaim(email: email, token: registration.deviceToken)
            statusMessage = "We sent a six-digit code to \(email)."
            return true
        } catch {
            errorMessage = userMessage(for: error)
            return false
        }
    }

    func resendVerification(to email: String) async -> Bool {
        guard let token else { return false }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            try await api.sendClaim(email: email, token: token)
            statusMessage = "A fresh code is on its way to \(email)."
            return true
        } catch {
            errorMessage = userMessage(for: error)
            return false
        }
    }

    func verify(code: String, existingWords: Int, existingPours: Int) async -> Bool {
        guard let token else { return false }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            try await api.verifyClaim(code: code, token: token)
            let verified = try await api.profile(token: token)
            profile = verified
            prepareQueue(for: verified.userId)
            configureInitialHistory(words: existingWords, pours: existingPours)
            statusMessage = "@\(verified.username) is on the Pub Wall."
            await backfillIfNeeded()
            await flushPending()
            await refreshLeaderboard()
            return true
        } catch {
            errorMessage = userMessage(for: error)
            return false
        }
    }

    func record(words: Int, pours: Int = 1) {
        guard token != nil, words >= 0, pours > 0 else { return }
        let defaults = UserDefaults.standard
        let userID: Int64
        if let profile, profile.emailVerified {
            userID = profile.userId
        } else {
            // A previously verified account keeps its queue owner in defaults.
            // This lets pours survive an offline launch before /api/me returns.
            userID = Int64(defaults.integer(forKey: DefaultsKey.pendingUserID))
            guard userID > 0 else { return }
        }
        prepareQueue(for: userID)
        defaults.set(defaults.integer(forKey: DefaultsKey.pendingWords) + words, forKey: DefaultsKey.pendingWords)
        defaults.set(defaults.integer(forKey: DefaultsKey.pendingPours) + pours, forKey: DefaultsKey.pendingPours)
        Task { await flushPending() }
    }

    func beginRecovery(email: String, username: String) async -> Bool {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            try await api.beginRecovery(email: email, username: username)
            statusMessage = "If those details match, a six-digit code is on its way."
            return true
        } catch {
            errorMessage = userMessage(for: error)
            return false
        }
    }

    func finishRecovery(email: String, username: String, code: String) async -> Bool {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let recovered = try await api.verifyRecovery(email: email, username: username, code: code)
            try PubWallKeychain.save(token: recovered.deviceToken)
            token = recovered.deviceToken
            profile = try await api.profile(token: recovered.deviceToken)
            if let profile { prepareQueue(for: profile.userId) }
            statusMessage = "Welcome back, @\(profile?.username ?? username)."
            await refreshLeaderboard()
            return true
        } catch {
            errorMessage = userMessage(for: error)
            return false
        }
    }

    func leave() async -> Bool {
        guard let token else { return true }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            try await api.deleteAccount(token: token)
            clearLocalAccount()
            statusMessage = "You’ve left the Pub Wall and your server record was deleted."
            await refreshLeaderboard()
            return true
        } catch {
            errorMessage = userMessage(for: error)
            return false
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    private func refreshLeaderboard() async {
        do {
            leaderboard = try await api.leaderboard()
        } catch {
            if profile != nil { errorMessage = userMessage(for: error) }
        }
    }

    private func backfillIfNeeded() async {
        guard let token, let profile, profile.emailVerified else { return }
        let defaults = UserDefaults.standard
        guard Int64(defaults.integer(forKey: DefaultsKey.backfilledUserID)) != profile.userId else { return }

        if profile.words > 0 || profile.pours > 0 {
            defaults.set(profile.userId, forKey: DefaultsKey.backfilledUserID)
            return
        }
        guard initialPours > 0 else {
            defaults.set(profile.userId, forKey: DefaultsKey.backfilledUserID)
            return
        }
        let backfillWords = min(initialWords, SyncLimit.backfillWords)
        let backfillPours = min(initialPours, SyncLimit.backfillPours)
        do {
            _ = try await api.backfill(words: backfillWords, pours: backfillPours, token: token)
            defaults.set(profile.userId, forKey: DefaultsKey.backfilledUserID)
            self.profile = try await api.profile(token: token)
            if initialWords > backfillWords || initialPours > backfillPours {
                statusMessage = "Your retained history was imported up to the Pub Wall safety limit. New pours will keep syncing normally."
            }
        } catch let error as PubWallAPIError where error.statusCode == 409 {
            defaults.set(profile.userId, forKey: DefaultsKey.backfilledUserID)
            self.profile = try? await api.profile(token: token)
        } catch {
            errorMessage = "You joined, but your existing totals have not synced yet. We’ll retry automatically."
            scheduleRefresh(after: 60)
        }
    }

    private func prepareQueue(for userID: Int64) {
        let defaults = UserDefaults.standard
        if Int64(defaults.integer(forKey: DefaultsKey.pendingUserID)) != userID {
            defaults.set(userID, forKey: DefaultsKey.pendingUserID)
            defaults.set(0, forKey: DefaultsKey.pendingWords)
            defaults.set(0, forKey: DefaultsKey.pendingPours)
        }
    }

    private func flushPending() async {
        guard !isFlushing, let token, let profile, profile.emailVerified else { return }
        let defaults = UserDefaults.standard
        if Int64(defaults.integer(forKey: DefaultsKey.backfilledUserID)) != profile.userId {
            await backfillIfNeeded()
            guard Int64(defaults.integer(forKey: DefaultsKey.backfilledUserID)) == profile.userId else { return }
        }
        prepareQueue(for: profile.userId)
        let queuedWords = defaults.integer(forKey: DefaultsKey.pendingWords)
        let queuedPours = defaults.integer(forKey: DefaultsKey.pendingPours)
        guard queuedPours > 0 else { return }

        // Keep long-offline queues inside the server's per-batch bounds while
        // preserving roughly the same words-per-pour ratio across each chunk.
        let poursAllowedByWords: Int
        if queuedWords > SyncLimit.wordsPerBatch {
            poursAllowedByWords = max(
                1,
                Int(
                    (Int64(SyncLimit.wordsPerBatch) * Int64(queuedPours))
                        / Int64(queuedWords)
                )
            )
        } else {
            poursAllowedByWords = queuedPours
        }
        let pours = min(queuedPours, min(SyncLimit.poursPerBatch, poursAllowedByWords))
        let proportionalWords = queuedPours > 0
            ? Int((Int64(queuedWords) * Int64(pours)) / Int64(queuedPours))
            : 0
        let words = min(
            queuedWords,
            min(SyncLimit.wordsPerBatch, max(queuedWords > 0 ? 1 : 0, proportionalWords))
        )

        isFlushing = true
        defer { isFlushing = false }
        do {
            _ = try await api.sendPours(words: words, pours: pours, token: token)
            defaults.set(max(0, defaults.integer(forKey: DefaultsKey.pendingWords) - words), forKey: DefaultsKey.pendingWords)
            defaults.set(max(0, defaults.integer(forKey: DefaultsKey.pendingPours) - pours), forKey: DefaultsKey.pendingPours)
            self.profile = try await api.profile(token: token)
            await refreshLeaderboard()
            if defaults.integer(forKey: DefaultsKey.pendingPours) > 0 {
                scheduleRetry(after: 60)
            }
        } catch let error as PubWallAPIError where error.statusCode == 429 {
            scheduleRetry(after: error.retryAfter ?? 60)
        } catch {
            scheduleRetry(after: 60)
        }
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, delay)))
            guard !Task.isCancelled else { return }
            await self?.flushPending()
        }
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, delay)))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func clearLocalAccount() {
        retryTask?.cancel()
        retryTask = nil
        PubWallKeychain.deleteToken()
        token = nil
        profile = nil
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: DefaultsKey.pendingWords)
        defaults.removeObject(forKey: DefaultsKey.pendingPours)
        defaults.removeObject(forKey: DefaultsKey.pendingUserID)
        defaults.removeObject(forKey: DefaultsKey.backfilledUserID)
    }

    private func userMessage(for error: Error) -> String {
        if let apiError = error as? PubWallAPIError {
            switch apiError.statusCode {
            case 409: return "That @handle has already been claimed."
            case 429: return "The Pub Wall is busy. Give it a minute and try again."
            case 501: return "Email verification is temporarily unavailable."
            default: return apiError.message
            }
        }
        if error is URLError { return "The Pub Wall could not be reached. Check your connection and try again." }
        return error.localizedDescription
    }
}
