import Foundation
import QdrantCore

struct SparseVectorService {
    static func generateSparseVectors(texts: [String]) -> [SparseVector] {
        let tokenizedTexts = texts.map { tokenize($0) }

        var documentFrequency: [String: Int] = [:]
        for tokens in tokenizedTexts {
            let unique = Set(tokens)
            for token in unique {
                documentFrequency[token, default: 0] += 1
            }
        }

        let tokenToIndex = buildVocabulary(documentFrequency: documentFrequency)
        let n = Double(texts.count)

        return tokenizedTexts.map { tokens in
            var termFrequency: [String: Int] = [:]
            for token in tokens {
                termFrequency[token, default: 0] += 1
            }

            var indices: [UInt32] = []
            var values: [Float] = []

            for (token, tf) in termFrequency {
                guard let index = tokenToIndex[token],
                      let df = documentFrequency[token]
                else { continue }

                let tfNorm = log(1.0 + Double(tf))
                let idf = log(1.0 + n / Double(df))
                let score = tfNorm * idf

                if score > 0 {
                    indices.append(UInt32(index))
                    values.append(Float(score))
                }
            }

            let sorted = zip(indices, values).sorted { $0.0 < $1.0 }
            return SparseVector(
                indices: sorted.map { $0.0 },
                values: sorted.map { $0.1 }
            )
        }
    }

    private static func tokenize(_ text: String) -> [String] {
        let lowered = text.lowercased()
        var tokens: [String] = []
        lowered.enumerateSubstrings(
            in: lowered.startIndex...,
            options: [.byWords, .localized]
        ) { substring, _, _, _ in
            if let word = substring, word.count >= 2 {
                tokens.append(word)
            }
        }
        return tokens
    }

    private static func buildVocabulary(documentFrequency: [String: Int]) -> [String: Int] {
        var vocab: [String: Int] = [:]
        for (index, token) in documentFrequency.keys.sorted().enumerated() {
            vocab[token] = index
        }
        return vocab
    }
}
