import XCTest

/// E2E smoke suite (spec section 8). Uses the simulated camera and the fake test
/// calibration: kBase 100, "Test LED" fLight 0.02, "Test HPS" fLight 0.0125.
/// Fixture S = 200 → 20,000 lx → 400 µmol/m²/s (LED) → DLI 17.3 at 12 h.
@MainActor
final class SmokeTests: XCTestCase {
    private func launch(signal: Double = 200, reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-fixtureSignal", "\(signal)", "-testCalibration"] + (reset ? ["-resetData"] : [])
        app.launch()
        return app
    }

    private func label(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.staticTexts[id]
    }

    private func waitForLabel(_ element: XCUIElement, _ text: String, timeout: TimeInterval = 5) -> Bool {
        let p = NSPredicate(format: "label == %@", text)
        return XCTWaiter.wait(for: [expectation(for: p, evaluatedWith: element)], timeout: timeout) == .completed
    }

    override func setUp() {
        continueAfterFailure = false
    }

    /// S-01 Launch → measure screen shows lux / PPFD / DLI from the fixture.
    func testS01MeasureScreen() {
        let app = launch()
        XCTAssertTrue(waitForLabel(label(app, "luxValue"), "20,000 lx"))
        XCTAssertEqual(label(app, "ppfdValue").label, "400 µmol/m²/s")
        XCTAssertEqual(label(app, "dliValue").label, "17.3 mol/m²/day")
        XCTAssertEqual(label(app, "stateLabel").label, "Live")
    }

    /// S-02 Select light type → relaunch → selection kept, PPFD reflects it.
    func testS02LightTypePersists() {
        var app = launch()
        app.buttons["lightTypeRow"].tap()
        app.buttons["lightType-test-hps"].tap()
        app.terminate()
        app = launch(reset: false)
        XCTAssertTrue(waitForLabel(label(app, "ppfdValue"), "250 µmol/m²/s"))
        let row = app.descendants(matching: .any).matching(identifier: "lightTypeRow").firstMatch
        XCTAssertTrue(row.label.contains("Test HPS"), "row label: \(row.label)")
    }

    /// S-03 Saturated and dark fixtures → "Too bright" / "Too dark", no number.
    func testS03TooBrightTooDark() {
        var app = launch(signal: 1e7)
        XCTAssertTrue(waitForLabel(label(app, "stateLabel"), "Too bright"))
        XCTAssertEqual(label(app, "luxValue").label, "—")
        app.terminate()
        app = launch(signal: 0.001)
        XCTAssertTrue(waitForLabel(label(app, "stateLabel"), "Too dark"))
        XCTAssertEqual(label(app, "luxValue").label, "—")
    }

    /// S-04 Calibrate 400 → 440: PPFD 440, lux unchanged.
    func testS04Calibrate() {
        let app = launch()
        XCTAssertTrue(waitForLabel(label(app, "ppfdValue"), "400 µmol/m²/s"))
        sleep(3)  // fill the 2 s stability window
        app.buttons["calibrateButton"].tap()
        let field = app.textFields["referenceField"]
        field.tap()
        field.typeText("440")
        app.buttons["confirmCalibrate"].tap()
        XCTAssertTrue(waitForLabel(label(app, "ppfdValue"), "440 µmol/m²/s"))
        XCTAssertEqual(label(app, "luxValue").label, "20,000 lx")
    }

    /// S-05 Heatmap 3×3, skip one → 8 cells + "no data"; stats exclude it.
    func testS05Heatmap() {
        let app = launch()
        app.tabBars.buttons["Map"].tap()
        app.buttons["startHeatmap"].tap()
        for i in 0..<9 {
            let button = i == 4 ? app.buttons["skipCell"] : app.buttons["recordCell"]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            let enabled = NSPredicate(format: "isEnabled == true")
            XCTAssertEqual(
                XCTWaiter.wait(for: [expectation(for: enabled, evaluatedWith: button)], timeout: 5), .completed)
            button.tap()
        }
        let cells = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'cell-'"))
        let labels = cells.allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(labels.filter { $0 == "400" }.count, 8, "cells: \(labels)")
        XCTAssertEqual(labels.filter { $0 == "no data" }.count, 1, "cells: \(labels)")
        let average = app.descendants(matching: .any).matching(identifier: "statAverage").firstMatch
        XCTAssertTrue(average.label.contains("400"), "average: \(average.label)")
        let uniformity = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '100%'"))
        XCTAssertTrue(uniformity.count > 0, "uniformity 100% not shown")
    }

    /// S-06 Save 3 readings → log → delete one → relaunch → 2 entries, newest first.
    func testS06Log() {
        var app = launch()
        XCTAssertTrue(waitForLabel(label(app, "dliValue"), "17.3 mol/m²/day"))
        for i in 1...3 {
            app.buttons["saveButton"].tap()
            let field = app.textFields["labelField"]
            field.tap()
            field.typeText("R\(i)")
            app.buttons["confirmSave"].tap()
            sleep(1)
        }
        app.tabBars.buttons["Log"].tap()
        let cells = app.collectionViews["logList"].cells
        XCTAssertEqual(cells.count, 3)
        cells.element(boundBy: 1).swipeLeft()
        app.buttons["Delete"].tap()
        app.terminate()
        app = launch(reset: false)
        app.tabBars.buttons["Log"].tap()
        let after = app.collectionViews["logList"].cells
        XCTAssertEqual(after.count, 2)
        XCTAssertTrue(
            after.element(boundBy: 0).staticTexts.element(matching: NSPredicate(format: "label BEGINSWITH 'R3'")).exists
        )
    }

    /// S-07 Export CSV → share sheet presented.
    func testS07ExportCSV() {
        let app = launch()
        XCTAssertTrue(waitForLabel(label(app, "dliValue"), "17.3 mol/m²/day"))
        app.buttons["saveButton"].tap()
        app.buttons["confirmSave"].tap()
        app.tabBars.buttons["Log"].tap()
        app.buttons["exportCSV"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 5))
    }

    /// S-08 Calculator DLI 20, PPFD 400 → 13.9 h.
    func testS08Calculator() {
        let app = launch()
        app.tabBars.buttons["Tools"].tap()
        app.buttons["hoursCalc"].tap()
        app.textFields["dliField"].tap()
        app.textFields["dliField"].typeText("20")
        app.textFields["ppfdField"].tap()
        app.textFields["ppfdField"].typeText("400")
        XCTAssertEqual(label(app, "hoursResult").label, "13.9 h")
    }
}
