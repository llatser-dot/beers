import SwiftUI

struct PubWallLeaderboardView: View {
    let leaderboard: PubWallLeaderboard
    let currentUsername: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Live leaderboard")
                    .font(Beers.display(20))
                    .foregroundStyle(Beers.ink)
                Spacer()
                Text("\(leaderboard.drinkers) opted in")
                    .font(Beers.ui(11, .bold))
                    .foregroundStyle(Beers.hopsDeep)
            }

            HStack(spacing: 10) {
                summary(value: leaderboard.drinkers, label: "Members")
                summary(value: leaderboard.totalPints, label: "Pints pulled")
                summary(value: leaderboard.totalWords, label: "Words")
            }

            if leaderboard.leaderboard.isEmpty {
                VStack(spacing: 8) {
                    Text("A fresh wall.")
                        .font(Beers.display(18))
                        .foregroundStyle(Beers.ink)
                    Text("No verified members are listed yet. No placeholder people or invented totals are shown.")
                        .font(Beers.ui(12, .medium))
                        .foregroundStyle(Beers.ink.opacity(0.62))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(leaderboard.leaderboard) { entry in
                        row(entry)
                    }
                }
            }
        }
    }

    private func summary(value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number)
                .font(Beers.display(19))
                .foregroundStyle(Beers.ink)
            Text(label.uppercased())
                .font(Beers.ui(9, .bold))
                .tracking(1.1)
                .foregroundStyle(Beers.stout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Beers.paper, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Beers.ink, lineWidth: 2))
    }

    private func row(_ entry: PubWallEntry) -> some View {
        let isCurrent = currentUsername?.caseInsensitiveCompare(entry.username) == .orderedSame
        return HStack(spacing: 14) {
            Text("#\(entry.rank)")
                .font(Beers.display(16))
                .foregroundStyle(Beers.stout)
                .frame(width: 38, alignment: .leading)
            Text("@\(entry.username)")
                .font(Beers.ui(14, .bold))
                .foregroundStyle(Beers.ink)
            if isCurrent {
                Text("YOU")
                    .font(Beers.ui(9, .bold))
                    .tracking(1.2)
                    .foregroundStyle(Beers.cream)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Beers.stout, in: Capsule())
            }
            Spacer()
            Text("\(entry.pints) pints")
                .font(Beers.ui(13, .bold))
                .foregroundStyle(Beers.stout)
            Text(entry.words, format: .number)
                .font(Beers.ui(11, .semibold))
                .foregroundStyle(Beers.ink.opacity(0.55))
            Text("words")
                .font(Beers.ui(10, .medium))
                .foregroundStyle(Beers.ink.opacity(0.55))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(isCurrent ? Beers.lager.opacity(0.38) : Beers.paper, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isCurrent ? Beers.amber : Beers.ink, lineWidth: 2))
    }
}
