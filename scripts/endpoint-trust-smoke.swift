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

        print("Endpoint trust smoke passed (\(cases.count) cases).")
    }
}
