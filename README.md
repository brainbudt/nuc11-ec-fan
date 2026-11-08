# nuc11-ec-fan

Experimental fan control for the **Intel NUC 11 Pro (NUC11TNH / Tiger Canyon)** on Linux. It reads and writes the embedded controller's (EC's) shared memory.

> **Status: research.** Reading works. Whether the EC applies a changed fan profile without Intel's Windows driver has **not been confirmed yet**. Do not use the write path unless you understand the risks below.

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

Intel's driver writes profiles through a kernel IOCTL. Whether it does more than copy bytes into this window (for example, notify the EC) is unknown. Finding that out is the purpose of `fan-write-test.sh`.

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

- Writing to EC memory is undocumented. A bad value could leave the fan too slow until the next reboot; the EC reloads the BIOS profile at power-on.
- The write test only *raises* the minimum duty, so the fan can only spin faster during the test.
- Only tested on one NUC11TNHi7. Other models and BIOS versions may use a different layout. `ecmem` refuses to run if the EC ID is not `NUC_EC`.

## Credits

The record layout and IOCTL background come from [CodeGrogu/intel-nuc-software-studio-decompiled](https://github.com/CodeGrogu/intel-nuc-software-studio-decompiled). The idea of reading fan RPM from the EC window comes from [mikns/nuc-fan-rpm](https://github.com/mikns/nuc-fan-rpm) (NUC10).

## License

Not yet chosen.
