# Spectra

Spectra is R4OS's console tool for kernel measurements, kernel logs, functional checks, explicit benchmarks and opt-in passive Desktop state. It runs through Terminal and SSH. A GUI is deferred; command parsing, collectors/checks and rendering are separate.

Since0.1.38, `METRICS MICROCODE [/JSON]` copies retained early CPU revision
receipts. `CHECK SMP /MICROCODE` runs15 synthetic presentation cases and
passive header, caller-tail and exact CPU/epoch checks. The existing owned
lifecycle check verifies an unchanged complete receipt while offline and a
fresh receipt after restart, with zero runtime update attempts. Queries
never load firmware or issue hardware instructions. Virtual revisions and
supplied firmware are separate from confirmed native update readback;
unavailable revisions remain null, distinct from valid0. CPUID fingerprints
are diagnostic; the existing PAT/FPU/module owners decide CPU admission.
Original Suite3 workloads/reference remain unchanged. Profiles and physical
qualification limits: `Docs/Core/CpuMicrocode08533.txt`.

```
SPECTRA METRICS CLOCK
SPECTRA METRICS DESKTOP /JSON /WATCH:2 /INTERVAL:100
SPECTRA METRICS ALL /JSON /EXPORT:C:\TEMP\KERNEL.JSON
SPECTRA METRICS LOCKS /WATCH:3 /INTERVAL:1000
SPECTRA LOGS BOOT
SPECTRA LOGS SERVICE /JSON
SPECTRA CHECK THREAD
SPECTRA CHECK THREAD /KERNEL
SPECTRA CHECK THREAD /KERNEL:SYNC
SPECTRA CHECK THREAD /PROCESSEXIT
SPECTRA CHECK PERFORMANCE
SPECTRA BENCH CLOCK /REPEAT:3 /WARM
```

Use `SPECTRA HELP` for the complete group list. No arguments display help. Passive queries never start workloads or enable kernel instrumentation. Benchmarks and checks require an explicit group.

Build through `Build.sh` (Linux) or `Build.bat` (Windows), with PS7 and the configured SDK. `Build.sh test` runs the command/routing/measurement host tests. `module.R4MF` owns the artifact identity; the installed name is `SPECTRA.R4X`.

`zig build` also requires the current sibling `Services/WindowService/Contract/desktop_diagnostics_v1.zig` source at the manifest-relative path. This small WINSVC-owned byte protocol is a source dependency, with no Desktop implementation dependency; the ordinary workspace build provides it. `build.zig.zon` pins the public SDK and library packages.

The module consolidates former R4OS kernel diagnostics. Source identities and required notices are retained in `Provenance/`; loader fixtures live in `Fixtures/Loader/`. See `DOCUMENTATION.de.txt` for data formats, limits and the migration boundary.

The required R4OS performance benchmark is `SPECTRA BENCH STANDARD`, suite
`spectra-standard-3` (Spectra 0.1.24). Each available CPU performs an equal
share of every workload behind a common start barrier. The metric is shared
wall time per total completed operation; all successful samples prove complete
participation. Each of the five areas actively warms up
for at least one second and three complete batches before five fixed, longer
measurements. The scheduler peer acknowledges readiness before timing starts.
All warmup work and measured samples are retained, with five equally weighted
scores plus overall. `/AREA:memory` selects a component; `/BASELINE` explicitly
defines a self-reference. `Tools/Export-StandardBenchmark.ps1` validates the
guest records and supplies the standalone Schema-1 host export/reference
comparison. `Baselines/standard-3.reference.json` pins the reference UUID and
scoring/export hashes; the full run stays in DevCenter or local workspace
artifacts. The runner resolves the verified local cache or downloads from
`R4OS_DEVCENTER_API_URL` / `Tools/BenchmarkHost.R4S` (`DEVCENTER_API_URL`).
Real run exports never belong in Git. `standard-1.reference.json` and
`standard-2.reference.json` retain the unchanged historical references. Scores
from different suites are not comparable. Suite 3 compares the same workload
protocol across CPU counts and hardware while preserving the actual native/VM,
RAM, storage and boot context. Parallel demand-VM work requires Kernel 0.1.330
or later. Kernel 0.1.331 also expands the shared stream pool so sixteen or
more filesystem participants can coexist with their export stream. The fixed
SMP4 reference remains unchanged. The package also owns the small
`Fixtures/StandardChild` lifecycle fixture.

`Build.sh test` includes Zig and PS7 result-contract checks. Workload details,
normal SMP4 integration and the current import fields are documented in
R4OS Docs: `Diagnostics/SpectraStandardBenchmark.txt`.

Since 0.1.3, `METRICS STACKS` also reads the latest resident stack failure per
CPU through the optional R4DEV v14 `stack_fault` slot. Causes, original fault
address/RSP, reserve/commit/guard bounds and available execution generations
use the existing text/JSON output. Unknown identities/bounds are null.
Committed bytes are independent of optional high-water estimates. These
records last until overwritten or reboot; they are not an event history.

Since 0.1.4, `CHECK STACK` also checks a single 384-KB frame aligned to 8 KB
with volatile page writes/readback, alongside recursive growth. It covers
the shared compiler's pagewise allocation and alignment probes. The existing
reserve and the STANDARD workloads remain unchanged.

Since 0.1.5, explicit `CHECK STACK /RECOVERY` exhausts its own main/worker
child stacks and requires failed/-4096 completion, peer retirement, reap
and exact resident fault identities. Critical or unclear contexts retain
the terminal kernel path; the existing reservations stay unchanged.

Since 0.1.6, `CHECK ASYNC_IO /LENGTHS` probes signed-result limits through
real ABI calls with small buffers. It checks rejection before admission,
unchanged files/live streams and the existing 64-bit range-read offset.

`CHECK THREAD /KERNEL[:SYNC|SCHED|FPU|ADMISSION]` explicitly runs shared native
contracts on an owned BSP controller. Exact task generations and actual
work-release receipts prove cleanup. ADMISSION checks two concurrent own
callers and a real join. Global timer/reserve injections remain isolated boot
cases; the structured result advertises them and unavailable hardware.
Use the same `/JSON` and explicit `/EXPORT:` presentation as other checks.

Since 0.1.13, `CHECK SMP [/ADMISSION]` runs owned native CPU-placement,
checksum, monotonic-clock, mapping/TLB-ACK and heap/mutex phases. Every worker
and backing resource needs its own retirement receipt. Fewer than two
schedulable CPUs report unavailable without starting work. Global timeout
injection and other boot-only acceptance cases remain isolated. `METRICS SMP`
only reads current CPU/clock registrations and actual TLB counters; a passive
snapshot never claims a historical check pass or supplies a benchmark score.

Since 0.1.14, `CHECK STORAGE /BLOCKQUEUE[:ADMISSION]` reuses the native
synthetic block dispatcher and async queue cases. It owns exact task/device/
request generations and completion receipts, drains before unregistering all
three own controller registrations, and retains unacknowledged resources.
It selects no physical test disk and performs no global queue/counter reset.
METRICS stays passive; default STORAGE checks retain their existing selection.

Since0.1.37, `METRICS MCA [/JSON]` copies bounded resident boot-passive or
terminal Machine Check evidence. `CHECK SMP /MCA` adds22 synthetic decoder
fixtures and actual passive header/epoch/sequence/tail checks; it injects no
hardware error. Each raw/decoded row keeps exact CPU/start epoch/capture/bank
identity. Global RIPV/EIPV/MCIP and bank VAL/ADDRV/MISCV, read faults, changed
readbacks and truncation remain explicit. A retained boot scan is not current
hardware health. Corrected records, uncorrected/deferred errors and corrupt
contexts are distinct. AMD SMCA extended decoding initially requires the
documented19h/01h/B1 profile and per-bank McaX; IPID determines block type,
never the bank ordinal. Virtual model information does not identify a failing
physical block. SYND priority matching is separate from raw capture. Unknown
models/fields stay unknown. No query clears status or promises general repair.
Suite3 workloads, fixed reference and measurement method remain unchanged.
Unqualified AMD legacy extended status stays unknown when UC is clear;
Deferred/TCC/Poison names require the exact SMCA model. The displayed MCE
enable state is captured CR4.MCE only, not global/bank reporting activation.
The existing owned CPU lifecycle check also copies the exact retained MCA
snapshot while its AP is proven offline and verifies a fresh capture after
restart, without additional register operations or extra manual transitions.

0.1.45: CHECK SIMD /REGISTERS runs the existing 96-round two-worker YMM0
stored-memory oracle inside complete SysV assembly bursts, with both workers
placed on CPU0 and actually joined. CHECK SIMD /IRQSTRESS retains the exact
20,000,000-round scalar oracle and reports actual timer IRQs, timer switches
and registered external R4D handler invocations for its own native task and
assembly RIP interval. Missing events are unavailable. Ordinary SIMD sleep
chains cover numerical call-boundary interleaving; direct kernel IRQ guards
cover guard roundtrips. They do not establish a hardware IRQ.

0.1.46: `CHECK SIMD /ENVIRONMENT` checks all sixteen active YMM/XMM
registers, eight x87 values with rotated TOP or sparse tags, all eight MMX
aliases, four rounding modes and only supported FTZ/DAZ combinations. Two
CPU0 workers run complete assembly bursts and report their own exact
native-task/RIP timer events. Fresh controls and real thread joins are
required. A separate ordinary indirect `misc.example` R4P echo checks SysV
callee-saved controls; its data registers remain caller-saved. The kernel's
boot-only `TASKREGISTRY selftest=fpu-environment` owns sleep/yield/migration,
normal/deadline Work, direct guards, reserve reuse and controlled nonlocal
returns. Actual IRQ callback coverage requires the explicit EXAMPLE test
mode below; absent events and unexecuted exception paths stay unqualified.

0.1.47: `METRICS SUMMARY` explicitly identifies the compatibility field
`fpu_task_state_bytes` as cumulative initialized bytes. It is separate from
current resident memory and general advertised CPU features. The dynamic
thread transcript uses `fpuInitializedBytesDelta` for the same counter.
Kernel boot selection `TASKREGISTRY selftest=xstate-contract` owns the
nonfaulting common storage bounds, complete state restoration and live
resident snapshot check before the existing full FP environment matrix.
Real #MF/#XM delivery remains a separate unexecuted acceptance case.

Since0.1.51, `METRICS DESKTOP` copies current WINSVC broker state and passive public display/output/capture metadata. It never starts a Desktop, capture consumer, renderer or detail instrumentation. Unknown render/visibility/cursor times remain null. `METRICS ALL` is unchanged. Protocol offsets, ownership/clock scope, exit semantics and the75--77 migration contract are in `Docs/Diagnostics/Spectra.txt`.
