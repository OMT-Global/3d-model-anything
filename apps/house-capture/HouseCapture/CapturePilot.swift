import Foundation
import CryptoKit

/// The regular product cannot opt into the experimental policy at runtime.
enum CapturePilot {
  static var available: Bool {
#if CAPTURE_PILOT
    return Bundle.main.bundleIdentifier == "com.jmcte.housecapture.capturepilot"
#else
    return false
#endif
  }
  static let meshBytes = 24 * 1_048_576
  static let pendingBytes = 8 * 1_048_576
  static let maxAnchors = 48
  static let maxPhotos = 64
  static func requiresFinish(completed: Int, largeMap: Bool, experimental: Bool, roomLimit: Int = 21) -> Bool {
    experimental ? completed >= min(21, max(4, roomLimit)) : largeMap || completed >= 4
  }
}

/// Immutable, hash-addressed evidence plus atomic per-room latest-anchor pointers.
/// A crash before a pointer rename leaves an unused chunk; the previous pointer remains valid.
/// No chunks are automatically deleted. All methods run on the coverage worker queue.
final class PilotMeshJournal {
  struct Entry: Codable {
    var format = "capture-pilot-mesh/1"
    var anchor: String
    var chunk: String
    var sha256: String
    var vertices: Int
    var faces: Int
    var coveredArea: Float
    var totalArea: Float
  }
  let root: URL
  let room: Int
  private let directory: URL
  init(root: URL, room: Int) throws {
    self.root = root
    self.room = room
    directory = root.appendingPathComponent("room-\(room)/anchors")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("chunks"), withIntermediateDirectories: true)
  }
  static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  func store(id: UUID, ply: Data, vertices: Int, faces: Int, coveredArea: Float, totalArea: Float) throws {
    let hash = Self.digest(ply)
    let path = "chunks/\(hash).ply"
    let destination = root.appendingPathComponent(path)
    if !FileManager.default.fileExists(atPath: destination.path) { try ply.write(to: destination, options: .atomic) }
    let entry = Entry(anchor: id.uuidString, chunk: path, sha256: hash, vertices: vertices, faces: faces, coveredArea: coveredArea, totalArea: totalArea)
    try JSONEncoder().encode(entry).write(to: directory.appendingPathComponent("\(id).json"), options: .atomic)
  }
  func removed(_ id: UUID) throws {
    // Preserve the last geometry; removal is an observation, not authority to erase evidence.
    let dir = root.appendingPathComponent("room-\(room)/removed")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("{\"anchor\":\"\(id)\",\"preserved\":true}".utf8).write(to: dir.appendingPathComponent("\(id).json"), options: .atomic)
  }
  func entries() throws -> [Entry] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
      .map { try JSONDecoder().decode(Entry.self, from: Data(contentsOf: $0)) }
  }
  private func body(_ entry: Entry) throws -> Data {
    guard entry.chunk == "chunks/\(entry.sha256).ply", entry.sha256.count == 64,
          entry.sha256.allSatisfy({ $0.isHexDigit }), entry.vertices >= 0, entry.faces >= 0 else { throw CocoaError(.fileReadCorruptFile) }
    let data = try Data(contentsOf: root.appendingPathComponent(entry.chunk))
    guard Self.digest(data) == entry.sha256, let range = data.range(of: Data("end_header\n".utf8)) else { throw CocoaError(.fileReadCorruptFile) }
    let body = data.subdata(in: range.upperBound..<data.count)
    guard body.count == entry.vertices * 32 + entry.faces * 14 else { throw CocoaError(.fileReadCorruptFile) }
    return body
  }
  static func header(vertices: Int, faces: Int) -> Data {
    Data(("ply\nformat binary_little_endian 1.0\ncomment capture-pilot ARKit world metres +Y up; latest observed anchor per room\n" +
      "element vertex \(vertices)\nproperty float x\nproperty float y\nproperty float z\nproperty float nx\nproperty float ny\nproperty float nz\nproperty float coverage\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nproperty uchar inroom\n" +
      "element face \(faces)\nproperty list uchar uint vertex_indices\nproperty uchar class\nend_header\n").utf8)
  }
  /// Streaming assembly retains only one bounded anchor chunk, never the complete house mesh.
  func export(to destination: URL) throws -> (vertices: Int, faces: Int, covered: Float) {
    let list = try entries()
    let vertices = list.reduce(0) { $0 + $1.vertices }, faces = list.reduce(0) { $0 + $1.faces }
    guard vertices <= Int(UInt32.max) else { throw CocoaError(.fileWriteOutOfSpace) }
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID()).ply")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try Self.header(vertices: vertices, faces: faces).write(to: temporary)
    let handle = try FileHandle(forWritingTo: temporary)
    defer { try? handle.close() }
    try handle.seekToEnd()
    for entry in list { try handle.write(contentsOf: body(entry).prefix(entry.vertices * 32)) }
    var offset: UInt32 = 0
    for entry in list {
      let data = try body(entry)
      var faces = Data(data.dropFirst(entry.vertices * 32))
      for f in 0..<entry.faces {
        guard faces[f * 14] == 3 else { throw CocoaError(.fileReadCorruptFile) }
        for corner in 0..<3 {
          let start = f * 14 + 1 + corner * 4
          let index = faces.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: start, as: UInt32.self).littleEndian }
          guard index < entry.vertices else { throw CocoaError(.fileReadCorruptFile) }
          var adjusted = (index + offset).littleEndian
          withUnsafeBytes(of: &adjusted) { faces.replaceSubrange(start..<start + 4, with: $0) }
        }
      }
      try handle.write(contentsOf: faces)
      offset += UInt32(entry.vertices)
    }
    try handle.synchronize()
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    } else { try FileManager.default.moveItem(at: temporary, to: destination) }
    let total = list.reduce(Float(0)) { $0 + $1.totalArea }
    return (vertices, faces, total > 0 ? list.reduce(Float(0)) { $0 + $1.coveredArea } / total : 0)
  }
}

/// Main-actor-owned admission tokens prevent a stale prior-photo load from crossing a mode change.
struct PriorPhotoLoadGate {
  private var generation = 0
  private var pending: Int?
  private var loaded = false
  mutating func invalidate() { generation += 1; pending = nil; loaded = false }
  mutating func request(allowed: Bool) -> Int? {
    guard allowed, !loaded, pending == nil else { return nil }
    generation += 1; pending = generation
    return generation
  }
  mutating func accept(_ token: Int, allowed: Bool) -> Bool {
    guard allowed, pending == token else { return false }
    pending = nil; loaded = true
    return true
  }
}
