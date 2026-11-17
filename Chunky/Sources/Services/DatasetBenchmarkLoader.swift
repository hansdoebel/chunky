import Foundation

nonisolated enum DatasetBenchmarkLoader {
    static func inspect(_ directory: URL) async throws -> (DatasetSnapshot, [String]) {
        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let snapshot = try DatasetSnapshot.load(from: directory)
            let fields = try DatasetBenchmarkCorpus.fields(in: snapshot)
            try Task.checkCancellation()
            return (snapshot, fields)
        }
        return try await withTaskCancellationHandler {
            let result = try await work.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            work.cancel()
        }
    }

    static func corpus(snapshot: DatasetSnapshot, field: String, limit: Int) async throws -> DatasetBenchmarkCorpus {
        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let corpus = try DatasetBenchmarkCorpus.load(snapshot: snapshot, field: field, limit: limit)
            try Task.checkCancellation()
            return corpus
        }
        return try await withTaskCancellationHandler {
            let result = try await work.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            work.cancel()
        }
    }
}
