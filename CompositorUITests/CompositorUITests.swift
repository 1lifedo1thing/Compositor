import XCTest

final class CompositorUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testCreateCanvasAndNewTab() throws {
        let app = XCUIApplication()
        app.launch()
        let width = app.textFields["widthInput"]
        width.click()
        width.typeKey("a", modifierFlags: .command)
        width.typeText("0")
        XCTAssertFalse(app.buttons["createCanvas"].isEnabled)
        width.typeKey("a", modifierFlags: .command)
        width.typeText("1200")
        let height = app.textFields["heightInput"]
        height.click()
        height.typeKey("a", modifierFlags: .command)
        height.typeText("800")
        app.buttons["createCanvas"].click()
        XCTAssertEqual(app.staticTexts["canvasDimensions"].value as? String, "1,200 × 800 px")
        app.buttons["actualPixels"].click()
        XCTAssertEqual(app.staticTexts["zoomStatus"].value as? String, "100%")
        app.typeKey("=", modifierFlags: .command)
        XCTAssertEqual(app.staticTexts["zoomStatus"].value as? String, "125%")
        app.buttons["fitCanvas"].click()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Editor foundation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.buttons["createCanvas"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func replace(_ field: XCUIElement, with text: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    @MainActor
    private func numericValue(_ field: XCUIElement) -> Double {
        let text = (field.value as? String ?? "").replacingOccurrences(of: ",", with: "")
        guard let value = Double(text) else {
            XCTFail("Expected a numeric field value, got \(String(describing: field.value))")
            return .nan
        }
        return value
    }

    @MainActor
    private func scrub(_ label: XCUIElement, by distance: CGFloat) {
        XCTAssertTrue(label.exists)
        let start = label.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.hover()
        start.click(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: distance, dy: 0)))
    }

    @MainActor
    func testNewCanvasWidthCanBeScrubbedAndTyped() throws {
        let app = XCUIApplication()
        app.launch()
        let width = app.textFields["widthInput"]
        let label = app.staticTexts["Width"]
        replace(width, with: "1000")
        app.staticTexts["New canvas"].click() // Commit the field before using the label.

        label.click()
        XCTAssertEqual(numericValue(width), 1000, "Clicking the label must not scrub")
        scrub(label, by: 80)
        XCTAssertEqual(numericValue(width), 1080, accuracy: 5, "A drag must use the original value once")
        scrub(label, by: -40)
        XCTAssertEqual(numericValue(width), 1040, accuracy: 5)

        replace(width, with: "2")
        app.staticTexts["New canvas"].click()
        scrub(label, by: -80)
        XCTAssertEqual(numericValue(width), 1)

        replace(width, with: "29990")
        app.staticTexts["New canvas"].click()
        scrub(label, by: 80)
        XCTAssertEqual(numericValue(width), 30_000)

        replace(width, with: "840")
        app.staticTexts["New canvas"].click()
        XCTAssertEqual(numericValue(width), 840, "The field must still accept typed values")
    }

    @MainActor
    func testLayerOpacityScrubIsOneUndoStep() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["createCanvas"].click()
        let opacity = app.textFields["Opacity percent"]
        XCTAssertTrue(opacity.waitForExistence(timeout: 5))
        XCTAssertEqual(numericValue(opacity), 100)

        scrub(app.staticTexts["Opacity"], by: -35)
        XCTAssertEqual(numericValue(opacity), 65, accuracy: 5)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(numericValue(opacity), 100, "One undo should restore the pre-drag opacity")
    }

    @MainActor
    func testCanvasSizeRelativeLockedWidthScrubUpdatesBothDimensions() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["createCanvas"].click()
        app.typeKey("c", modifierFlags: [.command, .option])
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        sheet.checkBoxes["Relative to current dimensions"].click()
        sheet.checkBoxes["Lock original aspect ratio"].click()
        let width = sheet.textFields["Width"]
        let height = sheet.textFields["Height"]
        XCTAssertEqual(numericValue(width), 0)
        XCTAssertEqual(numericValue(height), 0)

        scrub(sheet.staticTexts["Width"], by: 80)
        XCTAssertEqual(numericValue(width), 80, accuracy: 5)
        XCTAssertEqual(numericValue(height), 45, accuracy: 3)
        let summary = sheet.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "New:")).firstMatch.value as? String ?? ""
        let dimensions = summary.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "New: ", with: "")
            .components(separatedBy: " pixels")[0].components(separatedBy: " × ")
        XCTAssertEqual(dimensions.count, 2, "Expected both resulting canvas dimensions in \(summary)")
        if dimensions.count == 2 {
            XCTAssertEqual(Double(dimensions[0]) ?? .nan, 2000, accuracy: 5)
            XCTAssertEqual(Double(dimensions[1]) ?? .nan, 1125, accuracy: 3)
        }
        sheet.buttons["Cancel"].click()
    }

    @MainActor
    func testImageSizeInchesScrubWithAndWithoutResampling() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["createCanvas"].click()
        app.typeKey("i", modifierFlags: [.command, .option])
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        sheet.popUpButtons.firstMatch.click()
        app.menuItems["Inches"].click()

        let width = sheet.textFields["Width"]
        let height = sheet.textFields["Height"]
        let resolution = sheet.textFields["Resolution"]
        let originalWidth = numericValue(width)
        let originalHeight = numericValue(height)
        let originalResolution = numericValue(resolution)
        scrub(sheet.staticTexts["Width"], by: 72)
        XCTAssertEqual(numericValue(width), originalWidth + 1, accuracy: 0.08)
        XCTAssertGreaterThan(numericValue(height), originalHeight)
        XCTAssertEqual(numericValue(resolution), originalResolution, accuracy: 0.001)
        let resampledResult = sheet.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "Result:")).firstMatch.value as? String
        XCTAssertNotEqual(resampledResult, "Result: 1,920 × 1,080 pixels",
                          "Resampling should change the stored pixel dimensions")

        sheet.checkBoxes["Resample"].click()
        XCTAssertEqual(numericValue(width), originalWidth, accuracy: 0.01)
        XCTAssertTrue(sheet.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "Result: 1,920 × 1,080 pixels")).firstMatch.exists)
        scrub(sheet.staticTexts["Width"], by: 80)
        XCTAssertGreaterThan(numericValue(width), originalWidth)
        XCTAssertLessThan(numericValue(resolution), originalResolution)
        XCTAssertTrue(sheet.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "Result: 1,920 × 1,080 pixels")).firstMatch.exists,
                      "Without resampling, scrubbing physical width must preserve pixel dimensions")
        sheet.buttons["Cancel"].click()
    }

    @MainActor
    func testImageSizeRejectsNegativePhysicalResolutionWithoutCrashing() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["createCanvas"].click()
        app.typeKey("i", modifierFlags: [.command, .option])

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let units = sheet.popUpButtons.firstMatch
        XCTAssertTrue(units.exists)
        units.click()
        app.menuItems["Inches"].click()

        let resolution = sheet.textFields["Resolution"]
        XCTAssertTrue(resolution.exists)
        replace(resolution, with: "-5")
        sheet.staticTexts["Image Size"].click() // Commit the formatted TextField value.

        XCTAssertTrue(sheet.exists, "The sheet should remain open after an invalid resolution")
        XCTAssertFalse(sheet.buttons["Resize"].isEnabled)
        let widthLabel = sheet.staticTexts["Width"]
        let width = sheet.textFields["Width"]
        let unchangedWidth = width.value as? String
        XCTAssertFalse(widthLabel.isEnabled)
        scrub(widthLabel, by: 80)
        XCTAssertEqual(width.value as? String, unchangedWidth, "A disabled width label must not scrub")
        XCTAssertFalse(sheet.buttons["Resize"].isEnabled)

        sheet.buttons["Cancel"].click()
        XCTAssertFalse(sheet.exists)
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.buttons["Resize"].isEnabled)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // Explicit macOS baseline: includes XCTest launch/idle/accessibility overhead.
        let app = XCUIApplication()
        var samples: [Double] = []
        for _ in 0..<5 {
            app.terminate()
            let start = ProcessInfo.processInfo.systemUptime
            app.launch()
            XCTAssertTrue(app.staticTexts["New canvas"].waitForExistence(timeout: 5))
            samples.append(ProcessInfo.processInfo.systemUptime - start)
        }
        print("LAUNCH_TO_READY_SECONDS: \(samples)")
        print("LAUNCH_TO_READY_MEDIAN: \(samples.sorted()[2])")
    }
}
