import SwiftUI

struct PubWallView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingLeaveConfirmation = false

    private var controller: PubWallController { appState.pubWall }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                privacyBoundary

                if controller.isLoading && controller.profile == nil && controller.leaderboard.leaderboard.isEmpty {
                    ProgressView("Checking the Pub Wall…")
                        .font(Beers.ui(13, .semibold))
                        .tint(Beers.amber)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                } else if controller.isJoined, let profile = controller.profile {
                    PubWallMemberView(
                        profile: profile,
                        leaderboard: controller.leaderboard,
                        onLeave: { showingLeaveConfirmation = true }
                    )
                    PubWallLeaderboardView(
                        leaderboard: controller.leaderboard,
                        currentUsername: profile.username
                    )
                } else {
                    PubWallJoinView(
                        controller: controller,
                        existingWords: appState.pourStore.totalWords,
                        existingPours: appState.pourStore.totalPours
                    )
                    PubWallLeaderboardView(
                        leaderboard: controller.leaderboard,
                        currentUsername: nil
                    )
                }
            }
            .padding(28)
        }
        .background(Beers.cream)
        .task { await controller.refresh() }
        .alert(
            "Pub Wall",
            isPresented: Binding(
                get: { controller.errorMessage != nil },
                set: { if !$0 { controller.dismissError() } }
            )
        ) {
            Button("OK", role: .cancel, action: controller.dismissError)
        } message: {
            Text(controller.errorMessage ?? "Something went wrong.")
        }
        .confirmationDialog(
            "Leave the Pub Wall?",
            isPresented: $showingLeaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Leave and delete my Pub Wall account", role: .destructive) {
                Task { _ = await controller.leave() }
            }
            Button("Stay", role: .cancel) {}
        } message: {
            Text("Your public handle, aggregate counts and private email will be deleted from the server. Your local pours stay on this Mac.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("THE PUB WALL")
                    .font(Beers.ui(11, .bold))
                    .tracking(2.4)
                    .foregroundStyle(Beers.stout)
                Text("Pull pints. Climb the wall.")
                    .font(Beers.display(28))
                    .foregroundStyle(Beers.ink)
                Text("Every 1,000 dictated words pulls one pint.")
                    .font(Beers.ui(13, .medium))
                    .foregroundStyle(Beers.stout)
            }
            Spacer()
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await controller.refresh() }
            }
            .buttonStyle(.plain)
            .font(Beers.ui(12, .bold))
            .foregroundStyle(Beers.stout)
            .disabled(controller.isLoading)
        }
    }

    private var privacyBoundary: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Beers.hopsDeep)
            VStack(alignment: .leading, spacing: 4) {
                Text("Counts cross the bar. Your words never do.")
                    .font(Beers.ui(13, .bold))
                    .foregroundStyle(Beers.ink)
                Text("Public: your @handle, word and pour totals, pints and streak. Private: your verified email and a hashed device credential. Beers never sends transcripts or audio to the Pub Wall.")
                    .font(Beers.ui(12, .medium))
                    .foregroundStyle(Beers.ink.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Beers.paper, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Beers.hopsDeep, lineWidth: 2))
    }
}
