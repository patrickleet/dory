import SwiftUI
import AppKit

/// Guided first-run setup shown when the engine can't start because Apple's container
/// toolchain isn't installed. Offers a one-click Homebrew install when brew is present,
/// or the copyable command / installer download plus a re-check for manual installs.
struct EngineSetupCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            Text("One-time setup").font(.system(size: 19, weight: .heavy)).foregroundStyle(p.text)
                .padding(.bottom, 6)
            Text("Dory runs containers with Apple's open-source container engine, which isn't on this Mac yet. Install it once — Dory handles everything after that.")
                .font(.system(size: 13)).foregroundStyle(p.text2)
                .multilineTextAlignment(.center).lineSpacing(3)
                .frame(maxWidth: 400)
                .padding(.bottom, 18)

            commandRow(AppStore.toolchainInstallCommand)
                .frame(maxWidth: 400)
                .padding(.bottom, 16)

            if case .failed(let message) = store.toolchainInstallPhase {
                Text(message)
                    .font(.system(size: 12)).foregroundStyle(p.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                    .padding(.bottom, 12)
            }

            if store.canAutoInstallToolchain {
                primaryButton(primaryLabel, busy: store.toolchainInstallPhase.isBusy, id: "engine-setup-install") {
                    Task { await store.installContainerToolchain() }
                }
            } else {
                primaryButton("Download the installer ↗", busy: false, id: "engine-setup-download") {
                    guard let url = URL(string: AppStore.toolchainReleasesURL) else { return }
                    NSWorkspace.shared.open(url)
                }
            }

            Button {
                Task { await store.recheckToolchain() }
            } label: {
                Text("I installed it myself — check again")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(p.text3)
            }
            .buttonStyle(.plain)
            .disabled(store.toolchainInstallPhase.isBusy)
            .accessibilityIdentifier("engine-setup-recheck")
            .padding(.top, 10)
        }
    }

    private var primaryLabel: String {
        switch store.toolchainInstallPhase {
        case .installing: "Installing toolchain… (about a minute)"
        case .startingEngine: "Starting the engine…"
        case .idle, .failed: "Install & start engine"
        }
    }

    private func primaryButton(_ title: String, busy: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small).tint(.white) }
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            }
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(p.accent, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityIdentifier(id)
    }

    private func commandRow(_ command: String) -> some View {
        HStack(spacing: 10) {
            Text(command).font(.mono(12.5, weight: .regular)).foregroundStyle(p.monoText)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                if copied {
                    Text("Copied").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.green)
                } else {
                    Glyph(glyph: .plus, size: 13, color: p.text3)
                }
            }
            .buttonStyle(.plain).help("Copy")
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(p.monoBg, in: RoundedRectangle(cornerRadius: 9))
    }
}
