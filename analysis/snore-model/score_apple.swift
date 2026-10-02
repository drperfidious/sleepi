// Score Apple's built-in sound classifier on the refs/12 test set.
//   swiftc -O score_apple.swift -o work/score_apple && work/score_apple work/testset > apple_scores.csv
// Writes, per clip and condition, the highest confidence each label reached in any window.
// Same window duration (1.5 s, overlap 0.5) and label identifiers as sleepi's SoundProcessor; "snoring" and
// "cough" are the columns evaluate_apple.py reads. Identifiers checked against knownClassifications on this Mac.
import Foundation
import SoundAnalysis
import CoreMedia

let labels = ["snoring", "cough", "speech", "breathing", "sneeze", "laughter", "dog_bark", "door_slam", "car_horn", "glass_breaking"]
let windowSeconds = 1.5  // sleepi: request.windowDuration = CMTime(value: 3, timescale: 2)

final class MaxObserver: NSObject, SNResultsObserving {
    var maxes = [String: Double]()
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        for l in labels {
            if let c = r.classification(forIdentifier: l) { maxes[l] = max(maxes[l] ?? 0, c.confidence) }
        }
    }
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "testset")
let fm = FileManager.default
print((["condition", "file"] + labels).joined(separator: ","))
for cond in ["clean", "ac_10dB", "ac_5dB", "ac_0dB", "noise_only"] {
    let dir = root.appendingPathComponent(cond)
    let files = (try? fm.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".wav") }.sorted() ?? []
    for f in files {
        let req = try SNClassifySoundRequest(classifierIdentifier: .version1)
        req.windowDuration = CMTimeMakeWithSeconds(windowSeconds, preferredTimescale: 48_000)
        req.overlapFactor = 0.5
        let analyzer = try SNAudioFileAnalyzer(url: dir.appendingPathComponent(f))
        let obs = MaxObserver()
        try analyzer.add(req, withObserver: obs)
        analyzer.analyze() // synchronous: returns after every result has been delivered
        print(([cond, f] + labels.map { String(format: "%.4f", obs.maxes[$0] ?? 0) }).joined(separator: ","))
    }
}
