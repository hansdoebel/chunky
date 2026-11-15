import Foundation
import Testing

@testable import Chunky

struct OllamaServiceCacheTests {

    @Test func sameURLReusesTheClient() throws {
        let processor = DocumentProcessor()
        let first = try processor.getOllamaService(baseURL: "http://localhost:11434")
        let second = try processor.getOllamaService(baseURL: "http://localhost:11434")
        #expect(first === second)
        #expect(first.configuredURL == "http://localhost:11434")
    }

    @Test func urlChangeReplacesTheClient() throws {
        let processor = DocumentProcessor()
        let local = try processor.getOllamaService(baseURL: "http://localhost:11434")
        let other = try processor.getOllamaService(baseURL: "http://127.0.0.1:11435")
        #expect(local !== other)
        #expect(local.configuredURL == "http://localhost:11434")
        #expect(other.configuredURL == "http://127.0.0.1:11435")

        let again = try processor.getOllamaService(baseURL: "http://127.0.0.1:11435")
        #expect(again === other)
        let back = try processor.getOllamaService(baseURL: "http://localhost:11434")
        #expect(back !== local)
        #expect(back.configuredURL == "http://localhost:11434")
    }
}
