import SwiftUI

struct OperationNotice: Identifiable {
    let id = UUID()
    let message: String
    let isError: Bool
}

/// Nonmodal feedback; detailed operation results remain on each volume row.
struct OperationNoticeView: View {
    let notice: OperationNotice
    let onDismiss: () -> Void

    private var color: Color { notice.isError ? .orange : .green }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundColor(color)
            ScrollView {
                Text(notice.message)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 80)
            .fixedSize(horizontal: false, vertical: true)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭通知")
            .accessibilityLabel("关闭通知")
        }
        .padding(12)
        .background(color.opacity(0.10))
        .cornerRadius(8)
        .accessibilityElement(children: .contain)
    }
}
