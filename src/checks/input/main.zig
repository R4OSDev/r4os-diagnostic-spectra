const r4os = @import("r4os");

const DiagApi = struct {
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    draw: r4os.r4draw.Context,
    dev: r4os.r4dev.Context,

    fn init(r4_app: *r4os.App) ?DiagApi {
        return .{
            .sys = r4_app.system(),
            .desk = r4_app.desktop() orelse return null,
            .draw = r4_app.drawing() orelse return null,
            .dev = r4_app.devicesLowLevel() orelse return null,
        };
    }
};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    var ctx = DiagApi.init(r4_app) orelse return r4os.abi.err_no_group;
    var mouse: r4os.abi.Mouse = undefined;
    ctx.desk.mouseState(&mouse);

    ctx.sys.println("SPECTRA INPUT");
    ctx.sys.print("screen: ");
    ctx.sys.printU64(ctx.draw.screenWidth());
    ctx.sys.write("x");
    ctx.sys.printU64(ctx.draw.screenHeight());
    ctx.sys.write("\r\n");

    ctx.sys.print("mouse present=");
    ctx.sys.printU64(mouse.present);
    ctx.sys.write(" x=");
    ctx.sys.printI32(mouse.x);
    ctx.sys.write(" y=");
    ctx.sys.printI32(mouse.y);
    ctx.sys.write(" buttons=");
    ctx.sys.printU64(mouse.buttons);
    ctx.sys.write(" packets=");
    ctx.sys.printU64(mouse.packets);
    ctx.sys.write("\r\n");

    if (ctx.dev.performanceInput()) |input| {
        ctx.sys.print("i8042 irq1=");
        ctx.sys.printU64(input.i8042_irq1_count);
        ctx.sys.write(" irq12=");
        ctx.sys.printU64(input.i8042_irq12_count);
        ctx.sys.write(" bytes=");
        ctx.sys.printU64(input.i8042_byte_count);
        ctx.sys.write(" kbOnIrq12=");
        ctx.sys.printU64(input.i8042_keyboard_bytes_on_irq12);
        ctx.sys.write(" mouseOnIrq1=");
        ctx.sys.printU64(input.i8042_mouse_bytes_on_irq1);
        ctx.sys.write(" limitHits=");
        ctx.sys.printU64(input.i8042_drain_limit_hits);
        ctx.sys.write("\r\n");

        ctx.sys.print("keyboard capacity=");
        ctx.sys.printU64(input.keyboard_queue_capacity);
        ctx.sys.write(" pending=");
        ctx.sys.printU64(input.keyboard_queue_pending);
        ctx.sys.write(" highWater=");
        ctx.sys.printU64(input.keyboard_queue_high_water);
        ctx.sys.write(" accepted=");
        ctx.sys.printU64(input.keyboard_accepted);
        ctx.sys.write(" dropped=");
        ctx.sys.printU64(input.keyboard_dropped);
        ctx.sys.write("\r\n");

        ctx.sys.print("gui capacity=");
        ctx.sys.printU64(input.gui_queue_capacity);
        ctx.sys.write(" pending=");
        ctx.sys.printU64(input.gui_queue_pending);
        ctx.sys.write(" highWater=");
        ctx.sys.printU64(input.gui_queue_high_water);
        ctx.sys.write(" coalesced=");
        ctx.sys.printU64(input.gui_mouse_move_coalesced);
        ctx.sys.write(" evicted=");
        ctx.sys.printU64(input.gui_mouse_move_evicted);
        ctx.sys.write(" rejected=");
        ctx.sys.printU64(input.gui_rejected);
        ctx.sys.write("\r\n");

        ctx.sys.print("console capacity=");
        ctx.sys.printU64(input.console_queue_capacity);
        ctx.sys.write(" pending=");
        ctx.sys.printU64(input.console_queue_pending);
        ctx.sys.write(" highWater=");
        ctx.sys.printU64(input.console_queue_high_water);
        ctx.sys.write(" batches=");
        ctx.sys.printU64(input.console_batch_calls);
        ctx.sys.write(" attempted=");
        ctx.sys.printU64(input.console_bytes_attempted);
        ctx.sys.write(" accepted=");
        ctx.sys.printU64(input.console_bytes_accepted);
        ctx.sys.write(" full=");
        ctx.sys.printU64(input.console_full_events);
        ctx.sys.write("\r\n");

        ctx.sys.print("program launches=");
        ctx.sys.printU64(input.program_launch_attempts);
        ctx.sys.write(" entries=");
        ctx.sys.printU64(input.program_entries_started);
        ctx.sys.write(" attachPending=");
        ctx.sys.printU64(input.program_start_attach_pending);
        ctx.sys.write(" attachWaits=");
        ctx.sys.printU64(input.program_attach_wait_events);
        ctx.sys.write("\r\n");
    } else {
        ctx.sys.println("input performance unavailable");
    }

    ctx.sys.println("keys for 100 ticks, Q exits:");
    const deadline = ctx.sys.ticks() + 100;
    while (ctx.sys.ticks() < deadline) {
        const key = ctx.desk.readKey();
        if (key == 0) {
            ctx.sys.taskYield();
            continue;
        }
        ctx.sys.print("key ");
        ctx.sys.printHexU32(key);
        ctx.sys.write("\r\n");
        if (key == 'q' or key == 'Q') break;
    }

    return 0;
}
