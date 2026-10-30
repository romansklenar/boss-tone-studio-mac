# ADR-0016: Page-chosen files read and written through checked descriptors

Status: accepted, 2026-10-30

## Context

`fs_readString` and `fs_writeString` checked a path against the read or write set
([ADR-0003](ADR-0003-bridge-security.md)) and then opened it by name again. A link swapped in between, for the file or
a folder above it, was followed to wherever it led; missing parent folders were created by path, through such a link.

## Decision

- A read opens the checked path without following a link in its last name (`O_NOFOLLOW`; a link there is refused),
  and without waiting (`O_NONBLOCK`, cleared again before reading). Where the descriptor leads (`F_GETPATH`) must pass
  the same rule before a byte is read. For a file with several hard links `F_GETPATH` may name another one, so the
  descriptor also passes when the checked path, looked up without following a link at any level, names the same file
  (device and inode).
- A write opens the target's folder the same way and checks the folder's path plus the file name against the write
  set, with the same fallback for the folder. Missing folders are made from the deepest existing one, opened and
  checked the same way (its path plus the missing names and the file name), each by `mkdirat` through the descriptor
  of the one above and then opened with `O_NOFOLLOW`, never by path. The write creates a temporary file with a
  fixed-length name through the folder's descriptor, writes it and renames it over the target, which replaces a link
  there instead of following it. A new file gets mode 0666 less the umask, as Foundation's atomic write gave it; in
  place of an existing file the temporary one starts at 0600 and is then given that file's permission bits (not
  setuid, setgid or sticky, owner or extended attributes), so it is never readable by more than the old file was.
- Only a regular file is read: a missing path, a folder, a FIFO, a socket or a device reads as no file, as before.
- The bridge's answers and error texts stay as they were. Storage (`storage.json`, `storage2/`), whose paths the
  bridge names itself, keeps its path API.

## Consequences

- A link swapped in after the check is refused or replaced, never followed, and creates no folder where it leads; a
  write is still atomic and a failed one leaves the old file and no temporary file.
- A target whose name is as long as the system allows can still be saved, since the temporary name does not grow with
  it.
- The descriptor checks rely on Darwin's `F_GETPATH` and `AT_SYMLINK_NOFOLLOW_ANY`.
