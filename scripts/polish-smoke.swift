import Foundation

@main
struct PolishSmoke {
    static func main() {
        let input = CommandLine.arguments.dropFirst().joined(separator: " ")
        print(TranscriptPolisher.polish(input))
    }
}
