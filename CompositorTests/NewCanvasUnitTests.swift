import Testing
@testable import Compositor

@MainActor struct NewCanvasUnitTests {
    /// Print sizes turn into pixels at the DPI: US Letter at 300 DPI is 2550 × 3300.
    @Test func printSizesBecomePixelsAtTheDPI() {
        #expect(NewCanvasUnit.inches.pixels("8.5", resolution: 300) == 2550)
        #expect(NewCanvasUnit.inches.pixels("11", resolution: 300) == 3300)
        #expect(NewCanvasUnit.millimeters.pixels("210", resolution: 300) == 2480, "A4's width")
        #expect(NewCanvasUnit.centimeters.pixels("2,54", resolution: 72) == 72, "a comma works as the decimal point")
        #expect(NewCanvasUnit.pixels.pixels("1920", resolution: 300) == 1920, "pixels ignore the DPI")
        #expect(NewCanvasUnit.pixels.pixels("19.5", resolution: 72) == nil, "pixels are whole")
        #expect(NewCanvasUnit.inches.pixels("200", resolution: 300) == nil, "60,000 pixels is past the side limit")
        #expect(NewCanvasUnit.inches.pixels("0", resolution: 300) == nil)
    }

    /// Switching units writes the same canvas another way, and the pill steps px → in → cm → mm → px.
    @Test func unitsRoundTripAndCycle() {
        #expect(NewCanvasUnit.inches.text(1920, resolution: 72) == "26.67")
        #expect(NewCanvasUnit.inches.text(2550, resolution: 300) == "8.5")
        #expect(NewCanvasUnit.millimeters.text(2480, resolution: 300) == "209.97")
        for unit in NewCanvasUnit.allCases where unit != .pixels {
            #expect(unit.pixels(unit.text(2550, resolution: 300), resolution: 300) == 2550, "\(unit)")
        }
        #expect(NewCanvasUnit.allCases.map(\.next) == [.inches, .centimeters, .millimeters, .pixels])
    }

    /// The chosen DPI is the document's, and goes into the saved project and exports.
    @Test func newProjectKeepsItsResolution() throws {
        let session = EditorSession()
        session.createNewProject(width: 2550, height: 3300, resolution: 300)
        #expect(session.document?.resolution == 300)
        #expect(try #require(session.projectSnapshot()).manifest.resolution == 300)
    }
}
