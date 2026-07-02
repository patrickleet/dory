import SwiftUI

struct DoryLogo: View {
    var size: CGFloat = 30
    var corner: CGFloat = 9

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Color(hex: 0xEAF1FE))
            .frame(width: size, height: size)
            .overlay(
                Image("DoryLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.86, height: size * 0.86)
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(.black.opacity(0.06))
            )
            .shadow(color: .black.opacity(0.16), radius: 3, x: 0, y: 1.5)
    }
}
