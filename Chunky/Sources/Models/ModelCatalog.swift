import Foundation

enum ModelInstallState: String, Equatable {
    case installed
    case missing
    case downloading
}

struct ManagedModel: Equatable, Identifiable {
    var name: String
    var state: ModelInstallState
    var size: Int64?
    var digest: String
    var quantization: String
    var parameterSize: String
    var source: String
    var mlx: Bool

    var downloadKind: String { source == "ollama" ? "ollama" : "huggingface" }

    var id: String { name }

    var sizeLabel: String {
        guard let size else { return "" }
        if size >= 1_000_000_000 { return String(format: "%.1f GB", Double(size) / 1_000_000_000) }
        if size >= 1_000_000 { return String(format: "%.0f MB", Double(size) / 1_000_000) }
        return "\(size) B"
    }
}

enum ModelCatalog {
    struct PullProgress: Equatable {
        var status: String
        var percent: Double?
    }

    static func ollamaModels(from data: Data) throws -> [ManagedModel] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let models = object["models"] as? [[String: Any]] ?? []
        return models.compactMap { item in
            let name = (item["name"] as? String) ?? (item["model"] as? String) ?? ""
            guard !name.isEmpty else { return nil }
            let details = item["details"] as? [String: Any] ?? [:]
            return ManagedModel(
                name: name,
                state: .installed,
                size: (item["size"] as? NSNumber)?.int64Value,
                digest: item["digest"] as? String ?? "",
                quantization: details["quantization_level"] as? String ?? "",
                parameterSize: details["parameter_size"] as? String ?? "",
                source: "ollama",
                mlx: name.hasSuffix("-mlx")
            )
        }
    }

    static func pullProgress(line: String) -> PullProgress? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let total = (object["total"] as? NSNumber)?.doubleValue ?? 0
        let completed = (object["completed"] as? NSNumber)?.doubleValue ?? 0
        return PullProgress(
            status: object["status"] as? String ?? "",
            percent: total > 0 ? completed / total * 100 : nil
        )
    }

    static func recommended(host: ProcessingHost) -> [ManagedModel] {
        let names: [String]
        switch host {
        case .localMac:
            names = ["granite-docling-mlx"]
        case .devbox:
            names = [
                EmbeddingWidth.defaultModel,
                "ibm-granite/granite-docling-258M",
                "ibm-granite/granite-vision-3.3-2b",
            ]
        }
        return names.map { name in
            ManagedModel(
                name: name,
                state: .missing,
                size: nil,
                digest: "",
                quantization: "",
                parameterSize: "",
                source: name.contains("/") ? "huggingface" : "ollama",
                mlx: name.hasSuffix("-mlx")
            )
        }
    }

    static func marking(_ models: [ManagedModel], inventory: [ManagedModel] = [], downloading: Set<String> = []) -> [ManagedModel] {
        models.map { model in
            var copy = model
            if downloading.contains(model.name) {
                copy.state = .downloading
            } else if let found = inventory.first(where: { matches($0, model) }) {
                copy.state = .installed
                copy.size = found.size ?? copy.size
                copy.digest = found.digest
                copy.quantization = found.quantization
                copy.parameterSize = found.parameterSize
            } else {
                copy.state = .missing
            }
            return copy
        }
    }

    static func matches(_ installed: ManagedModel, _ wanted: ManagedModel) -> Bool {
        if installed.name == wanted.name { return true }
        let base = installed.name.split(separator: ":").first.map(String.init) ?? installed.name
        return base == wanted.name
    }

    static func installedModels(fromWorker data: Data) throws -> [ManagedModel] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let rows = object["installed"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            let name = row["name"] as? String ?? ""
            guard !name.isEmpty else { return nil }
            return ManagedModel(
                name: name,
                state: .installed,
                size: (row["size"] as? NSNumber)?.int64Value,
                digest: "",
                quantization: "",
                parameterSize: "",
                source: row["source"] as? String ?? "huggingface",
                mlx: name.hasSuffix("-mlx")
            )
        }
    }

    static func visible(_ models: [ManagedModel], host: ProcessingHost) -> [ManagedModel] {
        switch host {
        case .localMac: return models
        case .devbox: return models.filter { !$0.mlx }
        }
    }
}
