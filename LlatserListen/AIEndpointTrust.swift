import Foundation

/// Pure endpoint classification kept separate so the privacy boundary can be
/// exercised without launching the app or touching the user's preferences.
enum AIEndpointTrust {
    static func normalizedHost(from endpoint: String) -> String? {
        guard let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased(),
              !host.isEmpty else {
            return nil
        }
        return host
    }

    static func isLoopback(host: String?) -> Bool {
        guard let host = host?
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased(), !host.isEmpty else { return false }

        if host == "localhost" || host == "::1" || host == "0:0:0:0:0:0:0:1" {
            return true
        }

        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets[0] == "127" else { return false }

        return octets.allSatisfy { octet in
            let scalars = octet.unicodeScalars
            guard !scalars.isEmpty,
                  scalars.allSatisfy({ (48...57).contains($0.value) }),
                  let value = Int(octet) else { return false }
            return value <= 255
        }
    }

    static func isLoopback(endpoint: String) -> Bool {
        isLoopback(host: normalizedHost(from: endpoint))
    }
}
