import XCTest

final class WorkflowUITests: XCTestCase {
  func testInterruptedModelEditApprovePublishAndReopen() {
    let app = XCUIApplication()
    app.launchArguments = ["-workflow-demo", "-workflow-demo-id", UUID().uuidString]
    app.launch()
    let start = app.buttons["Start synthetic model"]
    XCTAssertTrue(start.waitForExistence(timeout: 10)); start.tap()
    XCTAssertTrue(app.staticTexts["Building synthetic room…"].waitForExistence(timeout: 5))
    app.terminate(); app.launch()
    let edit = app.buttons["Edit this revision"]
    XCTAssertTrue(edit.waitForExistence(timeout: 10)); edit.tap()
    XCTAssertTrue(app.navigationBars["Edit model"].waitForExistence(timeout: 5))
    let label = app.textFields["Room label"]
    label.tap()
    label.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Synthetic studio".count) + "Synthetic revision")
    app.buttons["Save revision"].tap()
    XCTAssertTrue(app.buttons["Edit this revision"].waitForExistence(timeout: 5))
    app.segmentedControls.buttons["Publish"].tap()
    let approve = app.buttons["Approve this revision"]
    XCTAssertTrue(approve.waitForExistence(timeout: 5)); approve.tap()
    let publish = app.buttons["Publish demo locally"]
    app.swipeUp()
    XCTAssertTrue(publish.waitForExistence(timeout: 5)); publish.tap()
    let confirm = app.buttons.matching(identifier: "Publish demo locally").allElementsBoundByIndex.last!
    XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
    let published = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Last working demo:'")).firstMatch
    XCTAssertTrue(published.waitForExistence(timeout: 8))
    app.terminate(); app.launch()
    app.segmentedControls.buttons["Publish"].tap()
    XCTAssertTrue(published.waitForExistence(timeout: 8))
    let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Synthetic-approved-publication"; screenshot.lifetime = .keepAlways; add(screenshot)
  }

  func testUnconfiguredCloudAndSiteAreExplicitlyGated() {
    let app = XCUIApplication(); app.launchArguments = ["-workflow-gated"]; app.launch()
    XCTAssertTrue(app.staticTexts["Setup required"].waitForExistence(timeout: 10))
    let noRepositorySetup = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "will not ask you to create a GitHub account or repository")).firstMatch
    XCTAssertTrue(noRepositorySetup.exists)
    let modelGate = XCTAttachment(screenshot: app.screenshot()); modelGate.name = "Repo-free-cloud-setup-gate"; modelGate.lifetime = .keepAlways; add(modelGate)
    XCTAssertFalse(app.buttons["Start synthetic model"].exists)
    app.segmentedControls.buttons["Publish"].tap()
    XCTAssertTrue(app.staticTexts["Publish to your private Site"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Setup required"].exists)
    let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Protected-site-setup-gate"; screenshot.lifetime = .keepAlways; add(screenshot)
  }
}
