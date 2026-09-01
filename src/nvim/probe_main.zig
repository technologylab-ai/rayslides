const std = @import("std");
const neovim = @import("neovim");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const result = neovim.probe.run(init.io, init.gpa, "nvim") catch |err| switch (err) {
        error.FileNotFound => {
            try stdout_writer.interface.writeAll("Neovim embed probe skipped: nvim was not found\n");
            try stdout_writer.interface.flush();
            return;
        },
        else => return err,
    };
    try stdout_writer.interface.print(
        "Neovim embed probe passed: grid={}x{}, grid_line={}, flush={}, edited_buffer={}\n",
        .{ result.grid_width, result.grid_height, result.saw_grid_line, result.saw_flush, result.edited_buffer },
    );
    const session_result = try neovim.session_probe.run(init.io, init.gpa, "nvim");
    try stdout_writer.interface.print(
        "Neovim session probe passed:\n" ++
            "  basic: ready={}, rendered={}, write={}, clean_q_closed={}\n" ++
            "  quit/apply: rejected_wq_open={}, dirty_q_open={}, q!_closed={}, wq={}, x={}, ZZ={}, ZQ={}\n" ++
            "  lifecycle: clean_qa={}, dirty_qa_open={}, qa!={}, buffer_close={}, child_failure={}, host_reaped={}\n" ++
            "  fidelity: repeated_write_discard={}, exact_source={}, focus={}, field_buffer={}\n",
        .{
            session_result.ready,
            session_result.rendered,
            session_result.write_round_trip,
            session_result.quit_closed_overlay,
            session_result.rejected_wq_stayed_open,
            session_result.dirty_q_stayed_open,
            session_result.forced_quit_closed_overlay,
            session_result.wq_applied_and_closed,
            session_result.x_applied_and_closed,
            session_result.zz_applied_and_closed,
            session_result.zq_discarded_and_closed,
            session_result.clean_qa_closed,
            session_result.dirty_qa_stayed_open,
            session_result.forced_qa_closed,
            session_result.buffer_close_closed_overlay,
            session_result.child_failure_closed_overlay,
            session_result.host_shutdown_reaped,
            session_result.repeated_writes_then_discard,
            session_result.exact_source_round_trip,
            session_result.focus_round_trip,
            session_result.field_buffer_round_trip,
        },
    );
    try stdout_writer.interface.flush();
}
