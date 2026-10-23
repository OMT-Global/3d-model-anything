import Foundation

/// Synthetic-only persistence/transport regression tests, also runnable with swiftc on the Mac.
@MainActor enum ModelWorkflowSelfTest {
  static func run() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func check(_ condition: Bool, _ message: String) throws {
      guard condition else { throw WorkflowError.rejected("Workflow regression: " + message) }
      print("WORKFLOW: ok " + message)
    }
    let backendURL = root.appendingPathComponent("backend.json")
    let cacheURL = root.appendingPathComponent("cache.json")
    let backend = try SyntheticWorkflowTransport(roomID: "test", url: backendURL)
    let transport = LostResponseTransport(backend)
    var session = try WorkflowSession(roomID: "test", url: cacheURL, transport: transport)
    let model = WorkflowCommand(kind: "model", scanID: "synthetic-scan")
    await session.send(model)
    try check(session.pending == model, "lost response retains original request ID")
    session = try WorkflowSession(roomID: "test", url: cacheURL, transport: transport)
    await session.resume()
    try check(session.pending == nil && session.state.jobs.count == 1, "restart replays once without a duplicate job")
    await session.send(model)
    try check(session.state.jobs.count == 1, "repeated command is idempotent")
    await session.refresh()
    session = try WorkflowSession(roomID: "test", url: cacheURL, transport: SyntheticWorkflowTransport(roomID: "test", url: backendURL))
    try check(session.state.jobs.first?.state == "running", "interrupted progress survives reopening")
    await session.refresh()
    guard let original = session.state.revisions.first else { throw WorkflowError.invalidModel }
    try check(original.document == .synthetic, "synthetic geometry is previewable")
    await session.send(.init(kind: "publish", revisionID: original.id))
    try check(session.state.publishedRevisionID == nil, "unapproved publication is rejected")
    await session.send(.init(kind: "approve", revisionID: original.id))
    await session.send(.init(kind: "publish", revisionID: original.id))
    await session.refresh()
    try check(session.state.publishedRevisionID == original.id, "approved revision publishes locally")
    var edited = original.document; edited.objects[3].position[0] = 1.25
    await session.send(.init(kind: "edit", baseRevisionID: original.id, document: edited))
    try check(session.state.revisions.count == 2 && session.state.revisions.last?.approved == false, "editing creates a separately approved revision")
    try check(session.state.revisions.first?.document == original.document && session.state.publishedRevisionID == original.id, "original and last working publication are retained")
    try check(session.state.revisions.last?.parentID == original.id, "revision provenance retained")
    let invalidURL = URL(string: "http://unsafe.example")!
    do { _ = try RemoteWorkflowTransport(baseURL: invalidURL, roomID: "test", authorization: { "unused" }); throw WorkflowError.rejected("HTTP accepted") }
    catch WorkflowError.setupRequired { print("WORKFLOW: ok insecure endpoint rejected") }
    var bad = edited; bad.objects[0].position[0] = .infinity
    do { try bad.validate(); throw WorkflowError.rejected("Invalid geometry accepted") }
    catch WorkflowError.invalidModel { print("WORKFLOW: ok invalid geometry rejected") }
    try Data("invalid cache".utf8).write(to: cacheURL, options: .atomic)
    do { _ = try WorkflowSession(roomID: "test", url: cacheURL, transport: backend); throw WorkflowError.rejected("Cache silently reset") }
    catch is DecodingError { print("WORKFLOW: ok damaged cache surfaced without reset") }
  }
}

@MainActor private final class LostResponseTransport: WorkflowTransport {
  let backend: any WorkflowTransport
  var loseOnce = true
  init(_ backend: any WorkflowTransport) { self.backend = backend }
  func snapshot() async throws -> WorkflowSnapshot { try await backend.snapshot() }
  func advance() async throws -> WorkflowSnapshot { try await backend.advance() }
  func command(_ command: WorkflowCommand) async throws -> WorkflowSnapshot {
    let result = try await backend.command(command)
    if loseOnce { loseOnce = false; throw URLError(.networkConnectionLost) }
    return result
  }
}
