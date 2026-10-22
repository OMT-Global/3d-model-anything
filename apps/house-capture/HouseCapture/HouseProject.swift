import Foundation
import simd

/// A house scanned over several days (the Polycam "Extend" idea, but with one house-wide frame).
///
///     Documents/Houses/<id>/
///       house.json                           this struct
///       zones/<zone-id>/worldmap.arworldmap   latest ARWorldMap of the zone (NSKeyedArchiver)
///       sessions/<yyyy-MM-dd HH.mm.ss>/       one capture session = one ScanBundle (house-capture/5)
///
/// Frames: every session records in its own ARKit world. A **zone** is a few neighbouring rooms that
/// share one ARWorldMap (one map for the whole house hits RoomPlan's scene-size limit around 10
/// rooms). A session that relocalized against its zone's map is already in the zone frame
/// (`toZone` = identity); one that couldn't is "unaligned" until the Mac pipeline (ICP) or a manual
/// alignment fills in `toZone`. Each zone has a `toHouse`; the first zone defines the house frame.
///     point_house = zone.toHouse × session.alignment.toZone × point_session
/// Sessions are never rewritten after they finish (only their alignment in house.json changes);
/// "replace this room with a newer scan" just moves `Room.active`.
struct HouseProject: Codable, Identifiable {
  var format = "house-project/1"
  var id: String
  var name: String
  var createdAt: Date
  var zones: [Zone] = []
  var sessions: [Session] = []
  var rooms: [Room] = []

  struct Zone: Codable, Identifiable {
    var id: String
    var name: String
    /// relative to the house folder; nil until a session in this zone saved a map
    var worldMap: String?
    var worldMapUpdatedAt: Date?
    /// zone frame → house frame, column-major 4×4 (identity for the first zone)
    var toHouse: [Float] = matrix_identity_float4x4.columnMajor
    /// false for a zone whose placement in the house isn't known yet (Mac pipeline / manual alignment)
    var aligned: Bool
  }

  struct Session: Codable, Identifiable {
    /// the folder name, e.g. "2026-09-20 10.12.00"
    var id: String
    var zone: String
    var startedAt: Date
    var endedAt: Date?
    var alignment: Alignment
    /// RoomRecord indices captured in this session
    var rooms: [Int] = []
    /// Optional for older house-project/1 files; missing metadata is resolved from the bundle.
    var captureMode: CaptureMode?
    var folder: String { "sessions/\(id)" }
  }

  struct Alignment: Codable {
    /// "first" (started the zone), "relocalized" (ARWorldMap matched + verified against the saved
    /// mesh), "unaligned" (map didn't match; needs ICP/manual), "manual", "icp"
    var method: String
    /// session ARKit world → zone frame, column-major 4×4
    var toZone: [Float] = matrix_identity_float4x4.columnMajor
    /// median distance live mesh ↔ saved mesh after relocalizing (meters)
    var residualMeters: Float?
    var note: String?
  }

  struct Room: Codable, Identifiable {
    var id: String
    var name: String
    var zone: String
    /// the scan of this room currently used for the model
    var active: RoomRef?
    /// every scan of this room, oldest first (includes `active`)
    var history: [RoomRef] = []
  }

  struct RoomRef: Codable, Equatable {
    var session: String
    /// RoomRecord.index inside that session's bundle
    var index: Int
    var capturedAt: Date
  }
}

// MARK: - Disk

extension HouseProject {
  static var root: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Houses", isDirectory: true)
  }

  var url: URL { Self.root.appendingPathComponent(id, isDirectory: true) }

  static func create(name: String) throws -> HouseProject {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
    var house = HouseProject(id: formatter.string(from: Date()), name: name, createdAt: Date())
    for dir in ["zones", "sessions"] {
      try FileManager.default.createDirectory(at: house.url.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    try house.save()
    house = try HouseProject.load(url: house.url)
    return house
  }

  static func all() -> [HouseProject] {
    let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    return urls.filter(\.hasDirectoryPath).compactMap { try? load(url: $0) }.sorted { $0.createdAt > $1.createdAt }
  }

  static func load(url: URL) throws -> HouseProject {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var house = try decoder.decode(HouseProject.self, from: Data(contentsOf: url.appendingPathComponent("house.json")))
    // Early outdoor exports recorded mode only in manifest.json. Hydrate once per load,
    // so selection and history checks never mistake them for legacy indoor scans.
    for i in house.sessions.indices where house.sessions[i].captureMode == nil {
      let bundle = ScanBundle(url: url.appendingPathComponent(house.sessions[i].folder))
      if let manifest = bundle.manifest {
        house.sessions[i].captureMode = manifest.captureMode ??
          (manifest.rooms.contains { $0.captureMode == .outdoor } ? .outdoor : .indoor)
      }
    }
    return house
  }

  func save() throws {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    e.dateEncodingStrategy = .iso8601
    try e.encode(self).write(to: url.appendingPathComponent("house.json"), options: .atomic)
  }

  func delete() throws { try FileManager.default.removeItem(at: url) }

  func bundle(for session: Session) -> ScanBundle { ScanBundle(url: url.appendingPathComponent(session.folder, isDirectory: true)) }

  func zone(_ id: String) -> Zone? { zones.first { $0.id == id } }

  func worldMapURL(zone: Zone) -> URL? { zone.worldMap.map { url.appendingPathComponent($0) } }

  /// session ARKit world → house frame
  func toHouse(_ session: Session) -> simd_float4x4 {
    let zoneM = zone(session.zone).map { simd_float4x4(columnMajor: $0.toHouse) } ?? matrix_identity_float4x4
    return zoneM * simd_float4x4(columnMajor: session.alignment.toZone)
  }
}

extension simd_float4x4 {
  init(columnMajor m: [Float]) {
    precondition(m.count == 16)
    self.init(SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]), SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15]))
  }
}
