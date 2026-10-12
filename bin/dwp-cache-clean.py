#!/usr/bin/env python3
"""Explicit, interactive cache cleanup; Python 3.8+, standard library only."""
import argparse
import os
import pwd
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'lib'))
from dwp_cache import CacheTree, Refused, TARGETS, available


def main():
    parser = argparse.ArgumentParser(description='DWP controlled cache cleaner: preview by default.',
        epilog='Only fixed pip HTTP caches. No custom paths, sudo, --yes, or recursive removal. '
               'Stop pip/install/build jobs first. Downloads may be needed again. '
               'Each unlink requires typing DELETE in a terminal. See docs/cache-cleaner.md.')
    parser.add_argument('--target', choices=sorted(TARGETS), help='Exactly one allowlisted cache')
    parser.add_argument('--list', action='store_true', help='Show fixed targets without scanning')
    parser.add_argument('--apply', action='store_true', help='Enable per-file interactive deletion')
    parser.add_argument('--color', choices=('auto', 'always', 'never'), default='auto')
    args = parser.parse_args()
    color = args.color == 'always' or (args.color == 'auto' and sys.stdout.isatty()
                and 'NO_COLOR' not in os.environ and os.environ.get('TERM') != 'dumb')
    print(('\033[1;36m' if color else '') + 'DWP // CONTROLLED CACHE CLEANER' + ('\033[0m' if color else ''))
    if args.list:
        if args.apply or args.target:
            parser.error('--list cannot be combined with --target or --apply')
        for key, parts in sorted(TARGETS.items()):
            print('{}: ~/{}'.format(key, '/'.join(parts)))
        return 0
    if not args.target:
        parser.error('--target is required (or use --list)')
    if sys.platform != 'darwin':
        raise Refused('Live scanning/cleanup requires macOS; tests use isolated fixtures.')
    if os.getuid() == 0 or os.geteuid() != os.getuid():
        raise Refused('Do not run as root, sudo, or with changed privileges.')
    home = pwd.getpwuid(os.getuid()).pw_dir
    if args.apply and not (sys.stdin.isatty() and sys.stdout.isatty()):
        raise Refused('--apply requires interactive terminal input and output.')
    with CacheTree(home, args.target) as tree:
        plan = tree.scan()
        print('Target: {}'.format(ascii(str(tree.path))))
        print('PREVIEW: {} files; {} logical bytes; {} allocated bytes (estimate).'.format(
            len(plan), sum(s.st_size for _, s in plan), sum(s.st_blocks * 512 for _, s in plan)))
        print('Downloads can be fetched again only while their upstream source remains available.')
        for name, st in plan:
            print('  {:>12} bytes  {}'.format(st.st_size, ascii('/'.join(name))))
        if not args.apply or not plan:
            print('No changes. Use --apply for interactive per-file approval.')
            return 0
        if input('Stop all pip/install/build jobs. Type JOBS STOPPED to continue: ') != 'JOBS STOPPED':
            print('Cancelled; no changes.')
            return 0
        before = available(tree.root_fd)
        count = logical = allocated = 0
        try:
            for name, st in plan:
                print('UNLINK {} ({} bytes)'.format(ascii(str(tree.path.joinpath(*name))), st.st_size))
                answer = input('Type DELETE for this file, SKIP to keep it, anything else to stop: ')
                if answer == 'SKIP':
                    continue
                if answer != 'DELETE':
                    break
                tree.delete(name, st)
                count += 1
                logical += st.st_size
                allocated += st.st_blocks * 512
                print('DELETED {}'.format(ascii('/'.join(name))))
        finally:
            after = available(tree.root_fd)
            print('RESULT: {} files unlinked; {} logical bytes; {} allocated bytes estimated.'.format(count, logical, allocated))
            print('Available bytes before={}, after={}, observed delta={}.'.format(
                before, after, 'unknown' if before is None or after is None else after - before))
            print('Delta is volume-wide, not attributable reclaimed bytes: APFS snapshots/clones, '
                  'open files and concurrent activity affect it. Empty directories are retained.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (Refused, OSError) as exc:
        print('STOP: {}'.format(ascii(str(exc))), file=sys.stderr)
        sys.exit(2)
    except (KeyboardInterrupt, EOFError):
        print('\nStopped by operator; any already reported deletions remain in effect.', file=sys.stderr)
        sys.exit(130)
