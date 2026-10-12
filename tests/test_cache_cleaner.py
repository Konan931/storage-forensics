"""Synthetic fixtures only; never use real home/cache directories."""
import contextlib
import importlib.util
import io
import os
import pwd
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'lib'))
from dwp_cache import CacheTree, Refused, available
spec = importlib.util.spec_from_file_location('clean_cli', ROOT / 'bin/dwp-cache-clean.py')
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)


class CleanerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cache-test-', dir=str(Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()))
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / 'home'
        self.cache = self.home / 'Library/Caches/pip/http-v2'
        self.leaf = self.cache.joinpath(*list('abcde'), 'abcde' + '0' * 51 + '.body')
        self.leaf.parent.mkdir(parents=True)
        self.leaf.write_bytes(b'cache' * 4096)
        self.sentinel = self.home / 'Pictures/Photos.photoslibrary/sentinel'
        self.sentinel.parent.mkdir(parents=True)
        self.sentinel.write_text('protected')

    def tree(self):
        return CacheTree(str(self.home), 'pip-http-v2')

    def test_preview_preserves_all(self):
        with self.tree() as tree:
            plan = tree.scan()
            self.assertEqual(len(plan), 1)
            self.assertEqual(plan[0][1].st_size, 20480)
        self.assertTrue(self.leaf.exists())

    def test_delete_only_approved_leaf(self):
        with self.tree() as tree:
            plan = tree.scan()
            self.assertIsInstance(available(tree.root_fd), int)
            tree.delete(*plan[0])
        self.assertFalse(self.leaf.exists())
        self.assertTrue(self.leaf.parent.exists())
        self.assertEqual(self.sentinel.read_text(), 'protected')

    def test_unknown_target(self):
        with self.assertRaises(Refused):
            CacheTree(str(self.home), '../../Pictures')

    def test_unknown_directory_blocks_entire_plan(self):
        (self.cache / 'project').mkdir()
        with self.tree() as tree, self.assertRaises(Refused):
            tree.scan()
        self.assertTrue(self.leaf.exists())

    def test_unknown_file_blocks_plan(self):
        (self.leaf.parent / 'notes.txt').write_text('valuable')
        with self.tree() as tree, self.assertRaises(Refused):
            tree.scan()

    def test_leaf_symlink(self):
        self.leaf.unlink()
        self.leaf.symlink_to(self.sentinel)
        with self.tree() as tree, self.assertRaises(Refused):
            tree.scan()
        self.assertEqual(self.sentinel.read_text(), 'protected')

    def test_ancestor_symlink(self):
        moved = self.home / 'moved'
        self.cache.rename(moved)
        self.cache.symlink_to(moved)
        with self.assertRaises((Refused, OSError)), self.tree():
            pass

    def test_hardlink(self):
        self.leaf.unlink()
        os.link(self.sentinel, self.leaf)
        with self.tree() as tree, self.assertRaises(Refused):
            tree.scan()

    def test_fifo(self):
        self.leaf.unlink()
        os.mkfifo(str(self.leaf))
        with self.tree() as tree, self.assertRaises(Refused):
            tree.scan()

    def test_permission_change(self):
        with self.tree() as tree:
            plan = tree.scan()
            self.leaf.parent.chmod(0o777)
            with self.assertRaises(Refused):
                tree.delete(*plan[0])

    def test_file_changed_after_preview(self):
        with self.tree() as tree:
            plan = tree.scan()
            self.leaf.write_text('changed')
            with self.assertRaises(Refused):
                tree.delete(*plan[0])

    def test_file_replaced_with_symlink_after_preview(self):
        with self.tree() as tree:
            plan = tree.scan()
            self.leaf.unlink()
            self.leaf.symlink_to(self.sentinel)
            with self.assertRaises(Refused):
                tree.delete(*plan[0])
        self.assertEqual(self.sentinel.read_text(), 'protected')

    def test_directory_renamed_after_preview(self):
        with self.tree() as tree:
            plan = tree.scan()
            self.cache.rename(self.cache.with_name('moved'))
            self.cache.mkdir()
            with self.assertRaises(Refused):
                tree.delete(*plan[0])

    def test_missing_cache(self):
        with self.assertRaises(FileNotFoundError), CacheTree(str(self.home), 'pip-http'):
            pass

    def test_empty_cache(self):
        self.leaf.unlink()
        with self.tree() as tree:
            self.assertEqual(tree.scan(), [])

    def test_old_format(self):
        old = self.cache.with_name('http')
        self.cache.rename(old)
        body = old.joinpath(*list('abcde'), self.leaf.name)
        body.rename(body.with_suffix(''))
        with CacheTree(str(self.home), 'pip-http') as tree:
            plan = tree.scan()
            tree.delete(*plan[0])

    def run_cli(self, args, answers=(), tty=True):
        # Only the synthetic home is injected; production exposes no home override.
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(sys, 'argv', ['clean'] + args))
            stack.enter_context(patch.object(sys, 'platform', 'darwin'))
            stack.enter_context(patch.object(cli.os, 'getuid', return_value=501))
            stack.enter_context(patch.object(cli.os, 'geteuid', return_value=501))
            stack.enter_context(patch.object(cli.pwd, 'getpwuid', return_value=type('User', (), {'pw_dir': str(self.home)})()))
            # Fixture files belong to the actual test runner (possibly root).
            actual_uid = self.leaf.stat().st_uid
            real_tree = CacheTree
            def fixture_tree(home, target):
                tree = real_tree(home, target)
                tree.uid = actual_uid
                return tree
            stack.enter_context(patch.object(cli, 'CacheTree', side_effect=fixture_tree))
            stack.enter_context(patch('builtins.input', side_effect=answers))
            stack.enter_context(patch.object(sys.stdin, 'isatty', return_value=tty))
            output = io.StringIO()
            output.isatty = lambda: tty
            stack.enter_context(contextlib.redirect_stdout(output))
            result = cli.main()
            return result, output.getvalue()

    def test_cli_default_dry_run(self):
        result, output = self.run_cli(['--target', 'pip-http-v2'])
        self.assertEqual(result, 0)
        self.assertTrue(self.leaf.exists())
        self.assertIn('No changes', output)

    def test_cli_apply_approval_and_measurement(self):
        result, output = self.run_cli(['--target', 'pip-http-v2', '--apply'], ['JOBS STOPPED', 'DELETE'])
        self.assertFalse(self.leaf.exists())
        self.assertIn('1 files unlinked', output)
        self.assertIn('observed delta=', output)

    def test_cli_decline(self):
        self.run_cli(['--target', 'pip-http-v2', '--apply'], ['JOBS STOPPED', 'no'])
        self.assertTrue(self.leaf.exists())

    def test_cli_skip(self):
        self.run_cli(['--target', 'pip-http-v2', '--apply'], ['JOBS STOPPED', 'SKIP'])
        self.assertTrue(self.leaf.exists())

    def test_cli_noninteractive_refused(self):
        with self.assertRaises(Refused):
            self.run_cli(['--target', 'pip-http-v2', '--apply'], tty=False)

    def test_cli_no_global_yes_or_path_override(self):
        for arg in ['--yes', '--home', '--path', '--approved']:
            result = subprocess.run([sys.executable, str(ROOT / 'bin/dwp-cache-clean.py'), arg], capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_plain_and_forced_color(self):
        _, plain = self.run_cli(['--target', 'pip-http-v2', '--color', 'never'])
        _, ansi = self.run_cli(['--target', 'pip-http-v2', '--color', 'always'])
        self.assertNotIn('\033', plain)
        self.assertIn('\033[', ansi)

    def test_all_protected_sentinels(self):
        paths = ['Library/Application Support/MobileSync/Backup',
                 'Library/Mobile Documents', 'Library/CloudStorage',
                 'Library/Containers/com.docker.docker', 'Projects',
                 'Library/Caches/unknown']
        for path in paths:
            folder = self.home / path
            folder.mkdir(parents=True, exist_ok=True)
            (folder / 'sentinel').write_text('keep')
        with self.tree() as tree:
            tree.delete(*tree.scan()[0])
        for path in paths:
            self.assertEqual((self.home / path / 'sentinel').read_text(), 'keep')

    def test_unlink_failure_is_not_reported_as_success(self):
        original = os.unlink
        with self.tree() as tree:
            plan = tree.scan()
            with patch('dwp_cache.os.unlink', side_effect=PermissionError('fixture')):
                with self.assertRaises(PermissionError):
                    tree.delete(*plan[0])
        self.assertTrue(self.leaf.exists())

    def test_no_color_environment(self):
        with patch.dict(os.environ, {'NO_COLOR': ''}):
            _, output = self.run_cli(['--target', 'pip-http-v2'])
        self.assertNotIn('\033', output)

    def test_cli_interrupt_keeps_file(self):
        with self.assertRaises(KeyboardInterrupt):
            self.run_cli(['--target', 'pip-http-v2', '--apply'], ['JOBS STOPPED', KeyboardInterrupt()])
        self.assertTrue(self.leaf.exists())

    def test_nested_directory_replaced(self):
        with self.tree() as tree:
            plan = tree.scan()
            parent = self.leaf.parent
            parent.rename(parent.with_name('saved'))
            parent.mkdir()
            self.leaf.write_text('new content')
            with self.assertRaises(Refused):
                tree.delete(*plan[0])
        self.assertEqual(self.leaf.read_text(), 'new content')

    def test_root_cli_refused(self):
        with patch.object(sys, 'argv', ['clean', '--target', 'pip-http-v2']), \
             patch.object(sys, 'platform', 'darwin'), \
             patch.object(os, 'getuid', return_value=0), \
             contextlib.redirect_stdout(io.StringIO()), self.assertRaises(Refused):
            cli.main()

    def test_available_unknown(self):
        with patch('dwp_cache.os.fstatvfs', side_effect=OSError):
            self.assertIsNone(available(0))


if __name__ == '__main__':
    unittest.main()
