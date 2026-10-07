import SwiftUI

/// §4 строка 69: по центру ленты иконка чата 64 #9ca3af opacity .5,
/// под ней текст 14 #9ca3af, зазор 12.
struct EmptyState: View {
    let hint: String

    var body: some View {
        VStack(spacing: Theme.emptyGap) {
            SvgIcon(d: Icons.chat, size: Theme.emptyIconSize, color: Theme.muted)
                .opacity(Theme.emptyIconOpacity)
            Text(hint)
                .font(.system(size: Theme.emptyTextSize))
                .foregroundColor(Theme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.listPadding)
    }
}
