import Foundation
@main struct ModelWorkflowTests {
  @MainActor static func main() async {
    do { try await ModelWorkflowSelfTest.run(); print("WORKFLOW: all passed") }
    catch { print("WORKFLOW: FAIL \(error)"); exit(1) }
  }
}
