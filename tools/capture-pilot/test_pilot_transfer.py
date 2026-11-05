import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('pilot_transfer', Path(__file__).with_name('pilot_transfer.py'))
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


class PilotTransferTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.source = self.root / 'session'
        self.journal = self.source / 'pilot/mesh'
        p.atomic_json(self.source / 'pilot/session.json', {'format': 'capture-pilot/1', 'meshJournal': 'pilot/mesh', 'completedRooms': 2})
        self.add_anchor(0, 'a', 0)
        self.add_anchor(0, 'b', 2)
        self.add_anchor(1, 'a', 8)

    def tearDown(self):
        self.temp.cleanup()

    def photo_record(self, **overrides):
        record = dict(file='photos/0000.jpg', room=0, timestamp=1, width=1, height=1,
                      transform=[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
                      intrinsics=[1, 0, 0, 0, 1, 0, 0, 0, 1], tracking='normal', manual=False)
        record.update(overrides)
        return record

    def add_anchor(self, room, name, x):
        data = p.header(3, 1)
        for pos in [(x, 0, 0), (x + 1, 0, 0), (x, 1, 0)]:
            data += struct.pack('<7f4B', *pos, 0, 0, 1, 0, 255, 0, 0, 1)
        data += struct.pack('<BIIIB', 3, 0, 1, 2, 1)
        sha = p.hashlib.sha256(data).hexdigest()
        chunk = self.journal / f'chunks/{sha}.ply'
        chunk.parent.mkdir(parents=True, exist_ok=True)
        chunk.write_bytes(data)
        p.atomic_json(self.journal / f'room-{room}/anchors/{name}.json', dict(format='capture-pilot-mesh/1', anchor=name,
            chunk=f'chunks/{sha}.ply', sha256=sha, vertices=3, faces=1, coveredArea=0, totalArea=1))
        return chunk

    def test_copy_verified_and_idempotent_resume(self):
        target = self.root / 'copy'
        first = p.copy_verified(self.source, target)
        second = p.copy_verified(self.source, target)
        self.assertEqual(first, second)
        self.assertEqual(p.inventory(self.source), p.inventory(target))
        self.assertFalse(first['sourceDeleted'])
        self.assertTrue(Path(first['receipt']).is_file())

    def test_resume_rejects_matching_hardlinks_to_source_or_other_file(self):
        for source_link in [True, False]:
            with self.subTest(source_link=source_link):
                target = self.root / f'hardlink-copy-{source_link}'
                dst = target / 'pilot/session.json'
                dst.parent.mkdir(parents=True)
                original = self.source / 'pilot/session.json'
                linked = original if source_link else self.root / 'other-matching-file'
                if not source_link:
                    p.shutil.copyfile(original, linked)
                p.os.link(linked, dst)
                before = dst.read_bytes()
                with self.assertRaisesRegex(ValueError, 'Hard-linked destination'):
                    p.copy_verified(self.source, target)
                self.assertEqual(dst.read_bytes(), before)
                self.assertEqual(linked.read_bytes(), before)
                self.assertFalse((self.root / (target.name + '.verified.json')).exists())

    def test_receipt_recheck_rejects_later_hardlink(self):
        target = self.root / 'copy'
        receipt = Path(p.copy_verified(self.source, target)['receipt'])
        archive_file = target / 'pilot/session.json'
        linked = self.root / 'later-link'
        p.os.link(archive_file, linked)
        with self.assertRaisesRegex(ValueError, 'Hard-linked archive'):
            p.verify_copy(target, receipt)
        self.assertTrue(archive_file.is_file())
        self.assertTrue(linked.is_file())

    def test_receipt_detects_later_corruption(self):
        target = self.root / 'copy'
        receipt = Path(p.copy_verified(self.source, target)['receipt'])
        self.assertTrue(p.verify_copy(target, receipt)['verified'])
        (target / 'pilot/session.json').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'Archive differs'):
            p.verify_copy(target, receipt)

    def test_receipt_recheck_rejects_valid_post_receipt_extra_evidence(self):
        target = self.root / 'copy'
        receipt = Path(p.copy_verified(self.source, target)['receipt'])
        extra = target / 'pilot/mesh/room-99/anchors/stale.json'
        original = p.read_json(self.journal / 'room-0/anchors/a.json')
        original['anchor'] = 'stale'
        p.atomic_json(extra, original)
        self.assertEqual(p.verify(target)['rooms'], 3)
        with self.assertRaisesRegex(ValueError, 'Archive differs from receipt'):
            p.verify_copy(target, receipt)
        self.assertEqual(p.read_json(extra), original)
        self.assertTrue(receipt.is_file())

    def test_resume_completed_files_with_interrupted_sibling_staging(self):
        target = self.root / 'copy'
        (target / 'pilot').mkdir(parents=True)
        p.shutil.copyfile(self.source / 'pilot/session.json', target / 'pilot/session.json')
        interrupted = self.root / '.capture-pilot-copy-interrupted'
        interrupted.write_bytes(b'truncated-owned-staging-from-an-earlier-process')
        p.copy_verified(self.source, target)
        self.assertEqual(p.inventory(self.source), p.inventory(target))
        self.assertEqual(interrupted.read_bytes(), b'truncated-owned-staging-from-an-earlier-process')

    def test_atomic_json_ignores_predictable_symlink_and_hardlink_victims(self):
        for kind in ['symlink', 'hardlink']:
            with self.subTest(kind=kind):
                victim = self.root / f'{kind}-victim'
                victim.write_bytes(b'preserve unrelated file')
                receipt = self.root / f'{kind}-receipt.json'
                old_partial = receipt.with_name('.' + receipt.name + '.partial')
                if kind == 'symlink':
                    old_partial.symlink_to(victim)
                else:
                    p.os.link(victim, old_partial)
                p.atomic_json(receipt, {'verified': True})
                self.assertEqual(victim.read_bytes(), b'preserve unrelated file')
                self.assertEqual(old_partial.read_bytes(), b'preserve unrelated file')
                self.assertEqual(p.read_json(receipt), {'verified': True})

    def test_atomic_json_failure_preserves_receipt_and_cleans_only_owned_temp(self):
        receipt = self.root / 'receipt.json'
        p.atomic_json(receipt, {'old': True})
        unrelated = self.root / '.capture-pilot-json-unrelated'
        unrelated.write_text('preserve')
        before = set(self.root.iterdir())
        with patch.object(p.json, 'dump', side_effect=OSError('synthetic write failure')):
            with self.assertRaises(OSError):
                p.atomic_json(receipt, {'new': True})
        self.assertEqual(p.read_json(receipt), {'old': True})
        self.assertEqual(unrelated.read_text(), 'preserve')
        self.assertEqual(set(self.root.iterdir()), before)

    def test_copy_does_not_open_legacy_partial_symlink_or_hardlink(self):
        for kind in ['symlink', 'hardlink']:
            with self.subTest(kind=kind):
                victim = self.root / f'copy-{kind}-victim'
                victim.write_bytes(b'preserve unrelated file')
                target = self.root / f'copy-{kind}'
                (target / 'pilot').mkdir(parents=True)
                old_partial = target / 'pilot/.session.json.partial'
                if kind == 'symlink':
                    old_partial.symlink_to(victim)
                else:
                    p.os.link(victim, old_partial)
                with self.assertRaisesRegex(ValueError, 'Symlink|Destination inventory differs'):
                    p.copy_verified(self.source, target)
                self.assertEqual(victim.read_bytes(), b'preserve unrelated file')
                self.assertEqual(old_partial.read_bytes(), b'preserve unrelated file')
                self.assertFalse((self.root / (target.name + '.verified.json')).exists())

    def test_copy_preserves_destination_created_during_commit(self):
        target = self.root / 'copy'
        real_commit = p.commit_exclusive
        raced = []
        def racing_commit(source, destination):
            Path(destination).write_bytes(b'new unrelated destination file')
            raced.append(Path(destination))
            return real_commit(source, destination)
        with patch.object(p, 'commit_exclusive', racing_commit):
            with self.assertRaises(FileExistsError):
                p.copy_verified(self.source, target)
        self.assertEqual(raced[0].read_bytes(), b'new unrelated destination file')
        self.assertFalse((self.root / 'copy.verified.json').exists())
        self.assertFalse(list(self.root.glob('.capture-pilot-copy-*')))

    def test_interruption_after_exclusive_commit_can_resume(self):
        target = self.root / 'copy'
        real_commit = p.commit_exclusive
        committed = []
        def interrupted_commit(source, destination):
            real_commit(source, destination)
            self.assertFalse(Path(source).exists())
            self.assertEqual(Path(destination).stat().st_nlink, 1)
            committed.append(Path(destination))
            raise KeyboardInterrupt('synthetic interruption after atomic commit')
        with patch.object(p, 'commit_exclusive', interrupted_commit):
            with self.assertRaises(KeyboardInterrupt):
                p.copy_verified(self.source, target)
        self.assertEqual(len(committed), 1)
        self.assertFalse((self.root / 'copy.verified.json').exists())
        receipt = Path(p.copy_verified(self.source, target)['receipt'])
        self.assertTrue(p.verify_copy(target, receipt)['verified'])
        self.assertEqual(p.inventory(self.source), p.inventory(target))

    def test_unsupported_exclusive_commit_preserves_source(self):
        source = self.root / 'staging'
        source.write_bytes(b'evidence')
        destination = self.root / 'destination'
        with patch.object(p.sys, 'platform', 'unsupported'):
            with self.assertRaises(OSError):
                p.commit_exclusive(source, destination)
        self.assertEqual(source.read_bytes(), b'evidence')
        self.assertFalse(destination.exists())

    def test_destination_conflict_preserves_both(self):
        target = self.root / 'copy'
        p.copy_verified(self.source, target)
        conflict = target / 'pilot/session.json'
        conflict.write_text('keep my file')
        with self.assertRaisesRegex(ValueError, 'Destination conflict'):
            p.copy_verified(self.source, target)
        self.assertEqual(conflict.read_text(), 'keep my file')
        self.assertTrue((self.source / 'pilot/session.json').is_file())

    def test_extra_room_pointer_rejects_receipt_and_is_preserved(self):
        target = self.root / 'copy'
        pointer = target / 'pilot/mesh/room-99/anchors/stale.json'
        original = p.read_json(self.journal / 'room-0/anchors/a.json')
        original['anchor'] = 'stale'
        p.atomic_json(pointer, original)
        with self.assertRaisesRegex(ValueError, 'Destination inventory differs'):
            p.copy_verified(self.source, target)
        self.assertEqual(p.read_json(pointer), original)
        self.assertFalse((self.root / 'copy.verified.json').exists())
        self.assertEqual(p.verify(target)['rooms'], 3)  # otherwise valid but stale evidence

    def test_extra_photo_sidecar_rejects_receipt_and_is_preserved(self):
        image = self.source / 'photos/0000.jpg'
        image.parent.mkdir()
        image.write_bytes(b'synthetic-reference-photo')
        target = self.root / 'copy'
        extra = target / 'pilot/photo-records/stale.json'
        record = self.photo_record(room=99)
        p.atomic_json(extra, record)
        with self.assertRaisesRegex(ValueError, 'Destination inventory differs'):
            p.copy_verified(self.source, target)
        self.assertEqual(p.read_json(extra), record)
        self.assertFalse((self.root / 'copy.verified.json').exists())
        self.assertEqual(p.verify(target)['photoRecords'], 1)

    def test_duplicate_or_misnamed_pointer_rejected_before_copy_and_reconstruction(self):
        original = self.journal / 'room-0/anchors/a.json'
        duplicate = original.with_name('duplicate.json')
        p.shutil.copyfile(original, duplicate)
        for action in [lambda: p.verify(self.source),
                       lambda: p.copy_verified(self.source, self.root / 'copy'),
                       lambda: p.reconstruct(self.source, self.root / 'models')]:
            with self.assertRaisesRegex(ValueError, 'anchor identity'):
                action()
        self.assertTrue(original.is_file())
        self.assertTrue(duplicate.is_file())
        self.assertFalse((self.root / 'copy').exists())
        self.assertFalse((self.root / 'models').exists())

    def test_room_journal_aliases_and_non_directory_names_rejected(self):
        for name, keep_canonical, as_file in [('room-01', False, False),
                                             ('room-01', True, False),
                                             ('room--1', True, False),
                                             ('room-2', True, True)]:
            with self.subTest(name=name, canonical=keep_canonical, file=as_file):
                archive = self.root / f'archive-{name}-{keep_canonical}-{as_file}'
                p.shutil.copytree(self.source, archive)
                journal = archive / 'pilot/mesh'
                alias = journal / name
                if as_file:
                    alias.write_text('not a directory')
                elif keep_canonical:
                    p.shutil.copytree(journal / 'room-1', alias)
                else:
                    (journal / 'room-1').rename(alias)
                for action in [lambda: p.verify(archive),
                               lambda: p.copy_verified(archive, self.root / 'invalid-copy'),
                               lambda: p.reconstruct(archive, self.root / 'invalid-models')]:
                    with self.assertRaisesRegex(ValueError, 'room journal'):
                        action()
                self.assertTrue(alias.exists())
                self.assertFalse((self.root / 'invalid-copy').exists())
                self.assertFalse((self.root / 'invalid-models').exists())

    def test_missing_completed_journal_rejected_before_copy_and_reconstruction(self):
        for missing in ['pilot/mesh', 'pilot/mesh/room-1', 'pilot/mesh/chunks', 'pilot/mesh/room-1/anchors']:
            with self.subTest(missing=missing):
                archive = self.root / ('missing-' + missing.replace('/', '-'))
                p.shutil.copytree(self.source, archive)
                removed = archive / missing
                removed.rename(self.root / ('preserved-' + missing.replace('/', '-')))
                for action in [lambda: p.verify(archive),
                               lambda: p.copy_verified(archive, self.root / 'missing-copy'),
                               lambda: p.reconstruct(archive, self.root / 'missing-models')]:
                    with self.assertRaisesRegex(ValueError, 'Missing'):
                        action()
                self.assertFalse((self.root / 'missing-copy').exists())
                self.assertFalse((self.root / 'missing-models').exists())

    def test_empty_interrupted_journal_copies_with_directories(self):
        empty = self.root / 'interrupted'
        (empty / 'pilot/mesh/room-0/anchors').mkdir(parents=True)
        (empty / 'pilot/mesh/chunks').mkdir()
        p.atomic_json(empty / 'pilot/session.json',
                      {'format': 'capture-pilot/1', 'meshJournal': 'pilot/mesh', 'completedRooms': 0})
        target = self.root / 'interrupted-copy'
        receipt = Path(p.copy_verified(empty, target)['receipt'])
        self.assertTrue((target / 'pilot/mesh/room-0/anchors').is_dir())
        self.assertTrue(p.verify_copy(target, receipt)['verified'])
        self.assertEqual(p.verify(target)['rooms'], 1)
        (target / 'pilot/mesh/room-0/anchors').rename(target / 'pilot/missing-anchors')
        with self.assertRaisesRegex(ValueError, 'Archive differs'):
            p.verify_copy(target, receipt)

    def test_receipt_detects_loss_of_whole_empty_interrupted_room(self):
        empty_room = self.journal / 'room-2/anchors'
        empty_room.mkdir(parents=True)
        target = self.root / 'copy'
        receipt = Path(p.copy_verified(self.source, target)['receipt'])
        (target / 'pilot/mesh/room-2').rename(self.root / 'preserved-empty-room')
        with self.assertRaisesRegex(ValueError, 'Archive differs'):
            p.verify_copy(target, receipt)

    def test_directory_only_source_change_during_copy_stops_receipt(self):
        real_commit = p.commit_exclusive
        target = self.root / 'copy'
        def changed_commit(source, destination):
            real_commit(source, destination)
            (self.source / 'new-empty-directory').mkdir(exist_ok=True)
        with patch.object(p, 'commit_exclusive', changed_commit):
            with self.assertRaisesRegex(ValueError, 'Source changed'):
                p.copy_verified(self.source, target)
        self.assertFalse((self.root / 'copy.verified.json').exists())

    def test_incomplete_photo_and_depth_records_rejected_before_output(self):
        image = self.source / 'photos/0000.jpg'
        image.parent.mkdir()
        image.write_bytes(b'synthetic image')
        for depth in [False, True]:
            valid = self.photo_record()
            if depth:
                valid['confidence'] = valid['file']
            cases = [{}]
            for key in ['file', 'room', 'timestamp', 'width', 'height', 'transform', 'intrinsics'] + (['confidence'] if depth else ['tracking', 'manual']):
                record = dict(valid)
                del record[key]
                cases.append(record)
            cases.extend([dict(valid, timestamp=float('nan')), dict(valid, room=True), dict(valid, transform=[0])])
            folder = self.source / ('pilot/depth-records' if depth else 'pilot/photo-records')
            sidecar = folder / 'record.json'
            for record in cases:
                p.atomic_json(sidecar, record)
                for action in [lambda: p.verify(self.source),
                               lambda: p.copy_verified(self.source, self.root / 'invalid-record-copy'),
                               lambda: p.reconstruct(self.source, self.root / 'invalid-record-models')]:
                    with self.assertRaises(ValueError):
                        action()
                self.assertFalse((self.root / 'invalid-record-copy').exists())
                self.assertFalse((self.root / 'invalid-record-models').exists())
            p.atomic_json(sidecar, valid)
            self.assertGreater(p.verify(self.source)['depthRecords' if depth else 'photoRecords'], 0)

    def test_corruption_prevents_copy(self):
        chunk = next((self.journal / 'chunks').glob('*.ply'))
        chunk.write_bytes(b'corrupt')
        with self.assertRaisesRegex(ValueError, 'Hash mismatch|Chunk hash mismatch'):
            p.copy_verified(self.source, self.root / 'copy')
        self.assertFalse((self.root / 'copy.verified.json').exists())

    def test_reconstruct_offsets_and_room_immutability(self):
        p.reconstruct(self.source, self.root / 'models')
        mesh = self.root / 'models/room-0.ply'
        vertices, faces, offset = p.ply_info(mesh)
        self.assertEqual((vertices, faces), (6, 2))
        data = mesh.read_bytes()
        self.assertEqual(struct.unpack_from('<BIIIB', data, offset + 6 * 32 + 14), (3, 3, 4, 5, 1))
        self.assertEqual(struct.unpack_from('<f', data, offset)[0], 0)
        other = self.root / 'models/room-1.ply'
        self.assertEqual(struct.unpack_from('<f', other.read_bytes(), p.ply_info(other)[2])[0], 8)

    def test_interrupted_record_recovery(self):
        image = self.source / 'photos/0000.jpg'
        image.parent.mkdir()
        image.write_bytes(b'synthetic-jpeg-placeholder')
        record = self.photo_record(room=2, timestamp=5, width=4032, height=3024, highRes=True)
        p.atomic_json(self.source / 'pilot/photo-records/0000.jpg.json', record)
        p.reconstruct(self.source, self.root / 'models')
        self.assertEqual(p.read_json(self.root / 'models/photos.json'), [record])

    def test_missing_photo_is_not_verified(self):
        p.atomic_json(self.source / 'pilot/photo-records/a.json', self.photo_record(file='photos/missing.jpg'))
        with self.assertRaisesRegex(ValueError, 'Missing file'):
            p.verify(self.source)

    def test_path_traversal_and_symlink_refused(self):
        with self.assertRaises(ValueError):
            p.safe_file(self.source, '../other')
        (self.source / 'link').symlink_to(self.root)
        with self.assertRaisesRegex(ValueError, 'Symlink'):
            p.copy_verified(self.source, self.root / 'copy')

    def test_metadata_file_symlinks_rejected_before_any_json_parse(self):
        paths = ['pilot/session.json', 'pilot/mesh/room-0/anchors/a.json',
                 'pilot/photo-records/linked.json', 'pilot/depth-records/linked.json']
        for index, relative in enumerate(paths):
            with self.subTest(path=relative):
                archive = self.root / f'linked-archive-{index}'
                p.shutil.copytree(self.source, archive)
                outside = self.root / f'external-metadata-{index}.json'
                outside.write_bytes(b'external invalid JSON must never be parsed')
                link = archive / relative
                link.parent.mkdir(parents=True, exist_ok=True)
                link.unlink(missing_ok=True)
                link.symlink_to(outside)
                with patch.object(p, 'read_json', side_effect=AssertionError('metadata parsed before tree validation')):
                    for operation in [lambda: p.verify(archive),
                                      lambda: p.copy_verified(archive, self.root / f'linked-copy-{index}'),
                                      lambda: p.reconstruct(archive, self.root / f'linked-models-{index}')]:
                        with self.assertRaisesRegex(ValueError, 'Symlink'):
                            operation()
                    if 'anchors' in relative:
                        with self.assertRaisesRegex(ValueError, 'Symlink'):
                            p.entries(archive / 'pilot/mesh', 0)
                self.assertEqual(outside.read_bytes(), b'external invalid JSON must never be parsed')
                self.assertTrue(link.is_symlink())
                self.assertFalse((self.root / f'linked-copy-{index}').exists())
                self.assertFalse((self.root / f'linked-models-{index}').exists())

    def test_metadata_directory_symlink_rejected_before_parsing(self):
        outside = self.root / 'external-records'
        outside.mkdir()
        victim = outside / 'record.json'
        victim.write_bytes(b'external invalid JSON must never be parsed')
        (self.source / 'pilot/photo-records').symlink_to(outside, target_is_directory=True)
        with patch.object(p, 'read_json', side_effect=AssertionError('external metadata parsed')):
            with self.assertRaisesRegex(ValueError, 'Symlink'):
                p.verify(self.source)
            with self.assertRaisesRegex(ValueError, 'Symlink'):
                p.reconstruct(self.source, self.root / 'models')
        self.assertEqual(victim.read_bytes(), b'external invalid JSON must never be parsed')
        self.assertFalse((self.root / 'models').exists())

    def test_output_symlink_parent_cannot_alias_inside_source(self):
        alias = self.root / 'source-alias'
        alias.symlink_to(self.source, target_is_directory=True)
        before = p.inventory(self.source)
        for name, operation in [('copy', p.copy_verified), ('models', p.reconstruct)]:
            with self.subTest(operation=name):
                with self.assertRaisesRegex(ValueError, 'separate'):
                    operation(self.source, alias / name)
                self.assertFalse((self.source / name).exists())
                self.assertEqual(p.inventory(self.source), before)
        self.assertTrue(alias.is_symlink())

    def test_mutating_source_has_no_receipt(self):
        real_inventory = p.inventory
        calls = 0
        def changing(root):
            nonlocal calls
            calls += 1
            if calls == 2:
                (self.source / 'new-file').write_text('changed while copying')
            return real_inventory(root)
        with patch.object(p, 'inventory', changing):
            with self.assertRaisesRegex(ValueError, 'Source changed'):
                p.copy_verified(self.source, self.root / 'copy')
        self.assertFalse((self.root / 'copy.verified.json').exists())

    def test_21_separate_room_reconstruction(self):
        for room in range(2, 21):
            self.add_anchor(room, 'a', room * 2)
        self.assertEqual(p.verify(self.source)['rooms'], 21)
        self.assertEqual(p.reconstruct(self.source, self.root / 'models')['rooms'], 21)
        self.assertEqual(len(list((self.root / 'models').glob('room-*.ply'))), 21)

    def test_house_archive_reconstruction_rejected_before_output(self):
        house = self.root / 'house'
        nested = house / 'sessions/capture'
        nested.parent.mkdir(parents=True)
        self.source.rename(nested)
        self.assertEqual(p.verify(house)['sessions'], 1)
        output = self.root / 'models'
        with self.assertRaisesRegex(ValueError, 'direct session folder'):
            p.reconstruct(house, output)
        self.assertFalse(output.exists())
        self.assertEqual(p.reconstruct(nested, output)['rooms'], 2)

    def test_existing_reconstruction_not_overwritten(self):
        p.reconstruct(self.source, self.root / 'models')
        before = p.inventory(self.root / 'models')
        with self.assertRaisesRegex(ValueError, 'existing output'):
            p.reconstruct(self.source, self.root / 'models')
        self.assertEqual(before, p.inventory(self.root / 'models'))


if __name__ == '__main__':
    unittest.main()
