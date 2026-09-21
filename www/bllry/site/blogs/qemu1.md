% QEMU CXL Type3: guest-controlled mailbox LENGTH causes heap OOB read and host memory disclosure
% bllry
% 2026-08-20

<!-- gif goes here -->
<p><img src="" alt="" border="0"></p>

Reported to QEMU (`hw/cxl/cxl-device-utils.c`).

A guest-controlled `LENGTH` field in the CXL Type3 mailbox lets a guest trigger
a heap out-of-bounds read in QEMU and, via the Set LSA / Get LSA echo gadget,
turn that into an attacker-chosen-length host-memory disclosure.

![CXL mailbox OOB read reproduction](/blogs/qemu1.png){width=643 height=600}

## Host environment

- Operating system: Debian GNU/Linux 13 (trixie)
- OS/kernel version: Linux debian-framework-13 6.12.100+deb13-amd64 #1 SMP PREEMPT_DYNAMIC Debian 6.12.100-1 (2026-07-30) x86_64 GNU/Linux
- Architecture: x86_64
- QEMU flavor: qemu-system-x86_64
- QEMU version: QEMU emulator version 11.0.93 (v11.1.0-rc3), commit 3e3ccab1

QEMU command line:

```sh
qemu-system-x86_64 \
  -M q35,cxl=on -m 4G,maxmem=8G,slots=8 -smp 4 -enable-kvm \
  -drive file=guest.qcow2,if=none,id=hd0,format=qcow2 \
  -device virtio-blk-pci,drive=hd0,bus=pcie.0 \
  -object memory-backend-ram,id=vmem0,share=on,size=256M \
  -object memory-backend-ram,id=cxl-lsa0,share=on,size=64K \
  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
  -device cxl-rp,port=0,bus=cxl.1,id=root_port13,chassis=0,slot=2 \
  -device cxl-type3,bus=root_port13,volatile-memdev=vmem0,lsa=cxl-lsa0,id=cxl-vmem0 \
  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G
```

## Emulated/virtualized environment

- Operating system: Debian GNU/Linux 12 (bookworm), cloud image
- OS/kernel version: Linux cxlpoc 6.1.0-52-amd64 #1 SMP PREEMPT_DYNAMIC Debian 6.1.180-1 (2026-08-03) x86_64 GNU/Linux
- Architecture: x86_64

## Description

`mailbox_reg_write()` (`hw/cxl/cxl-device-utils.c:155-232`) reads a 20-bit
guest-controlled `LENGTH` field from the mailbox CMD register (`len_in`, up to
`0xFFFFF`, `include/hw/cxl/cxl_device.h:387`) and does
`pl_in_copy = g_memdup2(pl, len_in)` (`cxl-device-utils.c:205`), copying that
many bytes from a fixed `0x800`-byte payload buffer
(`CXL_MAILBOX_MAX_PAYLOAD_SIZE`, `cxl_device.h:85-86`) with no bound against
that fixed size. The only length check that exists (`cxl_process_cci_message()`,
`hw/cxl/cxl-mailbox-utils.c:4617`) runs *after* this over-read has already
happened, and does not apply at all to mailbox commands registered with
variable-length input (`in == ~0`).

This heap out-of-bounds read is escalated into an attacker-chosen-length
host-memory disclosure using the CXL Set LSA / Get LSA mailbox commands
(opcodes `0x4103`/`0x4102`, `cxl-mailbox-utils.c:2275-2333`) which are
registered with `in == ~0` and persist + echo payload bytes back to the guest
verbatim (`hw/mem/cxl_type3.c:1394-1428`): declaring a `LENGTH` larger than the
guest actually wrote on SET_LSA causes the extra bytes (sourced from the OOB
read) to be persisted into the LSA store alongside the guest's own data; a
subsequent GET_LSA at the right offset reads them straight back through the
mailbox payload MMIO window.

A guest with root access to a `cxl-type3` device (no other privileges, no switch
topology, no non-default QEMU build flags) can use this to read up to ~1 MiB of
QEMU host-process heap memory per mailbox transaction &mdash; a guest-to-host
isolation break, and a standard building block for defeating host ASLR as a
first step toward a fuller escape.

## Steps to reproduce

1. Build QEMU at commit `3e3ccab106f879b1512f8e0d51a827dd4de30e22`
   (`../configure --target-list=x86_64-softmmu && make`).
2. Launch it with the command line above (Type3 device + `lsa=` backend).
3. As root in the guest, `mmap` the device's BAR2
   (`/sys/bus/pci/devices/<BDF>/resource2`, after unbinding the in-guest
   `cxl_pci` driver if one attached) and run the attached PoC
   `cxl_lsa_leak_poc.c`, which:
   a. Writes known filler bytes to the mailbox payload window, then rings the
      doorbell for SET_LSA (opcode `0x4103`) with a `LENGTH` larger than the
      `0x800`-byte payload buffer, so QEMU's `g_memdup2()` over-reads past the
      buffer and persists all of it (filler + OOB tail) into the LSA store.
   b. Issues GET_LSA (opcode `0x4102`) for those bytes starting right after the
      filler, reading the leaked host heap bytes back into the mailbox payload
      window.
   c. Dumps those bytes over MMIO.
4. Both commands return `CXL_MBOX_SUCCESS` (rc=0); the dumped bytes are
   verifiably not the guest's own filler.

## Analysis of the leaked bytes

On a real run the dumped region contains pointer-shaped values that are not part
of the guest-supplied filler. Some decode to addresses in the range typical of
an `mmap`'d region and others to a PIE executable image. Repeating the run
independently produces different values at the same offsets each time,
consistent with ASLR on live host-process memory and inconsistent with a static
pattern or anything the guest itself supplied (the guest's own filler is a fixed
`0xAA` and only occupies the offsets before the leaked tail).

## Suggested fix

Clamp `len_in` against `CXL_MAILBOX_MAX_PAYLOAD_SIZE` in `mailbox_reg_write()`
(`hw/cxl/cxl-device-utils.c:193`) before the `g_memdup2()` call, independent of
the per-command length check that currently only runs afterward in
`cxl_process_cci_message()`. Other mailbox commands registered with `in == ~0`
(FEATURES_SET_FEATURE, SANITIZE_MEDIA_OPERATIONS, the dynamic-capacity extent
commands) inherit the same unclamped `len_in` and should be checked too.

## Additional notes

- CVSS 3.1: 7.1 (High) &mdash; `AV:L/AC:L/PR:H/UI:N/S:C/C:H/I:N/A:N` (my best
  estimate).
- I only used AI for the static analysis; the script and PoC were written and
  checked by me.
- This was a confusing bug to work on, so if anything in the writeup is unclear
  please let me know.
