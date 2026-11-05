import SwiftUI
import simd

struct ManualOpeningEditor: View {
  let house: HouseProject
  let room: HouseProject.Room
  let onChange: () -> Void
  @State private var snapshot: ManualOpenings?
  @State private var roomData: Data?
  @State private var wallID = ""
  @State private var label = "Opening"
  @State private var width: Float = 0.9
  @State private var height: Float = 2.1
  @State private var position: Float = 0
  @State private var error: String?
  private var walls: [OpeningWall] {
    guard let roomData, let json = try? JSONSerialization.jsonObject(with: roomData) as? [String: Any] else { return [] }
    return OpeningWall.parse(json)
  }
  private var wall: OpeningWall? { walls.first { $0.id == wallID } }
  private var pose: simd_float4x4? {
    guard let wall else { return nil }
    return wall.opening(width: width, height: height, offset: position * max(0, (wall.width-width)/2), floor: wall.floorHeight)
  }
  private var observations: [ManualOpenings.Entry] {
    guard let roomData else { return [] }
    return snapshot?.entries(room: room, data: roomData) ?? []
  }

  var body: some View {
    Form {
      Section("Add a missing opening") {
        Text("Choose its wall, position and measured size. This adds a connection marker to this scan version; the saved walls and mesh stay intact.").font(.caption)
        DoorwayMap(house: house, room: room,
                   doors: walls.map { RoomDoor(id: $0.id, width: $0.width, transform: $0.transform) }, selected: $wallID)
        Picker("Wall", selection: $wallID) {
          Text("Choose wall").tag("")
          ForEach(Array(walls.enumerated()), id: \.element.id) { i, wall in
            Text(String(format: "Wall %d · %.2f m", i+1, wall.width)).tag(wall.id)
          }
        }
        TextField("Opening label", text: $label)
        HStack { Text("Width (m)"); TextField("Width", value: $width, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
        HStack { Text("Height (m)"); TextField("Height", value: $height, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
        if let wall {
          Text("Position along wall").font(.caption)
          Slider(value: $position, in: -1...1)
          Text("The opening starts at the saved wall's floor edge. Check that this matches the real doorway before connecting rooms.").font(.caption)
          if let pose {
            DoorwayMap(house: house, room: room,
                       doors: [RoomDoor(id: "new-opening", width: width, transform: pose)], selected: .constant("new-opening"))
            Text(String(format: "New opening: %.2f m from wall centre", position * max(0, (wall.width-width)/2))).font(.caption)
          } else {
            Text("Use a width above 0.20 m and below 4 m, and a height from 1 m to below 3.50 m. The opening must fit inside the selected wall.").font(.caption)
          }
        }
        Button("Add opening") { add() }
          .disabled(snapshot == nil || pose == nil || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if walls.isEmpty { Text("No usable saved wall is available. Capture the wall before adding an opening.").font(.caption) }
      }
      if !observations.isEmpty {
        Section("Openings added to this scan") {
          ForEach(observations) { entry in
            HStack {
              VStack(alignment: .leading) {
                Text(entry.label)
                Text(String(format: "%.2f × %.2f m%@", entry.width, entry.height, entry.hidden ? " · hidden" : "")).font(.caption)
              }
              Spacer()
              Button(entry.hidden ? "Restore" : "Hide") { toggle(entry) }.buttonStyle(.borderless)
            }
          }
        }
      }
      if let error { Section { Text(error).foregroundStyle(.red) } }
    }
    .navigationTitle("Manual openings")
    .onAppear {
      do {
        roomData = RoomJSON.data(house: house, room: room)
        snapshot = try ManualOpenings.load(house: house)
      } catch { self.error = error.localizedDescription }
    }
    .onChange(of: wallID) { _, _ in position = 0 }
  }

  private func add() {
    guard let snapshot, let roomData, let active = room.active, let wall, let pose else { return }
    var candidate = snapshot
    candidate.entries.append(.init(id: "manual-" + UUID().uuidString,
                                   binding: .init(room_id: room.id, active_ref: active, target_room_sha256: ConnectionMath.hash(roomData)),
                                   wallID: wall.id, label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                                   width: width, height: height, transform: pose.columnMajor))
    save(candidate)
  }

  private func toggle(_ entry: ManualOpenings.Entry) {
    guard var candidate = snapshot, let i = candidate.entries.firstIndex(where: { $0.id == entry.id }) else { return }
    candidate.entries[i].hidden.toggle()
    save(candidate)
  }

  private func save(_ candidate: ManualOpenings) {
    guard let snapshot, let roomData else { return }
    do {
      try ManualOpenings.save(expected: snapshot, candidate: candidate, house: house, room: room, roomData: roomData)
      self.snapshot = candidate; error = nil; onChange()
    } catch { self.error = error.localizedDescription }
  }
}
