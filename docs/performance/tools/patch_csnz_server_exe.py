#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch_csnz_server_exe.py -- applies the performance patches to CSNZ_Server.exe

The patches (see docs/performance/PATCH_NOTES.md for the full write-up):

  1. CTCPServer::Listen()  - the WSAPoll() event masks are synchronised with the real
     state of every client's send queue, which removes the busy-poll loop that burned
     ~100% of one CPU core while any player was connected.  The poll timeout becomes
     1 ms (a queued packet has to be flushed promptly).

  2. The accept path no longer arms the new client's fd with POLLWRNORM.

  3. CFileLogger::LogVarg() - the log file is opened once instead of
     fopen()/vfprintf()/fclose() for every single log line; every line is still flushed,
     so durability is unchanged.

The patched code lives in 384 bytes of padding at the end of .text
(VA 0x140265C70).  Two PE header fields are extended so the injected code and its
globals are inside the mapped image:
    .text VirtualSize 0x264C6F -> 0x265000   (covers the code, stays executable)
    .data VirtualSize 0x027AA8 -> 0x027AC8   (24 bytes of zero-filled BSS for the
                                              cached FILE*, cached path and timer flag)

Everything else in the file stays byte-identical to the original.

Usage:
    python3 patch_csnz_server_exe.py CSNZ_Server.exe --out CSNZ_Server_patched.exe
    python3 patch_csnz_server_exe.py CSNZ_Server_patched.exe --verify
    python3 patch_csnz_server_exe.py CSNZ_Server.exe --dry-run --report-diff
"""

import argparse
import hashlib
import struct
import sys
from pathlib import Path

# --------------------------------------------------------------------------- #
# layout of the binary this patch was developed against
# --------------------------------------------------------------------------- #
IMAGE_BASE = 0x140000000
TEXT_VA, TEXT_RAW, TEXT_VSZ, TEXT_RSZ = 0x1000, 0x400, 0x264C6F, 0x264E00
DATA_VA, DATA_RAW, DATA_VSZ = 0x2D2000, 0x2D0E00, 0x27AA8

CAVE_VA = 0x140265C70             # start of the zero padding at the end of .text
CAVE_FILE = CAVE_VA - IMAGE_BASE - TEXT_VA + TEXT_RAW          # 0x265070
CAVE_SIZE = 0x180                 # 384 bytes of padding available (cave.bin fits exactly)

SYM_PREPOLL = 0x140265C70         # injected: network event-mask synchronisation
SYM_GETLOGFILE = 0x140265D38      # injected: cached log file handle
SYM_LOGDONE = 0x140265D70         # injected: flush instead of fclose

GLOGFILE = 0x1402F9AA8            # cached log FILE*     (new .data BSS tail)
GLOGPATH = 0x1402F9AB0            # cached log path ptr  (new .data BSS tail)
GTIMERFLAG = 0x1402F9AB8          # timeBeginPeriod flag (new .data BSS tail)

SEC_TEXT_VSZ_OFF = 0x210          # .text section header + 8 (VirtualSize)
SEC_TEXT_VSZ_NEW = 0x265000
SEC_DATA_VSZ_OFF = 0x260          # .data section header + 8 (VirtualSize)
SEC_DATA_VSZ_NEW = 0x27AC8

# (VA, original bytes, new bytes or None for "call into the injected code", description)
PATCHES = [
    (0x14011A89C, bytes.fromhex("41b8e8030000"), None,
     "CTCPServer::Listen: 'mov r8d,1000' -> call PrePoll (sync WSAPoll masks)"),
    (0x14011A8A2, bytes.fromhex("488b4968"), bytes.fromhex("488b4f68"),
     "CTCPServer::Listen: read m_fds from rdi (rcx is clobbered by PrePoll)"),
    (0x14011A9EF, bytes.fromhex("c744243810010000"), bytes.fromhex("c744243800010000"),
     "CTCPServer::Listen: new client fd events 0x110 -> 0x100 (POLLRDNORM)"),
    (0x1401101E0, bytes.fromhex("ff15ea681500"), None,
     "CFileLogger::LogVarg: fopen() -> GetLogFile() (open the log file once)"),
    (0x14011020D, bytes.fromhex("ff15ed681500"), None,
     "CFileLogger::LogVarg: fclose() -> LogDone() (flush, keep the handle)"),
]

# sha256 of CSNZ_Server.exe as shipped in this repository
ORIGINAL_SHA256 = "a8a386380d02b6aae1c1d29fea71a3bdbc4bce81fb54c4552a269591cd210856"
EXPECTED_PATCHED_SHA256 = "65c5c9af6d40d26364f569e5f57da63d7e67619538f1317021a86b83064cce8b"


def va2off(va: int) -> int:
    """Virtual address -> file offset (only .text and .data are needed)."""
    rva = va - IMAGE_BASE
    if TEXT_VA <= rva < TEXT_VA + TEXT_RSZ:
        return rva - TEXT_VA + TEXT_RAW
    if DATA_VA <= rva < DATA_VA + DATA_VSZ:
        return rva - DATA_VA + DATA_RAW
    raise ValueError("VA %#x is outside the sections this patcher knows about" % va)


def rel32(site_va: int, target_va: int) -> bytes:
    """call rel32 encoding (5 bytes)."""
    return b"\xe8" + struct.pack("<i", target_va - (site_va + 5))


def build_patches(cave: bytes):
    """returns the full list of (file_offset, original_bytes, new_bytes, description)"""
    out = []
    for va, orig, new, desc in PATCHES:
        if new is None:
            if "PrePoll" in desc:
                new = rel32(va, SYM_PREPOLL) + b"\x90"
            elif "GetLogFile" in desc:
                new = rel32(va, SYM_GETLOGFILE) + b"\x90"
            elif "LogDone" in desc:
                new = rel32(va, SYM_LOGDONE) + b"\x90"
            else:
                raise ValueError(desc)
        assert len(new) == len(orig), desc
        out.append((va2off(va), orig, new, desc))
    out.append((CAVE_FILE, b"\x00" * len(cave), cave,
                "inject helper code into .text padding at %#x" % CAVE_VA))
    out.append((SEC_TEXT_VSZ_OFF, struct.pack("<I", TEXT_VSZ), struct.pack("<I", SEC_TEXT_VSZ_NEW),
                ".text VirtualSize %#x -> %#x (map the injected code)" % (TEXT_VSZ, SEC_TEXT_VSZ_NEW)))
    out.append((SEC_DATA_VSZ_OFF, struct.pack("<I", DATA_VSZ), struct.pack("<I", SEC_DATA_VSZ_NEW),
                ".data VirtualSize %#x -> %#x (zeroed BSS for the injected globals)" % (DATA_VSZ, SEC_DATA_VSZ_NEW)))
    return out


def apply_patch(path: Path, out_path: Path, dry_run=False, verify_only=False, force=False):
    data = bytearray(path.read_bytes())
    cave = (Path(__file__).with_name("cave.bin")).read_bytes()
    if len(cave) > CAVE_SIZE:
        sys.exit("cave.bin is %d bytes, only %d available" % (len(cave), CAVE_SIZE))

    sites = build_patches(cave)
    digest = hashlib.sha256(bytes(data)).hexdigest()
    already_patched = all(bytes(data[o:o + len(n)]) == n for o, _, n, _ in sites)

    if digest != ORIGINAL_SHA256 and not already_patched and not force:
        sys.exit("refusing to patch: sha256 %s\n"
                 "is not the CSNZ_Server.exe this patch was built for (expected %s).\n"
                 "If you are sure this is a compatible build, re-run with --force."
                 % (digest, ORIGINAL_SHA256))

    problems, changed = [], 0
    for off, orig, new, desc in sites:
        cur = bytes(data[off:off + len(orig)])
        if cur == new:
            print("  already patched : %s" % desc)
            continue
        if cur != orig:
            problems.append("  MISMATCH at 0x%x (%s):\n      found    %s\n      expected %s"
                            % (off, desc, cur.hex(" "), orig.hex(" ")))
            continue
        print("  patch 0x%06x : %s" % (off, desc))
        changed += 1
        if not dry_run:
            data[off:off + len(new)] = new

    if problems:
        print("\n".join(problems))
        sys.exit("refusing to patch: the file does not match the expected original")

    if verify_only:
        if changed:
            sys.exit("NOT fully patched: %d of %d site(s) still have the original bytes"
                     % (changed, len(sites)))
        print("\nfile is fully patched  (%s)" % digest)
        return
    if dry_run:
        print("\ndry run: nothing written (%d site(s) would change)" % changed)
        return

    out_path.write_bytes(data)
    new_digest = hashlib.sha256(bytes(data)).hexdigest()
    print("\nwrote %s (%d bytes)" % (out_path, len(data)))
    print("sha256: %s" % new_digest)
    if new_digest == EXPECTED_PATCHED_SHA256:
        print("       matches the reference patched build in docs/performance/binpatch/")


def report_diff(orig_path: Path, patched_path: Path):
    a = orig_path.read_bytes()
    b = patched_path.read_bytes()
    if len(a) != len(b):
        print("\nsize differs: %d -> %d bytes" % (len(a), len(b)))
        return
    runs = []
    for i in range(len(a)):
        if a[i] != b[i]:
            if runs and i == runs[-1][1] + 1:
                runs[-1][1] = i
            else:
                runs.append([i, i])
    print("\n%d differing byte(s) in %d run(s) of %d" % (sum(e - s + 1 for s, e in runs), len(runs), len(a)))
    for s, e in runs:
        print("  0x%06x..0x%06x (%d byte%s)" % (s, e, e - s + 1, "" if e == s else "s"))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("exe", type=Path, help="input file (the original CSNZ_Server.exe, or a patched one)")
    ap.add_argument("--out", type=Path, help="output file (default: patch in place)")
    ap.add_argument("--dry-run", action="store_true", help="verify what would change, write nothing")
    ap.add_argument("--verify", action="store_true", help="exit non-zero unless the file is fully patched")
    ap.add_argument("--report-diff", action="store_true", help="list the differing bytes afterwards")
    ap.add_argument("--force", action="store_true", help="allow inputs that are not the known original")
    args = ap.parse_args()

    print("input sha256: %s" % hashlib.sha256(args.exe.read_bytes()).hexdigest())
    out = args.out or args.exe
    apply_patch(args.exe, out, args.dry_run or args.verify, args.verify, args.force)

    if args.report_diff and not args.dry_run and not args.verify:
        report_diff(args.exe, out)


if __name__ == "__main__":
    main()
