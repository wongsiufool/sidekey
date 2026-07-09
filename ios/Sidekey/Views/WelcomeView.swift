import SwiftUI

/// 启动 / 欢迎页 (柔光珊瑚): 浮起的 168 软白「S」键 + Sidekey(衬线) + slogan + 全宽珊瑚主按钮。
/// 由 RootView 启动时短暂展示后淡出; 点一下可立即跳过 (逻辑不变)。
struct WelcomeView: View {
    @State private var appeared = false

    // 与 sidekey-app-icon-v1.png 边缘采样一致，避免原始图标的正方形画布露底。
    private let canvas = Color(hex: 0xFDF8F5)
    private let ink = Color(hex: 0x303841)

    var body: some View {
        ZStack {
            canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                sKey
                    .scaleEffect(appeared ? 1 : 0.78).opacity(appeared ? 1 : 0)
                Spacer().frame(height: 40)
                BrandMark(size: 34)
                Text("welcome.slogan")
                    .font(.system(size: 15))
                    .foregroundStyle(ink.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                Spacer()
                CoralButton(title: NSLocalizedString("welcome.cta", comment: "")) {}
                    .allowsHitTesting(false)            // 整页可点即跳过, 按钮仅视觉
                    .padding(.horizontal, 40)
                    .padding(.bottom, 56)
                    .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 16)
            }
            .padding(.horizontal, 20)
        }
        .environment(\.sidekeyTheme, SidekeyTheme.make(.fresh, dark: false))
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.72)) { appeared = true } }
    }

    /// 使用用户确认的原始 sidekey-app-icon-v1 图标。画布背景与页面同色，
    /// 因此保留原始图标的材质、光影与比例，同时不会在启动页显出方形底。
    private var sKey: some View {
        Image("SidekeyWelcomeMark")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 196, height: 196)
            // 原图四周是用于 App Icon 的留白。启动页只展示中间的原始键帽，
            // 避免那圈带轻微渐变的留白和页面纯色之间形成方形边界。
            .scaleEffect(1.16)
            .clipShape(RoundedRectangle(cornerRadius: 42, style: .continuous))
    }
}
