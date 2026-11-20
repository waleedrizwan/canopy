import Foundation
import Testing

@testable import CanopyCore

private let limits = ExposureLimits(minSeconds: 1.0 / 8000, maxSeconds: 1.0 / 27, minISO: 50, maxISO: 1600)

private func stats(_ linear: Double, saturated: Double = 0) -> FrameStats {
    FrameStats(
        meanEncodedLuma: 0, meanLinearR: linear, meanLinearG: linear, meanLinearB: linear,
        saturatedFraction: saturated, sampleCount: 100)
}

@Suite struct MeterTests {
    /// Integration: constant frames → variance < 0.5%.
    @Test func constantFramesAreStable() {
        var m = Meter(method: .lockedExposure, limits: limits, startIndex: 3)
        let e = m.ladder.steps[3]
        for i in 0..<30 {
            _ = m.ingest(MeterFrame(time: Double(i) / 27, stats: stats(0.3), reported: e))
        }
        let r = m.reading
        #expect(r.state == .live)
        #expect(r.signal.map { abs($0 - Signal.methodA(meanLinear: 0.3, exposure: e)) < 1e-9 } == true)
        var window = RollingStats(capacity: 30)
        m.recentSignals(seconds: 2).forEach { window.add($0) }
        #expect(window.values.count > 10 && (window.coefficientOfVariation ?? 1) < 0.005)
    }

    @Test func mismatchedFramesDropped() {
        var m = Meter(method: .lockedExposure, limits: limits, startIndex: 3)
        let wrong = Exposure(seconds: 1.0 / 1000, iso: 50)
        for i in 0..<20 {
            _ = m.ingest(MeterFrame(time: Double(i), stats: stats(0.3), reported: wrong))
        }
        #expect(m.reading.state == .adjusting && m.reading.signal == nil)
    }

    @Test func stepsDarkerAndHoldsLastGood() {
        var m = Meter(method: .lockedExposure, limits: limits, startIndex: 3)
        let e = m.ladder.steps[3]
        for i in 0..<10 { _ = m.ingest(MeterFrame(time: Double(i), stats: stats(0.3), reported: e)) }
        let good = m.reading.signal
        let cmd = m.ingest(MeterFrame(time: 11, stats: stats(0.7), reported: e))
        #expect(cmd == .setExposure(m.ladder.steps[4]))
        #expect(m.reading.state == .adjusting && m.reading.signal == nil && m.reading.held == good)
    }

    @Test func tooBrightAtDarkestStep() {
        var m = Meter(method: .lockedExposure, limits: limits, startIndex: 1000)
        let e = m.ladder.steps[m.ladderIndex]
        _ = m.ingest(MeterFrame(time: 0, stats: stats(0.9, saturated: 0.5), reported: e))
        #expect(m.reading.state == .tooBright && m.reading.signal == nil)
    }

    @Test func tooDarkAtBrightestStep() {
        var m = Meter(method: .lockedExposure, limits: limits, startIndex: 0)
        _ = m.ingest(MeterFrame(time: 0, stats: stats(0.001), reported: m.ladder.steps[0]))
        #expect(m.reading.state == .tooDark)
    }

    /// Stale values are never shown as live after an interruption.
    @Test func pauseAndResumeClearsReading() {
        var m = Meter(method: .lockedExposure, limits: limits, startIndex: 3)
        let e = m.ladder.steps[3]
        for i in 0..<10 { _ = m.ingest(MeterFrame(time: Double(i), stats: stats(0.3), reported: e)) }
        #expect(m.reading.signal != nil)
        m.pause(.interrupted)
        #expect(m.reading.state == .paused(.interrupted) && m.reading.signal == nil)
        _ = m.ingest(MeterFrame(time: 20, stats: stats(0.3), reported: e))
        #expect(m.reading.state == .paused(.interrupted))
        #expect(m.resume() == .setExposure(e))
        _ = m.ingest(MeterFrame(time: 21, stats: stats(0.3), reported: e))
        #expect(m.reading.state == .live && m.reading.signal == nil)
    }

    @Test func autoExposureSettledOnly() {
        var m = Meter(method: .autoExposure, limits: limits)
        let e = Exposure(seconds: 1.0 / 100, iso: 100)
        _ = m.ingest(MeterFrame(time: 0, stats: stats(0.2), reported: e, targetOffsetEV: 1.5))
        #expect(m.reading.state == .adjusting)
        for i in 1...10 {
            _ = m.ingest(MeterFrame(time: Double(i), stats: stats(0.2), reported: e, targetOffsetEV: 0.1))
        }
        #expect(m.reading.state == .live && m.reading.signal != nil)
    }

    @Test func thermalPolicy() {
        #expect(!ThermalLevel.fair.shouldPause)
        #expect(ThermalLevel.serious.shouldPause && ThermalLevel.critical.shouldPause)
    }
}

@Suite struct PersistenceTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("canopy-\(UUID().uuidString)/data.json")
    }

    @Test func roundTrip() throws {
        let store = VersionedFileStore(url: tempURL())
        #expect(try store.loadAppData() == nil)
        var data = AppData()
        data.settings.plantLightTypeID = "hps"
        try data.calibrations.set(1.1, for: SetupKey(camera: .back, diffuser: "none", lightType: "hps"))
        data.log.add(LogAndCSVTests.entries[0])
        data.heatmapInProgress = try Heatmap(rows: 3, columns: 3)
        try store.save(data)
        #expect(try store.loadAppData() == data)
    }

    /// Migration: a v1 file (as written by build 1) still loads.
    @Test func loadsSchemaV1() throws {
        let schemaV1 = """
            {"schemaVersion":1,"data":{"settings":{"camera":"front","diffuserID":"none","photoperiodHours":16},
            "calibrations":{"multipliers":[]},"log":{"entries":[]}}}
            """
        let data = try VersionedFileStore.decodeAppData(Data(schemaV1.utf8))
        #expect(data.settings.camera == .front && data.settings.photoperiodHours == 16 && !data.settings.reefMode)
    }

    @Test func refusesNewerSchema() {
        #expect(throws: VersionedFileStore.StoreError.newerSchema(99)) {
            try VersionedFileStore.decodeAppData(Data(#"{"schemaVersion":99,"data":{}}"#.utf8))
        }
    }

    @Test func plantAndReefLightTypesKeptSeparately() {
        var s = AppSettings(plantLightTypeID: "hps")
        s.reefMode = true
        s.activeLightTypeID = "reef-led"
        s.reefMode = false
        #expect(s.activeLightTypeID == "hps")
    }
}

@Suite struct LogBookTests {
    /// 100 entries listed newest first; delete and undo.
    @Test func ordering() throws {
        var book = LogBook()
        let base = LogAndCSVTests.entries[0]
        for i in 0..<100 {
            var e = base
            e.id = UUID()
            e.timestamp = Date(timeIntervalSince1970: Double((i * 7919) % 100) * 60)
            book.add(e)
        }
        let list = book.newestFirst
        #expect(list.count == 100)
        #expect(zip(list, list.dropFirst()).allSatisfy { $0.timestamp >= $1.timestamp })
        let first = try #require(list.first)
        let maybeDeletion = book.delete(id: first.id)
        let deletion = try #require(maybeDeletion)
        #expect(book.entries.count == 99)
        book.undo(deletion)
        #expect(book.entries.count == 100 && book.newestFirst.first?.id == first.id)
    }

    @Test func filters() {
        let book = LogBook(entries: LogAndCSVTests.entries)
        #expect(book.filtered(label: "Tomatoes").count == 1)
        #expect(book.filtered(lightType: "HPS").count == 1)
        #expect(book.filtered().count == 2)
        #expect(book.labels == ["Shelf, top", "Tomatoes"])
    }
}

@Suite struct CorpusTests {
    private func capture(_ frames: [RecordedCapture.Frame]) -> RecordedCapture {
        RecordedCapture(id: 1, method: "A", camera: .back, requestedFPS: 27, frames: frames)
    }

    private func frame(_ linear: Double, seconds: Double, iso: Double, offset: Double = 0, dropped: Bool = false)
        -> RecordedCapture.Frame
    {
        .init(t: 0, exifSeconds: seconds, exifISO: iso, targetOffsetEV: offset, stats: stats(linear), dropped: dropped)
    }

    @Test func replayRecomputesSignal() throws {
        let c = capture([frame(0.2, seconds: 0.01, iso: 200), frame(0.4, seconds: 0.01, iso: 200, dropped: true)])
        let s = try #require(CorpusReplay.signal(c, method: .lockedExposure))
        #expect(s.isApprox(10))
    }

    @Test func fitAndAgreement() throws {
        let k = try #require(CorpusReplay.fitKBase(pairs: [(10, 1000), (20, 2100), (40, 3900)]))
        #expect(k.isApprox(100))
        let pass = AgreementReport(predicted: [1000, 2000, 4000], reference: [1000, 2100, 3900])
        #expect(pass.passes)
        let fail = AgreementReport(predicted: [1000, 2000, 5000], reference: [1000, 2100, 3900])
        #expect(!fail.passes)
        #expect(!AgreementReport(predicted: [], reference: []).passes)
    }

    /// Spike capture files decode into the corpus format.
    @Test func decodesSpikeCaptureJSON() throws {
        let json = """
            {"id":3,"method":"A","camera":"back","requestedFPS":27,"createdAt":"2026-11-20T05:09:51Z",
             "frames":[{"t":1.5,"exifSeconds":0.037037,"exifISO":4000,"targetOffsetEV":2.6,"dropped":false,
               "stats":{"meanEncodedLuma":0.5,"meanLinearR":0.3,"meanLinearG":0.3,"meanLinearB":0.3,
                        "saturatedFraction":0,"sampleCount":10}}]}
            """
        let c = try JSONDecoder().decode(RecordedCapture.self, from: Data(json.utf8))
        #expect(c.meterFrames.count == 1 && c.meterFrames[0].reported?.iso == 4000)
    }
}
