import SwiftUI
import simd

struct RoomDoor: Identifiable {
  let id: String
  let width: Float
  let transform: simd_float4x4
  var height: Float? = nil
  var label: String? = nil
  var reviewOnly = false
  var manuallyAdded = false
  static func load(house: HouseProject, room: HouseProject.Room) -> [RoomDoor] {
    guard let data = RoomJSON.data(house: house, room: room),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
    let captured = parse(json)
    let registered = ConnectionLandmarks.load(house: house)?.doors(room: room, data: data, capturedIDs: Set(captured.map(\.id))) ?? []
    let existing = Set((captured + registered).map(\.id))
    let manual = ((try? ManualOpenings.load(house: house))?.entries(room: room, data: data) ?? [])
      .compactMap(\.door).filter { !existing.contains($0.id) }
    return captured + registered + manual
  }
  static func parse(_ json: [String: Any]) -> [RoomDoor] {
    var ids = Set<String>()
    return (["doors", "openings"].flatMap { json[$0] as? [[String: Any]] ?? [] }).compactMap { d in
      guard let t = RoomJSON.floats(d["transform"]), t.count == 16,
            let dimensions = RoomJSON.floats(d["dimensions"]), let width = dimensions.first, width.isFinite, width > 0,
            let id = d["identifier"] as? String, ids.insert(id).inserted else { return nil }
      guard let transform = ConnectionMath.rigid(t) else { return nil }
      return .init(id: id, width: width, transform: transform, height: dimensions.count > 1 ? dimensions[1] : nil)
    }
  }
}

/// RoomPlan's saved CapturedRoom JSON, read untyped for the doorway tools.
enum RoomJSON {
  static func data(house: HouseProject, room: HouseProject.Room) -> Data? {
    guard let ref = room.active, let session = house.session(ref.session),
          let data = try? Data(contentsOf: house.bundle(for: session).file("rooms/room-\(ref.index).json")) else { return nil }
    return data
  }
  static func load(house: HouseProject, room: HouseProject.Room) -> [String: Any]? {
    guard let data = data(house: house, room: room) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }
  /// JSONSerialization numbers are NSNumbers holding Doubles, and `as? [Float]` rejects any
  /// value a Float can't hold exactly (-0.7317813 included), so read NSNumber and narrow.
  static func floats(_ value: Any?) -> [Float]? { (value as? [NSNumber])?.map(\.floatValue) }
  /// Wall centre lines on the floor plane (x, z)
  static func wallSegments(_ json: [String: Any]) -> [(SIMD2<Float>, SIMD2<Float>)] {
    (json["walls"] as? [[String: Any]] ?? []).compactMap { w in
      guard let t = floats(w["transform"]), t.count == 16, t.allSatisfy(\.isFinite),
            let width = floats(w["dimensions"])?.first, width.isFinite, width > 0 else { return nil }
      let center = SIMD2(t[12], t[14]), half = SIMD2(t[0], t[2]) * width / 2
      return (center-half, center+half)
    }
  }
}

/// Doorway correspondence is user-verified; never silently treat separate maps as aligned.
struct RoomConnection: View {
  let house: HouseProject
  let source: HouseProject.Room
  let onSave: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var targetID = ""
  @State private var sourceDoorID = ""
  @State private var targetDoorID = ""
  @State private var flip = true
  @State private var previewing = false
  @State private var previewedFingerprint: String?
  @State private var matchFloors = false
  @State private var preparedPreview = false
  @State private var preparedPreviewHash: String?
  @State private var replacePreparedPlacements = false
  @State private var debugConfigured = false
  @State private var openingsRevision = 0
  @State private var replacePlacement = false
  @State private var error: String?
  private var target: HouseProject.Room? { house.rooms.first { $0.id == targetID } }
  private var sourceDoors: [RoomDoor] { RoomDoor.load(house: house, room: source) }
  private var targetDoors: [RoomDoor] { target.map { RoomDoor.load(house: house, room: $0) } ?? [] }
  private struct Floor { var height: Float; var reviewOnly: Bool }
  private func floor(_ room: HouseProject.Room, door: RoomDoor) -> Floor? {
    guard let data = RoomJSON.data(house: house, room: room) else { return nil }
    if let landmarks = ConnectionLandmarks.load(house: house), let anchor = landmarks.floor(room: room, data: data) {
      return Floor(height: anchor.height, reviewOnly: landmarks.review_only)
    }
    guard let json = RoomJSON.load(house: house, room: room),
          let height = ConnectionMath.inferredFloor(door: door, json: json) else { return nil }
    return Floor(height: height, reviewOnly: false)
  }
  private var selection: (HouseProject.Room, RoomDoor, RoomDoor)? {
    guard let target, let sd = sourceDoors.first(where: { $0.id == sourceDoorID }),
          let td = targetDoors.first(where: { $0.id == targetDoorID }) else { return nil }
    return (target, sd, td)
  }
  private var reviewOnly: Bool {
    guard let (target, sd, td) = selection else { return false }
    return sd.reviewOnly || td.reviewOnly || (matchFloors && (floor(source, door: sd)?.reviewOnly == true || floor(target, door: td)?.reviewOnly == true))
  }
  private var previewFingerprint: String? {
    guard let candidate, let target, let data = try? ConnectionMath.encoded(candidate),
          let sourceData = RoomJSON.data(house: house, room: source), let targetData = RoomJSON.data(house: house, room: target) else { return nil }
    let sidecar = (try? Data(contentsOf: house.url.appendingPathComponent(ConnectionLandmarks.filename))) ?? Data()
    let manual = (try? Data(contentsOf: house.url.appendingPathComponent(ManualOpenings.filename))) ?? Data()
    return ConnectionMath.hash(data + sourceData + targetData + sidecar + manual)
  }
  private var candidate: HouseProject? {
    guard let (target, sd, td) = selection else { return nil }
    if matchFloors {
      guard let sf = floor(source, door: sd), let tf = floor(target, door: td) else { return nil }
      return ConnectionMath.placement(house: house, source: source, target: target, sourceDoor: sd,
                                      targetDoor: td, flip: flip, floors: (sf.height, tf.height))
    }
    return ConnectionMath.placement(house: house, source: source, target: target,
                                    sourceDoor: sd, targetDoor: td, flip: flip)
  }

  private var prepared: PreparedConnectionPlan? { PreparedConnectionPlan.load(house: house) }
  private var preparedFingerprint: String? {
    guard let data = try? Data(contentsOf: house.url.appendingPathComponent(PreparedConnectionPlan.filename)),
          let candidate = prepared?.candidate(house: house), let encoded = try? ConnectionMath.encoded(candidate) else { return nil }
    return ConnectionMath.hash(data + encoded)
  }
  var body: some View {
    let _ = openingsRevision
    Form {
      if let prepared {
        Section("Prepared group connections") {
          Text(prepared.note).font(.caption)
          let affected = house.rooms.filter { prepared.zones.map(\.id).contains($0.zone) }.map(\.name)
          Text("Moves together: " + affected.joined(separator: ", ")).font(.caption)
          let replacesPlacement = prepared.zones.contains { house.zone($0.id)?.aligned == true }
          if replacesPlacement { Toggle("Replace these groups' existing placements", isOn: $replacePreparedPlacements) }
          if prepared.reviewOnly { Text("Review only: no prepared placements can be saved.").font(.caption) }
          if prepared.candidate(house: house) == nil { Text("The house or its scan versions changed. Prepare a fresh plan before previewing.").font(.caption) }
          Button("Preview prepared groups") { preparedPreviewHash = preparedFingerprint; preparedPreview = true }.disabled(preparedFingerprint == nil)
          Button("Save prepared groups") {
            do {
              guard !prepared.reviewOnly, (!replacesPlacement || replacePreparedPlacements), let previewFingerprint = preparedFingerprint, previewFingerprint == preparedPreviewHash,
                    let candidate = prepared.candidate(house: house) else { throw ConnectionMath.Failure.stale }
              try ConnectionHistory.save(expected: house, candidate: candidate); onSave(); dismiss()
            } catch { self.error = error.localizedDescription }
          }.disabled(prepared.reviewOnly || preparedFingerprint == nil || preparedPreviewHash != preparedFingerprint || (replacesPlacement && !replacePreparedPlacements))
        }
      }
      Section {
        Text("Match the same physical doorway in two rooms. Add a missing opening from a saved wall, or capture the doorway again.")
        Picker("Connect \(source.name) to", selection: $targetID) {
          Text("Choose room").tag("")
          ForEach(house.rooms.filter { $0.id != source.id }) { Text($0.name).tag($0.id) }
        }
        DoorwayMap(house: house, room: source, doors: sourceDoors, selected: $sourceDoorID)
        doorPicker("Doorway in \(source.name)", doors: sourceDoors, selection: $sourceDoorID)
        NavigationLink("Manage openings in \(source.name)") {
          ManualOpeningEditor(house: house, room: source) { openingsRevision += 1; previewedFingerprint = nil }
        }
        if let target { DoorwayMap(house: house, room: target, doors: targetDoors, selected: $targetDoorID) }
        doorPicker("Doorway in other room", doors: targetDoors, selection: $targetDoorID)
        if let target {
          NavigationLink("Manage openings in \(target.name)") {
            ManualOpeningEditor(house: house, room: target) { openingsRevision += 1; previewedFingerprint = nil }
          }
        }
        Text("Tap the matching doorway numbers on each room plan. Widths help distinguish similar openings.").font(.caption)
        Toggle("Rooms face opposite sides of doorway", isOn: $flip)
        Toggle("Match floor levels", isOn: $matchFloors)
        if matchFloors { Text("Uses the floor beneath each doorway, preserving its horizontal position. Use only for the same physical opening on the same floor; staircase ends are different openings.").font(.caption) }
        if let (target, sd, td) = selection, !ConnectionMath.usableHeight(sd.height) || !ConnectionMath.usableHeight(td.height) {
          Text("A doorway has an implausible or missing height. Doorway-centre matching is blocked; a reviewed floor landmark is needed.").font(.caption)
          if matchFloors && (floor(source, door: sd) == nil || floor(target, door: td) == nil) { Text("No valid floor landmark is available for this opening.").font(.caption) }
        }
        if let (_, sd, td) = selection, !ConnectionMath.usableWidth(sd.width) || !ConnectionMath.usableWidth(td.width) {
          Text("A doorway has an implausible width. Add a measured manual opening before connecting.").font(.caption)
        }
        if reviewOnly { Text("Registered landmarks are for review only. You can preview them; saving is blocked until they are verified.").font(.caption) }
        if target?.zone == source.zone { Text("These rooms already share a tracking frame.") }
        if let target, house.zone(target.zone)?.aligned != true { Text("Choose a room already placed in the house as the reference.") }
        if sourceDoors.isEmpty || (target != nil && targetDoors.isEmpty) { Text("A doorway is missing. Add a manual opening or capture the connecting doorway before joining these rooms.") }
        if candidate == nil { Text("Choose compatible doorways (within 20 cm in width) in separately captured rooms with established tracking.").font(.caption) }
        if house.zone(source.zone)?.aligned == true {
          Toggle("Replace this group's existing placement", isOn: $replacePlacement)
          Text("This group is already placed. Preview and confirm its replacement; other groups keep their saved placements.").font(.caption)
        }
        Button("Preview connection") { previewedFingerprint = previewFingerprint; previewing = true }
          .disabled(candidate == nil || (house.zone(source.zone)?.aligned == true && !replacePlacement))
        Text("Check walls, floor levels, and which side of the doorway each room occupies. This is a manual placement, not an automatic match.").font(.caption)
        let companions = house.rooms.filter { $0.zone == source.zone && $0.id != source.id }.map(\.name)
        if !companions.isEmpty { Text("Also moves with this room: " + companions.joined(separator: ", ")).font(.caption) }
        Button("Save connection") {
          guard let candidate else { return }
          do {
            guard !reviewOnly, (house.zone(source.zone)?.aligned != true || replacePlacement), let previewFingerprint, previewFingerprint == previewedFingerprint else { throw ConnectionMath.Failure.stale }
            try ConnectionHistory.save(expected: house, candidate: candidate)
            onSave(); dismiss()
          } catch { self.error = error.localizedDescription }
        }.disabled(reviewOnly || previewFingerprint == nil || previewedFingerprint != previewFingerprint || (house.zone(source.zone)?.aligned == true && !replacePlacement))
        Button("Undo last saved connection") {
          do { try ConnectionHistory.undo(house: house); onSave(); dismiss() }
          catch { self.error = error.localizedDescription }
        }
        Text("Undo restores connection metadata only and refuses to replace newer changes.").font(.caption)
        if let error { Text(error).foregroundStyle(.red) }
      }
    }
    .navigationTitle("Connect rooms")
    .onAppear {
      #if DEBUG
      guard !debugConfigured else { return }; debugConfigured = true
      let args = ProcessInfo.processInfo.arguments
      func value(_ name: String) -> String? { guard let i = args.firstIndex(of: name), i+1 < args.count else { return nil }; return args[i+1] }
      if let id = value("-connection-target") { targetID = id }
      if let id = value("-connection-source-door") { sourceDoorID = id }
      if let id = value("-connection-target-door") { targetDoorID = id }
      matchFloors = args.contains("-connection-floors")
      if args.contains("-connection-prepared-preview") { preparedPreviewHash = preparedFingerprint; preparedPreview = true }
      #endif
    }
    .onChange(of: targetID) { _, _ in targetDoorID = ""; previewedFingerprint = nil }
    .onChange(of: sourceDoorID) { _, _ in previewedFingerprint = nil }
    .onChange(of: targetDoorID) { _, _ in previewedFingerprint = nil }
    .onChange(of: flip) { _, _ in previewedFingerprint = nil }
    .onChange(of: replacePlacement) { _, _ in previewedFingerprint = nil }
    .onChange(of: replacePreparedPlacements) { _, _ in preparedPreviewHash = nil }
    .onChange(of: matchFloors) { _, _ in previewedFingerprint = nil }
    .sheet(isPresented: $preparedPreview) {
      if let candidate = prepared?.candidate(house: house) { NavigationStack { HouseViewer(house: candidate).toolbar { Button("Done") { preparedPreview = false } } } }
    }
    .sheet(isPresented: $previewing) {
      if let candidate { NavigationStack { HouseViewer(house: candidate).toolbar { Button("Done") { previewing = false } } } }
    }
  }
  private func doorPicker(_ title: String, doors: [RoomDoor], selection: Binding<String>) -> some View {
    Picker(title, selection: selection) {
      Text("Choose doorway").tag("")
      ForEach(Array(doors.enumerated()), id: \.element.id) { i, door in
        Text(door.label.map { "\($0) · \(door.manuallyAdded ? "manually added" : "registered landmark")" } ?? String(format: "Doorway %d · %.2f m wide", i+1, door.width)).tag(door.id)
      }
    }
  }
}

struct DoorwayMap: View {
  let house: HouseProject
  let room: HouseProject.Room
  let doors: [RoomDoor]
  @Binding var selected: String
  private var segments: [(SIMD2<Float>, SIMD2<Float>)] {
    RoomJSON.load(house: house, room: room).map(RoomJSON.wallSegments) ?? []
  }
  var body: some View {
    let lines = segments
    let points = lines.flatMap { [$0.0, $0.1] } + doors.map { SIMD2($0.transform.columns.3.x, $0.transform.columns.3.z) }
    let lo = points.reduce(SIMD2<Float>(repeating: .infinity)) { simd_min($0,$1) }
    let hi = points.reduce(SIMD2<Float>(repeating: -.infinity)) { simd_max($0,$1) }
    GeometryReader { geo in
      let scale = min(Float(geo.size.width-40)/max(hi.x-lo.x,1), Float(geo.size.height-40)/max(hi.y-lo.y,1))
      let project: (SIMD2<Float>) -> CGPoint = { p in CGPoint(x: CGFloat((p.x-(lo.x+hi.x)/2)*scale)+geo.size.width/2, y: CGFloat((p.y-(lo.y+hi.y)/2)*scale)+geo.size.height/2) }
      ZStack {
        Canvas { context, _ in
          for line in lines {
            var path = Path(); path.move(to: project(line.0)); path.addLine(to: project(line.1))
            context.stroke(path, with: .color(.secondary), lineWidth: 3)
          }
        }
        ForEach(Array(doors.enumerated()), id: \.element.id) { i, door in
          Button("\(i+1)") { selected = door.id }
            .font(.caption.bold()).frame(width: 28, height: 28)
            .background(selected == door.id ? Color.green : Color.blue, in: Circle()).foregroundStyle(.white)
            .position(project(SIMD2(door.transform.columns.3.x, door.transform.columns.3.z)))
            .buttonStyle(.plain)
        }
      }
    }.frame(height: points.isEmpty ? 0 : 180).accessibilityLabel("Doorway plan for \(room.name)")
  }
}
