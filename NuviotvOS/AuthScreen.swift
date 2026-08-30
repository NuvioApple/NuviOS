#if os(iOS)
import SwiftUI

/// Palette lifted from NuvioMobile's AuthScreen.kt so the iOS build reads as
/// the same product.
enum AuthPalette {
    static let textPrimary = Color(red: 0xF5 / 255, green: 0xF7 / 255, blue: 0xF8 / 255)
    static let textSecondary = Color(red: 0x96 / 255, green: 0x9C / 255, blue: 0xA3 / 255)
    static let textMuted = Color(red: 0x6E / 255, green: 0x71 / 255, blue: 0x78 / 255)
    static let primaryButtonBackground = Color(white: 0xF5 / 255)
    static let primaryButtonText = Color(white: 0x11 / 255)
    static let fieldBackground = Color.white.opacity(0.035)
    static let fieldBorder = Color.white.opacity(0.08)
    static let divider = Color.white.opacity(0.10)
    static let secondaryButtonBackground = Color.white.opacity(0.05)
    static let secondaryButtonBorder = Color.white.opacity(0.09)
}

/// The mobile sign-in screen, ported from NuvioMobile's `AuthMobileLayout`:
/// brand lockup, heading, email + password, primary action, mode toggle,
/// divider, link sign-in, and continue-without-account.
struct AuthScreen: View {
    @EnvironmentObject private var session: AppSession

    @State private var isSignUp = false
    @State private var email = ""
    @State private var password = ""
    @State private var passwordVisible = false
    @State private var showingServer = false

    @FocusState private var focused: Field?
    private enum Field { case email, password }

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty
            && password.count >= 6
            && !session.isSubmitting
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                brandLockup
                    .padding(.bottom, 64)

                heading
                    .padding(.bottom, 28)

                form
            }
            .frame(maxWidth: 342)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 30)
            .padding(.top, 48)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(AuthPalette.textPrimary)
        .onTapGesture { focused = nil }
        .onDisappear { session.cancelDeviceLink() }
        .fullScreenCover(isPresented: $showingServer) { ServerView() }
    }

    // MARK: Pieces

    private var brandLockup: some View {
        VStack(spacing: 10) {
            Text("Nuvio")
                .font(.system(size: 38, weight: .bold, design: .rounded))
            Text("Watch your library, anywhere")
                .font(.system(size: 14))
                .foregroundStyle(AuthPalette.textSecondary)
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isSignUp ? "Create Account" : "Welcome Back")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(AuthPalette.textPrimary)
            Text(
                isSignUp
                    ? "Sign up to sync your data across devices"
                    : "Sign in to access your library and progress"
            )
            .font(.system(size: 15))
            .foregroundStyle(AuthPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: isSignUp)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            AuthTextField(
                text: $email,
                placeholder: "Email",
                systemImage: "envelope"
            )
            .focused($focused, equals: .email)
            .textContentType(.emailAddress)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.next)
            .onSubmit { focused = .password }

            Spacer().frame(height: 14)

            AuthTextField(
                text: $password,
                placeholder: "Password",
                systemImage: "lock",
                isSecure: !passwordVisible,
                trailing: {
                    Button {
                        passwordVisible.toggle()
                    } label: {
                        Image(systemName: passwordVisible ? "eye.slash" : "eye")
                            .font(.system(size: 20))
                            .foregroundStyle(AuthPalette.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            )
            .focused($focused, equals: .password)
            .textContentType(isSignUp ? .newPassword : .password)
            .submitLabel(.done)
            .onSubmit(submit)

            if let error = session.authError {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            if isSignUp {
                termsAcknowledgement
                    .padding(.top, 14)
            }

            AuthPrimaryButton(
                title: isSignUp ? "Create Account" : "Sign In",
                isLoading: session.isSubmitting,
                enabled: canSubmit,
                action: submit
            )
            .padding(.top, 22)

            modeToggle
                .padding(.top, 18)

            divider
                .padding(.top, 28)

            if !isSignUp, session.canSignIn {
                DeviceLinkSection(
                    state: session.deviceLink,
                    enabled: !session.isSubmitting,
                    onStart: {
                        focused = nil
                        session.startDeviceLink(deviceName: Self.deviceName)
                    },
                    onCancel: { session.cancelDeviceLink() }
                )
                .padding(.top, 24)
                .padding(.bottom, 14)
            }

            AuthSecondaryButton(
                title: "Continue Without Account",
                enabled: !session.isSubmitting
            ) {
                session.continueAsGuest()
            }
            .padding(.top, isSignUp || !session.canSignIn ? 24 : 0)

            Text("Your data will only be stored locally")
                .font(.system(size: 13))
                .foregroundStyle(AuthPalette.textMuted)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 14)

            Button("Server") { showingServer = true }
                .font(.system(size: 13))
                .foregroundStyle(AuthPalette.textMuted)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 18)
        }
    }

    private var termsAcknowledgement: some View {
        HStack(spacing: 4) {
            Text("By signing up, I agree to the")
                .foregroundStyle(AuthPalette.textSecondary)
            Link("Terms", destination: URL(string: "https://nuvio.tv/terms")!)
                .foregroundStyle(AuthPalette.textPrimary)
        }
        .font(.system(size: 13))
    }

    private var modeToggle: some View {
        HStack(spacing: 0) {
            Text(isSignUp ? "Already have an account? " : "Don't have an account? ")
                .foregroundStyle(AuthPalette.textSecondary)
            Button(isSignUp ? "Sign In" : "Sign Up") {
                session.cancelDeviceLink()
                session.clearAuthError()
                isSignUp.toggle()
            }
            .foregroundStyle(AuthPalette.textPrimary)
            .fontWeight(.semibold)
        }
        .font(.system(size: 14))
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var divider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(AuthPalette.divider).frame(height: 1)
            Text("or")
                .font(.system(size: 13))
                .foregroundStyle(AuthPalette.textMuted)
            Rectangle().fill(AuthPalette.divider).frame(height: 1)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        focused = nil
        session.cancelDeviceLink()
        Task { await session.submit(email: email, password: password, isSignUp: isSignUp) }
    }

    private static var deviceName: String { UIDevice.current.name }
}

// MARK: - Controls

struct AuthTextField<Trailing: View>: View {
    @Binding var text: String
    let placeholder: String
    let systemImage: String
    var isSecure: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 19))
                .foregroundStyle(AuthPalette.textSecondary)
                .frame(width: 22)

            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(.system(size: 16))
            .foregroundStyle(AuthPalette.textPrimary)

            trailing()
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(AuthPalette.fieldBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(AuthPalette.fieldBorder, lineWidth: 1)
        )
    }
}

extension AuthTextField where Trailing == EmptyView {
    init(text: Binding<String>, placeholder: String, systemImage: String, isSecure: Bool = false) {
        self.init(
            text: text,
            placeholder: placeholder,
            systemImage: systemImage,
            isSecure: isSecure,
            trailing: { EmptyView() }
        )
    }
}

struct AuthPrimaryButton: View {
    let title: String
    var isLoading = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                        .tint(AuthPalette.primaryButtonText)
                } else {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                AuthPalette.primaryButtonBackground.opacity(enabled || isLoading ? 1 : 0.45),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .foregroundStyle(
                AuthPalette.primaryButtonText.opacity(enabled || isLoading ? 1 : 0.55)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled || isLoading)
    }
}

struct AuthSecondaryButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    AuthPalette.secondaryButtonBackground,
                    in: RoundedRectangle(cornerRadius: 16)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(AuthPalette.secondaryButtonBorder, lineWidth: 1)
                )
                .foregroundStyle(AuthPalette.textPrimary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Ported from NuvioMobile's DeviceLinkAuthSection: a single button that turns
/// into the code plus an "Open nuvio.tv/link" action while waiting.
struct DeviceLinkSection: View {
    let state: DeviceLinkState
    let enabled: Bool
    let onStart: () -> Void
    let onCancel: () -> Void

    var body: some View {
        switch state {
        case .idle:
            AuthSecondaryButton(title: "Sign In with Link", enabled: enabled, action: onStart)

        case .starting:
            waitingBox {
                HStack(spacing: 10) {
                    ProgressView().tint(AuthPalette.textSecondary)
                    Text("Creating code…")
                        .font(.system(size: 14))
                        .foregroundStyle(AuthPalette.textSecondary)
                }
            }

        case .waiting(let code, let verificationURL, let isCompleting):
            waitingBox {
                VStack(spacing: 12) {
                    Text(code)
                        .font(.system(size: 30, weight: .bold, design: .monospaced))
                        .tracking(4)
                        .foregroundStyle(AuthPalette.textPrimary)

                    Text(isCompleting ? "Signing in…" : "Waiting for approval…")
                        .font(.system(size: 13))
                        .foregroundStyle(AuthPalette.textSecondary)

                    if let url = URL(string: verificationURL), !isCompleting {
                        Link("Open nuvio.tv/link", destination: url)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AuthPalette.textPrimary)
                    }

                    Button("Cancel", action: onCancel)
                        .font(.system(size: 13))
                        .foregroundStyle(AuthPalette.textMuted)
                }
            }

        case .failed(let message):
            waitingBox {
                VStack(spacing: 10) {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    Button("Try Again", action: onStart)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AuthPalette.textPrimary)
                }
            }
        }
    }

    private func waitingBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                AuthPalette.secondaryButtonBackground,
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(AuthPalette.secondaryButtonBorder, lineWidth: 1)
            )
    }
}

#endif
