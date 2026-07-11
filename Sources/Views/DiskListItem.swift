import SwiftUI

// MARK: - Disk List Item

struct DiskListItem: View {
    let disk: PhysicalDisk
    let isSelected: Bool
    let onSelect: (String) -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(disk.device + " - " + disk.volumeName)
                        .font(.system(.body, design: .monospaced))
                    if disk.isAdded { Text("✅ 已添加").font(.caption).foregroundColor(.green) }
                }
                Text("UUID: " + disk.uuid)
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Text(disk.size)
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(disk.isAdded ? Color.green : (isSelected ? Color.blue : Color.gray), lineWidth: 1)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(disk.isAdded ? Color.green.opacity(0.05) : (isSelected ? Color.blue.opacity(0.1) : Color.clear))
                )
        )
        .opacity(disk.isAdded ? 0.6 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(disk.currentMount ?? "") }
    }
}
