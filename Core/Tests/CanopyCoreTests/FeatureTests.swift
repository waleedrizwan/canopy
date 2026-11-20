import Foundation
import Testing

@testable import CanopyCore

private let enUS = Locale(identifier: "en_US")

@Suite struct PipelineTests {
    @Test func signalToLux() {
        #expect(lux(signal: 250, kBase: 4) == .lux(1000))
    }

    @Test func luxFormatting() {
        #expect(Format.lux(Lux(12345.6), locale: enUS) == "12,346 lx")
    }

    @Test func ppfdFormatting() {
        #expect(Format.ppfd(PPFD(412.6), locale: enUS) == "413")
        #expect(Format.ppfd(PPFD(7.25), locale: enUS) == "7.3")
    }

    @Test(arguments: [(500.0, 12.0, 21.6), (0, 12, 0), (500, 24, 43.2)])
    func dli(ppfd: Double, hours: Double, expected: Double) throws {
        let d = Pipeline.dli(ppfd: PPFD(ppfd), photoperiod: try Photoperiod(hours: hours))
        #expect(abs(d.value - expected) < 1e-9)
    }

    @Test func photoperiodValidation() {
        #expect(throws: ValidationError.outOfRange(0...24)) { try Photoperiod(hours: -1) }
        #expect(throws: ValidationError.outOfRange(0...24)) { try Photoperiod(hours: 25) }
        #expect(throws: ValidationError.notAStep(0.5)) { try Photoperiod(hours: 12.3) }
        #expect((try? Photoperiod(hours: 12.5)) != nil)
    }

    @Test func kUserChangesPPFDNotLux() {
        let l = Lux(10_000)
        #expect(Pipeline.ppfd(lux: l, fLight: 0.02, kUser: 1.1).value.isApprox(220))
        #expect(l.value == 10_000)
    }

    @Test func parsing() {
        #expect(throws: ValidationError.empty) { try parseNumber("  ", locale: enUS) }
        #expect(throws: ValidationError.notANumber) { try parseNumber("abc", locale: enUS) }
        #expect((try? parseNumber("1,234.5", locale: enUS)) == 1234.5)
        #expect((try? parseNumber("12,5", locale: Locale(identifier: "de_DE"))) == 12.5)
    }
}

@Suite struct CalculatorTests {
    @Test func requiredHours() throws {
        guard case .hours(let h) = try Calculators.requiredHours(dli: DLI(20), ppfd: PPFD(400)) else {
            Issue.record("expected hours"); return
        }
        #expect(Format.hours(h, locale: enUS) == "13.9 h")
    }

    @Test func requiredPPFD() throws {
        let p = try Calculators.requiredPPFD(dli: DLI(20), hours: 16)
        #expect(abs(p.value - 347.2) < 0.05)
    }

    @Test func notReachable() throws {
        guard case .notReachable = try Calculators.requiredHours(dli: DLI(40), ppfd: PPFD(200)) else {
            Issue.record("expected not reachable"); return
        }
    }

    @Test func zeroAndBadInputRejected() {
        #expect(throws: ValidationError.zero) { try Calculators.requiredHours(dli: DLI(20), ppfd: PPFD(0)) }
        #expect(throws: ValidationError.zero) { try Calculators.requiredPPFD(dli: DLI(20), hours: 0) }
        #expect(throws: ValidationError.negative) { try Calculators.requiredPPFD(dli: DLI(-1), hours: 12) }
        #expect(throws: ValidationError.outOfRange(0...24)) { try Calculators.requiredPPFD(dli: DLI(20), hours: 25) }
        #expect(throws: ValidationError.notANumber) { try Calculators.requiredHours(dli: DLI(.nan), ppfd: PPFD(1)) }
        #expect(throws: ValidationError.zero) { try Calculators.ppfd(fromLux: Lux(1), fLight: 0, kUser: 1) }
    }

    @Test func converterUsesCalibratedFactor() throws {
        var cals = UserCalibrations()
        let key = SetupKey(camera: .back, diffuser: "none", lightType: "hps")
        try cals.set(1.1, for: key)
        let p = try Calculators.ppfd(fromLux: Lux(10_000), fLight: 0.0122, kUser: cals.kUser(for: key))
        let measureScreen = Pipeline.ppfd(lux: Lux(10_000), fLight: 0.0122, kUser: cals.kUser(for: key))
        #expect(p == measureScreen)
        let back = try Calculators.lux(fromPPFD: p, fLight: 0.0122, kUser: cals.kUser(for: key))
        #expect(back.value.isApprox(10_000))
    }
}

@Suite struct HeatmapTests {
    @Test func basicStats() {
        let s = HeatmapStats(values: [100, 200, 300])
        #expect(s.min == 100 && s.max == 300 && s.average == 200)
        #expect(s.uniformity == 0.5)
    }

    @Test func edgeCases() {
        let none = HeatmapStats(values: [])
        #expect(none.min == nil && none.average == nil && none.uniformity == nil)
        let zero = HeatmapStats(values: [0, 0, 0])
        #expect(zero.average == 0 && zero.uniformity == nil)
        let equal = HeatmapStats(values: [250, 250])
        #expect(equal.uniformity == 1 && equal.normalized(250) == 0.5)
    }

    @Test func skippedExcludedAndAllSkipped() throws {
        var h = try Heatmap(rows: 2, columns: 2)
        try h.record(PPFD(100), row: 0, column: 0, state: .live, tiltWarning: false)
        try h.skip(row: 0, column: 1)
        try h.record(PPFD(300), row: 1, column: 0, state: .live, tiltWarning: false)
        try h.record(PPFD(200), row: 1, column: 1, state: .live, tiltWarning: false)
        #expect(h.stats.average == 200)

        var allSkipped = try Heatmap(rows: 2, columns: 2)
        for r in 0..<2 { for c in 0..<2 { try allSkipped.skip(row: r, column: c) } }
        #expect(allSkipped.stats.average == nil && allSkipped.nextPending == nil)
    }

    @Test(arguments: [ReadingState.tooBright, .tooDark, .adjusting])
    func recordingBlocked(state: ReadingState) throws {
        var h = try Heatmap(rows: 2, columns: 2)
        #expect(throws: Heatmap.RecordError.blocked(state)) {
            try h.record(PPFD(1), row: 0, column: 0, state: state, tiltWarning: false)
        }
        #expect(throws: Heatmap.RecordError.tilted) {
            try h.record(PPFD(1), row: 0, column: 0, state: .live, tiltWarning: true)
        }
        #expect(h.cells.allSatisfy { $0 == .pending })
    }

    @Test func sizeLimits() {
        #expect((try? Heatmap(rows: 1, columns: 5)) == nil)
        #expect((try? Heatmap(rows: 11, columns: 5)) == nil)
        #expect((try? Heatmap(rows: 2, columns: 10)) != nil)
    }

    @Test func threeByThreeSkipOne() throws {
        var h = try Heatmap(rows: 3, columns: 3)
        var n = 0.0
        while let (r, c) = h.nextPending {
            if r == 1 && c == 1 {
                try h.skip(row: r, column: c)
            } else {
                n += 1
                try h.record(PPFD(n * 100), row: r, column: c, state: .live, tiltWarning: false)
            }
        }
        let measured = h.cells.filter { if case .measured = $0 { true } else { false } }
        #expect(measured.count == 8 && h.cells[4] == .skipped)
        #expect(h.stats.average == 450)
    }

    @Test func viridisEnds() {
        #expect(Viridis.color(0).red.isApprox(0.267))
        #expect(Viridis.color(1).blue.isApprox(0.144))
    }
}

@Suite struct UserCalibrationTests {
    let hpsBack = SetupKey(camera: .back, diffuser: "none", lightType: "hps")

    @Test func basic() throws {
        let outcome = try UserCalibrations.evaluate(reference: PPFD(440), uncalibrated: PPFD(400))
        guard case .accept(let k) = outcome else { Issue.record("expected accept"); return }
        #expect(k.isApprox(1.1))
        var cals = UserCalibrations()
        try cals.set(k, for: hpsBack)
        let lux = Lux(400 / 0.02)
        #expect(Pipeline.ppfd(lux: lux, fLight: 0.02, kUser: cals.kUser(for: hpsBack)).value.isApprox(440))
    }

    @Test func limits() throws {
        #expect(try UserCalibrations.evaluate(reference: PPFD(250), uncalibrated: PPFD(100)) == .needsConfirmation(2.5))
        #expect(throws: UserCalibrations.Refusal.outOfRange(12)) {
            try UserCalibrations.evaluate(reference: PPFD(1200), uncalibrated: PPFD(100))
        }
        #expect(throws: UserCalibrations.Refusal.zeroReading) {
            try UserCalibrations.evaluate(reference: PPFD(100), uncalibrated: PPFD(0))
        }
    }

    @Test func keying() throws {
        var cals = UserCalibrations()
        try cals.set(1.3, for: hpsBack)
        #expect(cals.kUser(for: SetupKey(camera: .back, diffuser: "none", lightType: "led")) == 1)
        #expect(cals.kUser(for: SetupKey(camera: .front, diffuser: "none", lightType: "hps")) == 1)
        cals.reset(hpsBack)
        #expect(cals.kUser(for: hpsBack) == 1)
    }

    @Test func roundTripsThroughJSON() throws {
        var cals = UserCalibrations()
        try cals.set(1.2, for: hpsBack)
        let decoded = try JSONDecoder().decode(UserCalibrations.self, from: JSONEncoder().encode(cals))
        #expect(decoded.kUser(for: hpsBack) == 1.2)
    }

    @Test func stability() {
        #expect(UserCalibrations.isStable([100, 101, 100.5]))
        #expect(!UserCalibrations.isStable([100, 105]))
        #expect(!UserCalibrations.isStable([0, 0, 0]))
    }

    @Test func customDiffuser() throws {
        #expect(try customDiffuserKBase(knownKBase: 2, signalWithKnown: 100, signalWithNew: 50) == 4)
        #expect(throws: ValidationError.zero) {
            try customDiffuserKBase(knownKBase: 2, signalWithKnown: 100, signalWithNew: 0)
        }
        #expect(throws: ValidationError.notANumber) {
            try customDiffuserKBase(knownKBase: .infinity, signalWithKnown: 100, signalWithNew: 1)
        }
    }

    @Test func tilt() {
        let up = Vector3(0, 0, -1)
        func g(_ deg: Double) -> Vector3 {
            let r = deg * .pi / 180
            return Vector3(sin(r), 0, -cos(r))
        }
        #expect(!isTiltWarning(degrees: tiltDegrees(gravity: g(5), reference: up)))
        #expect(isTiltWarning(degrees: tiltDegrees(gravity: g(15), reference: up)))
    }
}

@Suite struct LogAndCSVTests {
    static let plusOne = TimeZone(secondsFromGMT: 3600) ?? .gmt

    static let entries: [LogEntry] = [
        LogEntry(
            timestamp: Date(timeIntervalSince1970: 1_768_465_800),  // 2026-01-15T08:30:00Z
            lux: Lux(12345.678), ppfd: PPFD(228.4), dli: DLI(9.87), photoperiodHours: 12,
            lightType: "LED (full spectrum)", diffuser: "none", camera: .back,
            kBase: 2, fLight: 0.0185, kUser: 1.1, rawSignal: 6172.8, label: "Tomatoes"),
        LogEntry(
            timestamp: Date(timeIntervalSince1970: 1_768_507_530),  // 2026-01-15T20:05:30Z
            lux: Lux(0), ppfd: PPFD(0), dli: DLI(0), photoperiodHours: 24,
            lightType: "HPS", diffuser: "none", camera: .front,
            kBase: 2, fLight: 0.0122, kUser: 1, rawSignal: 0,
            label: "Shelf, top", note: "He said \"too bright\", then\nmoved it"),
    ]

    @Test func matchesGoldenFile() throws {
        let url = try #require(
            Bundle.module.url(forResource: "golden", withExtension: "csv", subdirectory: "Resources"))
        let golden = try String(contentsOf: url, encoding: .utf8)
        #expect(CSVExport.csv(Self.entries, timeZone: Self.plusOne) == golden)
    }

    @Test func awkwardNoteIsOneQuotedField() {
        #expect(CSVExport.field("a,b \"c\"\nd") == "\"a,b \"\"c\"\"\nd\"")
        #expect(CSVExport.field("plain") == "plain")
    }

    @Test func entriesAreSnapshots() throws {
        var cals = UserCalibrations()
        let key = SetupKey(camera: .back, diffuser: "none", lightType: "LED (full spectrum)")
        let saved = Self.entries[0]
        try cals.set(1.5, for: key)
        #expect(saved.kUser == 1.1 && saved.ppfd == PPFD(228.4))
    }

    @Test func entryRoundTripsThroughJSON() throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode([LogEntry].self, from: enc.encode(Self.entries))
        #expect(back == Self.entries)
    }
}

@Suite struct LightTypeTests {
    @Test func everyTypeHasFactorAndOrigin() throws {
        for t in try CalibrationConfig.bundled().lightTypes {
            #expect((t.fLight ?? 0) > 0, "\(t.id) has no factor")
            #expect(t.origin != nil, "\(t.id) has no origin")
        }
    }

    @Test func unverifiedTag() {
        let measured = LightType(
            id: "a", name: "A", group: "g", fLight: 0.02, origin: .measured(captureDate: "2026-11-20"))
        let published = LightType(id: "b", name: "B", group: "g", fLight: 0.02, origin: .published(citation: "x"))
        #expect(!measured.isUnverified && published.isUnverified)
    }
}

extension Double {
    func isApprox(_ other: Double, tolerance: Double = 1e-9) -> Bool {
        abs(self - other) <= tolerance * Swift.max(1, abs(other))
    }
}
