# nuc11-ec-fan

Experimental fan control for the **Intel NUC 11 Pro (NUC11TNH / Tiger Canyon)** on Linux. It reads and writes the embedded controller's (EC's) shared memory.

> **Status: research.** Reading works. One write experiment succeeded: the EC applied a changed fan-record field without Intel's Windows driver (see [Results](#results)). Only that single field has been tested, on one machine. Do not use the write path unless you understand the risks below.

## Background

On the NUC 11 the fan is not driven by a Super I/O chip that Linux supports (`it87`, `nct6775`, …). It is controlled by the EC, and the only control on Linux is the fan curve in the BIOS. Intel's Windows tool *NUC Software Studio* could change fan profiles at runtime, but it was discontinued in 2024 and the NUC11TNH was never on its supported list.

The EC exposes a shared-memory window at physical address `0xFE410400` (0x100 bytes; ACPI region `H2RA` starts at `0xFE410000`). Observed on a NUC11TNHi7 with BIOS `TNTGL357.0064`:

| Offset | Content |
| --- | --- |
| `+0x00` | ASCII EC ID `NUC_EC` |
| `+0x1C` | Fan present flag (`01`) |
| `+0x1D..0x1E` | Fan RPM, big-endian |
| `+0x80..0xDD` | Fan profile: six 14-byte records, each followed by 2 bytes not part of the record |

Fan record layout. It follows the analysis of NUC Software Studio for the NUC11PH (Phantom Canyon) in [CodeGrogu/intel-nuc-software-studio-decompiled](https://github.com/CodeGrogu/intel-nuc-software-studio-decompiled):

| Byte | Field |
| --- | --- |
| 0–5 | Primary: temperature source, max temp °C, min temp °C, min duty %, duty increment per °C, fan-off temp °C |
| 6–11 | Secondary: same six fields |
| 12 | config1 (bit 7 set = fixed/custom mode on ECNUC22) |
| 13 | config2 (bit 7 = zero-RPM / fan-off enabled on ECNUC22) |

Intel's driver writes profiles through a kernel IOCTL. It is unknown whether the driver does more than copy bytes into this window. The experiment below shows that, for at least one field, copying the byte is enough.

## Results

One run of `fan-write-test.sh` on a NUC11TNHi7 (BIOS `TNTGL357.0064`, idle, CPU 47–50 °C):

| Phase | Record 1 primary min duty | Reported fan speed |
| --- | --- | --- |
| Baseline | 50 % (`0x32`) | 3194–3208 RPM |
| Test, 30 s | 70 % (`0x46`) | rose to ~4000 RPM, visible within one 3 s sample; stayed at 3993–4060 RPM |
| After restore | 50 % (`0x32`, verified by readback) | declined gradually toward baseline over ~30 s (3297 RPM after 30 s); a later reading gave 3194 RPM |

What this shows:

- On this machine and BIOS, writing record 1's primary min duty into the EC window caused a sustained increase in reported speed. No explicit driver-notify step was needed. CPU temperatures before and during the change overlap, so temperature drift is an unlikely sole explanation. This is a single, unreplicated experiment.
- The big-endian field at `+0x1D` gave plausible speeds that tracked the change and the restore. This shows live telemetry, not physical calibration.
- Restoring to `0x32` was verified, and record 1 read back unchanged afterwards. No residual change was seen in the tested record; other or hidden EC state was not checked.

Not tested: other fields and records, and whether a change survives a reboot. The expectation is that the EC reloads the BIOS profile at power-on, but that has not been tested.

## Files

| File | Purpose |
| --- | --- |
| `ecmem.c` | Small static tool. `ecmem read` dumps the window via uncached `mmap` of `/dev/mem`. `ecmem write <off> <old> <new>` writes one byte, but only within fan record 1 (`0x80..0x8D`), only if the EC ID is `NUC_EC`, and only if the current value equals `<old>`. |
| `nuc-fan.sh` | Prints RPM and decodes fan record 1 (read-only). |
| `fan-write-test.sh` | One-shot experiment: raises record 1's primary min duty from 50 % to 70 % for 30 s, then restores it. It restores on any exit or signal, and stops for manual recovery if the byte holds an unexpected value. |

## Build and use

```sh
gcc -O2 -Wall -Wextra -static -o ecmem ecmem.c
sudo ./ecmem read
sudo ./nuc-fan.sh ./ecmem
```

Requirements: root, x86-64, and `/dev/mem` access to that MMIO range. Kernel lockdown (for example with Secure Boot) blocks it; check that `/sys/kernel/security/lockdown` is `[none]` or missing.

## Risks

- Writing to EC memory is undocumented. A bad value could leave the fan too slow. Whether a reboot or power cycle restores the BIOS profile is expected but untested.
- The write test only *raises* the minimum duty, so the fan can only spin faster during the test.
- Only tested on one NUC11TNHi7. Other models and BIOS versions may use a different layout. `ecmem` refuses to run if the EC ID is not `NUC_EC`.

## Credits

The record layout and IOCTL background come from [CodeGrogu/intel-nuc-software-studio-decompiled](https://github.com/CodeGrogu/intel-nuc-software-studio-decompiled). The idea of reading fan RPM from the EC window comes from [mikns/nuc-fan-rpm](https://github.com/mikns/nuc-fan-rpm) (NUC10).

## License

Not yet chosen.
