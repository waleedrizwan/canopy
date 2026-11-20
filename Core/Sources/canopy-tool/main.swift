import CanopyCore
import Foundation

// Usage:
//   canopy-tool summary <dir>             per-capture S for both methods, repeatability
//   canopy-tool fit <dir> <method>        fit kBase from <dir>/references.json, report agreement
// <dir> holds capture-NNN.json files (pulled with `make pull-spike`).
// <method> is lockedExposure or autoExposure.

func loadCaptures(_ dir: URL) throws -> [RecordedCapture] {
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.hasPrefix("capture-") && $0.hasSuffix(".json") }.sorted()
    let decoder = JSONDecoder()
    return try names.map {
        try decoder.decode(RecordedCapture.self, from: Data(contentsOf: dir.appendingPathComponent($0)))
    }
}

func fmt(_ v: Double?, _ digits: Int = 4) -> String {
    v.map { String(format: "%.\(digits)g", $0) } ?? "—"
}

func summary(_ dir: URL) throws {
    print("id  camera method fps  frames  S_A        S_B")
    for c in try loadCaptures(dir) {
        let a = CorpusReplay.signal(c, method: .lockedExposure)
        let b = CorpusReplay.signal(c, method: .autoExposure)
        func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }
        print(
            pad("\(c.id)", 4) + pad(c.camera.rawValue, 7) + pad(c.method, 7) + pad("\(Int(c.requestedFPS))", 5)
                + pad("\(c.meterFrames.count)", 8) + pad(fmt(a), 11) + fmt(b))
    }
}

func fit(_ dir: URL, method: SignalMethod) throws {
    let captures = Dictionary(uniqueKeysWithValues: try loadCaptures(dir).map { ($0.id, $0) })
    let refs = try JSONDecoder().decode(
        [ReferenceReading].self, from: Data(contentsOf: dir.appendingPathComponent("references.json")))
    var pairs: [(signal: Double, referenceLux: Double)] = []
    var rows: [(ReferenceReading, Double)] = []
    for r in refs {
        guard let c = captures[r.captureID], let s = CorpusReplay.signal(c, method: method) else {
            print("capture \(r.captureID): no usable signal for \(method.rawValue), skipped")
            continue
        }
        pairs.append((s, r.lux))
        rows.append((r, s))
    }
    guard let k = CorpusReplay.fitKBase(pairs: pairs) else {
        print("no usable pairs")
        return
    }
    print("method \(method.rawValue): kBase = \(fmt(k, 6)) from \(pairs.count) captures")
    print("id  ref_lux    ours_lux   error")
    for (r, s) in rows {
        let ours = s * k
        print(String(format: "%-3d %-10.0f %-10.0f %+.1f%%", r.captureID, r.lux, ours, (ours - r.lux) / r.lux * 100))
    }
    let report = AgreementReport(predicted: rows.map { $0.1 * k }, reference: rows.map { $0.0.lux })
    print(
        "median error \(fmt(report.median.map { $0 * 100 }, 3))%, max \(fmt(report.max.map { $0 * 100 }, 3))%"
            + " → \(report.passes ? "PASSES" : "FAILS") target"
            + " (median ≤ \(Provisional.agreementMedianMaxError * 100)%,"
            + " max ≤ \(Provisional.agreementSingleMaxError * 100)%)"
    )
    print("note: kBase fitted and checked on the same captures; hold some out before trusting it.")
}

let args = CommandLine.arguments
do {
    switch (args.count > 1 ? args[1] : "", args.count) {
    case ("summary", 3):
        try summary(URL(fileURLWithPath: args[2]))
    case ("fit", 4):
        guard let m = SignalMethod(rawValue: args[3]) else { throw CocoaError(.formatting) }
        try fit(URL(fileURLWithPath: args[2]), method: m)
    default:
        print("usage: canopy-tool summary <dir> | canopy-tool fit <dir> lockedExposure|autoExposure")
        exit(2)
    }
} catch {
    print("error: \(error)")
    exit(1)
}
