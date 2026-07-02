import SwiftUI

struct LaunchSplashView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    let onComplete: () -> Void

    @State private var appeared = false
    @State private var bob = false
    @State private var minElapsed = false
    @State private var finishing = false

    var body: some View {
        ZStack {
            p.bgWindow.ignoresSafeArea()
            VStack(spacing: 24) {
                ZStack {
                    Circle().fill(p.accent.opacity(0.10))
                        .frame(width: 200, height: 200)
                        .scaleEffect(bob ? 1.06 : 0.92)
                        .blur(radius: 10)
                    Image("DoryLogo")
                        .resizable().scaledToFit()
                        .frame(width: 132, height: 132)
                        .offset(y: bob ? -7 : 7)
                        .rotationEffect(.degrees(bob ? -2.5 : 2.5))
                }
                .scaleEffect(appeared ? 1 : 0.72)
                .opacity(appeared ? 1 : 0)

                VStack(spacing: 10) {
                    Text("Dory")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(p.text)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 10)
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(statusText)
                            .font(.system(size: 12.5)).foregroundStyle(p.text3)
                            .contentTransition(.opacity)
                    }
                    .opacity(appeared ? 1 : 0)
                }
            }
        }
        .task {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.72)) { appeared = true }
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { bob = true }
        }
        .task {
            try? await Task.sleep(for: .seconds(1.5))
            minElapsed = true
            maybeFinish()
        }
        .task {
            try? await Task.sleep(for: .seconds(15))
            finishOnce(delay: 0)
        }
        .onChange(of: store.loadState) { _, _ in maybeFinish() }
    }

    private var statusText: String {
        store.loadState == .ready ? "Ready" : "Starting engine…"
    }

    private func maybeFinish() {
        guard minElapsed, store.loadState == .ready else { return }
        finishOnce(delay: 0.45)
    }

    private func finishOnce(delay: Double) {
        guard !finishing else { return }
        finishing = true
        Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            onComplete()
        }
    }
}
