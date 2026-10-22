import Foundation
import simd

/// Track A's edits to house.json (the file format itself is HouseProject.swift).
///
/// Every change goes through `HouseProject.modify`: load the file, apply the change, save it
/// atomically. Screens and the capture controller hold copies, so a stale copy never
/// overwrites a newer file. Main thread only.
extension HouseProject {
  static let folderDateFormat = "yyyy-MM-dd HH.mm.ss"

  static func folderName(for date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = folderDateFormat
    return f.string(from: date)
  }

  static func url(forHouse id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

  static func load(id: String) throws -> HouseProject { try load(url: url(forHouse: id)) }

  /// Read-modify-write house.json
  @MainActor @discardableResult
  static func modify(_ id: String, _ change: (inout HouseProject) throws -> Void) throws -> HouseProject {
    var house = try load(id: id)
    try change(&house)
    try house.save()
    return house
  }

  /// Methods whose session world *is* the zone frame (toZone = identity, can feed the zone's map)
  static let zoneFrameMethods: Set<String> = ["first", "relocalized"]

  // MARK: queries

  /// Any outdoor history keeps this identity out of indoor rescan/doorway workflows,
  /// including legacy mixed histories whose active version happens to be indoor.
  func captureMode(for room: Room) -> CaptureMode {
    let refs = room.history + (room.active.map { [$0] } ?? [])
    return refs.contains { session($0.session)?.captureMode == .outdoor } ? .outdoor : .indoor
  }

  func sessionsInZone(_ zone: String) -> [Session] { sessions.filter { $0.zone == zone } }

  /// Sessions whose geometry is placed in the zone frame (anything but "unaligned")
  func placedSessionsInZone(_ zone: String) -> [Session] {
    sessions.filter { $0.zone == zone && $0.alignment.method != "unaligned" }
  }

  func roomsInZone(_ zone: String) -> [Room] { rooms.filter { $0.zone == zone } }

  func session(_ id: String) -> Session? { sessions.first { $0.id == id } }

  /// The zone to offer "Continue" in: where the last session was
  var lastZone: Zone? {
    let latest = sessions.max { $0.startedAt < $1.startedAt }
    return latest.flatMap { zone($0.zone) } ?? zones.first
  }

  /// the saved map of a zone, if its file is really there
  func existingWorldMap(zone: Zone) -> URL? {
    guard let u = worldMapURL(zone: zone), FileManager.default.fileExists(atPath: u.path) else { return nil }
    return u
  }

  // MARK: changes

  /// A new zone (area). Only the house's first zone is placed in the house frame from the start.
  @discardableResult
  mutating func addZone(named name: String) -> Zone {
    var n = zones.count + 1
    while zones.contains(where: { $0.id == "area-\(n)" }) { n += 1 }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let zone = Zone(id: "area-\(n)", name: trimmed.isEmpty ? "Area \(n)" : trimmed, worldMap: nil, aligned: zones.isEmpty)
    zones.append(zone)
    return zone
  }

  mutating func beginSession(id: String, zone: String, alignment: Alignment, at date: Date = Date(), captureMode: CaptureMode? = nil) {
    sessions.removeAll { $0.id == id }
    sessions.append(Session(id: id, zone: zone, startedAt: date, endedAt: nil, alignment: alignment, captureMode: captureMode))
  }

  mutating func setAlignment(session id: String, _ alignment: Alignment) {
    guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
    sessions[i].alignment = alignment
  }

  mutating func endSession(_ id: String, at date: Date = Date()) {
    guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
    sessions[i].endedAt = date
  }

  /// A room captured in a session. A room with the same name in the same zone is a rescan:
  /// it goes into that room's history and becomes the active scan.
  @discardableResult
  mutating func recordRoomScan(name: String, session id: String, index: Int, capturedAt: Date, roomID: String? = nil, matchName: Bool = true) -> Room? {
    guard let si = sessions.firstIndex(where: { $0.id == id }) else { return nil }
    let zone = sessions[si].zone
    let mode = sessions[si].captureMode ?? .indoor
    if let roomID, let target = rooms.first(where: { $0.id == roomID }), captureMode(for: target) != mode {
      return nil // Reject cross-mode rescans before mutating either history or session indexes.
    }
    if !sessions[si].rooms.contains(index) { sessions[si].rooms.append(index) }
    let ref = RoomRef(session: id, index: index, capturedAt: capturedAt)
    let key = Self.roomKey(name)
    if let ri = rooms.firstIndex(where: { roomID != nil ? $0.id == roomID : matchName && Self.roomKey($0.name) == key && captureMode(for: $0) == mode }) {
      rooms[ri].history.removeAll { $0.session == id && $0.index == index }
      rooms[ri].history.append(ref)
      rooms[ri].active = ref
      rooms[ri].zone = zone
      return rooms[ri]
    }
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let room = Room(id: UUID().uuidString, name: clean.isEmpty ? "Room \(index + 1)" : clean, zone: zone, active: ref, history: [ref])
    rooms.append(room)
    return room
  }

  /// Undo `recordRoomScan` ("Redo last room" / deleting a session): the previous scan of the
  /// room becomes active again; a room left with no scans is removed.
  mutating func removeRoomScan(session id: String, index: Int) {
    if let si = sessions.firstIndex(where: { $0.id == id }) { sessions[si].rooms.removeAll { $0 == index } }
    for ri in rooms.indices.reversed() {
      rooms[ri].history.removeAll { $0.session == id && $0.index == index }
      if let a = rooms[ri].active, a.session == id, a.index == index { rooms[ri].active = rooms[ri].history.last }
      if rooms[ri].history.isEmpty { rooms.remove(at: ri) }
    }
  }

  /// "Use this scan" for a room
  mutating func setActive(room id: String, _ ref: RoomRef) {
    guard let ri = rooms.firstIndex(where: { $0.id == id }), rooms[ri].history.contains(ref) else { return }
    rooms[ri].active = ref
    if let session = session(ref.session) { rooms[ri].zone = session.zone }
  }

  /// Forget a session (its folder is deleted separately)
  mutating func removeSession(_ id: String) {
    guard let s = session(id) else { return }
    for index in s.rooms { removeRoomScan(session: id, index: index) }
    // scans of this session that aren't in session.rooms (crash between the two writes)
    for ri in rooms.indices.reversed() {
      rooms[ri].history.removeAll { $0.session == id }
      if rooms[ri].active?.session == id { rooms[ri].active = rooms[ri].history.last }
      if rooms[ri].history.isEmpty { rooms.remove(at: ri) }
    }
    sessions.removeAll { $0.id == id }
  }

  mutating func setWorldMap(zone id: String, path: String, at date: Date = Date()) {
    guard let zi = zones.firstIndex(where: { $0.id == id }) else { return }
    zones[zi].worldMap = path
    zones[zi].worldMapUpdatedAt = date
  }

  /// Delete a room without destroying sessions shared with other rooms.
  @MainActor
  static func deleteRoom(houseID: String, roomID: String) throws {
    let before = try load(id: houseID)
    guard let room = before.rooms.first(where: { $0.id == roomID }) else { return }
    let updated = try modify(houseID) { h in
      for ref in room.history { h.removeRoomScan(session: ref.session, index: ref.index) }
      h.rooms.removeAll { $0.id == roomID }
    }
    for sessionID in Set(room.history.map(\.session)) {
      guard let session = updated.session(sessionID) else { continue }
      if session.rooms.isEmpty {
        try deleteSession(houseID: houseID, sessionID: sessionID)
      } else {
        let bundle = updated.bundle(for: session)
        let removed = Set(room.history.filter { $0.session == sessionID }.map(\.index))
        if var manifest = bundle.manifest {
          manifest.rooms.removeAll { removed.contains($0.index) }
          manifest.structure = nil
          try bundle.writeManifest(manifest)
        }
        for index in removed {
          bundle.deleteRoom(index: index)
          let mesh = bundle.file("mesh/room-\(index).ply")
          if FileManager.default.fileExists(atPath: mesh.path) { try FileManager.default.removeItem(at: mesh) }
        }
        for name in ["structure.json", "structure.usdz"] {
          let file = bundle.file(name)
          if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
      }
    }
    try cleanTrackingGroups(houseID: houseID, affected: Set(room.history.compactMap { before.session($0.session)?.zone }))
  }

  @MainActor
  static func deleteSession(houseID: String, sessionID: String) throws {
    let before = try load(id: houseID)
    guard !before.deletedRooms.contains(where: { $0.room.history.contains { $0.session == sessionID } }) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Restore or permanently delete the rooms in Recently Deleted before removing this session."])
    }
    let house = try modify(houseID) { $0.removeSession(sessionID) }
    let folder = house.url.appendingPathComponent("sessions/\(sessionID)", isDirectory: true)
    if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    try cleanTrackingGroups(houseID: houseID, affected: Set(before.session(sessionID).map { $0.rooms.isEmpty ? [] : [$0.zone] } ?? []))
  }

  /// Invalidates merged previews and maps after deletion, and removes empty internal groups.
  @MainActor
  static func cleanTrackingGroups(houseID: String, affected: Set<String>) throws {
    let before = try load(id: houseID)
    let empty = before.zones.filter { before.sessionsInZone($0.id).isEmpty }
    let updated = try modify(houseID) { h in
      h.zones.removeAll { z in empty.contains { $0.id == z.id } }
      for i in h.zones.indices where affected.contains(h.zones[i].id) {
        h.zones[i].worldMap = nil
        h.zones[i].worldMapUpdatedAt = nil
      }
      for i in h.rooms.indices {
        if let active = h.rooms[i].active, let session = h.session(active.session) { h.rooms[i].zone = session.zone }
      }
    }
    for zone in before.zones where affected.contains(zone.id) || empty.contains(where: { $0.id == zone.id }) {
      let folder = updated.url.appendingPathComponent("zones/\(zone.id)")
      if empty.contains(where: { $0.id == zone.id }) {
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
      } else {
        for name in ["worldmap.arworldmap", "structure.json", "structure.usdz"] {
          let file = folder.appendingPathComponent(name)
          if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
      }
    }
  }

  static func roomKey(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
