import Foundation

@main
enum EndpointTrustSmoke {
    static func main() {
        let cases: [(String, Bool)] = [
            ("http://localhost:11434/v1/chat/completions", true),
            ("http://127.0.0.1:11434/v1/chat/completions", true),
            ("http://127.255.255.254:11434/v1/chat/completions", true),
            ("http://[::1]:11434/v1/chat/completions", true),
            ("https://127.evil.example/v1/chat/completions", false),
            ("https://127.0.0.1.evil.example/v1/chat/completions", false),
            ("http://192.168.1.2:11434/v1/chat/completions", false),
            ("https://example.com/v1/chat/completions", false),
            ("file:///tmp/not-an-endpoint", false),
        ]

        for (endpoint, expected) in cases {
            let actual = AIEndpointTrust.isLoopback(endpoint: endpoint)
            guard actual == expected else {
                fputs("Endpoint trust failed for \(endpoint): expected \(expected), got \(actual)\n", stderr)
                exit(1)
            }
        }

        let originCases: [(String, String?)] = [
            ("https://api.example.com/v1/chat/completions", "https://api.example.com:443"),
            ("https://api.example.com:443/v1/chat/completions", "https://api.example.com:443"),
            ("http://api.example.com/v1/chat/completions", "http://api.example.com:80"),
            ("https://api.example.com:8443/v1/chat/completions", "https://api.example.com:8443"),
            ("not an endpoint", nil),
        ]

        for (endpoint, expected) in originCases {
            let actual = AIEndpointTrust.normalizedOrigin(from: endpoint)
            guard actual == expected else {
                fputs("Origin normalization failed for \(endpoint): expected \(expected ?? "nil"), got \(actual ?? "nil")\n", stderr)
                exit(1)
            }
        }

        let defaultHTTPS = AIEndpointTrust.normalizedOrigin(from: "https://api.example.com")
        let explicitHTTPS = AIEndpointTrust.normalizedOrigin(from: "https://api.example.com:443")
        guard defaultHTTPS == explicitHTTPS else {
            fputs("Default HTTPS port did not match explicit port 443\n", stderr)
            exit(1)
        }

        let plainHTTP = AIEndpointTrust.normalizedOrigin(from: "http://api.example.com")
        guard defaultHTTPS != plainHTTP else {
            fputs("HTTPS origin matched its HTTP downgrade\n", stderr)
            exit(1)
        }

        print("Endpoint trust smoke passed (\(cases.count) loopback cases, \(originCases.count) origin cases).")
    }
}
