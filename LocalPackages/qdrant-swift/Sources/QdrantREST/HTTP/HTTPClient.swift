import Foundation

extension CharacterSet {

    static let urlPathComponentAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return allowed
    }()
}

public actor HTTPClient {
    private let session: URLSession
    private let baseURL: URL
    private let apiKey: String?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        host: String,
        port: Int = 6333,
        useTLS: Bool = false,
        apiKey: String? = nil,
        session: URLSession = .shared
    ) throws {
        let scheme = useTLS ? "https" : "http"
        guard let url = URL(string: "\(scheme)://\(host):\(port)") else {
            throw HTTPError.invalidURL("\(scheme)://\(host):\(port)")
        }

        self.baseURL = url
        self.apiKey = apiKey
        self.session = session

        self.encoder = JSONEncoder()
        self.encoder.keyEncodingStrategy = .convertToSnakeCase

        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    public func get<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> T {
        let request = try buildRequest(method: "GET", path: path, queryItems: queryItems)
        return try await execute(request)
    }

    public func getText(
        path: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> String {
        let request = try buildRequest(method: "GET", path: path, queryItems: queryItems)
        let (data, response) = try await performRequest(request)
        try validateResponse(response, data: data)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HTTPError.decodingFailed(
                NSError(
                    domain: "HTTPClient", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not decode response as UTF-8 text"]
                ))
        }
        return text
    }

    public func post<T: Decodable, B: Encodable>(
        path: String,
        body: B,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> T {
        var request = try buildRequest(method: "POST", path: path, queryItems: queryItems)
        request.httpBody = try encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await execute(request)
    }

    public func post<B: Encodable>(
        path: String,
        body: B,
        queryItems: [URLQueryItem]? = nil
    ) async throws {
        var request = try buildRequest(method: "POST", path: path, queryItems: queryItems)
        request.httpBody = try encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await executeVoid(request)
    }

    public func put<T: Decodable, B: Encodable>(
        path: String,
        body: B,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> T {
        var request = try buildRequest(method: "PUT", path: path, queryItems: queryItems)
        request.httpBody = try encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await execute(request)
    }

    public func put<B: Encodable>(
        path: String,
        body: B,
        queryItems: [URLQueryItem]? = nil
    ) async throws {
        var request = try buildRequest(method: "PUT", path: path, queryItems: queryItems)
        request.httpBody = try encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await executeVoid(request)
    }

    public func patch<T: Decodable, B: Encodable>(
        path: String,
        body: B,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> T {
        var request = try buildRequest(method: "PATCH", path: path, queryItems: queryItems)
        request.httpBody = try encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await execute(request)
    }

    public func delete<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> T {
        let request = try buildRequest(method: "DELETE", path: path, queryItems: queryItems)
        return try await execute(request)
    }

    public func delete(
        path: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws {
        let request = try buildRequest(method: "DELETE", path: path, queryItems: queryItems)
        try await executeVoid(request)
    }

    public func delete<T: Decodable, B: Encodable>(
        path: String,
        body: B,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> T {
        var request = try buildRequest(method: "DELETE", path: path, queryItems: queryItems)
        request.httpBody = try encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await execute(request)
    }

    public func download(
        path: String,
        to destination: URL
    ) async throws {
        let request = try buildRequest(method: "GET", path: path, queryItems: nil)
        let (tempURL, response) = try await session.download(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPError.unexpectedResponse("Not an HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw HTTPError.statusCode(httpResponse.statusCode, message: "Download failed")
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: tempURL, to: destination)
    }

    private func buildRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem]?
    ) throws -> URLRequest {

        let encodedPath = encodePathSegments(path)

        var components = URLComponents(
            url: baseURL.appendingPathComponent(encodedPath), resolvingAgainstBaseURL: true)
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw HTTPError.invalidURL(path)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method

        if let apiKey = apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        }

        return request
    }

    private func encodePathSegments(_ path: String) -> String {

        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        let encodedSegments = segments.map { segment -> String in

            let segmentString = String(segment)
            return segmentString.addingPercentEncoding(
                withAllowedCharacters: .urlPathComponentAllowed) ?? segmentString
        }
        return encodedSegments.joined(separator: "/")
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            throw HTTPError.encodingFailed(error)
        }
    }

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await performRequest(request)
        try validateResponse(response, data: data)

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw HTTPError.decodingFailed(error)
        }
    }

    private func executeVoid(_ request: URLRequest) async throws {
        let (data, response) = try await performRequest(request)
        try validateResponse(response, data: data)
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw HTTPError.networkError(error)
        }
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPError.unexpectedResponse("Not an HTTP response")
        }

        let statusCode = httpResponse.statusCode

        guard (200...299).contains(statusCode) else {
            let message = extractErrorMessage(from: data)

            switch statusCode {
            case 400:
                throw HTTPError.badRequest(message ?? "Bad request")
            case 401:
                throw HTTPError.unauthenticated
            case 403:
                throw HTTPError.permissionDenied
            case 404:
                if let message = message, message.lowercased().contains("collection") {
                    throw HTTPError.collectionNotFound(message)
                } else if let message = message, message.lowercased().contains("point") {
                    throw HTTPError.pointNotFound(message)
                }
                throw HTTPError.statusCode(statusCode, message: message)
            case 500...599:
                throw HTTPError.serverError(message ?? "Internal server error")
            default:
                throw HTTPError.statusCode(statusCode, message: message)
            }
        }
    }

    private func extractErrorMessage(from data: Data) -> String? {
        struct ErrorResponse: Decodable {
            let status: ErrorStatus?
            let message: String?

            struct ErrorStatus: Decodable {
                let error: String?
            }
        }

        if let errorResponse = try? decoder.decode(ErrorResponse.self, from: data) {
            return errorResponse.status?.error ?? errorResponse.message
        }

        return String(data: data, encoding: .utf8)
    }
}
