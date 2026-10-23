import Foundation
import CryptoKit
import Combine

/// A versioned, data-only asset boundary. No remote scripts, URLs or generated code run in the app.
struct EditableRoom: Codable, Equatable {
  var format = "editable-room/1"
  var label: String
  var objects: [Object]
  struct Object: Codable, Identifiable, Equatable {
    var id: String
    var label: String
    var kind = "box"
    var position: [Double]
    var size: [Double]
    var color: String
  }
  func validate() throws {
    guard format == "editable-room/1", (1...120).contains(label.count), (1...500).contains(objects.count),
          Set(objects.map(\.id)).count == objects.count else { throw WorkflowError.invalidModel }
    for object in objects {
      guard object.kind == "box", (1...120).contains(object.label.count),
            object.id.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil,
            object.color.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil,
            object.position.count == 3, object.size.count == 3,
            (object.position + object.size).allSatisfy({ $0.isFinite && abs($0) <= 100 }),
            object.size.allSatisfy({ $0 > 0 }) else { throw WorkflowError.invalidModel }
    }
  }
  static var synthetic: EditableRoom {
    .init(label: "Synthetic studio", objects: [
      .init(id: "floor", label: "Floor", position: [0, -0.05, 0], size: [5, 0.1, 4], color: "#cbbda6"),
      .init(id: "back", label: "Back wall", position: [0, 1.4, -2], size: [5, 2.8, 0.1], color: "#eee4d4"),
      .init(id: "side", label: "Side wall", position: [-2.5, 1.4, 0], size: [0.1, 2.8, 4], color: "#d8cdbb"),
      .init(id: "table", label: "Table", position: [0.5, 0.45, 0], size: [1.8, 0.9, 0.85], color: "#c66635")
    ])
  }
}

struct ModelRevision: Codable, Identifiable, Equatable {
  var id: String
  var scanID: String
  var parentID: String?
  var origin: String
  var document: EditableRoom
  var approved: Bool
}
struct ModelJob: Codable, Identifiable {
  var id: String
  var scanID: String
  var state: String
  var taskID: String?
  var message: String
  var revisionID: String?
  var active: Bool { ["queued", "submitting", "running", "reconciling"].contains(state) }
}
struct ModelPublication: Codable, Identifiable {
  var id: String
  var revisionID: String
  var state: String
  var url: String?
}
struct WorkflowSnapshot: Codable {
  var roomID: String
  var jobs: [ModelJob] = []
  var revisions: [ModelRevision] = []
  var publications: [ModelPublication] = []
  var publishedRevisionID: String?
  var needsRefresh: Bool { jobs.contains { ["queued", "running"].contains($0.state) } || publications.contains { ["queued", "publishing"].contains($0.state) } }
  func validate() throws { for revision in revisions { try revision.document.validate() } }
}
struct WorkflowCommand: Codable, Equatable {
  var id = UUID().uuidString
  var kind: String
  var scanID: String?
  var baseRevisionID: String?
  var revisionID: String?
  var document: EditableRoom?
}

enum WorkflowError: LocalizedError {
  case setupRequired, invalidModel, pending, rejected(String), invalidResponse
  var errorDescription: String? {
    switch self {
    case .setupRequired: return "Cloud modeling is not connected yet. No GitHub setup is required from you. Protected Site publishing also needs setup. Your scans stay on this device."
    case .invalidModel: return "This model contains unsupported or invalid geometry. The previous revision is still available."
    case .pending: return "Retry the pending request before starting another action."
    case .rejected(let message): return message
    case .invalidResponse: return "The service response could not be verified. Retry the same request safely."
    }
  }
}

@MainActor protocol WorkflowTransport {
  func snapshot() async throws -> WorkflowSnapshot
  func command(_ command: WorkflowCommand) async throws -> WorkflowSnapshot
  func advance() async throws -> WorkflowSnapshot
}

/// Future deployment injects an approved endpoint and app authorization, never a Codex OAuth token.
/// No endpoint, credentials, entitlement inference or login flow is bundled in the release.
@MainActor final class RemoteWorkflowTransport: WorkflowTransport {
  private let endpoint: URL
  private let roomID: String
  private let authorization: () async throws -> String
  private let session: URLSession
  init(baseURL: URL, roomID: String, session: URLSession = URLSession(configuration: .ephemeral, delegate: WorkflowRedirectPolicy(), delegateQueue: nil), authorization: @escaping () async throws -> String) throws {
    guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
          baseURL.query == nil, baseURL.fragment == nil,
          roomID.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil else { throw WorkflowError.setupRequired }
    endpoint = baseURL.appendingPathComponent("v1/rooms").appendingPathComponent(roomID)
    self.roomID = roomID; self.authorization = authorization; self.session = session
  }
  func snapshot() async throws -> WorkflowSnapshot { try await request(nil, body: nil) }
  func command(_ command: WorkflowCommand) async throws -> WorkflowSnapshot { try await request("commands", body: JSONEncoder().encode(command)) }
  func advance() async throws -> WorkflowSnapshot { try await request("advance", body: Data("{}".utf8)) }
  private func request(_ action: String?, body: Data?) async throws -> WorkflowSnapshot {
    var request = URLRequest(url: action.map { endpoint.appendingPathComponent($0) } ?? endpoint)
    request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(try await authorization(), forHTTPHeaderField: "Authorization")
    request.cachePolicy = .reloadIgnoringLocalCacheData; request.timeoutInterval = 30
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, data.count <= 1_000_000 else { throw WorkflowError.invalidResponse }
    guard (200...299).contains(http.statusCode) else {
      // A definite 4xx rejects this command. Timeouts/5xx retain its durable idempotency key.
      if (400...499).contains(http.statusCode) { throw WorkflowError.rejected("Request declined (\(http.statusCode)). Check access and revision state.") }
      throw WorkflowError.invalidResponse
    }
    let state = try JSONDecoder().decode(WorkflowSnapshot.self, from: data)
    guard state.roomID == roomID else { throw WorkflowError.invalidResponse }
    try state.validate()
    return state
  }
}

final class WorkflowRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil) // Do not send app authorization or private requests to a redirected host.
  }
}

/// Offline demo owns a separate journal and only creates fixed synthetic evidence.
@MainActor final class SyntheticWorkflowTransport: WorkflowTransport {
  private struct Journal: Codable { var state: WorkflowSnapshot; var applied: [String: WorkflowCommand] = [:] }
  private let url: URL
  private var journal: Journal
  init(roomID: String, url: URL) throws {
    self.url = url
    if FileManager.default.fileExists(atPath: url.path) { journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url)) }
    else { journal = Journal(state: .init(roomID: roomID)) }
    try journal.state.validate()
  }
  func snapshot() async throws -> WorkflowSnapshot { journal.state }
  func command(_ command: WorkflowCommand) async throws -> WorkflowSnapshot {
    if let previous = journal.applied[command.id] {
      guard previous == command else { throw WorkflowError.rejected("Request ID already used.") }
      return journal.state
    }
    var next = journal
    switch command.kind {
    case "model":
      guard command.scanID == "synthetic-scan", !next.state.jobs.contains(where: \.active) else { throw WorkflowError.rejected("Resume the existing demo job.") }
      next.state.jobs.append(.init(id: UUID().uuidString, scanID: "synthetic-scan", state: "queued", message: "Synthetic job queued"))
    case "edit":
      guard let base = next.state.revisions.first(where: { $0.id == command.baseRevisionID }), let doc = command.document else { throw WorkflowError.invalidModel }
      try doc.validate()
      next.state.revisions.append(.init(id: UUID().uuidString, scanID: base.scanID, parentID: base.id, origin: "synthetic", document: doc, approved: false))
    case "approve":
      guard let i = next.state.revisions.firstIndex(where: { $0.id == command.revisionID }) else { throw WorkflowError.invalidModel }
      next.state.revisions[i].approved = true
    case "publish":
      guard let rev = next.state.revisions.first(where: { $0.id == command.revisionID }), rev.approved,
            !next.state.publications.contains(where: { $0.state == "queued" }) else { throw WorkflowError.rejected("Approve this revision and finish the current publication first.") }
      next.state.publications.append(.init(id: command.id, revisionID: rev.id, state: "queued"))
    default: throw WorkflowError.rejected("Unsupported action.")
    }
    next.applied[command.id] = command
    try save(next)
    return journal.state
  }
  func advance() async throws -> WorkflowSnapshot {
    var next = journal
    if let i = next.state.jobs.firstIndex(where: { ["queued", "running"].contains($0.state) }) {
      if next.state.jobs[i].state == "queued" {
        next.state.jobs[i].state = "running"; next.state.jobs[i].message = "Building synthetic room…"
      } else {
        let rev = ModelRevision(id: UUID().uuidString, scanID: "synthetic-scan", origin: "synthetic", document: .synthetic, approved: false)
        next.state.revisions.append(rev); next.state.jobs[i].state = "ready"
        next.state.jobs[i].revisionID = rev.id; next.state.jobs[i].message = "Synthetic revision ready"
      }
    }
    if let i = next.state.publications.firstIndex(where: { $0.state == "queued" }) {
      next.state.publications[i].state = "published"
      next.state.publishedRevisionID = next.state.publications[i].revisionID
    }
    try save(next)
    return journal.state
  }
  private func save(_ next: Journal) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(next).write(to: url, options: .atomic)
    journal = next
  }
}

@MainActor final class WorkflowSession: ObservableObject {
  private struct Cache: Codable { var state: WorkflowSnapshot; var pending: WorkflowCommand? }
  @Published private(set) var state: WorkflowSnapshot
  @Published private(set) var pending: WorkflowCommand?
  @Published private(set) var busy = false
  @Published var error: String?
  private let transport: any WorkflowTransport
  private let url: URL
  init(roomID: String, url: URL, transport: any WorkflowTransport) throws {
    self.url = url; self.transport = transport
    if FileManager.default.fileExists(atPath: url.path) {
      let cache = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: url))
      state = cache.state; pending = cache.pending
    } else { state = .init(roomID: roomID) }
    try state.validate()
  }
  static func demo(roomID: String, root: URL? = nil) throws -> WorkflowSession {
    let root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ModelWorkflows", isDirectory: true)
    let key = SHA256.hash(data: Data(roomID.utf8)).map { String(format: "%02x", $0) }.joined()
    let folder = root.appendingPathComponent(key, isDirectory: true)
    return try WorkflowSession(roomID: roomID, url: folder.appendingPathComponent("cache.json"), transport: SyntheticWorkflowTransport(roomID: roomID, url: folder.appendingPathComponent("synthetic.json")))
  }
  func send(_ command: WorkflowCommand) async {
    guard !busy else { return }
    guard pending == nil || pending == command else { error = WorkflowError.pending.localizedDescription; return }
    busy = true; error = nil
    defer { busy = false }
    do {
      // Persist intent BEFORE transmission; a lost response replays the exact same request.
      try persist(state, command)
      let updated = try await transport.command(command)
      try updated.validate(); try persist(updated, nil)
    } catch WorkflowError.rejected(let message) {
      do { try persist(state, nil) } catch { self.error = error.localizedDescription; return }
      error = message
    } catch { self.error = error.localizedDescription }
  }
  func resume() async {
    if let pending { await send(pending); return }
    guard !busy else { return }
    busy = true; defer { busy = false }
    do { let updated = try await transport.snapshot(); try updated.validate(); try persist(updated, nil); error = nil }
    catch { self.error = error.localizedDescription }
  }
  func refresh() async {
    guard !busy, pending == nil else { return }
    busy = true; defer { busy = false }
    do { let updated = try await transport.advance(); try updated.validate(); try persist(updated, nil); error = nil }
    catch { self.error = error.localizedDescription }
  }
  private func persist(_ state: WorkflowSnapshot, _ pending: WorkflowCommand?) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(Cache(state: state, pending: pending)).write(to: url, options: .atomic)
    self.state = state; self.pending = pending
  }
}
