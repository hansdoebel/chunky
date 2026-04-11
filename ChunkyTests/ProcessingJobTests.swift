import Foundation
import Testing

@testable import Chunky

struct ProcessingJobTests {

    // MARK: - Initialization Tests

    @Test func initializationWithPDFURL() {
        let url = URL(fileURLWithPath: "/path/to/document.pdf")
        let job = ProcessingJob(url: url)

        #expect(job.fileName == "document.pdf")
        #expect(job.sourceURL == url)
        #expect(job.status == .pending)
        #expect(job.progress == 0.0)
        #expect(job.chunksCount == 0)
        #expect(job.embeddedCount == 0)
        #expect(job.error == nil)
        #expect(job.jobType == .pdf)
    }

    @Test func initializationWithMarkdownURL() {
        let url = URL(fileURLWithPath: "/path/to/notes.md")
        let job = ProcessingJob(url: url)

        #expect(job.fileName == "notes.md")
        #expect(job.jobType == .markdown)
    }

    @Test func initializationWithMarkdownExtension() {
        let url = URL(fileURLWithPath: "/path/to/readme.markdown")
        let job = ProcessingJob(url: url)

        #expect(job.jobType == .markdown)
    }

    @Test func initializationWithJSONURL() {
        let url = URL(fileURLWithPath: "/path/to/data.json")
        let job = ProcessingJob(url: url)

        #expect(job.fileName == "data.json")
        #expect(job.jobType == .chunkedJSON)
    }

    @Test func initializationWithDocxURL() {
        let url = URL(fileURLWithPath: "/path/to/report.docx")
        let job = ProcessingJob(url: url)

        #expect(job.jobType == .pdf)  // Docx is processed like PDF via Docling
    }

    @Test func initializationWithPptxURL() {
        let url = URL(fileURLWithPath: "/path/to/presentation.pptx")
        let job = ProcessingJob(url: url)

        #expect(job.jobType == .pdf)  // Pptx is processed like PDF via Docling
    }

    @Test func initializationWithHTMLURL() {
        let url = URL(fileURLWithPath: "/path/to/page.html")
        let job = ProcessingJob(url: url)

        #expect(job.jobType == .pdf)  // HTML is processed via Docling
    }

    @Test func initializationWithImageURL() {
        let url = URL(fileURLWithPath: "/path/to/image.png")
        let job = ProcessingJob(url: url)

        #expect(job.jobType == .pdf)  // Images are processed via Docling OCR
    }

    // MARK: - Unique ID Tests

    @Test func eachJobHasUniqueID() {
        let url = URL(fileURLWithPath: "/path/to/document.pdf")
        let job1 = ProcessingJob(url: url)
        let job2 = ProcessingJob(url: url)

        #expect(job1.id != job2.id)
    }

    // MARK: - Status Tests

    @Test func defaultStatusIsPending() {
        let job = ProcessingJob(url: URL(fileURLWithPath: "/test.pdf"))
        #expect(job.status == .pending)
    }

    @Test func statusCanBeChanged() {
        let job = ProcessingJob(url: URL(fileURLWithPath: "/test.pdf"))

        job.status = .chunking
        #expect(job.status == .chunking)

        job.status = .embedding
        #expect(job.status == .embedding)

        job.status = .uploading
        #expect(job.status == .uploading)

        job.status = .completed
        #expect(job.status == .completed)

        job.status = .failed
        #expect(job.status == .failed)
    }

    // MARK: - Progress Tests

    @Test func progressCanBeUpdated() {
        let job = ProcessingJob(url: URL(fileURLWithPath: "/test.pdf"))

        job.progress = 0.5
        #expect(job.progress == 0.5)

        job.progress = 1.0
        #expect(job.progress == 1.0)
    }

    // MARK: - Chunk Count Tests

    @Test func chunkCountsCanBeUpdated() {
        let job = ProcessingJob(url: URL(fileURLWithPath: "/test.pdf"))

        job.chunksCount = 100
        #expect(job.chunksCount == 100)

        job.embeddedCount = 50
        #expect(job.embeddedCount == 50)
    }

    // MARK: - Error Tests

    @Test func errorCanBeSet() {
        let job = ProcessingJob(url: URL(fileURLWithPath: "/test.pdf"))

        job.error = "Something went wrong"
        #expect(job.error == "Something went wrong")
    }

    // MARK: - Case Insensitive Extension Tests

    @Test func extensionDetectionIsCaseInsensitive() {
        let pdfUpper = ProcessingJob(url: URL(fileURLWithPath: "/test.PDF"))
        let pdfMixed = ProcessingJob(url: URL(fileURLWithPath: "/test.Pdf"))
        let mdUpper = ProcessingJob(url: URL(fileURLWithPath: "/test.MD"))
        let jsonUpper = ProcessingJob(url: URL(fileURLWithPath: "/test.JSON"))

        #expect(pdfUpper.jobType == .pdf)
        #expect(pdfMixed.jobType == .pdf)
        #expect(mdUpper.jobType == .markdown)
        #expect(jsonUpper.jobType == .chunkedJSON)
    }
}
