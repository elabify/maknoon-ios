// Compact card used on the Identity tab above the credential stack.
// Shows the document photo (if available), name, kind, and country.

import SwiftUI

struct IDDocumentCard: View {
    let document: IDDocument
    let photo: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 52, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.indigo.opacity(0.15))
                    .frame(width: 52, height: 64)
                    .overlay(
                        Image(systemName: document.iconName)
                            .font(.title3)
                            .foregroundStyle(.indigo)
                    )
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(document.nickname ?? document.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if document.nickname == nil, let native = document.nativeDisplayName {
                    Text(native)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("\(document.kindLabel) · \(document.summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let exp = document.formattedDateOfExpiry {
                    Text("Expires \(exp)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }
}
