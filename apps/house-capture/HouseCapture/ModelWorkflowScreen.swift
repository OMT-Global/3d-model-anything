import SwiftUI
import SceneKit

enum RoomStage: String, CaseIterable, Identifiable {
  case scan = "Scan", model = "Model", publish = "Publish"
  var id: String { rawValue }
}

struct RoomWorkflowEntry: View {
  let roomID: String
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Scan", systemImage: "checkmark.circle.fill").foregroundStyle(Fieldwork.orange)
        Spacer(); Image(systemName: "arrow.right"); Spacer()
        Text("Model"); Spacer(); Image(systemName: "arrow.right"); Spacer(); Text("Publish")
      }.font(.caption.weight(.semibold)).accessibilityElement(children: .combine)
      NavigationLink { RoomWorkflowScreen(roomID: roomID) } label: {
        Label("Model & publish", systemImage: "cube.transparent")
          .frame(maxWidth: .infinity)
      }.buttonStyle(FieldworkButtonStyle(filled: false))
    }
  }
}

struct RoomWorkflowScreen: View {
  let roomID: String
  var synthetic = false
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @State private var stage: RoomStage = .model
  @State private var session: WorkflowSession?
  @State private var error: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        FieldworkEyebrow(text: synthetic ? "Synthetic workflow" : "Room workflow")
        Text("Scan. Model. Publish.").font(.largeTitle.bold()).tracking(-1)
        Picker("Stage", selection: $stage) {
          ForEach(RoomStage.allCases) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented)
        if synthetic {
          Label("Demo only · no scans uploaded", systemImage: "testtube.2")
            .font(.subheadline.weight(.semibold)).foregroundStyle(Fieldwork.orange)
        }
        if stage == .scan {
          Label(synthetic ? "Synthetic evidence ready" : "Original scan saved", systemImage: "checkmark.seal")
            .font(.title2.bold())
          Text(synthetic ? "A fixed studio fixture drives this demo. It does not read your saved room." : "Your scan and its history stay intact. Modeling will create a separate revision.")
          Button(synthetic ? "Continue to Model" : "Back to saved scan") {
            if synthetic { stage = .model } else { dismiss() }
          }.buttonStyle(FieldworkButtonStyle())
        } else if synthetic, let session {
          SyntheticWorkflowPanel(session: session, stage: stage)
        } else if synthetic, let error {
          Text(error).foregroundStyle(.red)
        } else if synthetic {
          ProgressView("Opening demo…")
        } else {
          setupCard
        }
      }.padding(24)
    }
    .background(Fieldwork.paper).foregroundStyle(Fieldwork.ink)
    .navigationTitle(synthetic ? "Synthetic demo" : "Model & publish")
    .navigationBarTitleDisplayMode(.inline)
    .task {
      guard synthetic else { return }
      do {
        if session == nil { session = try WorkflowSession.demo(roomID: "synthetic-" + roomID) }
        await session?.resume()
      } catch { self.error = error.localizedDescription }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await session?.resume() } }
    }
  }

  private var setupCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      Image(systemName: stage == .model ? "cloud" : "lock.shield").font(.largeTitle).foregroundStyle(Fieldwork.orange)
      Text(stage == .model ? "Model with Codex Cloud" : "Publish to your private Site").font(.title2.bold())
      Text(stage == .model
           ? "Cloud modeling with your ChatGPT account is not connected yet. This app will not ask you to create a GitHub account or repository."
           : "Preview and approve a model revision, then publish it to a protected ChatGPT Site. Your last working publication stays available until the new version is verified.")
      Label("Setup required", systemImage: "pause.circle").font(.headline)
      Text(stage == .model
           ? "Your scans stay on this device. Try the sample workflow below while cloud modeling remains unavailable."
           : "No Site is connected. Site sign-in and permission to publish must be configured separately.")
        .font(.subheadline).foregroundStyle(Fieldwork.secondary)
      NavigationLink {
        RoomWorkflowScreen(roomID: roomID, synthetic: true)
      } label: { Text("Try synthetic workflow").frame(maxWidth: .infinity) }
        .buttonStyle(FieldworkButtonStyle())
      Text("Try preview, editing, approval and publication recovery with a sample room, entirely on this device.")
        .font(.caption).foregroundStyle(Fieldwork.secondary)
    }.padding(20).background(Fieldwork.rule.opacity(0.22), in: RoundedRectangle(cornerRadius: 16))
  }
}

private struct SyntheticWorkflowPanel: View {
  @ObservedObject var session: WorkflowSession
  let stage: RoomStage
  @State private var selectedID: String?
  @State private var editing: ModelRevision?
  @State private var confirmingPublish = false
  private var revision: ModelRevision? {
    session.state.revisions.first { $0.id == selectedID } ?? session.state.revisions.last
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if stage == .model {
        Text("Model a sample studio").font(.title2.bold())
        if let job = session.state.jobs.last {
          Label(job.message, systemImage: job.state == "ready" ? "checkmark.circle" : "clock")
          if job.active { ProgressView().accessibilityLabel("Model job in progress") }
        }
        Button(session.state.jobs.isEmpty ? "Start synthetic model" : "Create another synthetic revision") {
          Task { await session.send(.init(kind: "model", scanID: "synthetic-scan")) }
        }.buttonStyle(FieldworkButtonStyle()).disabled(session.busy || session.pending != nil || session.state.jobs.contains(where: \.active))
      } else {
        Text("Approve, then publish").font(.title2.bold())
        Text("This demo saves a local publication. It does not create or update a ChatGPT Site.")
          .font(.subheadline).foregroundStyle(Fieldwork.secondary)
        if let id = session.state.publishedRevisionID {
          Label("Last working demo: \(id.prefix(8))", systemImage: "checkmark.shield")
        } else { Text("No publication yet").foregroundStyle(Fieldwork.secondary) }
      }
      if let revision {
        Picker("Model revision", selection: Binding(get: { revision.id }, set: { selectedID = $0 })) {
          ForEach(Array(session.state.revisions.enumerated()), id: \.element.id) { index, rev in
            Text("Revision \(index + 1)\(rev.approved ? " · approved" : "")").tag(rev.id)
          }
        }.pickerStyle(.menu)
        EditableRoomPreview(document: revision.document).frame(height: 270).clipShape(RoundedRectangle(cornerRadius: 12))
        Text("Drag to rotate · pinch to zoom").font(.caption).foregroundStyle(Fieldwork.secondary)
        if stage == .model {
          Button("Edit this revision", systemImage: "slider.horizontal.3") { editing = revision }
            .buttonStyle(FieldworkButtonStyle(filled: false)).disabled(session.busy || session.pending != nil)
        } else {
          Button(revision.approved ? "Revision approved" : "Approve this revision", systemImage: "checkmark.seal") {
            Task { await session.send(.init(kind: "approve", revisionID: revision.id)) }
          }.buttonStyle(FieldworkButtonStyle(filled: false)).disabled(revision.approved || session.busy || session.pending != nil)
          Button("Publish demo locally", systemImage: "lock.shield") { confirmingPublish = true }
            .buttonStyle(FieldworkButtonStyle()).disabled(!revision.approved || session.busy || session.pending != nil || session.state.publishedRevisionID == revision.id || session.state.publications.contains { $0.state == "queued" })
        }
      } else if stage == .publish {
        ContentUnavailableView("Model first", systemImage: "cube", description: Text("Create and inspect a model revision before approving it."))
      }
      if let error = session.error { Text(error).font(.subheadline).foregroundStyle(.red) }
      if session.pending != nil {
        Button("Retry pending request") { Task { await session.resume() } }.disabled(session.busy)
      }
      Button("Refresh progress", systemImage: "arrow.clockwise") { Task { await session.refresh() } }.disabled(session.busy)
      Text("You can leave this screen and resume later. Original scans and earlier model revisions are retained.")
        .font(.caption).foregroundStyle(Fieldwork.secondary)
    }
    .task(id: session.state.needsRefresh) {
      while session.state.needsRefresh && !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        await session.refresh()
      }
    }
    .sheet(item: $editing) { revision in
      ModelRevisionEditor(revision: revision) { document in
        Task { await session.send(.init(kind: "edit", baseRevisionID: revision.id, document: document)); selectedID = session.state.revisions.last?.id }
      }
    }
    .confirmationDialog("Publish this approved demo revision?", isPresented: $confirmingPublish, titleVisibility: .visible) {
      Button("Publish demo locally") {
        if let revision { Task { await session.send(.init(kind: "publish", revisionID: revision.id)) } }
      }
    } message: { Text("This only updates the synthetic publication on this device. Previous revisions are retained.") }
  }
}

private struct ModelRevisionEditor: View {
  @Environment(\.dismiss) private var dismiss
  @State private var document: EditableRoom
  let save: (EditableRoom) -> Void
  init(revision: ModelRevision, save: @escaping (EditableRoom) -> Void) { _document = State(initialValue: revision.document); self.save = save }
  var body: some View {
    NavigationStack {
      Form {
        Section("Preview") { EditableRoomPreview(document: document).frame(height: 220) }
        Section("Room") { TextField("Room label", text: $document.label) }
        ForEach($document.objects) { $object in
          Section(object.label) {
            TextField("Object label", text: $object.label)
            if object.id == "table" {
              VStack(alignment: .leading) { Text("Position X: \(object.position[0], specifier: "%.2f") m"); Slider(value: $object.position[0], in: -1.5...1.5, step: 0.05) }
              VStack(alignment: .leading) { Text("Width: \(object.size[0], specifier: "%.2f") m"); Slider(value: $object.size[0], in: 0.3...3, step: 0.05) }
              Picker("Material", selection: $object.color) {
                Text("Terracotta").tag("#c66635"); Text("Sage").tag("#718570"); Text("Ink").tag("#343c43")
              }
            }
          }
        }
        Section { Text("Saving creates a new revision. It needs its own approval before publication.") }
      }
      .navigationTitle("Edit model")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("Save revision") { save(document); dismiss() }.disabled((try? document.validate()) == nil) }
      }
    }.tint(Fieldwork.orange)
  }
}

private struct EditableRoomPreview: UIViewRepresentable {
  let document: EditableRoom
  final class Coordinator { var document: EditableRoom? }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeUIView(context: Context) -> SCNView {
    let view = SCNView(); view.backgroundColor = Fieldwork.uiPaper
    view.allowsCameraControl = true; view.autoenablesDefaultLighting = true
    view.antialiasingMode = .multisampling4X; view.isPlaying = false
    return view
  }
  func updateUIView(_ view: SCNView, context: Context) {
    guard context.coordinator.document != document, (try? document.validate()) != nil else { return }
    context.coordinator.document = document
    let scene = SCNScene(); scene.background.contents = Fieldwork.uiPaper
    for object in document.objects {
      let box = SCNBox(width: object.size[0], height: object.size[1], length: object.size[2], chamferRadius: 0)
      let rgb = UInt32(object.color.dropFirst(), radix: 16) ?? 0xcccccc
      box.firstMaterial?.diffuse.contents = UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
      box.firstMaterial?.lightingModel = .physicallyBased; box.firstMaterial?.roughness.contents = 0.8
      let node = SCNNode(geometry: box); node.position = SCNVector3(object.position[0], object.position[1], object.position[2]); scene.rootNode.addChildNode(node)
    }
    let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera?.fieldOfView = 42
    camera.position = SCNVector3(7, 6, 8); camera.look(at: SCNVector3(0, 0.8, 0)); scene.rootNode.addChildNode(camera)
    view.scene = scene; view.pointOfView = camera
  }
}
