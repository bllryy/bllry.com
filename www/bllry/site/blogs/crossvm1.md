% crosvm: arbitrary host pointer injection via vhost-user external_map
% bllry
% 2025-06-06

<!-- gif goes here -->
<p><img src="" alt="" border="0"></p>

This is a writeup of a bug I found and reported in
[crosvm](https://github.com/google/crosvm), Google's VMM used in ChromeOS and
Android. A compromised vhost-user backend can inject an arbitrary host pointer
into crosvm, which registers it directly as guest physical memory via
`KVM_SET_USER_MEMORY_REGION`. No validation at any stage. (The google devs
blow XD)

## Background

crosvm uses vhost-user to offload virtio device emulation to sandboxed backend
processes (e.g. virtio-gpu via rutabaga, virtiofs). The backend communicates
with the VMM over a Unix socket. `VHOST_USER_EXTERNAL_MAP` lets the backend
share a host memory region with the guest by sending a
`VhostUserExternalMapMsg` containing a `ptr` field &mdash; a raw u64 the VMM
treats as a host virtual address.

## The Bug

`VhostUserExternalMapMsg::is_valid()` only checks that `len > 0`. The `ptr`
field is never validated.

```rust
fn is_valid(&self) -> bool {
    self.len > 0  // ptr is never validated
}
```

The affected handler in
`devices/src/virtio/vhost_user_frontend/handler.rs:151-178`:

```rust
fn external_map(&mut self, req: &VhostUserExternalMapMsg) -> HandlerResult<()> {
    VmMemorySource::ExternalMapping {
        ptr: req.ptr,   // raw u64 from backend socket, no bounds/origin validation
        size: req.len,
    }
    // -> add_mapping() -> KVM_SET_USER_MEMORY_REGION maps host ptr into guest PA space
}
```

Full chain:

```
req.ptr
  -> VmMemorySource::ExternalMapping { ptr, size }
  -> add_mapping()
  -> base/mmap.rs:586  (ptr as *mut u8, cast to MappedRegion)
  -> KVM_SET_USER_MEMORY_REGION
```

## Preconditions

- Code execution in a vhost-user backend process (e.g. via a separate bug in
  virtio-gpu or virtiofs)
- Backend must have negotiated `VHOST_USER_EXTERNAL_MAP` (rutabaga GPU does)

## Reproduction

1. Exploit an independent bug in the virtio-gpu backend to gain code execution
   in that process.
2. Send `VhostUserExternalMapMsg { shmid: <negotiated>, ptr: <crosvm_target_addr>, len: 4096, shm_offset: 0 }`.
3. crosvm calls `KVM_SET_USER_MEMORY_REGION` with that address as the userspace
   pointer.
4. Guest reads/writes `crosvm_target_addr` directly.

## Impact

Full VMM memory read/write from a compromised backend. An attacker can read
secrets held in the crosvm process (keys, cross-guest data) and overwrite VMM
code or data structures to achieve hypervisor-level compromise &mdash; a full
host escape from the sandbox.

ASLR and seccomp on the backend don't help. Once you control the socket you
control the pointer field, and you can brute-force or leak the target address
independently. Namespace isolation doesn't apply to the shared socket path.

CVSS:3.1/AV:L/AC:H/PR:L/UI:N/S:C/C:H/I:H/A:H &mdash; Score: 8.5 (High)

## Fix

Validate `ptr` against a whitelist of addresses explicitly registered by
rutabaga before the message is processed. Only pointers originating from
tracked, size-verified mmap operations managed by the VMM should be accepted.
Everything else rejected at the `is_valid()` stage.

## Whats next?

Well google closed the bug report and the issue. So idk whats gonna happen
next :3

[//]: # "SPDX-License-Identifier: CC-BY-SA-4.0"
