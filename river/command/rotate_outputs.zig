const std = @import("std");

const wlr = @import("wlroots");

const server = &@import("../main.zig").server;
const util = @import("../util.zig");

const Direction = @import("../command.zig").Direction;
const PhysicalDirectionDirection = @import("../command.zig").PhysicalDirection;
const Error = @import("../command.zig").Error;
const Output = @import("../Output.zig");
const Seat = @import("../Seat.zig");
const ViewStack = @import("../view_stack.zig").ViewStack;
const View = @import("../View.zig");

fn updateView(view: *View, destination_output: *Output) void {
    view.pending.tags = destination_output.pending.tags;

    // if the view is mapped send enter/leave events
    if (view.surface != null) {
        view.sendLeave(view.output);
        view.sendEnter(destination_output);

        // Must be present if surface is non-null indicating that the view
        // is mapped.
        view.foreign_toplevel_handle.?.outputLeave(view.output.wlr_output);
        view.foreign_toplevel_handle.?.outputEnter(destination_output.wlr_output);
    }

    view.output = destination_output;

    var output_width: i32 = undefined;
    var output_height: i32 = undefined;
    destination_output.wlr_output.effectiveResolution(&output_width, &output_height);

    if (view.pending.float) {
        // Adapt dimensions of view to new output. Only necessary when floating,
        // because for tiled views the output will be rearranged, taking care
        // of this.
        if (view.pending.fullscreen) view.pending.box = view.post_fullscreen_box;
        const border_width = if (view.shouldDrawBorders()) server.config.border_width else 0;
        view.pending.box.width = std.math.min(view.pending.box.width, output_width - (2 * border_width));
        view.pending.box.height = std.math.min(view.pending.box.height, output_height - (2 * border_width));

        // Adjust position of view so that it is fully inside the target output.
        view.move(0, 0);
    }

    if (view.pending.fullscreen) {
        // If the view is floating, we need to set the post_fullscreen_box, as
        // that is still set for the previous output.
        if (view.pending.float) view.post_fullscreen_box = view.pending.box;

        view.pending.box = .{
            .x = 0,
            .y = 0,
            .width = output_width,
            .height = output_height,
        };
    }
}

pub fn rotateOutputs(
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 1) return Error.NotEnoughArguments;
    if (args.len > 1) return Error.TooManyArguments;

    // If the noop output is focused, there is nowhere to send the view
    if (seat.focused_output == &server.root.noop_output) {
        std.debug.assert(server.root.outputs.len == 0);
        return;
    }

    // Need at least 2 outputs
    if (server.root.all_outputs.len <= 1) {
        return;
    }

    std.debug.assert(server.root.all_outputs.first != null);
    std.debug.assert(server.root.all_outputs.last != null);
    std.debug.assert(server.root.all_outputs.first != server.root.all_outputs.last);

    var firstViews = std.ArrayList(*ViewStack(View).Node).init(util.gpa);
    var it: ?*std.TailQueue(*Output).Node = server.root.all_outputs.first;
    var refocused: bool = false;

    var viewNodeIt = it.?.data.views.first;
    while (viewNodeIt) |viewNode| : (viewNodeIt = viewNode.next) {
        if (viewNode.view.pending.tags & it.?.data.pending.tags != 0) {
            it.?.data.views.remove(viewNode);
            firstViews.append(viewNode) catch unreachable;
        }
    }

    var status_it = seat.status_trackers.first;
    while (status_it) |node| : (status_it = node.next) node.data.seat_status.sendFocusedView("");

    while (it) |node| : (it = node.next) {
        var output = node.data;
        if (node.next) |next| {
            viewNodeIt = next.data.views.first;
            while (viewNodeIt) |viewNode| {
                viewNodeIt = viewNode.next;
                if (viewNode.view.pending.tags & next.data.pending.tags != 0) {
                    next.data.views.remove(viewNode);
                    output.views.append(viewNode);
                    updateView(&viewNode.view, output);
                }
            }
        } else {
            for (firstViews.items) |viewNode| {
                output.views.append(viewNode);
                updateView(&viewNode.view, output);
            }
        }

        if (!refocused and seat.focused_output == output) {
            refocused = true;
            if (node.next) |next| {
                seat.focusOutput(next.data);
            } else {
                seat.focusOutput(server.root.all_outputs.first.?.data);
            }
        }
    }

    seat.focus(null);

    it = server.root.all_outputs.first.?;
    while (it) |node| : (it = node.next) {
        node.data.sendViewTags();
        node.data.sendUrgentTags();
        node.data.arrangeViews();
    }

    server.root.startTransaction();

    status_it = seat.status_trackers.first;
    while (status_it) |node| : (status_it = node.next) node.data.sendFocusedView();
}
