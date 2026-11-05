import Foundation
import CryptoKit
import simd

/// Optional, version-bound landmarks. These are never written into CapturedRoom JSON.
struct ConnectionLandmarks: Codable {
  static let filename = "connection-landmarks.json"
  var format = "offline-doorway-annotations/1"
  var house_id: String
  var review_only: Bool
  var landmarks: [Landmark]
  var floorAnchors: [FloorAnchor]?
  struct Binding: Codable {
    var room_id: String
    var active_ref: HouseProject.RoomRef
    var target_room_sha256: String
    func matches(_ room: HouseProject.Room, data: Data) -> Bool {
      room_id == room.id && active_ref == room.active && target_room_sha256 == ConnectionMath.hash(data)
    }
  }
  struct Landmark: Codable {
    var id: String
    var label: String
    var room_id: String
    var active_ref: HouseProject.RoomRef
    var target_room_sha256: String
    var width_m: Float
    var height_m: Float
    var transform: [Float]
    var binding: Binding { .init(room_id: room_id, active_ref: active_ref, target_room_sha256: target_room_sha256) }
  }
  struct FloorAnchor: Codable {
    var binding: Binding
    var height: Float
    var note: String
  }
  static func load(house: HouseProject) -> ConnectionLandmarks? {
    guard let data = try? Data(contentsOf: house.url.appendingPathComponent(filename)),
          let value = try? decode(data), value.house_id == house.id else { return nil }
    return value
  }
  static func decode(_ data: Data) throws -> ConnectionLandmarks {
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let value = try decoder.decode(Self.self, from: data)
    guard value.format == "offline-doorway-annotations/1", Set(value.landmarks.map(\.id)).count == value.landmarks.count else { throw ConnectionMath.Failure.invalid }
    return value
  }
  func doors(room: HouseProject.Room, data: Data, capturedIDs: Set<String>) -> [RoomDoor] {
    landmarks.filter { $0.binding.matches(room, data: data) && !capturedIDs.contains($0.id) }.compactMap {
      guard $0.width_m.isFinite, $0.width_m > 0.2, $0.width_m < 4,
            $0.height_m.isFinite, $0.height_m > 0,
            let matrix = ConnectionMath.rigid($0.transform) else { return nil }
      return RoomDoor(id: $0.id, width: $0.width_m, transform: matrix, height: $0.height_m,
                      label: $0.label, reviewOnly: review_only)
    }
  }
  func floor(room: HouseProject.Room, data: Data) -> FloorAnchor? {
    let matches = (floorAnchors ?? []).filter { $0.binding.matches(room, data: data) && $0.height.isFinite }
    return matches.count == 1 ? matches[0] : nil
  }
}

enum ConnectionMath {
  enum Failure: LocalizedError {
    case invalid, stale, reviewOnly, pendingUndo
    var errorDescription: String? {
      switch self {
      case .invalid: return "The connection data is invalid. The house has not been changed."
      case .stale: return "The house or connection data changed. Reopen the connection and preview it again."
      case .reviewOnly: return "These landmarks are for review only. Verify them before saving a connection."
      case .pendingUndo: return "An interrupted undo needs recovery. Use Undo last saved connection, then preview your connection again."
      }
    }
  }
  static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  static func encoded(_ house: HouseProject) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(house)
  }
  static func rigid(_ values: [Float]) -> simd_float4x4? {
    guard values.count == 16, values.allSatisfy(\.isFinite) else { return nil }
    let m = simd_float4x4(columnMajor: values), x = SIMD3(m.columns.0.x,m.columns.0.y,m.columns.0.z),
        y = SIMD3(m.columns.1.x,m.columns.1.y,m.columns.1.z), z = SIMD3(m.columns.2.x,m.columns.2.y,m.columns.2.z)
    guard simd_length(y-SIMD3(0,1,0)) < 0.0001, abs(simd_length(x)-1) < 0.0001,
          abs(simd_length(z)-1) < 0.0001, abs(simd_dot(x,z)) < 0.0001,
          simd_dot(simd_cross(x,y),z) > 0.9999,
          abs(m.columns.0.w)+abs(m.columns.1.w)+abs(m.columns.2.w)+abs(m.columns.3.w-1) < 0.0001 else { return nil }
    return m
  }
  static func floorAware(source: RoomDoor, target: RoomDoor, sourceFloor: Float, targetFloor: Float, flip: Bool) -> simd_float4x4? {
    guard sourceFloor.isFinite, targetFloor.isFinite, usableWidth(source.width), usableWidth(target.width), abs(source.width-target.width) < 0.2,
          rigid(source.transform.columnMajor) != nil, rigid(target.transform.columnMajor) != nil else { return nil }
    let turn = simd_float4x4(simd_quatf(angle: flip ? .pi : 0, axis: SIMD3(0,1,0)))
    var transform = target.transform * turn * source.transform.inverse
    transform.columns.3.y = targetFloor-sourceFloor
    return rigid(transform.columnMajor)
  }
  static func usableWidth(_ width: Float) -> Bool { width.isFinite && width > 0.2 && width < 4 }
  static func usableHeight(_ height: Float?) -> Bool {
    guard let height else { return false }
    return height.isFinite && height >= 1 && height < 3.5
  }
  /// Only infer a floor at a plausible door bottom. Tall/short detections need a bound guide.
  static func inferredFloor(door: RoomDoor, json: [String: Any]) -> Float? {
    guard usableHeight(door.height), let height = door.height,
          let floors = json["floors"] as? [[String: Any]], floors.count == 1,
          let transform = RoomJSON.floats(floors[0]["transform"]), transform.count == 16,
          transform.allSatisfy(\.isFinite), abs(door.transform.columns.3.y-height/2-transform[13]) < 0.5 else { return nil }
    return transform[13]
  }
  /// Compute a single group's placement without mutating scans, history or companion groups.
  /// Validate arrays before matrix construction, including persisted session/zone transforms.
  static func placement(house: HouseProject, source: HouseProject.Room, target: HouseProject.Room,
                        sourceDoor: RoomDoor, targetDoor: RoomDoor, flip: Bool,
                        floors: (source: Float, target: Float)? = nil) -> HouseProject? {
    guard let sr = source.active, let tr = target.active,
          let ss = house.session(sr.session), let ts = house.session(tr.session), ss.zone != ts.zone,
          ss.zone == source.zone, ts.zone == target.zone,
          ss.alignment.method != "unaligned", ts.alignment.method != "unaligned",
          let sourceSession = rigid(ss.alignment.toZone), let targetSession = rigid(ts.alignment.toZone),
          let zi = house.zones.firstIndex(where: { $0.id == ss.zone }),
          let reference = house.zone(ts.zone), reference.aligned, let referencePose = rigid(reference.toHouse),
          usableWidth(sourceDoor.width), usableWidth(targetDoor.width), abs(sourceDoor.width-targetDoor.width) < 0.2,
          rigid(sourceDoor.transform.columnMajor) != nil, rigid(targetDoor.transform.columnMajor) != nil else { return nil }
    let local: simd_float4x4
    if let floors {
      guard let match = floorAware(source: sourceDoor, target: targetDoor, sourceFloor: floors.source,
                                   targetFloor: floors.target, flip: flip) else { return nil }
      local = match
    } else {
      guard usableHeight(sourceDoor.height), usableHeight(targetDoor.height) else { return nil }
      let turn = simd_float4x4(simd_quatf(angle: flip ? .pi : 0, axis: SIMD3(0,1,0)))
      local = targetDoor.transform * turn * sourceDoor.transform.inverse
    }
    let transform = referencePose * targetSession * local * sourceSession.inverse
    guard rigid(transform.columnMajor) != nil else { return nil }
    var result = house
    result.zones[zi].toHouse = transform.columnMajor; result.zones[zi].aligned = true
    return result
  }
}

/// Preserves metadata bytes before a connection. Undo refuses to erase subsequent edits.
/// Camera files, meshes, scans, maps and history are never touched.
@MainActor enum ConnectionHistory {
  struct Checkpoint: Codable {
    var before: Data
    var afterHash: String
    var createdAt: Date
  }
  struct PendingUndo: Codable {
    var checkpointID: String
    var checkpoint: Checkpoint
  }
  struct UndoState: Codable {
    var consumed: Set<String> = []
    var pending: PendingUndo?
  }
  static let undoStateFilename = "undo-state.json"
  private static func undoState(in history: URL) throws -> UndoState {
    let path = history.appendingPathComponent(undoStateFilename)
    guard FileManager.default.fileExists(atPath: path.path) else { return UndoState() }
    return try JSONDecoder().decode(UndoState.self, from: Data(contentsOf: path))
  }
  private static func write(_ state: UndoState, in history: URL) throws {
    try JSONEncoder().encode(state).write(to: history.appendingPathComponent(undoStateFilename), options: .atomic)
  }
  static func save(expected: HouseProject, candidate: HouseProject) throws {
    guard expected.id == candidate.id else { throw ConnectionMath.Failure.invalid }
    let path = expected.url.appendingPathComponent("house.json"), before = try Data(contentsOf: path)
    let current = try HouseProject.load(url: expected.url)
    guard try ConnectionMath.encoded(current) == ConnectionMath.encoded(expected) else { throw ConnectionMath.Failure.stale }
    // Callers may only place existing groups. No room, session or other metadata edits.
    var permitted = expected
    for i in permitted.zones.indices {
      guard candidate.zones.indices.contains(i), candidate.zones[i].id == permitted.zones[i].id,
            ConnectionMath.rigid(candidate.zones[i].toHouse) != nil else { throw ConnectionMath.Failure.invalid }
      permitted.zones[i].toHouse = candidate.zones[i].toHouse; permitted.zones[i].aligned = candidate.zones[i].aligned
    }
    guard try ConnectionMath.encoded(permitted) == ConnectionMath.encoded(candidate) else { throw ConnectionMath.Failure.invalid }
    let history = expected.url.appendingPathComponent("connection-history", isDirectory: true)
    guard try undoState(in: history).pending == nil else { throw ConnectionMath.Failure.pendingUndo }
    // A no-op must neither create an undo step nor normalize the original metadata bytes.
    guard try ConnectionMath.encoded(expected) != ConnectionMath.encoded(candidate) else { return }
    // Patch only placement keys in the original JSON, preserving future/unknown metadata too.
    guard var json = try JSONSerialization.jsonObject(with: before) as? [String: Any],
          var rawZones = json["zones"] as? [[String: Any]], rawZones.count == candidate.zones.count else { throw ConnectionMath.Failure.invalid }
    for i in rawZones.indices {
      guard rawZones[i]["id"] as? String == candidate.zones[i].id else { throw ConnectionMath.Failure.invalid }
      rawZones[i]["toHouse"] = candidate.zones[i].toHouse
      rawZones[i]["aligned"] = candidate.zones[i].aligned
    }
    json["zones"] = rawZones
    let after = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
    let checkpoint = history.appendingPathComponent(UUID().uuidString + ".json")
    try JSONEncoder().encode(Checkpoint(before: before, afterHash: ConnectionMath.hash(after), createdAt: Date())).write(to: checkpoint, options: .atomic)
    guard try Data(contentsOf: path) == before else { throw ConnectionMath.Failure.stale }
    try after.write(to: path, options: .atomic)
  }
  static func undo(house: HouseProject) throws {
    let path = house.url.appendingPathComponent("house.json"), current = try Data(contentsOf: path)
    guard try ConnectionMath.encoded(HouseProject.load(url: house.url)) == ConnectionMath.encoded(house) else { throw ConnectionMath.Failure.stale }
    let history = house.url.appendingPathComponent("connection-history", isDirectory: true)
    var state = try undoState(in: history)
    let currentHash = ConnectionMath.hash(current)
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    if state.pending == nil {
      let files = (try? FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)) ?? []
      let currentEncoded = try ConnectionMath.encoded(house)
      let next = files.filter { $0.pathExtension == "json" && $0.lastPathComponent != undoStateFilename && !state.consumed.contains($0.lastPathComponent) }
        .compactMap { file -> PendingUndo? in
          guard let data = try? Data(contentsOf: file), let cp = try? JSONDecoder().decode(Checkpoint.self, from: data),
                cp.afterHash == currentHash, let original = try? decoder.decode(HouseProject.self, from: cp.before), original.id == house.id,
                let originalEncoded = try? ConnectionMath.encoded(original), originalEncoded != currentEncoded else { return nil }
          return PendingUndo(checkpointID: file.lastPathComponent, checkpoint: cp)
        }.sorted { $0.checkpoint.createdAt > $1.checkpoint.createdAt }.first
      guard let next else { throw ConnectionMath.Failure.stale }
      state.pending = next
      // Journal first: a crash on either side of the metadata write can be retried exactly once.
      try write(state, in: history)
    }
    guard let pending = state.pending, !state.consumed.contains(pending.checkpointID) else { throw ConnectionMath.Failure.invalid }
    let checkpoint = pending.checkpoint
    let original = try decoder.decode(HouseProject.self, from: checkpoint.before)
    guard original.id == house.id, try Data(contentsOf: path) == current else { throw ConnectionMath.Failure.stale }
    if currentHash == checkpoint.afterHash {
      try checkpoint.before.write(to: path, options: .atomic)
    } else if current != checkpoint.before {
      // An intervening edit wins. Retire the interrupted undo without restoring stale metadata.
      state.consumed.insert(pending.checkpointID); state.pending = nil
      try write(state, in: history)
      throw ConnectionMath.Failure.stale
    }
    // If already at `before`, only finish the interrupted transaction; don't undo another step.
    // Checkpoint bytes remain available for recovery, but can never be selected again.
    state.consumed.insert(pending.checkpointID); state.pending = nil
    try write(state, in: history)
  }
}

/// A joint fit is reviewed as one plan, so saving one shared-frame room cannot undo another.
/// A prepared plan is bound to exact metadata bytes and the active room layouts it used.
struct PreparedConnectionPlan: Codable {
  static let filename = "connection-review.json"
  var format = "house-connection-review/1"
  var houseID: String
  var baseHouseSHA256: String
  var reviewOnly: Bool
  var note: String
  var bindings: [ConnectionLandmarks.Binding]
  var zones: [Placement]
  struct Placement: Codable { var id: String; var toHouse: [Float] }
  static func load(house: HouseProject) -> PreparedConnectionPlan? {
    guard let data = try? Data(contentsOf: house.url.appendingPathComponent(filename)),
          let plan = try? JSONDecoder.iso8601.decode(Self.self, from: data), plan.format == "house-connection-review/1", plan.houseID == house.id else { return nil }
    return plan
  }
  func candidate(house: HouseProject) -> HouseProject? {
    guard house.id == houseID, let bytes = try? Data(contentsOf: house.url.appendingPathComponent("house.json")),
          ConnectionMath.hash(bytes) == baseHouseSHA256, !zones.isEmpty,
          let current = try? HouseProject.load(url: house.url),
          let currentEncoded = try? ConnectionMath.encoded(current), let expectedEncoded = try? ConnectionMath.encoded(house), currentEncoded == expectedEncoded,
          Set(zones.map(\.id)).count == zones.count else { return nil }
    // Every affected active room must be bound; no hidden companion is moved unreviewed.
    let affected = house.rooms.filter { room in
      guard let ref = room.active, let session = house.session(ref.session) else { return false }
      return zones.contains { $0.id == session.zone }
    }
    guard zones.allSatisfy({ pose in affected.contains { $0.zone == pose.id } }) else { return nil }
    guard !affected.isEmpty, affected.allSatisfy({ room in
      guard let ref = room.active, let session = house.session(ref.session), session.zone == room.zone,
            session.alignment.method != "unaligned", ConnectionMath.rigid(session.alignment.toZone) != nil,
            let data = RoomJSON.data(house: house, room: room) else { return false }
      return bindings.contains { $0.matches(room, data: data) }
    }) else { return nil }
    // Bindings may additionally protect the lower-floor reference or other checked geometry.
    guard bindings.allSatisfy({ binding in
      guard let room = house.rooms.first(where: { $0.id == binding.room_id }), let data = RoomJSON.data(house: house, room: room) else { return false }
      return binding.matches(room, data: data)
    }) else { return nil }
    var candidate = house
    for pose in zones {
      guard let index = candidate.zones.firstIndex(where: { $0.id == pose.id }), ConnectionMath.rigid(pose.toHouse) != nil else { return nil }
      candidate.zones[index].toHouse = pose.toHouse; candidate.zones[index].aligned = true
    }
    return candidate
  }
}
private extension JSONDecoder {
  static var iso8601: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }
}
