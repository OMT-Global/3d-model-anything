import ARKit
import SwiftUI

/// Optional on disk so house-capture/5 indoor exports remain readable without migration.
enum CaptureMode: String, Codable { case indoor, outdoor }

struct OutdoorMetadata: Codable {
  static let coordinateNote = "Independent local ARKit frame; not aligned to the house, other captures, GPS or a survey."
  var source = "ARWorldTrackingConfiguration"
  var scope = "Nearby building surfaces and ground; raw evidence for later reconstruction."
  var coordinates = coordinateNote
  var limitations = "Sunlight, distance, glass, moving vegetation and weak texture can leave gaps or drift. No complete-property, adjacency or survey-accuracy guarantee."
}

enum OutdoorCaptureCapabilities {
  static var isSupported: Bool {
    ARWorldTrackingConfiguration.isSupported &&
    ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) &&
    ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
  }
  static var reconstruction: ARConfiguration.SceneReconstruction {
    ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) ? .meshWithClassification : .mesh
  }
  static func configuration() -> ARWorldTrackingConfiguration {
    let config = ARWorldTrackingConfiguration()
    config.worldAlignment = .gravity
    config.sceneReconstruction = reconstruction
    config.frameSemantics = [.sceneDepth]
    // No plane flattening, GPS, RoomPlan, or initial map: each patch gets a fresh local frame.
    return config
  }
}

enum OutdoorDepthQuality {
  /// A guidance heuristic, not an accuracy or completeness measurement.
  static func message(usable: Int, sampled: Int) -> String {
    guard sampled > 0 else { return "Depth unavailable. Aim at a nearby textured surface; photos can still be saved." }
    if Float(usable) / Float(sampled) < 0.2 {
      return "Weak nearby depth. Move closer or try shade. Sunlight, glass and distant surfaces can leave gaps."
    }
    return "Nearby depth available. Move slowly with overlapping views; include the ground and building edges."
  }
  static func message(for data: ARDepthData?) -> String {
    guard let data, let confidence = data.confidenceMap else { return message(usable: 0, sampled: 0) }
    let depth = data.depthMap
    CVPixelBufferLockBaseAddress(depth, .readOnly)
    CVPixelBufferLockBaseAddress(confidence, .readOnly)
    defer {
      CVPixelBufferUnlockBaseAddress(depth, .readOnly)
      CVPixelBufferUnlockBaseAddress(confidence, .readOnly)
    }
    guard let d = CVPixelBufferGetBaseAddress(depth), let c = CVPixelBufferGetBaseAddress(confidence) else {
      return message(usable: 0, sampled: 0)
    }
    var usable = 0, sampled = 0
    let width = min(CVPixelBufferGetWidth(depth), CVPixelBufferGetWidth(confidence))
    let height = min(CVPixelBufferGetHeight(depth), CVPixelBufferGetHeight(confidence))
    for y in stride(from: 0, to: height, by: 8) {
      let row = d.advanced(by: y * CVPixelBufferGetBytesPerRow(depth)).assumingMemoryBound(to: Float.self)
      let conf = c.advanced(by: y * CVPixelBufferGetBytesPerRow(confidence)).assumingMemoryBound(to: UInt8.self)
      for x in stride(from: 0, to: width, by: 8) {
        sampled += 1
        if row[x].isFinite, row[x] > 0, row[x] <= 5, conf[x] >= 1 { usable += 1 }
      }
    }
    return message(usable: usable, sampled: sampled)
  }
}

struct OutdoorCaptureScreen: View {
  @ObservedObject var controller: CaptureController
  let onClose: () -> Void
  @Environment(\.scenePhase) private var scenePhase
  @State private var confirmDiscard = false
  @State private var reviewing = false
  @State private var sharing: URL?
  @State private var shareError: String?
  @State private var preparingShare = false

  var body: some View {
    ZStack {
      ARViewContainer(view: controller.scanView.view).ignoresSafeArea()
      VStack {
        HStack {
          Text("Outdoor capture").font(.headline)
          Spacer()
          if controller.phase == .betweenRooms || controller.phase == .scanning {
            Button("Cancel") { confirmDiscard = true }
          }
        }.padding().background(.regularMaterial)
        Spacer()
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if let warning = controller.lastWarning { Text(warning).font(.footnote).foregroundStyle(.orange) }
          switch controller.phase {
          case .betweenRooms:
            Text("Capture one nearby area").font(.title2.bold())
            Text("Record a section of a building and its ground from overlapping viewpoints. Stay close, move slowly, and try shade if depth is weak.")
            Text("Each capture is independent raw evidence for your Mac. It does not map the whole property or establish boundaries, adjacency or survey accuracy.").font(.footnote)
            TextField("Area name, e.g. Front entrance", text: $controller.roomName).textFieldStyle(.roundedBorder)
            Button("Start outdoor capture", action: controller.startRoom).buttonStyle(.borderedProminent).disabled(!controller.canStartRoom)
            Button("Back") { controller.abandon(); onClose() }
          case .scanning:
            Text(controller.roomName).font(.headline)
            Text("\(controller.photoCount) photos · \(Int(controller.stats.meshArea)) m² observed mesh").font(.caption.monospacedDigit())
            if let issue = controller.trackingIssue {
              Text(issue.message).font(.subheadline.bold())
              Text("Recording waits for stable tracking. You can still stop and save.").font(.caption)
            }
            Text(controller.outdoorDepthMessage).font(.subheadline)
            if controller.sessionNeedsRestart { Text("Tracking failed. Stop and save, then start a new capture.").foregroundStyle(.orange) }
            HStack {
              Button(controller.paused ? "Resume" : "Pause") { if controller.paused { controller.resume() } else { controller.pause() } }
                .disabled(controller.sessionNeedsRestart)
              Button("Take photo", action: controller.takePhoto).disabled(controller.paused || !controller.captureReady)
              Spacer()
              Button("Stop and save", action: controller.finishRoom).buttonStyle(.borderedProminent)
            }
          case .finishingRoom, .finishing:
            ProgressView("Saving mesh, photos and depth…")
          case .failed(let message):
            Text("Save needs attention").font(.headline)
            Text(message)
            Button("Retry save") { Task { await controller.finishSession() } }.buttonStyle(.borderedProminent)
          case .done:
            Text("Outdoor capture saved").font(.title2.bold())
            Text("Review the nearby surfaces and export the raw evidence for your Mac. Separate captures still need alignment.").font(.subheadline)
            Button("Review in 3D") { reviewing = true }.disabled(controller.reviewSource == nil)
            Button(preparingShare ? "Preparing export…" : "Share capture (.zip)") { share() }.disabled(preparingShare)
            if let shareError { Text(shareError).font(.footnote).foregroundStyle(.orange) }
            Button("Done", action: onClose).buttonStyle(.borderedProminent).disabled(preparingShare)
          case .relocalizing:
            Text("Preparing…") // Outdoor plans never relocalize against an indoor map.
          }
        }.padding()
        }.frame(maxHeight: controller.phase == .betweenRooms ? 440 : 340)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding()
      }
    }
    .confirmationDialog("Discard this outdoor capture?", isPresented: $confirmDiscard, titleVisibility: .visible) {
      Button("Discard capture", role: .destructive) { controller.abandon(); onClose() }
      Button("Keep capturing", role: .cancel) {}
    } message: { Text("Use Stop and save to keep the current mesh, photos and depth.") }
    .onAppear { controller.begin() }
    .onChange(of: scenePhase) { _, phase in if phase != .active { controller.pause() } }
    .sheet(isPresented: $reviewing) {
      if let source = controller.reviewSource {
        NavigationStack { ScanReview(source: source).toolbar { Button("Done") { reviewing = false } } }
      }
    }
    .sheet(item: $sharing) { ShareSheet(items: [$0]) }
  }

  private func share() {
    guard !preparingShare else { return }
    preparingShare = true
    let bundle = controller.bundle
    Task {
      defer { preparingShare = false }
      do { sharing = try await Task.detached(priority: .userInitiated) { try bundle.zipped() }.value }
      catch { shareError = error.localizedDescription }
    }
  }
}
