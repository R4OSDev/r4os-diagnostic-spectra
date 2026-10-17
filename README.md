# Spectra

Spectra is R4OS's console tool for kernel measurements, kernel logs, functional checks and explicit benchmarks. It runs through Terminal and SSH. A GUI is deferred; command parsing, collectors/checks and rendering are separate.

```
SPECTRA METRICS CLOCK
SPECTRA METRICS ALL /JSON /EXPORT:C:\TEMP\KERNEL.JSON
SPECTRA METRICS LOCKS /WATCH:3 /INTERVAL:1000
SPECTRA LOGS BOOT
SPECTRA LOGS SERVICE /JSON
SPECTRA CHECK THREAD
SPECTRA CHECK THREAD /PROCESSEXIT
SPECTRA CHECK PERFORMANCE
SPECTRA BENCH CLOCK /REPEAT:3 /WARM
```

Use `SPECTRA HELP` for the complete group list. No arguments display help. Passive queries never start workloads or enable kernel instrumentation. Benchmarks and checks require an explicit group.

Build through `Build.sh` (Linux) or `Build.bat` (Windows), with PS7 and the configured SDK. `Build.sh test` runs the command/routing/measurement host tests. `module.R4MF` owns the artifact identity; the installed name is `SPECTRA.R4X`.

An independent checkout can also use `zig build` with the R4OS Zig toolchain; `build.zig.zon` pins the public SDK and library packages.

The module consolidates former R4OS kernel diagnostics. Source identities and required notices are retained in `Provenance/`; loader fixtures live in `Fixtures/Loader/`. See `DOCUMENTATION.de.txt` for data formats, limits and the migration boundary.

The required R4OS performance benchmark is `SPECTRA BENCH STANDARD`, suite
`spectra-standard-2` (Spectra 0.1.2). Each of the five areas actively warms up
for at least one second and three complete batches before five fixed, longer
measurements. The scheduler peer acknowledges readiness before timing starts.
All warmup work and measured samples are retained, with five equally weighted
scores plus overall. `/AREA:memory` selects a component; `/BASELINE` explicitly
defines a self-reference. `Tools/Export-StandardBenchmark.ps1` validates the
guest records and supplies the standalone Schema-1 host export/reference
comparison. `Baselines/standard-2.reference.json` pins the reference UUID and
scoring/export hashes; the full run stays in DevCenter or local workspace
artifacts. The runner resolves the verified local cache or downloads from
`R4OS_DEVCENTER_API_URL` / `Tools/BenchmarkHost.R4S` (`DEVCENTER_API_URL`).
Real run exports never belong in Git. `standard-1.reference.json` pins the
unchanged historical Suite-1 reference. Scores from
the two suites are not comparable. The package also owns the small
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
