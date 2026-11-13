import Foundation

/// Read-only adapter for Grok Bot's account-scoped weekly usage cache.
/// Never reads cookies, credentials, or conversation data, and never writes to Grok.
struct GrokFetcher {
    struct Reading: Equatable {
        let percentUsed: Double
        let resetDate: Date?
        let loadedAt: Date
        let expiresAt: Date
    }

    enum FetchError: LocalizedError {
        case unavailable
        case expired
        case unsupported

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Open Grok Bot, sign in, and open Plan & Usage to load your weekly allowance."
            case .expired:
                return "Grok's saved usage has expired. Open Plan & Usage in Grok Bot, then refresh here."
            case .unsupported:
                return "Couldn't read Grok Bot's saved weekly allowance. Open Plan & Usage in Grok Bot, then refresh here."
            }
        }
    }

    private struct Envelope<Value: Decodable>: Decodable {
        let schemaVersion: Int
        let value: Value
    }

    private struct Cache: Decodable {
        let kind: String
        let reading: SavedReading?
        let expiresAtMs: Double
    }

    private struct SavedReading: Decodable {
        let usage: Usage
        let readAtMs: Double
    }

    private struct Usage: Decodable {
        let percentUsed: Double
        let nextResetMs: Double?
        let hasNonZeroIncludedLimit: Bool
    }

    func fetch() async throws -> Reading {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grok Bot/sand-client-persistence")
        return try await Task.detached(priority: .utility) {
            try Self.read(directory: directory)
        }.value
    }

    static func read(directory: URL, now: Date = Date()) throws -> Reading {
        let decoder = JSONDecoder()
        func data(for key: String) throws -> Data {
            let file = directory.appendingPathComponent(base32(key) + ".blob")
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw FetchError.unavailable
            }
            return try Data(contentsOf: file)
        }

        do {
            let slot = try decoder.decode(Envelope<String>.self,
                from: data(for: "sand.client.slice.client-meta.account-slot"))
            guard slot.schemaVersion == 1, slot.value.hasPrefix("grok|"),
                  slot.value.count > 5 else { throw FetchError.unsupported }
            // Matches encodeURIComponent used by Grok's persistence registry.
            let allowed = CharacterSet(charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
            guard let account = slot.value.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw FetchError.unsupported
            }
            let cache = try decoder.decode(Envelope<Cache>.self,
                from: data(for: "sand.client.slice.account.\(account).weekly-usage.cache"))
            guard cache.schemaVersion == 2 else { throw FetchError.unsupported }
            guard cache.value.kind == "present", let saved = cache.value.reading,
                  saved.usage.hasNonZeroIncludedLimit else { throw FetchError.unavailable }
            let usage = saved.usage
            guard usage.percentUsed.isFinite, usage.percentUsed >= 0,
                  saved.readAtMs.isFinite, saved.readAtMs > 0,
                  saved.readAtMs <= now.timeIntervalSince1970 * 1000 + 60_000,
                  cache.value.expiresAtMs.isFinite,
                  cache.value.expiresAtMs > saved.readAtMs else { throw FetchError.unsupported }
            let expires = Date(timeIntervalSince1970: cache.value.expiresAtMs / 1000)
            let loaded = Date(timeIntervalSince1970: saved.readAtMs / 1000)
            let reset = usage.nextResetMs.map { Date(timeIntervalSince1970: $0 / 1000) }
            guard usage.nextResetMs.map({ $0.isFinite && $0 > saved.readAtMs }) ?? true else {
                throw FetchError.unsupported
            }
            // Never turn an old cycle's usage into a fresh zero after reset.
            guard expires > now, loaded.addingTimeInterval(24 * 3600) > now,
                  reset.map({ $0 > now }) ?? true else { throw FetchError.expired }
            // Recheck the active account in case it changed during the read.
            let current = try decoder.decode(Envelope<String>.self,
                from: data(for: "sand.client.slice.client-meta.account-slot"))
            guard current.value == slot.value else { throw FetchError.unavailable }
            return Reading(percentUsed: usage.percentUsed, resetDate: reset,
                           loadedAt: loaded, expiresAt: min(expires, loaded.addingTimeInterval(24 * 3600)))
        } catch let error as FetchError {
            throw error
        } catch {
            throw FetchError.unsupported
        }
    }

    /// Grok names persistence files with unpadded, lowercase RFC 4648 Base32.
    private static func base32(_ value: String) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var buffer = 0
        var bits = 0
        var result = ""
        for byte in value.utf8 {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                result.append(alphabet[(buffer >> bits) & 31])
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { result.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return result
    }
}
