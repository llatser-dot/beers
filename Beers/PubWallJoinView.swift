import SwiftUI

struct PubWallJoinView: View {
    @ObservedObject var controller: PubWallController
    let existingWords: Int
    let existingPours: Int

    @State private var email = ""
    @State private var username = ""
    @State private var code = ""
    @State private var consent = false
    @State private var usernameAvailable: Bool?
    @State private var isCheckingUsername = false
    @State private var recoveryMode = false
    @State private var recoveryCodeSent = false
    @State private var availabilityTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if controller.needsVerification {
                verificationForm
            } else if recoveryMode {
                recoveryForm
            } else {
                joinForm
            }

            if let status = controller.statusMessage {
                Label(status, systemImage: "checkmark.seal.fill")
                    .font(Beers.ui(12, .semibold))
                    .foregroundStyle(Beers.hopsDeep)
            }
        }
        .padding(20)
        .background(Beers.paper, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Beers.ink, lineWidth: 2.5))
        .shadow(color: Beers.ink.opacity(0.14), radius: 0, x: 4, y: 4)
        .onDisappear { availabilityTask?.cancel() }
    }

    private var joinForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Join the wall")
                .font(Beers.display(20))
                .foregroundStyle(Beers.ink)
            Text("Your email stays private and lets you recover your handle. Your unique @handle and aggregate totals are public.")
                .font(Beers.ui(12, .medium))
                .foregroundStyle(Beers.ink.opacity(0.68))

            fieldLabel("Private email")
            TextField("you@example.com", text: $email)
                .textContentType(.emailAddress)
                .textFieldStyle(.plain)
                .pubWallField()

            fieldLabel("Public handle")
            HStack(spacing: 5) {
                Text("@")
                    .font(Beers.ui(14, .bold))
                    .foregroundStyle(Beers.stout)
                TextField("your_handle", text: $username)
                    .textContentType(.username)
                    .textFieldStyle(.plain)
                    .onChange(of: username, checkAvailability)
            }
            .pubWallField()

            usernameStatus

            Toggle(isOn: $consent) {
                Text("List my @handle and aggregate counts on the public Pub Wall.")
                    .font(Beers.ui(12, .semibold))
                    .foregroundStyle(Beers.ink)
            }
            .toggleStyle(BeersToggleStyle())

            Button(action: join) {
                HStack {
                    if controller.isSubmitting { ProgressView().controlSize(.small) }
                    Text("Email my verification code")
                    Spacer()
                    Text("→")
                }
                .font(Beers.ui(13, .bold))
                .foregroundStyle(Beers.cream)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background(Beers.stout, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(!canJoin || controller.isSubmitting)
            .opacity(canJoin ? 1 : 0.5)

            Button("Already joined? Recover your @handle") {
                recoveryMode = true
            }
            .buttonStyle(.plain)
            .font(Beers.ui(12, .bold))
            .foregroundStyle(Beers.stout)
        }
    }

    private var verificationForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Verify @\(controller.profile?.username ?? username)")
                .font(Beers.display(20))
                .foregroundStyle(Beers.ink)
            Text("Enter the six-digit code from your email. Nothing is published and no counts leave this Mac until verification succeeds.")
                .font(Beers.ui(12, .medium))
                .foregroundStyle(Beers.ink.opacity(0.68))

            fieldLabel("Verification code")
            TextField("123456", text: $code)
                .textFieldStyle(.plain)
                .pubWallField()
                .onSubmit(verify)

            Button(action: verify) {
                Text(controller.isSubmitting ? "Checking…" : "Verify and join the Pub Wall")
                    .font(Beers.ui(13, .bold))
                    .foregroundStyle(Beers.cream)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Beers.stout, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(code.count != 6 || controller.isSubmitting)

            fieldLabel("Need another code?")
            HStack(spacing: 8) {
                TextField("you@example.com", text: $email)
                    .textContentType(.emailAddress)
                    .textFieldStyle(.plain)
                    .pubWallField()
                Button("Resend") {
                    Task { _ = await controller.resendVerification(to: cleanedEmail) }
                }
                .buttonStyle(BeersButtonStyle(kind: .stoutGhost, small: true))
                .disabled(!validEmail || controller.isSubmitting)
            }
        }
    }

    private var recoveryForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recover your handle")
                .font(Beers.display(20))
                .foregroundStyle(Beers.ink)
            Text("We’ll email a code only when the private email and public handle match. The response never reveals whether an account exists.")
                .font(Beers.ui(12, .medium))
                .foregroundStyle(Beers.ink.opacity(0.68))

            fieldLabel("Email")
            TextField("you@example.com", text: $email)
                .textContentType(.emailAddress)
                .textFieldStyle(.plain)
                .pubWallField()

            fieldLabel("Handle")
            HStack(spacing: 5) {
                Text("@").font(Beers.ui(14, .bold))
                TextField("your_handle", text: $username)
                    .textFieldStyle(.plain)
            }
            .pubWallField()

            if recoveryCodeSent {
                fieldLabel("Recovery code")
                TextField("123456", text: $code)
                    .textFieldStyle(.plain)
                    .pubWallField()
                Button("Recover @\(cleanedUsername)") {
                    Task {
                        _ = await controller.finishRecovery(
                            email: cleanedEmail,
                            username: cleanedUsername,
                            code: code
                        )
                    }
                }
                .buttonStyle(BeersButtonStyle(kind: .amber, small: true))
                .disabled(code.count != 6 || controller.isSubmitting)
            } else {
                Button("Email recovery code") {
                    Task {
                        if await controller.beginRecovery(email: cleanedEmail, username: cleanedUsername) {
                            recoveryCodeSent = true
                        }
                    }
                }
                .buttonStyle(BeersButtonStyle(kind: .amber, small: true))
                .disabled(!validEmail || !validUsername || controller.isSubmitting)
            }

            Button("Back to joining") {
                recoveryMode = false
                recoveryCodeSent = false
                code = ""
            }
            .buttonStyle(.plain)
            .font(Beers.ui(12, .bold))
            .foregroundStyle(Beers.stout)
        }
    }

    @ViewBuilder
    private var usernameStatus: some View {
        if isCheckingUsername {
            Text("Checking availability…")
                .foregroundStyle(Beers.stout)
        } else if usernameAvailable == true {
            Label("@\(cleanedUsername) is available", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Beers.hopsDeep)
        } else if usernameAvailable == false, validUsername {
            Label("That handle is taken", systemImage: "xmark.circle.fill")
                .foregroundStyle(Beers.amber)
        } else {
            Text("3–20 characters: letters, numbers, dots, dashes or underscores.")
                .foregroundStyle(Beers.ink.opacity(0.55))
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Beers.ui(10, .bold))
            .tracking(1.5)
            .foregroundStyle(Beers.stout)
    }

    private var cleanedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var cleanedUsername: String {
        String(username.trimmingCharacters(in: .whitespacesAndNewlines).trimmingPrefix("@"))
    }

    private var validEmail: Bool {
        let parts = cleanedEmail.split(separator: "@")
        return parts.count == 2 && parts[1].contains(".")
    }

    private var validUsername: Bool {
        cleanedUsername.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9_.\-]{1,18}[A-Za-z0-9]$"#,
            options: .regularExpression
        ) != nil
    }

    private var canJoin: Bool {
        validEmail && validUsername && usernameAvailable == true && consent
    }

    private func checkAvailability() {
        availabilityTask?.cancel()
        usernameAvailable = nil
        guard validUsername else {
            isCheckingUsername = false
            return
        }
        isCheckingUsername = true
        let candidate = cleanedUsername
        availabilityTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let available = await controller.checkUsername(candidate)
            guard !Task.isCancelled, candidate == cleanedUsername else { return }
            usernameAvailable = available
            isCheckingUsername = false
        }
    }

    private func join() {
        Task { _ = await controller.join(email: cleanedEmail, username: cleanedUsername) }
    }

    private func verify() {
        guard code.count == 6 else { return }
        Task {
            _ = await controller.verify(
                code: code,
                existingWords: existingWords,
                existingPours: existingPours
            )
        }
    }
}

private extension View {
    func pubWallField() -> some View {
        font(Beers.ui(13, .semibold))
            .foregroundStyle(Beers.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Beers.cream, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Beers.ink, lineWidth: 2))
    }
}
