import AuthenticationServices
import SwiftUI
import BideUI

/// Onboarding screen for Apple or anonymous sign-in.
struct SignInView: View {

    let auth: AuthController

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 18) {
                BideMark(.horizontal, dotDiameter: 16)
                Text("Bide")
                    .font(BideFont.display)
                    .foregroundStyle(BideColor.primaryText)
                CubeRotatingText()
                    .padding(.horizontal, BideMetrics.gutter)
            }

            Spacer()
            Spacer()

            VStack(spacing: 18) {
                SignInWithAppleButton(.signIn) { request in
                    auth.configure(request)
                } onCompletion: { result in
                    Task { await auth.handle(result) }
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 52)
                .clipShape(Capsule())

                Button("Use without signing in") {
                    Task { await auth.continueWithoutSigningIn() }
                }
                .font(BideFont.body)
                .foregroundStyle(BideColor.primaryText)

                if let errorMessage = auth.errorMessage {
                    Text(errorMessage)
                        .font(BideFont.caption)
                        .foregroundStyle(BideColor.delay(.late))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, BideMetrics.gutter)
            .padding(.bottom, 24)
            .disabled(auth.isWorking)
            .opacity(auth.isWorking ? 0.5 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bideBackground()
        .preferredColorScheme(.dark)
    }
}
