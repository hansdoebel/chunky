import Testing
import Foundation
@testable import Chunky

struct KeychainServiceTests {

    // Use a unique test key to avoid conflicts
    private static let testKey = "chunky_test_key_\(UUID().uuidString)"

    // MARK: - Save and Get Tests

    @Test func saveAndRetrieveValue() throws {
        let key = "test_save_retrieve_\(UUID().uuidString)"
        let value = "test-secret-value"

        // Clean up first
        KeychainService.delete(key: key)

        // Save
        try KeychainService.save(key: key, value: value)

        // Retrieve
        let retrieved = KeychainService.get(key: key)
        #expect(retrieved == value)

        // Clean up
        KeychainService.delete(key: key)
    }

    @Test func overwriteExistingValue() throws {
        let key = "test_overwrite_\(UUID().uuidString)"

        // Clean up first
        KeychainService.delete(key: key)

        // Save initial value
        try KeychainService.save(key: key, value: "initial")
        #expect(KeychainService.get(key: key) == "initial")

        // Overwrite with new value
        try KeychainService.save(key: key, value: "updated")
        #expect(KeychainService.get(key: key) == "updated")

        // Clean up
        KeychainService.delete(key: key)
    }

    @Test func getNonExistentKey() {
        let key = "non_existent_key_\(UUID().uuidString)"

        let result = KeychainService.get(key: key)
        #expect(result == nil)
    }

    // MARK: - Delete Tests

    @Test func deleteExistingKey() throws {
        let key = "test_delete_\(UUID().uuidString)"

        // Save a value
        try KeychainService.save(key: key, value: "to-be-deleted")
        #expect(KeychainService.get(key: key) != nil)

        // Delete it
        KeychainService.delete(key: key)

        // Verify it's gone
        #expect(KeychainService.get(key: key) == nil)
    }

    @Test func deleteNonExistentKeyNoError() {
        let key = "non_existent_delete_\(UUID().uuidString)"

        // Should not throw
        KeychainService.delete(key: key)
    }

    // MARK: - Exists Tests

    @Test func existsReturnsTrueForExistingKey() throws {
        let key = "test_exists_true_\(UUID().uuidString)"

        KeychainService.delete(key: key)
        try KeychainService.save(key: key, value: "exists")

        #expect(KeychainService.exists(key: key) == true)

        KeychainService.delete(key: key)
    }

    @Test func existsReturnsFalseForMissingKey() {
        let key = "test_exists_false_\(UUID().uuidString)"

        KeychainService.delete(key: key)
        #expect(KeychainService.exists(key: key) == false)
    }

    // MARK: - Special Characters Tests

    @Test func handleSpecialCharacters() throws {
        let key = "test_special_\(UUID().uuidString)"
        let value = "p@ssw0rd!#$%^&*()_+-=[]{}|;':\",./<>?"

        KeychainService.delete(key: key)
        try KeychainService.save(key: key, value: value)

        let retrieved = KeychainService.get(key: key)
        #expect(retrieved == value)

        KeychainService.delete(key: key)
    }

    @Test func handleUnicodeCharacters() throws {
        let key = "test_unicode_\(UUID().uuidString)"
        let value = "密码🔐مرور"

        KeychainService.delete(key: key)
        try KeychainService.save(key: key, value: value)

        let retrieved = KeychainService.get(key: key)
        #expect(retrieved == value)

        KeychainService.delete(key: key)
    }

    @Test func handleEmptyString() throws {
        let key = "test_empty_\(UUID().uuidString)"

        KeychainService.delete(key: key)
        try KeychainService.save(key: key, value: "")

        let retrieved = KeychainService.get(key: key)
        #expect(retrieved == "")

        KeychainService.delete(key: key)
    }

    @Test func handleLongValue() throws {
        let key = "test_long_\(UUID().uuidString)"
        let value = String(repeating: "a", count: 10000)

        KeychainService.delete(key: key)
        try KeychainService.save(key: key, value: value)

        let retrieved = KeychainService.get(key: key)
        #expect(retrieved == value)

        KeychainService.delete(key: key)
    }

    // MARK: - Predefined Keys Tests

    @Test func predefinedKeysExist() {
        // Verify the predefined key constants exist
        #expect(KeychainService.qdrantAPIKeyKey == "qdrant_api_key")
        #expect(KeychainService.ollamaAPIKeyKey == "ollama_api_key")
    }
}
