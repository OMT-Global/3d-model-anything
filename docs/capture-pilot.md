# Continuous whole-house capture pilot

This is an **experimental, separate app**, `3D Capture Pilot`
(`com.jmcte.housecapture.capturepilot`). It shares source and the existing
`house-capture/5` bundle layout with the regular app, but has its own iOS container.
The regular Debug/Release product retains its four-room and large-map guardrails.

## Build and use

```sh
cd apps/house-capture
xcodegen generate
xcodebuild -project HouseCapture.xcodeproj -scheme HouseCapture \
  -configuration PilotRelease -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/house-capture-pilot -allowProvisioningUpdates build
```

Use Release on the phone. Select a signing team using normal local build settings.
PilotDebug is available for simulator self-tests. The experimental code requires
both the `CAPTURE_PILOT` compilation condition and the exact pilot bundle ID;
changing only a runtime preference cannot enable it in the regular app.

Start a new house/session and leave **Experimental whole house · one continuous
session** enabled. Name and scan each room separately, tap **Save room**, walk to
the next room, then start it. The pilot room history and guidance scroll while Scan/Finish stay pinned; the final
saved-room list also scrolls with Close pinned. The initial room limit is **21**, adjustable from
4–21 before the first room. Mode and limit lock when capture starts. Disabling
experimental mode before capture selects the baseline policy in the same pilot app.

There is one controller-owned `ARSession` and one `RoomCaptureSession` throughout.
Room boundaries call `stop(pauseARSession: false)` and run the next RoomPlan room
on those same objects. There is **no automatic split, replacement session, or
tracking reset** at four rooms or at a large map. After the configured room count,
finish the session. Starting another session is a separate coordinate frame.
Initial Continue/relocalization can reset before any new room exists; the pilot
metadata distinguishes that from room capture. Framework interruptions, tracking
changes and detected world jumps remain in diagnostics. One ARSession does not
guarantee uninterrupted or accurate tracking.

The 21-room number is a configurable experimental cap, **not a demonstrated
21-room success claim**. ARKit/RoomPlan retain their own growing tracking state.
App-side memory reductions cannot bound that state or promise less drift. Memory
warnings and critical heat pause recording; tracking failure prevents new rooms;
writer and storage failures preserve available evidence and are surfaced. A
suspicious fast position jump pauses recording for review. No recovery action
silently resets the world. Backgrounding, phone calls, low detail, heat, exhausted
storage or system termination can still prevent completion.

## High-resolution photos

High-resolution automatic requests default on in the pilot, use ARKit's recommended
high-resolution video format when available, and remain at least three seconds
apart. The original dimensions of a successful high-resolution frame are preserved
instead of applying the baseline 3024-pixel long-edge cap. This is the resolution
ARKit actually returns, **not a claim of 12 or 48 megapixels**. Poses and intrinsics
match saved sensor-oriented pixels. A high-resolution callback is accepted only
when its pose, tracking and blur checks pass. The UI shows the last saved dimensions, the current room's accepted high-resolution-API
photo count versus all room photos (including an explicit zero), and the session total.

Regular frames can still be saved when the high-resolution request is unavailable,
not sharp enough, timed out, or inhibited by thermal/memory policy. The status
explicitly describes this fallback; `photos.json` records `highRes`, actual width
and height per photo. The manual shutter remains a regular-frame reference photo.
Check high-resolution counts and dimensions for each room; the app does not
promise that every saved photo or every room has high-resolution imagery.

## Bounded app work and evidence

The pilot retains at most 48 recent scored mesh anchors and an estimated 24 MiB
of their geometry/scoring arrays in its stable working set. The input mailbox is
limited to 64 distinct anchors and 8 MiB of copied geometry. Replacement updates
coalesce by ID. A single oversized anchor stops mesh input and warns. Temporary
serialization, the current processing batch, SceneKit overlays, photo buffers,
RoomPlan and ARKit memory are additional; this is **not a process RSS limit**.
Live overlays for evicted anchors and their app-owned node references are released.
The pilot retains at most 48 overlay containers and resolves existing framework nodes
again on revisit. ARSCNView still manages empty anchor containers; these are not detached
or claimed to be bounded by the app cache. At most 64 photo depth grids are
retained for scoring, and previous room objects/grids are released at the next room.
Depth recording is limited to at most one frame per second, with three writes in
flight. Metadata arrays remain in memory; pixel/depth images do not accumulate.

Each processed mesh update is written as an immutable SHA-256-addressed PLY chunk,
then an atomic per-room anchor pointer selects that revision. Only after successful
persistence may scored geometry be evicted. Room transitions drain accepted input under the previous journal before switching; a
failed checkpoint stops the transition and retains its evidence. Earlier rooms' pointers never change
when an anchor is updated in a later room. Removed-anchor observations are separate
markers and never erase evidence. Old revisions and orphan chunks remain recoverable;
the pilot never automatically deletes them. This trades storage and write activity
for a smaller live working set; monitor free storage.

Live mesh mailbox pressure increments a visible skipped-update count. Those updates
were not accepted as persisted evidence. Saving the room re-snapshots current ARKit
anchors **serially**, one bounded anchor at a time, then streams their complete PLY
from disk. Anchors removed before that checkpoint can have gaps; the warning and
counter must not be read as lossless recovery. The output can include surfaces from
earlier rooms, as baseline session meshes do. Live coverage describes the recent
subset, and older persisted coverage scores can be stale; it is not whole-room
completeness. Photos remain independently recoverable for Mac processing.

Every completed photo/depth write commits its own metadata sidecar, including an
unfinished room. RoomPlan's raw data is persisted before building the per-room JSON
layout. Per-room USDZ exports, session/zone `StructureBuilder`, and automatic textured
3D review are deferred during pilot capture. Finish the session before inspecting
heavy previews. Existing per-room JSON, full PLY, photo/depth indexes, house history
and coordinate conventions remain compatible; the manifest's optional `capturePilot`
field links the extension metadata. A crashed room can have recoverable mesh/photos
without a finished RoomPlan layout. Recovery does **not** resume its old ARSession.

```
pilot/session.json                 policy, limits, continuity qualifications
pilot/room-N.json                  initial room name/index for interrupted evidence
pilot/mesh/chunks/<sha256>.ply      immutable anchor revisions
pilot/mesh/room-N/anchors/ID.json   atomic latest revision for that room/anchor
pilot/mesh/room-N/removed/ID.json   removal observation; evidence retained
pilot/photo-records/*.json         one committed PhotoRecord per saved image
pilot/depth-records/*.json          one committed depth Record per saved frame
```

Diagnostics retain physical memory samples and the session's sampled peak, thermal
and tracking state, saved world-map bytes, ARKit feature/anchor/vertex counts,
estimated app mesh bytes/count, scoring-photo count, pending mesh count/bytes,
coalesced/skipped updates, queue delay, and photo/depth writes in flight. The sampled
peak can miss brief spikes. Compare matched routes in baseline and pilot; synthetic
geometry comparison is not a device memory/FPS or tracking benchmark.

## Offline Mac transfer and reconstruction

Finish capture first. Use Finder file sharing over USB (the pilot exposes Documents),
Files, or the existing whole-house/session share action to copy the **entire session
or house folder**, including `pilot/`. For a large house, direct folder transfer
avoids a second large ZIP. Do not use a room-only export for raw journal recovery;
that export contains the standard finished-room assets, not the pilot extension.
No network service, Mac companion installation, or automatic deletion is involved.

From the repository root, with Python 3:

```sh
# Read-only verification of journal hashes, pointer shape, and referenced evidence.
python3 tools/capture-pilot/pilot_transfer.py verify /path/to/exported-session

# Resumable second copy: per-file SHA-256 verification, source mutation check,
# and a receipt beside the destination. An existing mismatched file is preserved.
python3 tools/capture-pilot/pilot_transfer.py copy \
  /path/to/exported-session /path/to/verified-archive

# Recheck every archived file against that transfer receipt later.
python3 tools/capture-pilot/pilot_transfer.py verify-copy \
  /path/to/verified-archive /path/to/verified-archive.verified.json

# Rebuild full per-room PLYs and recover independent photo/depth indexes.
# Output must be a new directory, separate from the evidence archive.
python3 tools/capture-pilot/pilot_transfer.py reconstruct \
  /path/to/verified-archive /path/to/reconstructed-models
```

The copy command reads the source, copies via exclusive randomly named staging files
beside the destination folder, verifies every file,
checks that the source did not change, then writes the SHA-256 inventory receipt.
Receipt writes use exclusive temporary files and atomic replacement. Copy commits use
macOS exclusive rename, so they never replace a concurrently created destination or
leave a second hard link after interruption. The copy command requires macOS and a
filesystem supporting exclusive rename; unsupported targets fail safely. Existing
hard-linked archive files are rejected, including on receipt recheck. Verification
and reconstruction do not require the exclusive-rename operation. Interrupted staging files stay
outside the destination inventory; later runs leave those unowned leftovers untouched.
Verification requires the declared mesh journal and every completed room directory;
canonical room and anchor identities prevent aliases from duplicating or omitting geometry.
Empty interrupted-room directories are preserved during copy. The complete destination
file and directory inventories must exactly match the source inventories before
a receipt is issued; receipts also retain empty directories for later checks. Required
photo/depth fields and their referenced files are validated before reconstruction.
Extra stale sidecars, pointers or other files stop verification and
are preserved. Retry the same copy command after an interruption. It verifies and reuses completed
matching files; conflicting destination files stop it without replacement. Keep
capture stopped during transfer. These hashes verify this local transfer and mesh
content integrity; they cannot prove an earlier Finder/AirDrop transfer preserved
unhashed source photos. Retain the phone originals and a backup. **No command deletes
source data, even after successful verification.**

Reconstruction accepts **one direct session folder** containing `pilot/session.json`.
For a copied whole house, choose its nested `sessions/<session>` directory; passing
the house itself is explicitly rejected before any output is created. Verification
and copying continue to support either a whole house or a session.

Reconstruction streams verified latest anchor chunks into per-room PLYs with corrected
face offsets, and recovers `photos.json`/`frames.json` from sidecars, including an
unfinished room. Output `reconstruction.json` states coordinates and limitations.
This is real assembly of the deferred full geometry, not photogrammetry, mesh fusion,
textured USDZ, or a RoomPlan structure merge. Original photo paths/poses/intrinsics
are supplied for further Mac texturing, using existing reconstruction tools as needed.
The repository's existing scan pipeline can consume the standard finished session;
its optional heavier dependencies are not required for verification or chunk assembly.
If reconstruction is interrupted, preserve its partial output and choose a new output
directory; the evidence archive is unchanged.

## Synthetic validation

```sh
python3 -m unittest discover -s tools/capture-pilot -p 'test_*.py' -v
xcrun swiftc -O apps/house-capture/HouseCapture/CapturePilot.swift \
  tools/capture-pilot/PilotJournalTests.swift -o /tmp/capture-pilot-journal-tests
/tmp/capture-pilot-journal-tests
```

The app's `-selftest` adds count/byte queue limits, 21-room policy, a baseline versus
pilot comparison of identical world geometry with 100 synthetic anchors (pilot keeps
48), room isolation, baseline-versus-pilot depth failure behavior, overlay eviction/revisit
without detaching framework containers, and disk-write failure preserving an earlier
complete export.
The standalone Swift tests exercise restart recovery, interrupted pointer writes,
SHA rejection, face-index offsets and export failure atomicity. Python tests exercise
21-room assembly, interrupted/repeated copy, corrupted/missing evidence, destination
conflicts, changed sources, unsafe paths and source retention. All fixtures are
synthetic. A physical 21-room walkthrough, real high-resolution availability, thermal
behavior, drift and ARKit peak memory remain device validation work.
