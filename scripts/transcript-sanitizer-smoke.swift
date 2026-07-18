import Foundation

@main
struct TranscriptSanitizerSmoke {
    static func main() {
        let cases = [
            ("Load onto my f mobile.", "Load onto my mobile."),
            ("I bought a mobile.", "I bought a mobile."),
            ("f Start again.", "Start again."),
            ("Use C++ with GPT-5.", "Use C++ with GPT-5."),
            ("Keep the\nspacing tidy.", "Keep the spacing tidy."),
        ]

        for (input, expected) in cases {
            let actual = TranscriptSanitizer.sanitize(input)
            guard actual == expected else {
                fputs("Transcript sanitiser failed: '\(input)' -> '\(actual)', expected '\(expected)'\n", stderr)
                exit(1)
            }
        }

        print("Transcript sanitiser smoke passed.")
    }
}
