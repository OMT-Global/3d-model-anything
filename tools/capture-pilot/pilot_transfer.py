#!/usr/bin/env python3
"""Offline Capture Pilot verifier, resumable copy, and bounded mesh reconstruction. Stdlib only."""
import argparse
import ctypes
import errno
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import struct
import sys
import tempfile


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def safe_file(root, relative):
    path = Path(relative)
    if path.is_absolute() or '..' in path.parts or not path.parts:
        raise ValueError(f'Unsafe relative path: {relative}')
    target = root / path
    if any(part.is_symlink() for part in [target, *target.parents] if part != root.parent):
        raise ValueError(f'Symlink refused: {relative}')
    if not target.is_file():
        raise ValueError(f'Missing file: {relative}')
    return target


def reject_symlink_tree(root):
    # Check names only before parsing metadata or following directory contents.
    if root.is_symlink():
        raise ValueError(f'Symlink refused: {root}')
    for path in root.rglob('*'):
        if path.is_symlink():
            raise ValueError(f'Symlink refused: {path.relative_to(root)}')


def inventory(root):
    result = {}
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            raise ValueError(f'Symlink refused: {path.relative_to(root)}')
        if path.is_file():
            rel = path.relative_to(root).as_posix()
            result[rel] = {'bytes': path.stat().st_size, 'sha256': digest(path)}
    return result


def directory_inventory(root):
    reject_symlink_tree(root)
    return sorted(path.relative_to(root).as_posix() for path in root.rglob('*') if path.is_dir())


def validate_record(session, record, depth=False):
    def number(value):
        return type(value) in (int, float) and math.isfinite(value)
    if not isinstance(record, dict):
        raise ValueError('Invalid evidence sidecar')
    for key in ['file', 'confidence'] if depth else ['file']:
        if not isinstance(record.get(key), str) or not record[key]:
            raise ValueError(f'Invalid evidence field: {key}')
        safe_file(session, record[key])
    for key in ['room', 'width', 'height']:
        if type(record.get(key)) is not int or record[key] < (0 if key == 'room' else 1):
            raise ValueError(f'Invalid evidence field: {key}')
    if not number(record.get('timestamp')):
        raise ValueError('Invalid evidence field: timestamp')
    for key, length in [('transform', 16), ('intrinsics', 9)]:
        value = record.get(key)
        if not isinstance(value, list) or len(value) != length or not all(number(x) for x in value):
            raise ValueError(f'Invalid evidence field: {key}')
    if depth:
        if record.get('rgb') is not None:
            if not isinstance(record['rgb'], str) or not record['rgb']:
                raise ValueError('Invalid evidence field: rgb')
            safe_file(session, record['rgb'])
        if record.get('rgbIntrinsics') is not None:
            value = record['rgbIntrinsics']
            if not isinstance(value, list) or len(value) != 9 or not all(number(x) for x in value):
                raise ValueError('Invalid evidence field: rgbIntrinsics')
    elif not isinstance(record.get('tracking'), str) or type(record.get('manual')) is not bool:
        raise ValueError('Invalid photo tracking or manual field')
    if record.get('highRes') is not None and type(record['highRes']) is not bool:
        raise ValueError('Invalid evidence field: highRes')


def require_independent_files(root):
    for path in root.rglob("*"):
        if path.is_file() and path.stat().st_nlink > 1:
            raise ValueError(f"Hard-linked archive file (preserved): {path.relative_to(root)}")


def read_json(path):
    return json.loads(path.read_text())


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix='.capture-pilot-json-', dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, 'w') as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)  # only the exclusively created file belongs to this call


def entries(journal, room):
    if journal.is_symlink():
        raise ValueError(f'Symlink refused: {journal}')
    result = []
    seen_anchors = set()
    for pointer in sorted((journal / f'room-{room}' / 'anchors').glob('*.json')):
        entry = read_json(safe_file(journal.resolve(), pointer.relative_to(journal).as_posix()))
        if entry.get('format') != 'capture-pilot-mesh/1':
            raise ValueError(f'Unknown mesh format: {pointer}')
        anchor = entry.get('anchor')
        if anchor != pointer.stem or anchor in seen_anchors:
            raise ValueError(f'Invalid or duplicate anchor identity: {pointer}')
        seen_anchors.add(anchor)
        sha = entry['sha256']
        if not re.fullmatch('[a-f0-9]{64}', sha) or entry['chunk'] != f'chunks/{sha}.ply':
            raise ValueError(f'Invalid chunk pointer: {pointer}')
        path = safe_file(journal, entry['chunk'])
        if digest(path) != sha:
            raise ValueError(f'Hash mismatch: {path}')
        vertices, faces, offset = ply_info(path)
        if (vertices, faces) != (entry['vertices'], entry['faces']):
            raise ValueError(f'Chunk count mismatch: {path}')
        result.append((entry, path, offset))
    return result


def ply_info(path):
    with path.open('rb') as stream:
        header = bytearray()
        while not header.endswith(b'end_header\n'):
            line = stream.readline(4096)
            if not line or len(header) + len(line) > 65536:
                raise ValueError(f'Invalid PLY header: {path}')
            header.extend(line)
        text = header.decode('ascii')
        if not text.startswith('ply\nformat binary_little_endian 1.0\n'):
            raise ValueError(f'Unsupported PLY: {path}')
        vertices = int(re.search(r'^element vertex (\d+)$', text, re.M)[1])
        faces = int(re.search(r'^element face (\d+)$', text, re.M)[1])
        properties = [line for line in text.splitlines() if line.startswith('property ')]
        expected = [f'property float {name}' for name in ['x', 'y', 'z', 'nx', 'ny', 'nz', 'coverage']]
        expected += [f'property uchar {name}' for name in ['red', 'green', 'blue', 'inroom']]
        expected += ['property list uchar uint vertex_indices', 'property uchar class']
        if properties != expected or path.stat().st_size != len(header) + vertices * 32 + faces * 14:
            raise ValueError(f'Invalid PLY layout or length: {path}')
        return vertices, faces, len(header)


def journal_rooms(journal):
    if not journal.is_dir():
        raise ValueError(f"Missing mesh journal directory: {journal}")
    rooms = []
    seen = set()
    for path in journal.glob('room-*'):
        match = re.fullmatch(r'room-(0|[1-9][0-9]*)', path.name)
        if not match or not path.is_dir():
            raise ValueError(f'Invalid room journal name or type: {path}')
        number = int(match[1])
        if number in seen:
            raise ValueError(f'Duplicate room journal: {path}')
        seen.add(number)
        rooms.append((number, path))
    return sorted(rooms)


def verify(root):
    reject_symlink_tree(root)
    root = root.resolve()
    sessions = sorted(root.rglob('pilot/session.json'))
    if (root / 'pilot/session.json').is_file() and root / 'pilot/session.json' not in sessions:
        sessions.insert(0, root / 'pilot/session.json')
    if not sessions:
        raise ValueError('No pilot/session.json found; choose a pilot session or house folder.')
    rooms = chunks = photos = depths = 0
    for policy in sessions:
        session = policy.parent.parent
        info = read_json(safe_file(root, policy.relative_to(root).as_posix()))
        if info.get('format') != 'capture-pilot/1':
            raise ValueError(f'Unknown pilot format: {policy}')
        completed = info.get('completedRooms')
        if info.get('meshJournal') != 'pilot/mesh' or type(completed) is not int or not 0 <= completed <= 21:
            raise ValueError(f'Invalid pilot journal policy: {policy}')
        journal = session / 'pilot/mesh'
        room_list = journal_rooms(journal)
        present = {number for number, _ in room_list}
        if not set(range(completed)).issubset(present):
            raise ValueError(f'Missing completed room journal: {policy}')
        if not (journal / 'chunks').is_dir():
            raise ValueError(f'Missing mesh chunks directory: {journal}')
        for number, room in room_list:
            if not (room / 'anchors').is_dir():
                raise ValueError(f'Missing room anchor directory: {room}')
            chunks += len(entries(journal, number))
            rooms += 1
        # Verify every immutable revision too, including orphan chunks after an interrupted pointer update.
        for chunk in (journal / 'chunks').glob('*.ply'):
            if digest(chunk) != chunk.stem:
                raise ValueError(f'Chunk hash mismatch: {chunk}')
            ply_info(chunk)
        for metadata in (session / 'pilot/photo-records').glob('*.json'):
            record = read_json(safe_file(session, metadata.relative_to(session).as_posix()))
            validate_record(session, record)
            photos += 1
        for metadata in (session / 'pilot/depth-records').glob('*.json'):
            record = read_json(safe_file(session, metadata.relative_to(session).as_posix()))
            validate_record(session, record, depth=True)
            depths += 1
    return dict(sessions=len(sessions), rooms=rooms, latestAnchors=chunks, photoRecords=photos, depthRecords=depths)


def commit_exclusive(source, destination):
    # macOS RENAME_EXCL commits atomically without overwrite or a second hard link.
    # Unsupported systems/filesystems fail closed; never fall back to replacing data.
    if sys.platform != 'darwin':
        raise OSError(errno.ENOTSUP, 'Verified copy requires macOS exclusive rename support')
    library = ctypes.CDLL(None, use_errno=True)
    rename = getattr(library, 'renamex_np', None)
    if rename is None:
        raise OSError(errno.ENOTSUP, 'Exclusive rename unavailable')
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 0x00000004) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def copy_verified(source, destination):
    reject_symlink_tree(source)
    source, destination = source.resolve(), destination.resolve()
    if source == destination or source in destination.parents or destination in source.parents:
        raise ValueError('Source and destination must be separate, non-nested directories.')
    verify(source)
    before = inventory(source)
    directories = directory_inventory(source)
    # A dedicated destination allows retry but never replaces a mismatched committed file.
    destination.mkdir(parents=True, exist_ok=True)
    # Preserve empty journal directories, including evidence for an interrupted room.
    for directory in sorted(path for path in source.rglob('*') if path.is_dir()):
        target = destination / directory.relative_to(source)
        if any(path.is_symlink() for path in [target, *target.parents]):
            raise ValueError(f'Symlink refused at destination: {target}')
        target.mkdir(parents=True, exist_ok=True)
    for relative, expected in before.items():
        src, dst = safe_file(source, relative), destination / relative
        if any(p.is_symlink() for p in [dst, *dst.parents]):
            raise ValueError(f'Symlink refused at destination: {relative}')
        dst.parent.mkdir(parents=True, exist_ok=True)
        if dst.exists():
            if dst.is_file() and dst.stat().st_nlink > 1:
                raise ValueError(f'Hard-linked destination file (preserved): {relative}')
            if not dst.is_file() or digest(dst) != expected['sha256']:
                raise ValueError(f'Destination conflict (preserved): {relative}')
            continue
        # Exclusive staging outside the destination keeps interrupted scratch files out of its inventory.
        descriptor, name = tempfile.mkstemp(prefix='.capture-pilot-copy-', dir=destination.parent)
        temporary = Path(name)
        try:
            with os.fdopen(descriptor, 'wb') as writer, src.open('rb') as reader:
                shutil.copyfileobj(reader, writer, 1024 * 1024)
                writer.flush()
                os.fsync(writer.fileno())
            if digest(temporary) != expected['sha256']:
                raise ValueError(f'Source changed or copy damaged: {relative}; retry after capture ends.')
            # Atomic exclusive commit: never replace a file that appeared since the earlier check.
            commit_exclusive(temporary, dst)
        finally:
            temporary.unlink(missing_ok=True)
    if inventory(source) != before or directory_inventory(source) != directories:
        raise ValueError('Source changed during transfer. No verification receipt issued; retry with capture stopped.')
    if inventory(destination) != before or directory_inventory(destination) != directories:
        raise ValueError('Destination inventory differs from source, including extra or changed files. Existing files are preserved; no verification receipt issued.')
    require_independent_files(destination)
    verify(destination)
    receipt = destination.parent / (destination.name + '.verified.json')
    atomic_json(receipt, {'format': 'capture-pilot-transfer/1', 'files': before, 'directories': directories, 'sourceDeleted': False})
    return dict(files=len(before), bytes=sum(v['bytes'] for v in before.values()), receipt=str(receipt), sourceDeleted=False)


def verify_copy(root, receipt):
    reject_symlink_tree(root)
    require_independent_files(root)
    value = read_json(receipt)
    if value.get('format') != 'capture-pilot-transfer/1' or not isinstance(value.get('files'), dict) or not isinstance(value.get('directories'), list):
        raise ValueError('Invalid transfer receipt')
    if inventory(root.resolve()) != value['files'] or directory_inventory(root.resolve()) != value['directories']:
        raise ValueError('Archive differs from receipt, including extra, missing or changed files. Existing files are preserved.')
    verify(root)
    return dict(files=len(value['files']), verified=True, sourceDeleted=False)


def header(vertices, faces):
    text = f'ply\nformat binary_little_endian 1.0\ncomment reconstructed offline from verified pilot chunks\nelement vertex {vertices}\n'
    text += ''.join(f'property float {n}\n' for n in ['x', 'y', 'z', 'nx', 'ny', 'nz', 'coverage'])
    text += ''.join(f'property uchar {n}\n' for n in ['red', 'green', 'blue', 'inroom'])
    text += f'element face {faces}\nproperty list uchar uint vertex_indices\nproperty uchar class\nend_header\n'
    return text.encode('ascii')


def reconstruct(session, output):
    reject_symlink_tree(session)
    session, output = session.resolve(), output.resolve()
    if session == output or session in output.parents or output in session.parents:
        raise ValueError('Reconstruction output must be separate from capture evidence.')
    if not (session / 'pilot/session.json').is_file():
        raise ValueError('Reconstruct requires one direct session folder; for a house archive choose its nested sessions/<session> folder.')
    verify(session)
    if output.exists():
        raise ValueError('Use a new reconstruction directory; existing output is preserved.')
    output.mkdir(parents=True)
    journal = session / 'pilot/mesh'
    result = []
    for number, room in journal_rooms(journal):
        parts = entries(journal, number)
        vertex_count = sum(p[0]['vertices'] for p in parts)
        face_count = sum(p[0]['faces'] for p in parts)
        if vertex_count > 2**32 - 1:
            raise ValueError('PLY index capacity exceeded')
        final = output / f'room-{number}.ply'
        partial = final.with_suffix('.ply.partial')
        with partial.open('wb') as writer:
            writer.write(header(vertex_count, face_count))
            for entry, path, offset in parts:
                with path.open('rb') as reader:
                    reader.seek(offset)
                    remaining = entry['vertices'] * 32
                    while remaining:
                        block = reader.read(min(remaining, 1024 * 1024))
                        if not block:
                            raise ValueError(f'Chunk truncated during reconstruction: {path}')
                        writer.write(block)
                        remaining -= len(block)
            base = 0
            for entry, path, offset in parts:
                with path.open('rb') as reader:
                    reader.seek(offset + entry['vertices'] * 32)
                    for _ in range(entry['faces']):
                        count, a, b, c, label = struct.unpack('<BIIIB', reader.read(14))
                        if count != 3 or max(a, b, c) >= entry['vertices']:
                            raise ValueError(f'Invalid face: {path}')
                        writer.write(struct.pack('<BIIIB', count, a + base, b + base, c + base, label))
                base += entry['vertices']
            writer.flush()
            os.fsync(writer.fileno())
        os.replace(partial, final)
        result.append(dict(room=number, vertices=vertex_count, faces=face_count, file=final.name, sha256=digest(final)))
    # Recover independently committed camera/depth indexes, including an unfinished room.
    for folder, name in [('photo-records', 'photos.json'), ('depth-records', 'frames.json')]:
        records = [read_json(safe_file(session, path.relative_to(session).as_posix())) for path in sorted((session / 'pilot' / folder).glob('*.json'))]
        records.sort(key=lambda r: (r['room'], r['timestamp'], r['file']))
        atomic_json(output / name, records)
    atomic_json(output / 'reconstruction.json', {'format': 'capture-pilot-reconstruction/1', 'rooms': result,
        'source': str(session), 'coordinates': 'Original single ARSession frame; no alignment, fusion, or invented surfaces.',
        'coverage': 'Latest persisted scores; bounded live scoring can understate older photo coverage.',
        'photos': 'photos.json contains original paths, poses, intrinsics, actual sizes and highRes flags. Use source images for offline texturing.',
        'incomplete': 'An interrupted room may have mesh/photos/depth but no RoomPlan layout; original evidence is unchanged.'})
    return dict(rooms=len(result), output=str(output), sourceDeleted=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for command in ['verify', 'copy', 'verify-copy', 'reconstruct']:
        p = sub.add_parser(command)
        p.add_argument('source', type=Path)
        if command != 'verify':
            p.add_argument('destination', type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'verify':
            result = verify(args.source.resolve())
        elif args.command == 'verify-copy':
            result = verify_copy(args.source, args.destination)
        elif args.command == 'copy':
            result = copy_verified(args.source, args.destination)
        else:
            result = reconstruct(args.source, args.destination)
        print(json.dumps(result, indent=2))
    except (ValueError, OSError, KeyError, TypeError, struct.error) as error:
        parser.exit(1, f'ERROR: {error}\nEvidence was not deleted.\n')


if __name__ == '__main__':
    main()
