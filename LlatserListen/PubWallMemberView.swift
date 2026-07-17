import SwiftUI

struct PubWallMemberView: View {
    let profile: PubWallProfile
    let leaderboard: PubWallLeaderboard
    let onLeave: () -> Void

    private var rank: Int? {
        leaderboard.leaderboard.first { $0.username.caseInsensitiveCompare(profile.username) == .orderedSame }?.rank
    }

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("@\(profile.username)")
                    .font(Beers.display(24))
                    .foregroundStyle(Beers.ink)
                Text(rank.map { "#\($0) on the wall" } ?? "On the wall")
                    .font(Beers.ui(12, .bold))
                    .foregroundStyle(Beers.stout)
            }
            Spacer()
            memberStat(value: profile.pints, label: "Pints")
            memberStat(value: profile.words, label: "Words")
            memberStat(value: profile.streakDays, label: "Day streak")
            Button("Leave", role: .destructive, action: onLeave)
                .buttonStyle(.plain)
                .font(Beers.ui(11, .bold))
                .foregroundStyle(Beers.amber)
        }
        .padding(18)
        .background(Beers.lager, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Beers.ink, lineWidth: 2.5))
    }

    private func memberStat(value: Int, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value, format: .number)
                .font(Beers.display(20))
                .foregroundStyle(Beers.ink)
            Text(label.uppercased())
                .font(Beers.ui(9, .bold))
                .tracking(1.1)
                .foregroundStyle(Beers.stout)
        }
    }
}
