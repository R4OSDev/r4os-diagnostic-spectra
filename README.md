# Spectra

Spectra is R4OS's diagnostic tool for kernel measurements, logs, checks and
explicit benchmarks. Terminal and SSH keep the existing CLI, including help
on an empty invocation. The Desktop shortcut and Start-menu entry explicitly
launch the same console-classified `SPECTRA.R4X` with GUI policy and `/GUI`.
A running Desktop never implicitly changes CLI routing.

The compact GUI offers Standard (default) and its five local `/AREA` tests,
Start, Upload and status text. Tab/arrows/Enter and mouse input are supported.
Start never uploads. Upload becomes available only after a complete Standard
has been atomically saved and read back with its SHA256. It always uses that
run's original UUID/file/hash; network failures permit an explicit retry.
Selecting another test or starting a new one clears the permission, keeping
all previously saved originals. Partial tests cannot upload.

Measurements, export validation and upload run in private same-binary console
jobs. The GUI uses bounded process handles, generations and nonce-bound typed
receipts after actual completion/reap. Closing requests cancellation and
waits for owned-job cleanup. No new system service or Kernel/SDK API is needed.
Suite3 work, warmup, CPU usage, fixed reference and server readback/scoring
rules are shared with the CLI. GUI exports identify their actual Desktop
context; scores are not asserted equal to headless execution.

Version0.1.79 adds `CHECK VM /INVENTORY`, also included in the default VM
check. It gives the task/thread inventory providers fresh demand-committed
caller rows without touching those pages first, then verifies real page
faults/residency, exact returned identities/layouts and release of both owned
regions. Epoch restarts publish no rows and are retried at most16 times.
This explicit bounded check adds no background work. It guards the Kernel412
fix for publishing caller results after ProgramState admission ends; native410
froze on the same untouched8192-byte task buffer. STANDARD workloads, scoring
and reference contracts are unchanged. Runtime receipts and limits belong to
`Docs/Audio/PlaybackProgress.txt`.

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
SPECTRA CHECK DESKTOP /JSON
SPECTRA CHECK DESKTOP /CANCEL /JSON
SPECTRA CHECK REMOTEFRAME /EXITOWNED /JSON
SPECTRA CHECK THREAD
SPECTRA CHECK THREAD /KERNEL
SPECTRA CHECK THREAD /KERNEL:SYNC
SPECTRA CHECK THREAD /KERNEL:IDLE
SPECTRA CHECK THREAD /PROCESSEXIT
SPECTRA CHECK PERFORMANCE
SPECTRA BENCH CLOCK /REPEAT:3 /WARM
SPECTRA BENCH DESKTOP /OWN-DESKTOP /JSON
SPECTRA BENCH SNES /WINDOW /NTSC /NORMAL /SMALL /OUTPUT-ANALYSIS /JSON
```

Use `SPECTRA HELP` for the complete group list. No arguments display help. Passive queries never start workloads or enable kernel instrumentation. Benchmarks and checks require an explicit group.

Desktop and SNES benchmarks keep rendering/emulation, fixed work, clocks and
pixel/state oracles with their existing owners. Spectra controls its exact
pending GUI child, waits for real completion/reap and forwards original owner
JSON values without quantifying or filtering them again. Window measurements
require an isolated Desktop. `/OWN-DESKTOP` explicitly creates a private host
only when none exists, and closes only that exact host with no foreign windows.
Commands return without poweroff. The native Core host benchmark keeps its
separate comparison context in `R4SNES/Benchmark.ps1 -Profile Core`.
`Tools/StructuredOutput.ps1` is the strict shared file-framing reader; the
independent SNES Schema-1 export, UUID and validation remain with its
host owner. See `Docs/Diagnostics/Spectra.txt` in the workspace.

Build through `Build.sh` (Linux) or `Build.bat` (Windows), with PS7 and the configured SDK. `Build.sh test` runs the command/routing/measurement host tests. `module.R4MF` owns the artifact identity; the installed name is `SPECTRA.R4X`.

`zig build` also requires the current sibling `Services/WindowService/Contract/desktop_diagnostics_v1.zig` and `Apps/Desktop/Contract/desktop_check_v2.zig` sources at their manifest-relative paths. These small owner byte protocols are source dependencies, with no Desktop implementation dependency; the ordinary workspace build provides it. `build.zig.zon` pins the public SDK and library packages.

`CHECK DESKTOP /HOST` owns an explicit isolated Desktop only when no foreign
host exists and reports its real completion/reap separately from check work.
`CHECK SUBSYSTEM [/HOST] [/SNES]` owns the retained Test-profile BASIC/GB/SNES scenarios,
including both60-second emulator pairs, original resolver/input/error/save
work and exact child receipts. It requires the actual Test fixtures; it is
not an implicit benchmark or an ordinary Full-profile command.
`/SNES` selects the same original SNES scenarios alone and reports `scope=snes`;
full Test-profile acceptance requires `scope=all`. Explicit window metadata
is sampled at most every 50 ms per target, independently of exact process
completion and reap. Original work, timing gates and cleanup stay unchanged.

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
scoring/export hashes; the full run stays in local workspace artifacts.
The runner resolves the verified local reference and fails before guest
execution if it is missing or differs from its frozen contract.
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
normal SMP4 integration and the complete local export fields are documented in
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

## Desktop migration complete (0.86.77)

RFDIAG's transitional module/build and the old Desktop CHECK/PERF forwarders
are retired. CHECK REMOTEFRAME owns the single public oracle; notices remain
in `Provenance/RemoteFrameDiag`. Its public repository history stays available.
BENCH SNES frames the complete original Desktop JSON trace; the redundant
SNES-PRESENT.TXT writer is gone. Historical exports remain readable.
Current owner contracts, retained hardware/product/SDK-fixture purposes and
the Rust-port handoff are in `Docs/Diagnostics/Spectra.txt`.

`CHECK LIFECYCLE /METADATA` compares32 complete full and metadata-only
acquisitions in each of five alternating batches, validates exact fields,
cursor modes/restart and real close/completion/reap, and reuses the existing
forced-ID-reuse case. It requires the explicit private boot option
`OPTION PROGRAMLIFECYCLE selftest=yes`; this option is not a normal product
configuration. Clock source/generation/resolution and nanosecond units must
match at both interval boundaries. The64-row local fixture bound is a
diagnostic refusal bound, not a process capacity. Wall time is per acquisition,
not Desktop FPS or physical display latency. `CHECK DESKTOP /HOST /RESTART`
also requires the existing Full fixtures APPDEF and CLOCK in its image.

The explicit metadata batches report actual Begin/Page/Busy/Restart/row counts.
Each acquisition has at most eight attempts; Busy yields one tick without a
registry lease, and measured wall time includes that wait. Partial or restarted
rows are never complete results. The existing ID-reuse case retains its original
24-child warm allocator/registry prerequisite and exact resource baseline.
Identity-only stale-ID children use the existing explicit `terminal_mode`
console host. An inherited host deliberately retains child producer blocks in
its visible transcript after Reap; that retained output is not a process leak.

`/KERNEL:IDLE` explicitly measures actual timer-vector entries on stable idle APs
(including stale vectors), then checks timer restoration and sixteen timed wakes
with one owned AP worker and exact retirement. It keeps every online CPU
schedulable. It is separate from the unchanged default `/KERNEL` (127) and
`/KERNEL:WORKERS` (128); combining these profiles is rejected. No idle sampler
or observation receipt writes run outside this requested check.

Spectra0.1.95 checks the explicit retirement of the nine audio duration
fields (Contract0.64.61) instead of total/max/last self-consistency. Its
original actual PCM acceptance, high-water/loss and Close checks remain.
Audio detail latency is printed as unavailable; historical exports are not
rewritten. All STANDARD workloads, amounts and scoring contracts are unchanged.
The generic SUMMARY export also represents each retired duration as
value:null with unavailable:retired in JSON, independent of detail mode.
Historical measured numbers and unrelated full-width counters stay numeric.

Version0.1.97 keeps the full raw R4AUDIO PCM conformance check through
actual Close acknowledgement. Only Busy is retried against the same stream
ID, bounded by 500 ms including Close calls; late ACKs fail the budget check.
It records the actual logical stream generation (the legacy raw owner is
KERNEL), accepted bytes, Close result and attempts. Other errors, missing
identity and timeouts remain failures. Work, zero-loss and retired-duration
oracles stay active. This CLI-only functional deadline is not a new normal
PCM duration measurement.

Version0.1.98 preserves the exact declared console payload and intentional exit
code of plain `CHECK LIFECYCLE /LIFECYCLEEXIT code bytes` child fixtures. It does
not append a check-result frame to those bytes. The original exact completion
length, payload, generation and retention assertions remain active. Invalid
fixture arguments and unexpected returns retain their result frame; ordinary
checks and explicit JSON/export presentation also retain it. The existing
successful plain COMPUTEHOLD no-frame contract is preserved.

The completion ring and its warmup use explicit independent terminal captures,
as the existing stale-generation fixtures already do. Each child's completion
still retains its exact raw bytes for CompletionRead until Reap; its sealed
producer blocks are not borrowed by the parent's visible transcript. Global
storage, memory and process baselines remain exact after actual child Reap.

The nonempty Legacy-ID fixtures also select their own terminal host. Their
public adapter still enters the same Kernel legacy launch operation1, retaining
raw legacy IDs, complete64/32-byte output, forced-ID collision and single-use
Reap checks. Console-tree cases continue to exercise genuine inherited hosts.

Version0.1.99 retries a genuinely changed instance-count snapshot inside the
existing lifecycle baseline wait budget. Partial snapshots never satisfy the
baseline. Invalid memory/storage and missing API failures remain immediate;
every original resource/memory/storage equality is preserved. The separate
first-window cold memory delta still requires owner attribution.

The complete lifecycle profile warms one actual depth4 terminal-window tree
before capturing its measured memory baseline. Twenty-four immediate exits do
not establish that simultaneous live Task shape. Exact cold inventories map
the first-tree growth to three cached64KB Task stacks (80KB guarded virtual
spans) and eleven resident page-table pages. Warmup still requires real Close,
Wait/Reap and exact process/resource/storage ownership return; every measured
Close/Kill and final baseline retains the original exact memory equality.

Version0.1.100 allows `CHECK LIFECYCLE /SERVICELIFECYCLE` to select the
unchanged existing ServiceExit0/37 and restart case. It needs the manual
SVCEXIT0/37 fixtures from the canonical Test configuration. Baseline failure
now prints the same complete ownership/memory/storage diagnostic as other
lifecycle cases; original service and exact baseline assertions stay intact.

Version0.1.101 warms the same real ServiceExit0/37 start/restart call-frame shape
in the current caller before taking its measured baseline. The check binds the
actual public R4X app-stack block and owner, then preserves every original
measured service/code/restart/registry/resource/storage/memory assertion. Kernel
ranked-owner stack headroom and64KB R4X stack commit remain functional. Retained
service terminal evidence is preserved; cold and separate-invocation failures
remain available for comparison. This is an explicit diagnostic precondition.

Version0.1.102 exposes the existing full asynchronous lifecycle case through
`CHECK LIFECYCLE /ASYNCLIFECYCLE`. Like /PROGRAMLIFECYCLE, this requires a real
fresh queue-backed SVCSTALL (`/HOLD /STALLENDPOINT`), with requests/responses0;
/ASYNCQUICK installs and removes its own fixture. Keep these setup contracts
separate. On the original first-cycle cold/warm failure, the existing baseline
formatter now prints the already captured resource/storage/memory values. No
extra measured query, oracle,72-cycle count or runtime warm policy was changed.

Version0.1.103 gives each actual async/thread kill fixture its own terminal-mode
console capture. Its worker/start/request output is preserved. Inherited
producer transcripts intentionally survive through their parent; native102
showed exactly one retained output payload (+16,424 current console bytes),
with unchanged resource totals and instance count after actual child Reap.
Each original Kill/Wait/three-thread/request/endpoint/owner/baseline assertion
and all72 measured cycles remain intact. No Kernel console-retention, service,
thread or I/O runtime behavior was changed; normal native103 qualification is
pending until its exact artifact has been checked.

Version0.1.104 reports the original global PROGRAMLIFECYCLE baseline through
its existing detailed failure formatter when final quiescence is missing.
Native103 already passes all72 measured async cycles with the original strict
memory/storage/resource/thread/request/endpoint assertions; its later global
failure remains an independent open finding. No baseline, warm policy, timeout,
Kernel behavior or cycle count was changed by this diagnostic-only increment.

Version0.1.105 moves the existing real ServiceExit0/37 warm calls ahead of the
original global PROGRAMLIFECYCLE baseline. The measured service phase and
standalone /SERVICELIFECYCLE retain the same warm/measured call counts. Native104
proved all local checks/72cycles and exact global registry/resource/storage
return, but one4KB Kernel-owned empty page table remained. Public memory block
9165 and read-only hardware-root traversal identify its APP_STACK span
0xffffff4006400000..0xffffff4006600000; the existing paging owner deliberately
retains empty intermediate tables after real leaf unmap/TLB acknowledgement.
The service warm phase previously occurred after the global baseline; the
same real calls now prepare that capacity before measuring it. The standalone
service path still warms its own caller. No page-table deletion, generic memory
tolerance, baseline substitution, extra warm service calls, timeout or72-cycle
change was introduced. Final cold native105 qualification remains pending.

Native105 qualification: fresh normalKernel449/canonicalSpectra105 KVM4 passes
all original PROGRAMLIFECYCLE cases,72 strict three-thread/blocked-I/O/cancel
cycles and the ORIGINAL final global owner/heap/PMM/VM/storage baseline. The
changed standalone service warm/measured entry also passes with a new caller
and actual64KB owned stack growth. Earlier red originals remain archived;
all_native_attempts_pass=false, required_scope_pass=true. Documentation and
formal release/benchmark/push completion are tracked separately in the roadmap.

Version0.1.113 keeps successful private GUI payload/frame fixtures silent.
Their real frames prove readiness; failure diagnostics and all exact
owner/counter/byte/kill/reap assertions remain. The completion-ring warmup
uses the same32..55-byte output shape as the measured children before the
original global baseline is captured. An empty-output warmup does not prepare
the retained producer backing needed by that measured ring. All measured
global and local memory equalities remain intact.

PROGRAMSTORAGE requires a running queue-backed SVCSTALL. The isolated full
PROGRAMLIFECYCLE profile requires a fresh instance of that fixture and CONFIG
options PROGRAMREGISTRY/PROGRAMLIFECYCLE selftest=yes. These options explicitly
admit the existing private fault and forced-ID tests in the isolated profile.
