"""Narrow pip HTTP cache engine. No shell commands or recursive deletion."""
import os
import re
import stat
from pathlib import Path

TARGETS = {
    'pip-http': ('Library', 'Caches', 'pip', 'http'),
    'pip-http-v2': ('Library', 'Caches', 'pip', 'http-v2'),
}


class Refused(Exception):
    pass


def identity(st):
    return st.st_dev, st.st_ino


def fingerprint(st):
    return (st.st_dev, st.st_ino, st.st_mode, st.st_uid, st.st_gid,
            st.st_nlink, st.st_size, st.st_mtime_ns, st.st_ctime_ns,
            getattr(st, 'st_flags', 0))


def available(fd):
    try:
        value = os.fstatvfs(fd)
        return value.f_bavail * value.f_frsize
    except OSError:
        return None


class CacheTree:
    def __init__(self, home, target):
        if target not in TARGETS:
            raise Refused('Unknown target')
        self.home = Path(home)
        if not self.home.is_absolute() or '..' in self.home.parts or self.home == Path('/'):
            raise Refused('Invalid home directory')
        self.path = self.home.joinpath(*TARGETS[target])
        self.target = target
        self.uid = os.getuid()
        self.fds = []
        self.edges = []
        self.dirs = {}
        self.root_fd = None

    def __enter__(self):
        try:
            needed = (os.open, os.stat, os.unlink)
            if not all(f in os.supports_dir_fd for f in needed) or os.listdir not in os.supports_fd:
                raise Refused('Python lacks required descriptor-relative filesystem operations')
            fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            self.fds.append(fd)
            for index, name in enumerate(self.path.parts[1:], 1):
                fd = self._open_dir(fd, name, index >= len(self.home.parts) - 1)
            self.root_fd = fd
            self.device = os.fstat(fd).st_dev
            self.dirs[()] = os.fstat(fd)
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def __exit__(self, *args):
        for fd in reversed(self.fds):
            os.close(fd)
        self.fds.clear()

    def _open_dir(self, parent, name, owned=True):
        st = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if not stat.S_ISDIR(st.st_mode) or st.st_mode & 0o022:
            raise Refused('Symlink, non-directory or writable-by-others ancestor: ' + name)
        if st.st_uid not in ((self.uid,) if owned else (0, self.uid)):
            raise Refused('Unexpected directory owner: ' + name)
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        self.fds.append(fd)
        if identity(os.fstat(fd)) != identity(st):
            raise Refused('Directory changed while opening')
        self.edges.append((parent, name, fd, st))
        return fd

    def validate(self):
        for parent, name, fd, old in self.edges:
            now = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if (identity(now) != identity(old) or identity(os.fstat(fd)) != identity(old)
                    or now.st_mode != old.st_mode or now.st_uid != old.st_uid
                    or now.st_gid != old.st_gid):
                raise Refused('Directory identity/permissions changed; rescan required')

    def _regular(self, st):
        if (not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or st.st_uid != self.uid
                or st.st_dev != self.device or st.st_mode & 0o022
                or getattr(st, 'st_flags', 0)):
            raise Refused('Unsafe entry: symlink, hardlink, special file, owner, mode, flags or device')

    def scan(self):
        plan = []

        def walk(parts, fd):
            for name in sorted(os.listdir(fd)):
                st = os.stat(name, dir_fd=fd, follow_symlinks=False)
                if len(parts) < 5:
                    if not re.fullmatch('[0-9a-f]', name) or not stat.S_ISDIR(st.st_mode):
                        raise Refused('Unknown cache structure; no deletion permitted')
                    child = self._open_dir(fd, name)
                    if os.fstat(child).st_dev != self.device:
                        raise Refused('Nested mount/device refused')
                    self.dirs[parts + (name,)] = os.fstat(child)
                    try:
                        walk(parts + (name,), child)
                    finally:
                        self.edges.pop()
                        self.fds.pop()
                        os.close(child)
                else:
                    pattern = r'[0-9a-f]{56}' + (r'(\.body)?' if self.target == 'pip-http-v2' else '')
                    if not re.fullmatch(pattern, name) or tuple(name[:5]) != parts:
                        raise Refused('Unknown cache filename; no deletion permitted')
                    self._regular(st)
                    plan.append((parts + (name,), st))
        walk((), self.root_fd)
        self.validate()
        return plan

    def delete(self, parts, expected):
        # API accepts only a previously scanned leaf inside a pinned directory.
        if (len(parts) != 6 or parts[:-1] not in self.dirs
                or not re.fullmatch(r'[0-9a-f]{56}(\.body)?', parts[-1])
                or tuple(parts[-1][:5]) != parts[:-1]):
            raise Refused('Not a scanned cache leaf')
        self.validate()
        edge_count, fd_count = len(self.edges), len(self.fds)
        fd = self.root_fd
        try:
            for depth, name in enumerate(parts[:-1], 1):
                fd = self._open_dir(fd, name)
                old = self.dirs[parts[:depth]]
                now = os.fstat(fd)
                if (identity(now) != identity(old) or now.st_mode != old.st_mode
                        or now.st_uid != old.st_uid or now.st_gid != old.st_gid):
                    raise Refused('Cache directory changed since preview')
            self.validate()
            current = os.stat(parts[-1], dir_fd=fd, follow_symlinks=False)
            self._regular(current)
            if fingerprint(current) != fingerprint(expected):
                raise Refused('File changed since preview; rescan required')
            # unlink does not follow last-component symlinks. A same-user malicious
            # writer can still race final stat/unlink; see the documented boundary.
            os.unlink(parts[-1], dir_fd=fd)
        finally:
            for opened in reversed(self.fds[fd_count:]):
                os.close(opened)
            del self.fds[fd_count:]
            del self.edges[edge_count:]
