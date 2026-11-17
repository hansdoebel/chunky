import Foundation
import Testing
@testable import Chunky

@MainActor
struct PreferenceInputTests {
    @Test func endpointTrimsOuterWhitespaceWithoutChangingRoutes() throws {
        #expect(try PreferenceInput.endpoint(" \nHTTPS://Example.COM:6334/proxy%20path/v1?tenant=one%2Ftwo\r\n") == "https://Example.COM:6334/proxy%20path/v1?tenant=one%2Ftwo")
        #expect(try PreferenceInput.endpoint("http://localhost:11434/") == "http://localhost:11434/")
        #expect(try PreferenceInput.endpoint("https://worker.example.ts.net") == "https://worker.example.ts.net")
        #expect(try PreferenceInput.endpoint("http://[::1]:6334") == "http://[::1]:6334")
        #expect(try PreferenceInput.endpoint("http://[fe80::1%25en0]:6334") == "http://[fe80::1%25en0]:6334")
        #expect(try PreferenceInput.endpoint("http://127.0.0.1:8080/worker") == "http://127.0.0.1:8080/worker")
    }

    @Test func endpointRejectsMalformedOrUnsafePastes() {
        for text in ["", "localhost:6334", "//localhost:6334", "ftp://host", "https:///path", "http://", "http://two hosts", "http://host/with space", "http://host\n/second-line", "http://host\t/path", "http://host/invalid%escape", "http://host/\\path", "http://user:secret@host", "http://user@host", "http://host:0", "http://host:65536", "http://host:-1", "http://host:+1", "http://host:abc", "http://host:", "http://[::1]:", "http://[::1]suffix", "http://%20host", "http://host/#fragment", "http://[not-an-ip]", "http://[::1%25]", "http://[::1%25en0%25extra]", "http://host\u{2028}path", "http://host\u{2029}path"] {
            #expect(throws: PreferenceInputError.self) { try PreferenceInput.endpoint(text) }
        }
    }

    @Test func endpointAcceptsPortBoundsAndExplicitOptionalEmptyValue() throws {
        #expect(try PreferenceInput.endpoint("http://host:1") == "http://host:1")
        #expect(try PreferenceInput.endpoint("http://host:65535") == "http://host:65535")
        #expect(try PreferenceInput.endpoint(" \n", allowEmpty: true) == "")
    }

    @Test func identifiersTrimWithoutDestroyingMeaningfulSpaces() throws {
        #expect(try PreferenceInput.identifier("  Team library \n", label: "Library") == "Team library")
        #expect(try PreferenceInput.identifier(" org/model:latest ", label: "Model") == "org/model:latest")
        #expect(try PreferenceInput.identifier(" \n", allowEmpty: true) == "")
        #expect(throws: PreferenceInputError.self) { try PreferenceInput.identifier("one\ntwo") }
        #expect(throws: PreferenceInputError.self) { try PreferenceInput.identifier("one\ttwo") }
        #expect(throws: PreferenceInputError.self) { try PreferenceInput.identifier("one\u{0}two") }
        #expect(throws: PreferenceInputError.self) { try PreferenceInput.identifier("one\u{2028}two") }
        #expect(throws: PreferenceInputError.self) { try PreferenceInput.identifier("one\u{2029}two") }
        #expect(throws: PreferenceInputError.self) { try PreferenceInput.identifier("  ", label: "Model") }
    }

    @Test func integersRejectGroupingFractionsUnicodeDigitsAndOverflow() throws {
        #expect(try PreferenceInput.integer(" 768\n", range: 1...2048, label: "Dimensions") == 768)
        #expect(try PreferenceInput.integer("1", range: 1...2048) == 1)
        #expect(try PreferenceInput.integer("2048", range: 1...2048) == 2048)
        #expect(try PreferenceInput.integer("-2", range: -2...2) == -2)
        for text in ["", "0", "2049", "-1", "1,024", "1.024", "1 024", "1.0", "+1", "１２", "1\n2", String(repeating: "9", count: 100)] {
            #expect(throws: PreferenceInputError.self) { try PreferenceInput.integer(text, range: 1...2048, label: "Dimensions") }
        }
    }

    @Test func errorsExplainTheActionWithoutEchoingCredentials() {
        do {
            _ = try PreferenceInput.endpoint("https://user:private-token@host")
            Issue.record("Credentials in an endpoint must fail validation")
        } catch {
            #expect(error.localizedDescription.contains("credential field"))
            #expect(!error.localizedDescription.contains("private-token"))
        }
        #expect(PreferenceInputError.integerRange("Dimensions", 1, 2048).localizedDescription.contains("1 and 2048"))
    }
}
