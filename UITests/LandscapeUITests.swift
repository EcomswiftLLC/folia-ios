import XCTest
import UIKit

/// Opens each screen on an iPad that has been rotated to landscape and saves a screenshot of it.
/// It fails when the app window does not end up wider than it is tall, so a rotation that silently
/// did not happen can never pass as a landscape check. Run by the `ipad-landscape` CI job.
final class LandscapeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    /// The simulator hands back its portrait frame buffer with a landscape picture lying on its side, so turn it upright.
    private func uprightScreenshot() -> UIImage {
        let image: UIImage = XCUIScreen.main.screenshot().image
        guard image.size.height > image.size.width else { return image }
        let size = CGSize(width: image.size.height, height: image.size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.rotate(by: -.pi / 2)
            image.draw(at: .zero)
        }
    }

    private func check(_ screen: String, settle: TimeInterval = 18, file: StaticString = #filePath, line: UInt = #line) {
        let app = XCUIApplication()
        app.launchArguments = ["-foScreen", screen]
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30), "No app window for \(screen)", file: file, line: line)

        // Give the rotation a few seconds, then let the screen finish loading its sample documents.
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline, window.frame.width <= window.frame.height {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(settle))

        let frame = window.frame
        let shot = XCTAttachment(image: uprightScreenshot())
        shot.name = "landscape-\(screen)"
        shot.lifetime = .keepAlways
        add(shot)

        XCTAssertGreaterThan(frame.width, frame.height, "\(screen): window is \(Int(frame.width))x\(Int(frame.height)), not landscape", file: file, line: line)
        XCTAssertTrue(app.state == .runningForeground, "\(screen): app left the foreground", file: file, line: line)
        app.terminate()
    }

    func testLibrary() { check("library") }
    func testLibraryEmpty() { check("library-empty", settle: 8) }
    func testDocument() { check("doc") }
    func testPage() { check("page") }
    func testCrop() { check("crop") }
    func testExport() { check("export") }
    func testTools() { check("tools") }
    func testSign() { check("sign") }
    func testText() { check("text", settle: 25) }
    func testSplit() { check("split") }
    func testCompress() { check("compress") }
    func testOnboarding() { check("onboarding", settle: 8) }
    func testSettings() { check("settings", settle: 8) }
}
