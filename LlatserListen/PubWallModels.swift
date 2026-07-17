import Foundation

struct PubWallEntry: Decodable, Identifiable, Equatable {
    let rank: Int
    let username: String
    let words: Int
    let pints: Int
    let streakDays: Int

    var id: String { username.lowercased() }
}

struct PubWallLeaderboard: Decodable, Equatable {
    let leaderboard: [PubWallEntry]
    let totalPints: Int
    let totalWords: Int
    let drinkers: Int
}

struct PubWallProfile: Decodable, Equatable {
    let userId: Int64
    let username: String
    let words: Int
    let pours: Int
    let pints: Int
    let streakDays: Int
    let lastPourDate: String?
    let emailVerified: Bool
    let createdAt: Int64
}

struct PubWallRegistration: Decodable {
    let userId: Int64
    let deviceToken: String
}

struct PubWallRecovery: Decodable {
    let ok: Bool
    let deviceToken: String
}

struct PubWallAvailability: Decodable {
    let available: Bool
}

struct PubWallOK: Decodable {
    let ok: Bool
}

struct PubWallPoursResult: Decodable {
    let ok: Bool
    let words: Int
    let pours: Int
    let pints: Int
    let streakDays: Int
}
