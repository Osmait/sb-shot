import XCTest

final class SbShotUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppLaunches() {
        let app = XCUIApplication()
        app.launch()
    }
}
