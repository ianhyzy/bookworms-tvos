import SwiftUI

/// Connects a Hardcover account with Hardcover's device-code sign-in: a QR code, or the code
/// entered at hardcover.app/link. The completion callback runs after the account and library
/// finish connecting.
struct HardcoverConnectionView: View {
    @Bindable var library: LibraryModel
    let onConnected: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var didComplete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isConnecting {
                connectionProgress
                    .transition(.opacity)
            } else {
                signInCard
                    .transition(.opacity)
            }
        }
        .disabled(library.isGenerating)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: isConnecting)
        .onAppear {
            isVisible = true
            completeIfReady()
            startDeviceAuthIfNeeded()
        }
        .onChange(of: needsHardcoverLink) {
            startDeviceAuthIfNeeded()
        }
        .onChange(of: library.hardcoverConnected) {
            completeIfReady()
        }
        .onChange(of: library.isLoading) {
            completeIfReady()
            if library.hardcoverDeviceAuthMessage == nil, library.message == nil {
                startDeviceAuthIfNeeded()
            }
        }
        .onDisappear {
            isVisible = false
            library.cancelHardcoverDeviceAuth()
        }
    }

    private var needsHardcoverLink: Bool {
        !library.hardcoverConnected || library.hardcoverSessionExpired
    }

    private var isConnecting: Bool {
        library.hardcoverConnectionPhase != nil || library.isLoading
    }

    private var connectionProgress: some View {
        VStack(spacing: 28) {
            ProgressView().controlSize(.large)
            VStack(spacing: 14) {
                Text(library.hardcoverConnectionPhase?.title ?? "Connecting to Hardcover")
                    .appFont(size: 46, weight: .semibold)
                    .contentTransition(.opacity)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.18),
                        value: library.hardcoverConnectionPhase)
                Text(library.hardcoverConnectionPhase?.detail ?? "Checking your sign-in…")
                    .appFont(size: 26)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 56)
        .frame(maxWidth: .infinity, minHeight: 380)
        .background(.primary.opacity(0.06), in: .rect(cornerRadius: 28))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("hardcover-connection-progress")
    }

    private var signInCard: some View {
        HStack(alignment: .center, spacing: 70) {
            VStack(alignment: .leading, spacing: 22) {
                Text("Sign in to Hardcover").appFont(size: 46, weight: .semibold)
                if library.hardcoverSessionExpired {
                    Text("Hardcover rejected the saved login. Sign in again to resume syncing.")
                        .appFont(size: 26).foregroundStyle(.orange)
                }
                Text("Scan the code with your phone, or go to **hardcover.app/link** and enter:")
                    .appFont(size: 26).foregroundStyle(.secondary)
                    .accessibilityIdentifier("hardcover-instructions")
                linkCode
                if library.hardcoverDeviceAuth != nil {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text(library.hardcoverDeviceAuthMessage ?? "Waiting for approval…")
                            .appFont(size: 26).foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("hardcover-device-status")
                    Button("New code") { library.startHardcoverDeviceAuth() }
                        .appFont(size: 24)
                        .performanceGlassButton()
                        .accessibilityIdentifier("hardcover-new-code")
                        .padding(.top, 8)
                        .focusSection()
                }
                if let message = library.message {
                    Text(message).appFont(size: 26).foregroundStyle(.orange)
                        .accessibilityIdentifier("hardcover-connection-error")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if let url = completeLink {
                    QRCodeView(url: url)
                } else {
                    Image("HardcoverTokenQR")
                        .interpolation(.none)
                        .resizable()
                        .accessibilityLabel("QR code that opens hardcover.app/link")
                }
            }
            .frame(width: 320, height: 320)
            .padding(18)
            .background(.white, in: .rect(cornerRadius: 24))
            .accessibilityIdentifier("hardcover-token-qr")
        }
    }

    /// The link that opens Hardcover's approval page with the code filled in, when Hardcover
    /// provides one. Without it, the bundled code opens hardcover.app/link.
    private var completeLink: URL? {
        guard let url = library.hardcoverDeviceAuth?.verificationURIComplete,
            url.scheme == "https", url.host() == "hardcover.app"
        else { return nil }
        return url
    }

    /// Shows the device code, its request spinner, or a retry after a failed request.
    @ViewBuilder private var linkCode: some View {
        if let auth = library.hardcoverDeviceAuth {
            Text(auth.userCode)
                .appFont(size: 64, weight: .bold)
                .fontDesign(.monospaced)
                .tracking(4)
                .padding(.horizontal, 36).padding(.vertical, 16)
                .background(.primary.opacity(0.1), in: .rect(cornerRadius: 18))
                .accessibilityIdentifier("hardcover-device-code")
        } else if library.hardcoverDeviceAuthLoading {
            HStack(spacing: 16) {
                ProgressView()
                Text("Requesting code…").appFont(size: 26).foregroundStyle(.secondary)
            }
            .padding(.vertical, 16)
        } else {
            HStack(spacing: 24) {
                Button("Get link code") { library.startHardcoverDeviceAuth() }
                    .appFont(size: 26)
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("hardcover-device-retry")
                if let failure = library.hardcoverDeviceAuthMessage {
                    Text(failure).appFont(size: 26).foregroundStyle(.orange)
                }
            }
            .focusSection()
        }
    }

    private func startDeviceAuthIfNeeded() {
        guard isVisible, !didComplete, needsHardcoverLink, !library.isLoading,
            library.hardcoverConnectionPhase == nil, library.hardcoverDeviceAuth == nil,
            !library.hardcoverDeviceAuthLoading
        else { return }
        library.startHardcoverDeviceAuth()
    }

    private func completeIfReady() {
        // Saving a login precedes installing its library, so wait for the complete operation.
        guard isVisible, !didComplete, library.hardcoverConnected,
            !library.hardcoverSessionExpired, !isConnecting
        else { return }
        didComplete = true
        onConnected()
    }
}
