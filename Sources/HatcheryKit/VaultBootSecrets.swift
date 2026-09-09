import Foundation

/// This fetches a named secret from vault at boot through the app key.
/// A bearer of the app key retrieves the secret map and returns the named value or nil when absent.
public enum VaultBootSecrets {
    /// Describes a fetch error.
    /// - `refused`: vault returned 401 or 403.
    /// - `unreachable`: a transport error or a response status the vault does not document.
    /// - `unreadable`: the response body is not a map of secret names to values.
    public enum FetchError: Error, Sendable {
        case refused
        case unreachable
        case unreadable
    }

    /// Fetches a named secret from vault.
    /// The fetch uses `GET <baseURL>/api/apps/<app>/secrets` with `Authorization: Bearer <appKey>`.
    /// Retries `unreachable` and 502/503/504 status with delays 2, 4, 8, 16 seconds, then throws.
    /// A missing secret name returns nil the same as a key absent from the map.
    public static func fetch(
        baseURL: String,
        app: String,
        appKey: String,
        name: String,
        session: URLSession = .shared,
        delays: [TimeInterval] = [2, 4, 8, 16]
    ) async throws -> String? {
        guard let url = URL(string: "\(baseURL)/api/apps/\(app)/secrets") else {
            throw FetchError.unreadable
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(appKey)", forHTTPHeaderField: "Authorization")

        var lastError: FetchError = .unreachable
        for (index, delay) in delays.enumerated() {
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw FetchError.unreachable
                }

                switch httpResponse.statusCode {
                case 200:
                    break
                case 401, 403:
                    throw FetchError.refused
                case 502, 503, 504:
                    if index < delays.count {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }
                    throw FetchError.unreachable
                default:
                    throw FetchError.unreachable
                }

                let decoded = try JSONDecoder().decode([String: String].self, from: data)
                return decoded[name]
            } catch let error as FetchError {
                lastError = error
                if error == .refused {
                    throw error
                }
                if index < delays.count - 1 {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw error
            } catch {
                throw FetchError.unreadable
            }
        }

        throw lastError
    }
}
