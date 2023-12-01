/// Split represents a surface split where two surfaces are shown side-by-side
/// within the same window either vertically or horizontally.
const Split = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const font = @import("../../font/main.zig");
const input = @import("../../input.zig");
const CoreSurface = @import("../../Surface.zig");

const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const c = @import("c.zig");

const log = std.log.scoped(.gtk);

/// Our actual GtkPaned widget
paned: *c.GtkPaned,

/// The container for this split panel.
container: Surface.Container,

/// The elements of this split panel.
top_left: Surface.Container.Elem,
bottom_right: Surface.Container.Elem,

/// Create a new split panel with the given sibling surface in the given
/// direction. The direction is where the new surface will be initialized.
///
/// The sibling surface can be in a split already or it can be within a
/// tab. This properly handles updating the surface container so that
/// it represents the new split.
pub fn create(
    alloc: Allocator,
    sibling: *Surface,
    direction: input.SplitDirection,
) !*Split {
    var split = try alloc.create(Split);
    errdefer alloc.destroy(split);
    try split.init(sibling, direction);
    return split;
}

pub fn init(
    self: *Split,
    sibling: *Surface,
    direction: input.SplitDirection,
) !void {
    // Create the new child surface for the other direction.
    const alloc = sibling.app.core_app.alloc;
    var surface = try Surface.create(alloc, sibling.app, .{
        .parent = &sibling.core_surface,
    });
    errdefer surface.destroy(alloc);

    // Create the actual GTKPaned, attach the proper children.
    const orientation: c_uint = switch (direction) {
        .right => c.GTK_ORIENTATION_HORIZONTAL,
        .down => c.GTK_ORIENTATION_VERTICAL,
    };
    const paned = c.gtk_paned_new(orientation);
    errdefer c.g_object_unref(paned);

    // Keep a long-lived reference, which we unref in destroy.
    _ = c.g_object_ref(paned);

    // Update all of our containers to point to the right place.
    // The split has to point to where the sibling pointed to because
    // we're inheriting its parent. The sibling points to its location
    // in the split, and the surface points to the other location.
    const container = sibling.container;
    sibling.container = .{ .split_tl = &self.top_left };
    surface.container = .{ .split_br = &self.bottom_right };

    self.* = .{
        .paned = @ptrCast(paned),
        .container = container,
        .top_left = .{ .surface = sibling },
        .bottom_right = .{ .surface = surface },
    };

    // Replace the previous containers element with our split.
    // This allows a non-split to become a split, a split to
    // become a nested split, etc.
    container.replace(.{ .split = self });

    // Update our children so that our GL area is properly
    // added to the paned.
    self.updateChildren();

    // The new surface should always grab focus
    surface.grabFocus();
}

pub fn destroy(self: *Split, alloc: Allocator) void {
    self.top_left.deinit(alloc);
    self.bottom_right.deinit(alloc);

    // Clean up our GTK reference. This will trigger all the destroy callbacks
    // that are necessary for the surfaces to clean up.
    c.g_object_unref(self.paned);

    alloc.destroy(self);
}

/// Remove the top left child.
pub fn removeTopLeft(self: *Split) void {
    self.removeChild(self.top_left, self.bottom_right);
}

/// Remove the top left child.
pub fn removeBottomRight(self: *Split) void {
    self.removeChild(self.bottom_right, self.top_left);
}

fn removeChild(
    self: *Split,
    remove: Surface.Container.Elem,
    keep: Surface.Container.Elem,
) void {
    const window = self.container.window() orelse return;
    const alloc = window.app.core_app.alloc;

    // Remove our children since we are going to no longer be
    // a split anyways. This prevents widgets with multiple parents.
    self.removeChildren();

    // Our container must become whatever our top left is
    self.container.replace(keep);

    // Grab focus of the left-over side
    keep.grabFocus();

    // When a child is removed we are no longer a split, so destroy ourself
    remove.deinit(alloc);
    alloc.destroy(self);
}

// This replaces the element at the given pointer with a new element.
// The ptr must be either top_left or bottom_right (asserted in debug).
// The memory of the old element must be freed or otherwise handled by
// the caller.
pub fn replace(
    self: *Split,
    ptr: *Surface.Container.Elem,
    new: Surface.Container.Elem,
) void {
    // We can write our element directly. There's nothing special.
    assert(&self.top_left == ptr or &self.bottom_right == ptr);
    ptr.* = new;

    // Update our paned children. This will reset the divider
    // position but we want to keep it in place so save and restore it.
    const pos = c.gtk_paned_get_position(self.paned);
    defer c.gtk_paned_set_position(self.paned, pos);
    self.updateChildren();
}

// grabFocus grabs the focus of the top-left element.
pub fn grabFocus(self: *Split) void {
    self.top_left.grabFocus();
}

/// Update the paned children to represent the current state.
/// This should be called anytime the top/left or bottom/right
/// element is changed.
fn updateChildren(self: *const Split) void {
    // We have to set both to null. If we overwrite the pane with
    // the same value, then GTK bugs out (the GL area unrealizes
    // and never rerealizes).
    self.removeChildren();

    // Set our current children
    c.gtk_paned_set_start_child(
        @ptrCast(self.paned),
        self.top_left.widget(),
    );
    c.gtk_paned_set_end_child(
        @ptrCast(self.paned),
        self.bottom_right.widget(),
    );
}

/// A mapping of direction to the element (if any) in that direction.
pub const DirectionMap = std.EnumMap(
    input.SplitFocusDirection,
    ?*Surface,
);

pub const Side = enum { top_left, bottom_right };

/// Returns the map that can be used to determine elements in various
/// directions (primarily for gotoSplit).
pub fn directionMap(self: *const Split, from: Side) DirectionMap {
    return switch (from) {
        .top_left => self.directionMapFromTopLeft(),
        .bottom_right => self.directionMapFromBottomRight(),
    };
}

fn directionMapFromTopLeft(self: *const Split) DirectionMap {
    var result = DirectionMap.initFull(null);

    if (self.container.split()) |parent_split| {
        const deepest_br = parent_split.deepestSurface(.bottom_right);
        result.put(.previous, deepest_br);

        // This behavior matches the behavior of macOS at the time of writing
        // this. There is an open issue (#524) to make this depend on the
        // actual physical location of the current split.
        result.put(.top, deepest_br);
        result.put(.left, deepest_br);
    }

    switch (self.bottom_right) {
        .surface => |s| {
            result.put(.next, s);
            result.put(.bottom, s);
            result.put(.right, s);
        },

        .split => |s| {
            const deepest_tl = s.deepestSurface(.top_left);
            result.put(.next, deepest_tl);
            result.put(.bottom, deepest_tl);
            result.put(.right, deepest_tl);
        },
    }

    return result;
}

fn directionMapFromBottomRight(self: *const Split) DirectionMap {
    var result = DirectionMap.initFull(null);

    if (self.container.split()) |parent_split| {
        const deepest_tl = parent_split.deepestSurface(.top_left);
        result.put(.next, deepest_tl);

        // This behavior matches the behavior of macOS at the time of writing
        // this. There is an open issue (#524) to make this depend on the
        // actual physical location of the current split.
        result.put(.top, deepest_tl);
        result.put(.left, deepest_tl);
    }

    switch (self.top_left) {
        .surface => |s| {
            result.put(.previous, s);
            result.put(.bottom, s);
            result.put(.right, s);
        },

        .split => |s| {
            const deepest_br = s.deepestSurface(.bottom_right);
            result.put(.previous, deepest_br);
            result.put(.bottom, deepest_br);
            result.put(.right, deepest_br);
        },
    }

    return result;
}

/// Get the most deeply nested surface for a given side.
fn deepestSurface(self: *const Split, side: Side) *Surface {
    return switch (side) {
        .bottom_right => switch (self.bottom_right) {
            .surface => |s| s,
            .split => |s| s.deepestSurface(.bottom_right),
        },

        .top_left => switch (self.top_left) {
            .surface => |s| s,
            .split => |s| s.deepestSurface(.top_left),
        },
    };
}

fn removeChildren(self: *const Split) void {
    c.gtk_paned_set_start_child(@ptrCast(self.paned), null);
    c.gtk_paned_set_end_child(@ptrCast(self.paned), null);
}
