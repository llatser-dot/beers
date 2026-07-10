import Foundation

@main
struct VocabularySmoke {
    static func main() {
        VocabularyCorrections.save([
            VocabularyCorrection(heard: "dot co dot uk", replacement: ".co.uk"),
            VocabularyCorrection(heard: "dot gov dot uk", replacement: ".gov.uk"),
            VocabularyCorrection(heard: "dot ac dot uk", replacement: ".ac.uk"),
            VocabularyCorrection(heard: "dot com", replacement: ".com"),
            VocabularyCorrection(heard: "dot info", replacement: ".info"),
            VocabularyCorrection(heard: "dot org", replacement: ".org"),
            VocabularyCorrection(heard: "dot net", replacement: ".net"),
            VocabularyCorrection(heard: "dot ai", replacement: ".ai"),
            VocabularyCorrection(heard: "dot io", replacement: ".io"),
            VocabularyCorrection(heard: "dot dev", replacement: ".dev"),
            VocabularyCorrection(heard: "dot co", replacement: ".co"),
            VocabularyCorrection(heard: "dot uk", replacement: ".uk"),
            VocabularyCorrection(heard: "dot", replacement: "."),
            VocabularyCorrection(heard: "Clio", replacement: "Cleo"),
            VocabularyCorrection(heard: "Kleo", replacement: "Cleo"),
            VocabularyCorrection(heard: "KLEO", replacement: "Cleo"),
            VocabularyCorrection(heard: "C L E O", replacement: "Cleo"),
            VocabularyCorrection(heard: "Latsa Listen", replacement: "Llatser Listen"),
            VocabularyCorrection(heard: "Latsa", replacement: "Llatser"),
            VocabularyCorrection(heard: "Latser", replacement: "Llatser"),
            VocabularyCorrection(heard: "Latsir", replacement: "Llatser"),
            VocabularyCorrection(heard: "Ladser", replacement: "Llatser")
        ])

        let input = CommandLine.arguments.dropFirst().joined(separator: " ")
        print(VocabularyCorrections.apply(to: input))
    }
}
