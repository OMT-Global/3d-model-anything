# Scan → Model → Publish

This branch builds on the camera white-balance fix in PR #3 (`c155dbc`). Its draft PR is stacked on `fix/iphone-white-balance`; the independent local-preview and outdoor-capture PRs are not included. Keep both draft PRs unmerged until iPhone testing and explicit merge authorization. There is no deployment in this change.

## Product requirement: no end-user repository

End users must not need a GitHub account, repository, fork, branch or Codex repository environment. The development repository is source control only. A shared or hidden developer repository is not an acceptable substitute for user authorization, subscription spend consent or tenant isolation. The legacy Cloud CLI proof is developer-only and cannot be installed as the mobile HTTP runner. The API explicitly reports `endUserRepositoryRequired: false` and `repoFreeCloudAvailable: false`; model permission alone is not execution availability.

See [repo-free modeling evidence and alternatives](REPO-FREE-MODELING.md). No supported direct repo-free Codex Cloud product route has been verified, so live modeling remains gated without sending the user to GitHub setup.

## What works now

- **Scan:** existing capture, preview, sharing and history remain available. The saved-room page adds an explicit Scan → Model → Publish entry. Scan formats and files are unchanged.
- **Model:** the iOS screen shows the Cloud setup gate. A separately labeled, on-device synthetic workflow demonstrates durable job progress, reopening, an editable 3D model, and immutable revisions. It never reads a user's scan. Room/object labels, sample-table position, width and material are editable. The deliberately small `editable-room/1` format supports boxes; this is a foundation for reconstruction, not a claim of photo-realistic modeling.
- **Publish:** the user approves one exact immutable revision, then explicitly publishes. The synthetic app stores a local publication only. Editing creates a new unapproved revision; earlier revisions and the previous publication remain available.
- **Portable service:** standard-library Python with SQLite implements authenticated owner-scoped commands, durable idempotency, progress, revision approval, and publication recovery. It runs on Linux; no runtime Mac relay or Apple framework is needed.
- **Official-client integration:** `OfficialCodexRunner` invokes the installed official `codex cloud exec/status` client with one attempt, an explicit environment and branch. Prompt input goes over stdin. Official ChatGPT subscription auth remains inside that client. This adapter has process-fixture coverage and a restartable synthetic Cloud proof harness using official `cloud diff` to retrieve bounded JSON. Authentication and environment discovery have been exercised against the real client; **no live reconstruction job has run**. A private legacy developer environment was created under existing access before the no-end-user-repository requirement arrived; that proof was then stopped and has no task or result.
- **Private viewer template:** a separate Three.js build reads only the authenticated user's published revision. The service authenticates HTML, JS, model data and all asset routes; it denies access by default. It is not added to GitHub Pages or the public demo bundle.

## Deliberate live gates

The release app has no configured remote endpoint, no login flow, no upload button, no copied OAuth identity or token, and no paid API fallback. `RemoteWorkflowTransport` is an HTTPS integration seam, not an active connection. A ChatGPT Pro subscription is assumed for the intended product, but neither a Site login nor an app principal proves subscription entitlement or authority to spend usage. The operator must explicitly authorize model execution, and the official client enforces actual account access and availability.

The default service uses `GatedRunner` and `GatedPublisher`. This repository does not implement a public ChatGPT Sites provisioning API, a Sites deployment, a private object store, or a scan upload gateway. Configuring a publisher means supplying a separately verified adapter to one pre-created private Site. The synthetic harness does not validate any provider's authentication or hosting policy.

Before enabling live use, separately scope and approve:

| Provider/resource | Exact action and scope still needed | Cost status |
| --- | --- | --- |
| OpenAI / repo-free model provider and approved runtime | Establish a supported repo-free execution contract, per-user subscription authorization and isolation. The legacy repository proof cannot enable the mobile service. No production host is provisioned; any new auth or host requires approval. | Subscription eligibility and host cost remain to be verified. No purchase made. |
| Private storage / provider and bucket not yet selected | Approve authenticated upload/download of one selected room, retention, quotas, short-lived grants, task identity binding and egress policy. No home data has been uploaded. | Unknown until resource selected; no paid storage created. |
| ChatGPT Sites / pre-created private viewer not yet identified | Verify supported update interface, visitor ACLs, owner publish authorization, protection of every asset endpoint, immutable version staging, health check and atomic publication pointer. | No Site created or published; any provider costs need approval. |
| iOS / app authorization | Supply short-lived app credentials and account binding through an approved login flow, then connect `RemoteWorkflowTransport` and private scan selection. Codex credentials must never be supplied to the phone. | No new credentials or persistent access created. |

No integration should declare itself live simply because its configuration values are present. Start with a synthetic live task after these gates are approved, then obtain explicit approval before using private scans.

## Real-client synthetic proof (operator tool, not the mobile service)

On 2026-10-23 the installed official `codex-cli 0.164.0` reported ChatGPT login, and `codex cloud list --json` succeeded using that existing access. The official client's repository lookup returned zero environments for `OMT-Global/3d-model-anything` and its upstream. The environment selector contained no matching label; explicit `cloud list --env OMT-Global/3d-model-anything` returned environment not found. After browser sign-in, the repository picker confirmed existing access; one private legacy environment was created with agent internet off and no secrets or new grants. Creation completed before the user clarified that end users must not need repositories. The repository-based proof stopped immediately. No other repository's environment was substituted. No Cloud task was submitted, so there is **no live task ID or verified Cloud model artifact** to report.

`model_service.cloud_smoke` is retained only as a developer experiment, not the product path. The repository-based test is stopped; resuming it requires a separate developer-test decision and cannot satisfy repo-free product acceptance. It sends only a fixed public synthetic measurement fixture in the prompt, requests four measured boxes as `editable-room/1`, and attempts to retrieve a single new JSON file through official `codex cloud diff --attempt 1`. It never runs `cloud apply`, executes generated code, commits generated output, uploads files, or accepts private input. This use of a task diff is restricted to the built-in synthetic fixture and is **not** the private scan/output gateway.

**Unproven output boundary:** a workspace change or `git add -N` does not guarantee that Cloud persists a result diff. The official CLI only reads the backend-provided diff; [upstream issue #51289](https://github.com/openai/codex/issues/51289) reports READY tasks with no serialized diff. This harness is an experiment to verify that boundary, not a guaranteed artifact transport. Missing or unreadable diffs leave the same task unverified with no revision and no resubmission; later polls can recover if the artifact becomes available. Local Git-diff fixtures test parsing only. Production artifact transport remains gated until a supported private result contract is established.

The importer checks the exact result path, regular-file mode, complete single-file diff, bounded size, duplicate JSON keys, job ID, input digest, document schema, and independently computed geometry. Retrieval is bound to the durable task ID. Only a verified model creates a revision, initially unapproved. Existing model schema is intentionally limited to boxes; a synthetic pass does not prove visual reconstruction quality for real rooms.

Run from the repository with an explicit, approved environment ID and branch. The state directory must be outside any Git checkout, owned by the operator with mode 0700 and no symlinked journal/log files under trusted parent directories: the official client can emit an `error.log` containing account/environment metadata. Keep that journal and log local; do not publish them.

```sh
# Keep this value for all commands and restarts; a new directory is a new run.
PROOF_DIR="$(mktemp -d)"

# Inspect the exact public prompt; makes no network request.
PYTHONPATH=apps/model-service python3 -m model_service.cloud_smoke plan \
  --state-dir "$PROOF_DIR" --environment APPROVED_ENV_ID \
  --branch feat/scan-model-publish

# Read-only auth/environment check. A failure reserves no job.
PYTHONPATH=apps/model-service python3 -m model_service.cloud_smoke check \
  --state-dir "$PROOF_DIR" --environment APPROVED_ENV_ID \
  --branch feat/scan-model-publish

# Explicitly spends existing subscription usage: one Cloud task, one attempt.
PYTHONPATH=apps/model-service python3 -m model_service.cloud_smoke submit \
  --state-dir "$PROOF_DIR" --environment APPROVED_ENV_ID \
  --branch feat/scan-model-publish

# Repeat as needed; poll cannot submit work. show makes no network request.
PYTHONPATH=apps/model-service python3 -m model_service.cloud_smoke poll \
  --state-dir "$PROOF_DIR" --environment APPROVED_ENV_ID \
  --branch feat/scan-model-publish
```

Keep the same state directory, environment and branch across restarts. `submit` returns an existing job rather than creating another; only a known, unclaimed queued job can resume submission. Unknown submission outcomes remain blocked. An operator may use `reconcile --verified-task-id task_...` only after verifying the task's environment, branch and prompt job correlation in the official UI. An incorrect binding cannot import a result with a different job ID or input digest. A new state directory represents a new spend intent, not a retry. The tool deliberately has no automatic retry or new-attempt command.

The test's successful output requires `verified: true`, an actual Cloud task ID, and a validated revision document/digest. A submitted or READY task alone is insufficient. `phoneConnected` and `publicationEnabled` remain false. Local mocked tests exercise this lifecycle but are not live Cloud evidence. The real preflight executed here returned `cloud_environment_unavailable`, with empty jobs/revisions and `verified: false`.

**Current gate:** do not ask end users to sign into GitHub or create environments. Authenticated inspection confirmed that both legacy creation and the current Cloud setup UI require repository selection. The current UI has no enabled Get started action with zero repositories selected. A separate Sign in with ChatGPT plan-usage route is documented for eligible apps, but it needs app-specific consent and does not itself supply an OpenAI-hosted task VM. Remotely hosted product eligibility and runtime hosting remain unresolved. See [the evidence and alternatives](REPO-FREE-MODELING.md); no OAuth registration, credential transfer, new hosting or fallback provider was started.

A completed operator CLI proof would establish the official Cloud execution/result boundary only. Phone-driven production still needs an approved non-Mac launcher, app account/spend authorization and secure private transfer. This change neither configures those resources nor alters the installed iPhone build. Sites stays separately gated.

## Data and transport contract

`editable-room/1` is bounded JSON: a room label plus 1–500 unique objects containing `id`, `label`, `kind: box`, `position`, `size` (three finite meter values, absolute values at most 100, positive dimensions), and `#RRGGBB` color. No script, arbitrary URL, shader or executable code is accepted. Both the service and app validate it. Future marketplace objects need a new versioned asset contract with licensed, authorized, digest-pinned assets; a marketplace is out of scope.

The **private input gateway**, once implemented, must authenticate the owner, accept only the explicitly selected room export, enforce size/path/archive limits and verify a SHA-256 before registering an immutable scan ID. The service accepts only a sealed descriptor `{kind, assetID, sha256}`. `assetID` is opaque; the service does not fetch arbitrary URLs, open client-supplied paths or put scan data in Git. A trusted gateway calls `register_scan`; no unverified public registration/upload route is exposed.

`PrivateTransfer.prompt(job_id, scan)` must issue short-lived, least-privilege input/output grants associated with the owner, job, sealed scan digest and approved execution context. Only the associated task may download inputs or upload its result. Put no long-lived credentials in prompts. Define expiry, revocation, output size limits and cleanup before enabling this adapter. Treat scan contents and generated text as untrusted evidence. The worker should use packaged reconstruction guidance derived from scan-to-threejs, without requiring an end-user repository and preserve coordinate transforms, measurements and uncertainty, returning a bounded data model through the private gateway. Do not commit scans or generated private artifacts into this public repository.

The gateway's authenticated `read_result(task_id, scan)` must return:

```json
{
  "format": "reconstruction-result/1",
  "taskID": "task_example",
  "scanSHA256": "<sealed input SHA-256>",
  "documentSHA256": "<SHA-256 of canonical document JSON>",
  "document": {"format": "editable-room/1", "label": "Example", "objects": []}
}
```

The empty object array above describes the envelope only; actual room validation requires at least one object. Canonical JSON is UTF-8, sorted keys, compact separators, finite numbers, as defined by `contracts.canonical`. `OfficialCodexRunner.result` verifies task identity, input digest, document digest and schema. The authenticated gateway must additionally bind the task to the job/owner and reject wrong-task/replayed writes. No binary artifact return, direct ZIP upload or model-selection flag is assumed from Cloud.

The HTTP app takes a trusted `authenticate(environ) -> Principal` dependency. Default is deny-all. Production middleware must verify its own session/signature and derive the owner and permissions server-side; never trust client owner headers. `can_model` is explicit spend authority and `can_publish` is publication authority. A read-only Site visitor is not granted either. Current reads are owner-only; shared visitor ACLs belong in the approved Site adapter. TLS termination and production WSGI hosting are deployment work, not configured here. Browser mutations require same-origin requests and JSON; no CORS is enabled. Responses use `no-store` and a same-origin content policy. Do not expose SQLite, service source, logs or an unprotected static copy of the viewer.

| API | Behavior |
| --- | --- |
| `GET /v1/capabilities` | Current mode, principal permissions, no-end-user-repository requirement and repo-free Cloud availability; no spend |
| `GET /v1/rooms/{roomID}` | Owned workflow snapshot; no spend |
| `POST /v1/rooms/{roomID}/commands` | JSON command with durable opaque `id` and `kind` |
| `POST /v1/rooms/{roomID}/advance` | Explicit authorized worker tick; body `{}`; may submit a queued job or resume publication |
| `GET /v1/rooms/{roomID}/published` | Only last acknowledged approved revision; owner authorization required |

Commands are `model` + `scanID`, `edit` + `baseRevisionID` + `document`, `approve` + `revisionID`, or `publish` + `revisionID`. Unknown fields are rejected. A request ID is unique per owner across rooms and binds the entire command; repeat it after transport failure. Changing the payload under that ID yields a conflict. After a definitive failed model job, a new user intent uses a new ID; a replay of the old request cannot launch another job.

## Failure and retention behavior

SQLite claims the job before invoking the official client. Cloud has no proven submit idempotency key, so process death after claim or ambiguous submit output leaves `submitting`/`reconciling`. Automatic retries never submit it again. An operator must use the official Cloud UI/list to verify owner, environment and job correlation, then bind the existing task through the non-HTTP `reconcile` hook. Do not clear unknown submissions merely to make the UI progress. Known running tasks can be polled safely; unrecognized CLI output is not treated as completion. Invalid output cannot replace a valid revision.

A Site publisher must be idempotent by publication request ID. Stage immutable revision data, verify protected asset access and viewer health, then conditionally advance its pointer from the expected previous revision. Return acknowledgement only after verification. Ambiguous errors retain `publishing`; retry the same ID. The local pointer moves only after acknowledgement. Keep old data until a separately approved retention action. There are no automatic deletion or rollback-to-empty operations.

The mobile cache persists the pending command before transmission. Lost responses and app termination replay that same ID; corrupt caches surface errors instead of silently resetting history. The synthetic journal lives under Application Support/ModelWorkflows, independent of Documents/Houses. The existing scan deletion actions are unchanged. A future live adapter needs account-scoped local caches and a separately designed deletion/retention policy before handling private model artifacts.

## Local synthetic validation

```sh
npm ci
npm run test:workflow
npm run build
npm run build:private-viewer
PYTHONPATH=apps/model-service python3 -m model_service --synthetic
```

Open `http://127.0.0.1:8787/?room=demo`, login `demo` / `synthetic-only`. This intentionally public demo password only protects a loopback synthetic fixture; it is not production authentication. State is temporary and deleted when the harness exits. No Cloud client or Site API is called. The private viewer must be served through this authenticated application; Vite/static hosting alone is not a protection boundary.

On a Mac, run the Foundation-only persistence checks:

```sh
swiftc apps/house-capture/HouseCapture/ModelWorkflow.swift \
  apps/house-capture/HouseCapture/ModelWorkflowSelfTest.swift \
  tools/test-model-workflow.swift -o /tmp/test-model-workflow
/tmp/test-model-workflow
```

`-selftest` includes these regressions and the existing camera crash-fix checks. `-workflow-demo` and `-workflow-gated` are Debug-only launch views. `-workflow-demo-id <unique-id>` isolates synthetic UI runs. Generate the Xcode project and run the `HouseCapture` scheme's `HouseCaptureWorkflowUITests` on an iOS simulator. These test app interruption, editing, approval, local publication, reopening, and live setup gates without camera use. CI runs Python tests, TypeScript and both viewer builds; iOS verification requires Xcode.

## iPhone acceptance next

The separately authorized in-place upgrade to 1.0(3) was installed and launched successfully, with the saved scan index and file inventory verified intact after a private local backup. The user has tried the synthetic workflow. This Cloud integration follow-up does not reinstall or interrupt that app. Its live Model/Site setup gates remain visible until the remote service and app authorization are actually connected. Camera scanning and private reconstruction remain separate gates. Keep the feature draft PR unmerged until the user completes testing and explicitly authorizes merge.

## Official interface evidence

Verified against the installed CLI's help and [official Codex source at 970111f](https://github.com/openai/codex/blob/970111f6cb62cc02fe36a82ea7d71b37a2889c97/codex-rs/cloud-tasks/src/lib.rs). The source confirms that non-ready `cloud status` results exit 1, so the adapter parses recognized status labels instead of treating every nonzero exit as a transport failure. The current local official source (`a314c7d`) also confirms stdin prompts, explicit environment resolution and `cloud diff --attempt`. This is source/interface evidence plus authenticated read-only discovery, not a successful live reconstruction.
