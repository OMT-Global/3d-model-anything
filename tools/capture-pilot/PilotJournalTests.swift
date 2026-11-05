import Foundation

@main struct PilotJournalTests {
  static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    print("PASS: \(message)")
  }
  static func triangle(_ x: Float) -> Data {
    var data = PilotMeshJournal.header(vertices: 3, faces: 1)
    func put<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
    for point: [Float] in [[x, 0, 0], [x + 1, 0, 0], [x, 1, 0]] {
      for value in point + [0, 0, 1, 0] { put(value) }
      for value: UInt8 in [255, 0, 0, 1] { put(value) }
    }
    put(UInt8(3)); put(UInt32(0)); put(UInt32(1)); put(UInt32(2)); put(UInt8(1))
    return data
  }
  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-journal-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for completed in 0..<21 {
      try expect(!CapturePilot.requiresFinish(completed: completed, largeMap: true, experimental: true), "room \(completed + 1) permitted without splitting a large pilot map")
    }
    try expect(CapturePilot.requiresFinish(completed: 21, largeMap: false, experimental: true), "pilot stops after configured 21 rooms")
    try expect(CapturePilot.requiresFinish(completed: 4, largeMap: false, experimental: false), "baseline four-room guardrail unchanged")
    try expect(CapturePilot.requiresFinish(completed: 0, largeMap: true, experimental: false), "baseline large-map guardrail unchanged")
    try expect(CapturePilot.requiresFinish(completed: 7, largeMap: false, experimental: true, roomLimit: 7), "pilot room guardrail configurable")
    let journal = try PilotMeshJournal(root: root.appendingPathComponent("journal"), room: 0)
    let id = UUID(), a = triangle(0), b = triangle(2)
    try journal.store(id: id, ply: a, vertices: 3, faces: 1, coveredArea: 0, totalArea: 1)
    try journal.store(id: id, ply: b, vertices: 3, faces: 1, coveredArea: 0, totalArea: 1)
    try journal.store(id: UUID(), ply: a, vertices: 3, faces: 1, coveredArea: 0, totalArea: 1)
    try journal.removed(id)
    let output = root.appendingPathComponent("room.ply")
    let result = try journal.export(to: output)
    try expect(result.vertices == 6 && result.faces == 2, "latest revision only plus second anchor exported")
    let data = try Data(contentsOf: output), start = data.range(of: Data("end_header\n".utf8))!.upperBound
    let face = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: start + 6 * 32 + 14 + 1, as: UInt32.self) }
    try expect(face == 3, "streamed faces remap vertex offsets")
    let restarted = try PilotMeshJournal(root: journal.root, room: 0)
    try expect(try restarted.entries().count == 2, "atomic pointers recover after process restart")
    let room1 = try PilotMeshJournal(root: journal.root, room: 1)
    try room1.store(id: id, ply: triangle(5), vertices: 3, faces: 1, coveredArea: 0, totalArea: 1)
    try expect(try restarted.entries().first { $0.anchor == id.uuidString }!.sha256 == PilotMeshJournal.digest(b), "later room cannot mutate earlier room evidence")
    // Orphan chunk simulates crash after immutable write but before pointer commit.
    let orphan = triangle(9)
    try orphan.write(to: journal.root.appendingPathComponent("chunks/\(PilotMeshJournal.digest(orphan)).ply"))
    try expect(try restarted.entries().count == 2, "interrupted pointer commit leaves previous complete revision")
    // Corruption must never replace a good prior export.
    try Data("damaged".utf8).write(to: journal.root.appendingPathComponent("chunks/\(PilotMeshJournal.digest(b)).ply"))
    do { _ = try restarted.export(to: output); throw NSError(domain: "expected rejection", code: 1) }
    catch let error as CocoaError { try expect(error.code == .fileReadCorruptFile, "hash mismatch fails closed") }
    try expect(try Data(contentsOf: output) == data, "failed export preserves existing output")
    print("PILOT JOURNAL TESTS PASSED")
  }
}
