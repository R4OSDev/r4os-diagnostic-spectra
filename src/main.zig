const std = @import("std");
const r4os = @import("r4os");
const cli = @import("cli.zig");
const Output = @import("output.zig").Output;
const metrics = @import("metrics.zig");
const logs = @import("logs.zig");
const checks = @import("checks.zig");

var output: Output = undefined;
var request: cli.Request = undefined;

pub fn r4_app_main(app: *r4os.App) i32 {
    const launcher = @import("standard_launch.zig");
    const raw = app.args();
    if (std.mem.eql(u8, raw, @import("remote_frame_check.zig").child_argument)) return @import("remote_frame_check.zig").child(app);
    if (std.mem.startsWith(u8, raw, @import("desktop_replay_check.zig").child_argument)) return @import("desktop_replay_check.zig").child(app);
    const worker = std.mem.startsWith(u8, raw, launcher.prefix);
    var worker_command: [1024]u8 = undefined;
    request = (if (worker) launcher.workerRequest(app, raw, &worker_command) else cli.parse(raw)) catch |err| {
        const sys = app.system();
        sys.write("SPECTRA: ");
        sys.println(@errorName(err));
        sys.println("SPECTRA HELP shows commands.");
        return 2;
    };
    if (!worker and request.command == .bench and cli.same(request.group(), "STANDARD")) return launcher.launch(app, &request);
    output = Output.init(app, &request);
    if (output.failed) {
        app.system().println("SPECTRA: export could not be opened");
        return 3;
    }
    if (app.devicesLowLevel()) |dev| if (dev.performanceInstrumentation()) |info| {
        output.detail = info.mode != 0;
    };
    var result: i32 = 0;
    switch (request.command) {
        .help => output.message("help", "SPECTRA " ++ @import("spectra_version").value ++ " - kernel diagnostics and explicit Desktop state\r\n" ++
            "  METRICS ALL|CLOCK|SUMMARY|LOCKS|STACKS|TASKS|SMP|CPUFEATURES|CPUPOWER|MCA|MICROCODE|PMU|ENTROPY|MEMORY|BOOT|IRQ|STORAGE|WORK|IPC|NETWORK|INPUT|PCI|LIFECYCLE\r\n" ++
            "  LOGS BOOT|SERVICE|APPLICATION\r\n" ++
            "  METRICS DESKTOP (passive current WINSVC/Kernel copies; excluded from ALL)\r\n" ++
            "  CHECK BOOT|PERFORMANCE|WORK|THREAD|SMP|STACK|SIMD|LIFECYCLE|ASYNC_IO|MEMORY|FILESYSTEM|NTFS|LOADER|RESOURCES|INPUT|NETWORK|IPC|VM|STORAGE|TCP|USB [options]\r\n" ++
            "  CHECK SMP [/ADMISSION|/LIFECYCLE|/POWER|/FEATURES|/FEATURES-OFFLINE:n|/MCA|/MICROCODE|/PMU|/ACCEL|/ENTROPY|/ENTROPY-NONE]\r\n" ++
            "  CHECK TEXT /CODECS (strict imported legacy/UTF-8 and exact document bytes)\r\n" ++
            "  CHECK DESKTOP [/HOST] [/RESTART] [/AUDIO] [/CAPTURE] [/REPLAY] (/REPLAY requires a native GR owner)\r\n" ++
            "  CHECK DESKTOP /OWNER (one copied owner report; no scene work, capture or restart)\r\n" ++
            "  CHECK SUBSYSTEM [/HOST] [/SNES] (isolated Test fixtures; /SNES selects only that original pair)\r\n" ++
            "  CHECK DESKTOP /CANCEL (own real check child; expects Exit4, reap and empty resources)\r\n" ++
            "  CHECK REMOTEFRAME [/EXITOWNED] (immutable snapshots; real child exit/reap/owner cleanup)\r\n" ++
            "  CHECK THREAD /KERNEL[:SYNC|SCHED|FPU|ADMISSION|WORKERS] (bounded native checks)\r\n" ++
            "  CHECK VM /INVENTORY (untouched task/thread output pages, real demand faults)\r\n" ++
            "  CHECK LIFECYCLE /METADATA (bounded full/lifecycle comparison and exact ownership)\r\n" ++
            "  CHECK THREAD /RTC (isolated guest; changes/restores calendar; requires 4 CPUs)\r\n" ++
            "  CHECK THREAD /PLACEMENT (native CPU sets/work classes; requires 4 CPUs)\r\n" ++
            "  CHECK VM /AP (owned AP VM, paging, same/cross-volume file I/O; requires 4 CPUs)\r\n" ++
            "  CHECK MEMORY /KERNELHEAP (bounded kernel allocator cases and own cleanup)\r\n" ++
            "  CHECK STORAGE /BLOCKQUEUE[:ADMISSION] (owned synthetic blockqueue cases)\r\n" ++
            "  CHECK STORAGE /NVMEIRQ (one read-only exact IRQ/completion proof)\r\n" ++
            "  BENCH CLOCK|BLIT|SERVICE-REGISTRY|KERNEL-IPC|DRIVER-WORK|PCI-INVENTORY|MEMORY-METADATA [options]\r\n" ++
            "  BENCH OBSERVER (console cost comparison)\r\n" ++
            "  BENCH PMU (bounded native counters; separate from STANDARD)\r\n" ++
            "  BENCH DESKTOP [/OWN-DESKTOP] (original static SDR RAM output work)\r\n" ++
            "  BENCH SNES /WINDOW [/NTSC|/PAL] [/NORMAL|/DETAIL|/PAIRED] [/SMALL|/MAXIMIZED]\r\n" ++
            "    [/CHECK] [/OUTPUT-ANALYSIS] [/OWN-DESKTOP] (isolated Desktop required)\r\n" ++
            "    /OWN-DESKTOP explicitly starts/closes only a new private host; no implicit poweroff.\r\n" ++
            "  BENCH STANDARD [/AREA:scheduler_sync|memory|ipc|lifecycle|filesystem_io]\r\n" ++
            "    [/BASELINE | /REFERENCE:path /COMPAREKEY:method] [/SETTLE:0..5000]\r\n" ++
            "  /JSON writes versioned NDJSON; /EXPORT:path explicitly writes a file.\r\n" ++
            "  METRICS/LOGS: /WATCH:1..60 /INTERVAL:100..60000 (waiting totals at most 60 s).\r\n" ++
            "  Exit: 0 success, 1 failed/incomplete, 2 arguments, 3 output, 4 cancelled.\r\n" ++
            "  Queries do not enable detail instrumentation or traces.", false),
        .check, .bench => result = if (request.command == .bench and cli.same(request.group(), "STANDARD")) @import("standard.zig").run(app, &request, &output) else checks.run(app, &request, &output),
        .metrics, .logs => {
            var i: u32 = 0;
            while (i < request.count) : (i += 1) {
                if (app.system().programShouldClose()) {
                    result = 4;
                    break;
                }
                output.sequence = i;
                const rc = if (request.command == .metrics) metrics.run(app, request.group(), &output) else logs.run(app, request.group(), &output);
                if (rc != 0) result = rc;
                output.flush();
                if (i + 1 < request.count) {
                    var remaining = request.interval_ms;
                    while (remaining != 0 and !app.system().programShouldClose()) {
                        const step: u32 = @min(remaining, 100);
                        app.system().sleepTicks(@max(1, (@as(u64, step) * app.system().monotonicHz() + 999) / 1000));
                        remaining -= step;
                    }
                }
            }
        },
    }
    if (!output.finish()) {
        app.system().println("SPECTRA: output failed; export aborted");
        return 3;
    }
    return result;
}
