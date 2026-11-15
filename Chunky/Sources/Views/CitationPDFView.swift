import AppKit
import SwiftUI

struct CitationPDFScreen: View {
    @Environment(\.dismiss) private var dismiss
    var highlight: CitationHighlight
    var pageImage: (Int) -> (image: NSImage, size: VerificationReport.PageSize)?
    var fallbackImage: (Int) -> (image: NSImage, size: VerificationReport.PageSize)?

    init(
        highlight: CitationHighlight,
        pageImage: @escaping (Int) -> (image: NSImage, size: VerificationReport.PageSize)? = { _ in nil },
        fallbackImage: @escaping (Int) -> (image: NSImage, size: VerificationReport.PageSize)? = { _ in nil }
    ) {
        self.highlight = highlight
        self.pageImage = pageImage
        self.fallbackImage = fallbackImage
    }

    var body: some View {
        let rendered = pageImage(highlight.page) ?? fallbackImage(highlight.page)
        let size = rendered?.size ?? VerificationReport.PageSize(width: 612, height: 792)
        let note = note(rendered: rendered != nil)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(highlight.title.isEmpty ? "Source PDF" : highlight.title)
                    .font(.title2)
                    .lineLimit(2)
                Spacer()
                Button("Close") { dismiss() }
            }
            Text(highlight.chrome)
                .font(.headline)
            if let note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(AppTheme.statusOrange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VerificationPagePreview(image: rendered?.image, boxes: highlight.boxes, pageSize: size)
                .frame(width: 360, height: 480)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func note(rendered: Bool) -> String? {
        if highlight.pdfURL == nil {
            return highlight.message ?? CitationPDF.missingFile
        }
        if !rendered {
            return CitationPDF.unreadableFile
        }
        return nil
    }
}
