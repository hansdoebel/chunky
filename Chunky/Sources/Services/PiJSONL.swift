import Foundation

nonisolated enum PiJSONL {
    static func encodeLine(_ object: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var line = data
        line.append(0x0A)
        return line
    }

    static func pullRecords(from buffer: inout Data) -> [Data] {
        var records: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var record = Data(buffer[..<newline])
            buffer.removeSubrange(..<buffer.index(after: newline))
            if record.last == 0x0D {
                record.removeLast()
            }
            if !record.isEmpty {
                records.append(record)
            }
        }
        return records
    }

    static func decodeObject(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw PiRPCError.malformed
        }
        return dictionary
    }

    static func stripped(_ value: Any?) -> Any? {
        if value is NSNull {
            return nil
        }
        return value
    }

    static func bool(_ value: Any?) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return false
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
        guard let dictionary = value as? NSDictionary else { return nil }
        var result: [String: Any] = [:]
        for (key, item) in dictionary {
            if let key = key as? String {
                result[key] = item
            }
        }
        return result
    }

    static func dictionaries(_ value: Any?) -> [[String: Any]] {
        let rows: [Any]
        if let typed = value as? [[String: Any]] {
            return typed
        }
        if let list = value as? [Any] {
            rows = list
        } else if let list = value as? NSArray {
            rows = list.map { $0 }
        } else {
            return []
        }
        return rows.compactMap { dictionary($0) }
    }
}

nonisolated enum PiRPCError: LocalizedError, Equatable {
    case malformed
    case commandFailed(String, String)
    case processExited
    case busy

    var errorDescription: String? {
        switch self {
        case .malformed:
            return "pi returned a malformed record"
        case .commandFailed(let command, let message):
            return "pi \(command) failed: \(message)"
        case .processExited:
            return "pi exited"
        case .busy:
            return "pi already has a stream waiting"
        }
    }
}

nonisolated struct PiRPCResponse {
    var id: String
    var command: String
    var success: Bool
    var data: Any?
    var error: String?

    var disposition: String? {
        PiJSONL.dictionary(data)?["disposition"] as? String
    }

    static func errorText(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty {
            return text
        }
        if let object = value as? [String: Any] {
            if let message = object["message"] as? String, !message.isEmpty {
                return message
            }
        }
        return nil
    }
}

nonisolated struct PiEvent {
    var object: [String: Any]

    var type: String {
        object["type"] as? String ?? ""
    }

    var textDelta: String? {
        guard type == "message_update" else { return nil }
        guard let update = object["assistantMessageEvent"] as? [String: Any] else { return nil }
        guard update["type"] as? String == "text_delta" else { return nil }
        return update["delta"] as? String
    }

    var aborted: Bool {
        object["aborted"] as? Bool ?? false
    }
}
