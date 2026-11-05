import Foundation
import simd

/// User observations stay separate from captured geometry and are bound to one scan version.
/// Hiding an opening retains its observation, so it can be restored without rescanning.
struct ManualOpenings: Codable {
  static let filename = "manual-openings.json"
  var format = "manual-openings/1"
  var houseID: String
  var entries: [Entry] = []

  struct Entry: Codable, Identifiable {
    var id: String
    var binding: ConnectionLandmarks.Binding
    var wallID: String
    var label: String
    var width: Float
    var height: Float
    var transform: [Float]
    var hidden = false
    var door: RoomDoor? {
      guard !hidden, width.isFinite, width > 0.2, width < 4,
            height.isFinite, height >= 1, height < 3.5,
            let pose = ConnectionMath.rigid(transform) else { return nil }
      return RoomDoor(id: id, width: width, transform: pose, height: height, label: label, manuallyAdded: true)
    }
  }

  static func decode(_ data: Data, houseID: String) throws -> Self {
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let value = try decoder.decode(Self.self, from: data)
    guard value.format == "manual-openings/1", value.houseID == houseID,
          Set(value.entries.map(\.id)).count == value.entries.count else { throw ConnectionMath.Failure.invalid }
    return value
  }

  static func load(house: HouseProject) throws -> Self {
    let path = house.url.appendingPathComponent(filename)
    guard FileManager.default.fileExists(atPath: path.path) else { return Self(houseID: house.id) }
    return try decode(Data(contentsOf: path), houseID: house.id)
  }

  func entries(room: HouseProject.Room, data: Data) -> [Entry] {
    entries.filter { $0.binding.matches(room, data: data) }
  }

  /// A stale editor cannot attach an observation to a different active scan or erase newer edits.
  /// No house metadata, capture files or the optional reviewed floor guide are rewritten.
  @MainActor static func save(expected: Self, candidate: Self, house: HouseProject,
                             room: HouseProject.Room, roomData: Data) throws {
    let currentHouse = try HouseProject.load(id: house.id)
    guard let currentRoom = currentHouse.rooms.first(where: { $0.id == room.id }),
          currentRoom.active == room.active, let currentData = RoomJSON.data(house: currentHouse, room: currentRoom),
          currentData == roomData else { throw ConnectionMath.Failure.stale }
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
    let path = house.url.appendingPathComponent(filename)
    let before = try load(house: house)
    guard try encoder.encode(before) == encoder.encode(expected) else { throw ConnectionMath.Failure.stale }
    let encoded = try encoder.encode(candidate)
    _ = try decode(encoded, houseID: house.id)
    // Edits may append one valid observation or toggle visibility. Never replace prior measurements.
    guard candidate.entries.count >= expected.entries.count,
          candidate.entries.count <= expected.entries.count + 1 else { throw ConnectionMath.Failure.invalid }
    for i in expected.entries.indices {
      var allowed = expected.entries[i]
      if allowed.binding.matches(currentRoom, data: currentData) { allowed.hidden = candidate.entries[i].hidden }
      guard try encoder.encode(allowed) == encoder.encode(candidate.entries[i]) else { throw ConnectionMath.Failure.invalid }
    }
    if candidate.entries.count > expected.entries.count {
      let entry = candidate.entries.last!
      guard entry.binding.matches(currentRoom, data: currentData), let door = entry.door,
            !entry.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let json = try JSONSerialization.jsonObject(with: currentData) as? [String: Any],
            let wall = OpeningWall.parse(json).first(where: { $0.id == entry.wallID }) else { throw ConnectionMath.Failure.invalid }
      let local = wall.transform.inverse * door.transform.columns.3
      guard let expectedPose = wall.opening(width: entry.width, height: entry.height, offset: local.x, floor: wall.floorHeight),
            zip(expectedPose.columnMajor, entry.transform).allSatisfy({ abs($0-$1) < 0.0001 }) else { throw ConnectionMath.Failure.invalid }
    }
    try encoded.write(to: path, options: .atomic)
  }
}

struct OpeningWall: Identifiable {
  let id: String
  let width: Float
  let height: Float
  let transform: simd_float4x4
  var floorHeight: Float { transform.columns.3.y - height / 2 }

  static func parse(_ json: [String: Any]) -> [Self] {
    var ids = Set<String>()
    return (json["walls"] as? [[String: Any]] ?? []).compactMap { wall in
      guard let id = wall["identifier"] as? String, ids.insert(id).inserted,
            let dimensions = RoomJSON.floats(wall["dimensions"]), dimensions.count >= 2,
            dimensions[0].isFinite, dimensions[0] > 0.2, dimensions[1].isFinite, dimensions[1] >= 1,
            let values = RoomJSON.floats(wall["transform"]), let pose = ConnectionMath.rigid(values) else { return nil }
      return Self(id: id, width: dimensions[0], height: dimensions[1], transform: pose)
    }
  }

  /// The centre offset is along the saved wall's local X axis, in metres from its midpoint.
  func opening(width: Float, height: Float, offset: Float, floor: Float) -> simd_float4x4? {
    guard width.isFinite, width > 0.2, width < 4, height.isFinite, height >= 1, height < 3.5,
          offset.isFinite, floor.isFinite, abs(offset) + width / 2 <= self.width / 2 + 0.001,
          floor >= floorHeight - 0.1, floor + height <= floorHeight + self.height + 0.1 else { return nil }
    var pose = transform
    pose.columns.3 += transform.columns.0 * offset
    pose.columns.3.y = floor + height / 2
    return ConnectionMath.rigid(pose.columnMajor)
  }
}
