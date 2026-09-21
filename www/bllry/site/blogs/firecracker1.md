% firecracker: W^X bypass via unrestricted mprotect in the vmm seccomp filter
% bllry
% 2026-05-28

<!-- gif goes here -->
<p><img src="" alt="" border="0"></p>

Reported to AWS VDP, fixed in v1.16.0.

This is a writeup of a seccomp policy gap I found and reported in
[Firecracker](https://github.com/firecracker-microvm/firecracker), AWS's VMM
behind Lambda and Fargate. The vmm-thread seccomp filter in v1.15.1 lets you
flip an anonymous page to `PROT_EXEC`, so any code-exec primitive inside the
VMM turns straight into stable shellcode. seccomp is the last containment
layer after jailer/chroot/namespaces &mdash; and here it doesn't enforce W^X.

## Background

Firecracker ships per-thread seccomp filters (`vmm`, `api`, `vcpu`), compiled
from JSON in `resources/seccomp/` and installed before guest code runs.
They're an allowlist: `default_action` is `trap`, matched rules `allow`. The
point of the filter is to shrink what a compromised VMM thread can ask the
host kernel to do.

If that filter is doing its job, one thing it should never hand you is a
writable-then-executable page. That's the whole W^X premise: an attacker with
a memory-write primitive still can't get native code running because they
can't mark memory executable. Firecracker's vmm filter in v1.15.1 doesn't
hold that line.

## The gap

Two rules in the `vmm` filter, from the shipped v1.15.1
`x86_64-unknown-linux-musl.json`:

```json
{"syscall": "mmap",
 "comment": "Used by rust's stdlib ...",
 "args": [{"index": 3, "type": "dword", "op": "eq", "val": 34,
           "comment": "MAP_ANONYMOUS | MAP_PRIVATE"}]}

{"syscall": "mprotect",
 "comment": "Used by memory hotplug to protect access to underlying host memory"}
```

The `mmap` rule for `flags=34` (`MAP_ANONYMOUS|MAP_PRIVATE`, the mapping Rust's
allocator leans on) only constrains arg index 3, the flags. Arg index 2
&mdash; `prot` &mdash; is never checked. `PROT_EXEC` anonymous mappings go
straight through.

The `mprotect` rule has no `args` key at all. Every argument is a wildcard, so
`mprotect(page, len, PROT_READ|PROT_EXEC)` is unconditionally allowed.

What makes it clearly an oversight rather than a design choice: the `vcpu`
thread's rule for the *same* `flags=34` mmap does pin prot down.

```json
{"syscall": "mmap",
 "args": [{"index": 3, "op": "eq", "val": 34},
          {"index": 2, "op": "eq", "val": 3,
           "comment": "PROT_READ | PROT_WRITE"}]}
```

So the vmm thread &mdash; the one holding device-emulation state and the
juicier post-exploitation surface &mdash; is strictly more permissive than
vcpu for the identical allocation. vcpu says "RW only"; vmm says "whatever
you want."

## The chain

Given a write primitive in the VMM, the escalation to native code is four
allowed syscalls:

1. `mmap(NULL, len, PROT_READ|PROT_WRITE, MAP_ANONYMOUS|MAP_PRIVATE, -1, 0)`
   &mdash; flags=34, allowed, prot unchecked.
2. write shellcode into the RW page.
3. `mprotect(page, len, PROT_READ|PROT_EXEC)` &mdash; no arg filter, allowed.
4. jump to the page. W^X is gone.

Nothing here needs a second bug. No ROP, no kernel primitive, no `memfd`+`mmap`
shared-mapping trick. The filter that's supposed to prevent exactly this signs
off on every step.

## PoC

I don't need a running microVM for this &mdash; the precondition of any
seccomp-escape report is "attacker already has code exec in the sandboxed
process," so the PoC just installs a faithful copy of the vmm filter (same
`trap` default, same `mmap`/`mprotect` rules) in a standalone process and
runs the chain under it.

```
[+] VMM seccomp filter installed (default=TRAP, mprotect has NO arg filter)
[1] mmap(... PROT_READ|PROT_WRITE, MAP_ANONYMOUS|MAP_PRIVATE ...)  -> allowed
[2] write shellcode into RW page
[3] mprotect(page, 4096, PROT_READ|PROT_EXEC)                     -> allowed
[4] calling shellcode:
F01: shellcode executing
[!] BYPASS COMPLETE: shellcode executed under the active vmm seccomp filter
```

Patched behaviour would be a `SIGSYS` at step 3. On v1.15.1's policy it just
runs.

## Impact

Firecracker runs multi-tenant workloads on Lambda and Fargate. The layers are
KVM (guest to VMM), then jailer chroot/namespaces/cgroups plus seccomp (VMM to
host). seccomp is the final one. A guest-triggerable memory-corruption bug in
virtio device emulation gets you a primitive in the VMM; this gap converts
that into arbitrary native code with no further work, defeating the
containment layer meant to blunt exactly that step. From there: cross-VM data
on the same host, the jailer chroot, host interfaces the VMM can see.

It's not a bug that stands alone &mdash; you need the memory-corruption
primitive first &mdash; but that's the point of W^X: it's supposed to be the
wall that stops a write primitive from becoming code exec, and the wall
wasn't there.

## Fix

AWS validated it and shipped the fix in **v1.16.0**
([PR #5921](https://github.com/firecracker-microvm/firecracker/pull/5921),
backport [#5922](https://github.com/firecracker-microvm/firecracker/pull/5922)).
Every vmm `mmap` rule and the `mprotect` rule now carry a `PROT_EXEC=0` check
on arg index 2:

```json
{"index": 2, "type": "dword", "op": {"masked_eq": 4}, "val": 0,
 "comment": "Ensure PROT_EXEC is not set"}
```

`masked_eq 4` against `val 0` means "bit 2 (`PROT_EXEC`) must be clear."
Anything requesting execute perms now traps. Same treatment applied across the
balloon, timezone, io_uring, pmem and hotplug mappings &mdash; the whole vmm
thread now refuses executable mappings, so the chain dies at step 3.

## whats next?

Nick from the AWS VDP was quick and straight with the whole thing &mdash;
validated, patched, released, no drama. Good program. onto the next one :3

[//]: # "SPDX-License-Identifier: CC-BY-SA-4.0"
