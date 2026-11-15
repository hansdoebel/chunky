import AppKit
import PDFKit
import SwiftUI

struct VerificationDocument: Identifiable, Equatable {
    var id: String
    var filename: String
    var report: VerificationReport?
    var note: String?
}

struct VerificationScreen: View {
    var documents: [VerificationDocument]
    var pageImage: (String, Int) -> NSImage?
    var onReverify: (String) -> Void
    @State private var selectedID: String?
    @State private var page: Int

    init(
        documents: [VerificationDocument],
        pageImage: @escaping (String, Int) -> NSImage? = { _, _ in nil },
        onReverify: @escaping (String) -> Void = { _ in },
        selectedID: String? = nil,
        page: Int? = nil
    ) {
        self.documents = documents
        self.pageImage = pageImage
        self.onReverify = onReverify
        let initial = selectedID ?? documents.first?.id
        _selectedID = State(initialValue: initial)
        let report = documents.first { $0.id == initial }?.report
        _page = State(initialValue: page ?? report?.focusPage ?? 1)
    }

    private var selected: VerificationDocument? {
        documents.first { $0.id == selectedID } ?? documents.first
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            documentList
            Divider()
            detail
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var documentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Documents")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)
            if documents.isEmpty {
                Text("Finish an ingest to verify it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(documents) { document in
                            documentRow(document)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(width: 220, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.gray.opacity(0.08))
    }

    private func documentRow(_ document: VerificationDocument) -> some View {
        let chosen = document.id == selected?.id
        return Button {
            selectedID = document.id
            page = document.report?.focusPage ?? 1
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(VerificationStatusColor.color(document.report?.status ?? "yellow"))
                    .frame(width: 8, height: 8)
                Text(document.filename)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(chosen ? Color.accentColor.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let selected {
                    header(selected)
                    if let report = selected.report {
                        pageStrip(report)
                        HStack(alignment: .top, spacing: 16) {
                            preview(report, documentID: selected.id)
                            findings(report)
                        }
                    } else {
                        Text(selected.note ?? "This document has not been verified yet.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Choose a document to see its page checks.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ document: VerificationDocument) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(document.filename)
                    .font(.title2)
                if let report = document.report {
                    Text(report.status.capitalized)
                        .font(.headline)
                        .foregroundStyle(VerificationStatusColor.color(report.status))
                }
            }
            Spacer()
            Button("Re-verify") { onReverify(document.id) }
                .buttonStyle(.borderedProminent)
        }
    }

    private func pageStrip(_ report: VerificationReport) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(report.pages) { row in
                    Button {
                        page = row.page
                    } label: {
                        VStack(spacing: 4) {
                            Text("\(row.page)")
                                .font(.caption.monospacedDigit())
                            Circle()
                                .fill(VerificationStatusColor.color(row.status))
                                .frame(width: 10, height: 10)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(page == row.page ? Color.gray.opacity(0.16) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func preview(_ report: VerificationReport, documentID: String) -> some View {
        let image = pageImage(documentID, page)
        let box = report.spotChecks.first { $0.page == page }?.bbox ?? report.spotChecks.first?.bbox
        return VerificationPagePreview(image: image, bbox: box, pageSize: report.pageSize)
            .frame(width: 280, height: 360)
    }

    private func findings(_ report: VerificationReport) -> some View {
        let row = report.pages.first { $0.page == page }
        return VStack(alignment: .leading, spacing: 10) {
            if let row {
                Text("Page \(row.page) coverage \(Int((row.coverage * 100).rounded()))%")
                    .font(.headline)
                ForEach(row.flags, id: \.self) { flag in
                    Text(flag)
                        .font(.callout)
                        .foregroundStyle(VerificationStatusColor.color(row.status))
                }
            }
            labeled("Store", report.store.status)
            labeled("Vectors", report.vectorSpotCheck.status)
            labeled("Retrieval", report.retrieval.status)
            if let mismatch = report.attributions.first(where: { !$0.matched && $0.page == page }) {
                Text("Chunk \(mismatch.chunkID) looks closer to page \(mismatch.suggestedPage ?? 0).")
                    .font(.callout)
            }
            if let preview = report.spotChecks.first(where: { $0.page == page })?.preview, !preview.isEmpty {
                Text(preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if let note = report.text.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labeled(_ title: String, _ status: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(VerificationStatusColor.color(status))
                .frame(width: 8, height: 8)
            Text(title)
            Spacer()
            Text(status)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

struct VerificationPagePreview: View {
    var image: NSImage?
    var bbox: VerificationBBox?
    var pageSize: VerificationReport.PageSize

    var body: some View {
        GeometryReader { geo in
            let page = CGSize(width: pageSize.width, height: pageSize.height)
            let area = Self.fitted(geo.size, page: page)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.35)))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: area.width, height: area.height)
                        .offset(x: area.minX, y: area.minY)
                }
                if let bbox {
                    let rect = bbox.rect(pageWidth: pageSize.width, pageHeight: pageSize.height, in: area)
                    Rectangle()
                        .fill(AppTheme.statusOrange.opacity(0.35))
                        .overlay(Rectangle().stroke(AppTheme.statusOrange, lineWidth: 2))
                        .frame(width: max(rect.width, 2), height: max(rect.height, 2))
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
    }

    static func fitted(_ container: CGSize, page: CGSize) -> CGRect {
        let scale = min(container.width / max(page.width, 1), container.height / max(page.height, 1))
        let width = page.width * scale
        let height = page.height * scale
        return CGRect(x: (container.width - width) / 2, y: (container.height - height) / 2, width: width, height: height)
    }
}

struct VerificationRoot: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var processor: DocumentProcessor
    @State private var selectedID: UUID?

    var body: some View {
        let selected = appState.jobs.first { $0.id == selectedID } ?? appState.jobs.first
        Group {
            if let selected {
                VerificationObserved(job: selected, jobs: appState.jobs, processor: processor, settings: appState.settings) { id in
                    selectedID = id
                }
            } else {
                VerificationScreen(documents: [])
            }
        }
        .onAppear { selectedID = selectedID ?? appState.jobs.first?.id }
    }
}

private struct VerificationObserved: View {
    @ObservedObject var job: ProcessingJob
    var jobs: [ProcessingJob]
    var processor: DocumentProcessor
    var settings: AppSettings
    var onSelect: (UUID) -> Void

    var body: some View {
        VerificationScreen(
            documents: jobs.map { item in
                let current = item.id == job.id ? job : item
                return VerificationDocument(
                    id: current.id.uuidString,
                    filename: current.fileName,
                    report: current.verification,
                    note: current.verificationNote
                )
            },
            pageImage: { id, page in
                guard let match = jobs.first(where: { $0.id.uuidString == id }) else { return nil }
                return PDFPageRenderer.image(url: match.sourceURL, page: page)
            },
            onReverify: { id in
                guard let match = jobs.first(where: { $0.id.uuidString == id }) else { return }
                if let uuid = UUID(uuidString: id) { onSelect(uuid) }
                Task { await processor.reverify(job: match, settings: settings) }
            },
            selectedID: job.id.uuidString
        )
    }
}

enum PDFPageRenderer {
    static func image(url: URL, page: Int) -> NSImage? {
        guard page > 0, let document = PDFDocument(url: url), let pdfPage = document.page(at: page - 1) else {
            return nil
        }
        let bounds = pdfPage.bounds(for: .mediaBox)
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        NSColor.white.setFill()
        bounds.fill()
        if let context = NSGraphicsContext.current?.cgContext {
            pdfPage.draw(with: .mediaBox, to: context)
        }
        image.unlockFocus()
        return image
    }
}
