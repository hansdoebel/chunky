import SwiftUI

struct ProjectLinksPane: View {
    static let repositoryURL = URL(string: "https://github.com/hansdoebel/chunky")!

    var body: some View {
        Link("GitHub Repository", destination: Self.repositoryURL)
        Link(
            "Docling Documentation",
            destination: URL(string: "https://docling-project.github.io/docling/")!
        )
    }
}
