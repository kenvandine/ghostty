const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const log = std.log.scoped(.flatpak);

/// Returns true if we're running in a Flatpak environment.
pub fn isFlatpak() bool {
    // If we're not on Linux then we'll make this comptime false.
    if (comptime builtin.os.tag != .linux) return false;
    return if (std.fs.accessAbsolute("/.flatpak-info", .{})) true else |_| false;
}

/// A struct to help execute commands on the host via the
/// org.freedesktop.Flatpak.Development DBus module. This uses GIO/GLib
/// under the hood.
///
/// This always spawns its own thread and maintains its own GLib event loop.
/// This makes it easy for the command to behave synchronously similar to
/// std.process.ChildProcess.
///
/// There are lots of chances for low-hanging improvements here (automatic
/// pipes, /dev/null, etc.) but this was purpose built for my needs so
/// it doesn't have all of those.
///
/// Requires GIO, GLib to be available and linked.
pub const FlatpakHostCommand = struct {
    const fd_t = std.os.fd_t;
    const EnvMap = std.process.EnvMap;
    const c = @cImport({
        @cInclude("gio/gio.h");
        @cInclude("gio/gunixfdlist.h");
    });

    /// Argv are the arguments to call on the host with argv[0] being
    /// the command to execute.
    argv: []const []const u8,

    /// The cwd for the new process. If this is not set then it will use
    /// the current cwd of the calling process.
    cwd: ?[:0]const u8 = null,

    /// Environment variables for the child process. If this is null, this
    /// does not send any environment variables.
    env: ?*const EnvMap = null,

    /// File descriptors to send to the child process. It is up to the
    /// caller to create the file descriptors and set them up.
    stdin: fd_t,
    stdout: fd_t,
    stderr: fd_t,

    /// State of the process. This is updated by the dedicated thread it
    /// runs in and is protected by the given lock and condition variable.
    state: State = .{ .init = {} },
    state_mutex: std.Thread.Mutex = .{},
    state_cv: std.Thread.Condition = .{},

    /// State the process is in. This can't be inspected directly, you
    /// must use getters on the struct to get access.
    const State = union(enum) {
        /// Initial state
        init: void,

        /// Error starting. The error message is only available via logs.
        /// (This isn't a fundamental limitation, just didn't need the
        /// error message yet)
        err: void,

        /// Process started with the given pid on the host.
        started: struct {
            pid: c_int,
            subscription: c.guint,
            loop: *c.GMainLoop,
        },

        /// Process exited
        exited: struct {
            pid: c_int,
            status: u8,
        },
    };

    /// Errors that are possible from us.
    pub const Error = error{
        FlatpakMustBeStarted,
        FlatpakSpawnFail,
        FlatpakSetupFail,
        FlatpakRPCFail,
    };

    /// Spawn the command. This will start the host command. On return,
    /// the pid will be available. This must only be called with the
    /// state in "init".
    ///
    /// Precondition: The self pointer MUST be stable.
    pub fn spawn(self: *FlatpakHostCommand, alloc: Allocator) !c_int {
        const thread = try std.Thread.spawn(.{}, threadMain, .{ self, alloc });
        thread.setName("flatpak-host-command") catch {};

        // Wait for the process to start or error.
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        while (self.state == .init) self.state_cv.wait(&self.state_mutex);

        return switch (self.state) {
            .init => unreachable,
            .err => Error.FlatpakSpawnFail,
            .started => |v| v.pid,
            .exited => |v| v.pid,
        };
    }

    /// Wait for the process to end and return the exit status. This
    /// can only be called ONCE. Once this returns, the state is reset.
    pub fn wait(self: *FlatpakHostCommand) !u8 {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();

        while (true) {
            switch (self.state) {
                .init => return Error.FlatpakMustBeStarted,
                .err => return Error.FlatpakSpawnFail,
                .started => {},
                .exited => |v| {
                    self.state = .{ .init = {} };
                    self.state_cv.broadcast();
                    return v.status;
                },
            }

            self.state_cv.wait(&self.state_mutex);
        }
    }

    /// Send a signal to the started command. This does nothing if the
    /// command is not in the started state.
    pub fn signal(self: *FlatpakHostCommand, sig: u8, pg: bool) !void {
        const pid = pid: {
            self.state_mutex.lock();
            defer self.state_mutex.unlock();
            switch (self.state) {
                .started => |v| break :pid v.pid,
                else => return,
            }
        };

        // Get our bus connection.
        var g_err: [*c]c.GError = null;
        const bus = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, &g_err) orelse {
            log.warn("signal error getting bus: {s}", .{g_err.*.message});
            return Error.FlatpakSetupFail;
        };
        defer c.g_object_unref(bus);

        const reply = c.g_dbus_connection_call_sync(
            bus,
            "org.freedesktop.Flatpak",
            "/org/freedesktop/Flatpak/Development",
            "org.freedesktop.Flatpak.Development",
            "HostCommandSignal",
            c.g_variant_new(
                "(uub)",
                pid,
                sig,
                @intCast(c_int, @intFromBool(pg)),
            ),
            c.G_VARIANT_TYPE("()"),
            c.G_DBUS_CALL_FLAGS_NONE,
            c.G_MAXINT,
            null,
            &g_err,
        );
        if (g_err != null) {
            log.warn("signal send error: {s}", .{g_err.*.message});
            return;
        }
        defer c.g_variant_unref(reply);
    }

    fn threadMain(self: *FlatpakHostCommand, alloc: Allocator) void {
        // Create a new thread-local context so that all our sources go
        // to this context and we can run our loop correctly.
        const ctx = c.g_main_context_new();
        defer c.g_main_context_unref(ctx);
        c.g_main_context_push_thread_default(ctx);
        defer c.g_main_context_pop_thread_default(ctx);

        // Get our loop for the current thread
        const loop = c.g_main_loop_new(ctx, 1).?;
        defer c.g_main_loop_unref(loop);

        // Get our bus connection. This has to remain active until we exit
        // the thread otherwise our signals won't be called.
        var g_err: [*c]c.GError = null;
        const bus = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, &g_err) orelse {
            log.warn("spawn error getting bus: {s}", .{g_err.*.message});
            self.updateState(.{ .err = {} });
            return;
        };
        defer c.g_object_unref(bus);

        // Spawn the command first. This will setup all our IO.
        self.start(alloc, bus, loop) catch |err| {
            log.warn("error starting host command: {}", .{err});
            self.updateState(.{ .err = {} });
            return;
        };

        // Run the event loop. It quits in the exit callback.
        c.g_main_loop_run(loop);
    }

    /// Start the command. This will start the host command and set the
    /// pid field on success. This will not wait for completion.
    ///
    /// Once this is called, the self pointer MUST remain stable. This
    /// requirement is due to using GLib under the covers with callbacks.
    fn start(
        self: *FlatpakHostCommand,
        alloc: Allocator,
        bus: *c.GDBusConnection,
        loop: *c.GMainLoop,
    ) !void {
        var err: [*c]c.GError = null;
        var arena_allocator = std.heap.ArenaAllocator.init(alloc);
        defer arena_allocator.deinit();
        const arena = arena_allocator.allocator();

        // Our list of file descriptors that we need to send to the process.
        const fd_list = c.g_unix_fd_list_new();
        defer c.g_object_unref(fd_list);
        if (c.g_unix_fd_list_append(fd_list, self.stdin, &err) < 0) {
            log.warn("error adding fd: {s}", .{err.*.message});
            return Error.FlatpakSetupFail;
        }
        if (c.g_unix_fd_list_append(fd_list, self.stdout, &err) < 0) {
            log.warn("error adding fd: {s}", .{err.*.message});
            return Error.FlatpakSetupFail;
        }
        if (c.g_unix_fd_list_append(fd_list, self.stderr, &err) < 0) {
            log.warn("error adding fd: {s}", .{err.*.message});
            return Error.FlatpakSetupFail;
        }

        // Build our arguments for the file descriptors.
        const fd_builder = c.g_variant_builder_new(c.G_VARIANT_TYPE("a{uh}"));
        defer c.g_variant_builder_unref(fd_builder);
        c.g_variant_builder_add(fd_builder, "{uh}", @as(c_int, 0), self.stdin);
        c.g_variant_builder_add(fd_builder, "{uh}", @as(c_int, 1), self.stdout);
        c.g_variant_builder_add(fd_builder, "{uh}", @as(c_int, 2), self.stderr);

        // Build our env vars
        const env_builder = c.g_variant_builder_new(c.G_VARIANT_TYPE("a{ss}"));
        defer c.g_variant_builder_unref(env_builder);
        if (self.env) |env| {
            var it = env.iterator();
            while (it.next()) |pair| {
                const key = try arena.dupeZ(u8, pair.key_ptr.*);
                const value = try arena.dupeZ(u8, pair.value_ptr.*);
                c.g_variant_builder_add(env_builder, "{ss}", key.ptr, value.ptr);
            }
        }

        // Build our args
        const args_ptr = c.g_ptr_array_new();
        {
            errdefer _ = c.g_ptr_array_free(args_ptr, 1);
            for (self.argv) |arg| {
                const argZ = try arena.dupeZ(u8, arg);
                c.g_ptr_array_add(args_ptr, argZ.ptr);
            }
        }
        const args = c.g_ptr_array_free(args_ptr, 0);
        defer c.g_free(@ptrCast(?*anyopaque, args));

        // Get the cwd in case we don't have ours set. A small optimization
        // would be to do this only if we need it but this isn't a
        // common code path.
        const g_cwd = c.g_get_current_dir();
        defer c.g_free(g_cwd);

        // The params for our RPC call
        const params = c.g_variant_new(
            "(^ay^aay@a{uh}@a{ss}u)",
            @as(*const anyopaque, if (self.cwd) |*cwd| cwd.ptr else g_cwd),
            args,
            c.g_variant_builder_end(fd_builder),
            c.g_variant_builder_end(env_builder),
            @as(c_int, 0),
        );
        _ = c.g_variant_ref_sink(params); // take ownership
        defer c.g_variant_unref(params);

        // Subscribe to exit notifications
        const subscription_id = c.g_dbus_connection_signal_subscribe(
            bus,
            "org.freedesktop.Flatpak",
            "org.freedesktop.Flatpak.Development",
            "HostCommandExited",
            "/org/freedesktop/Flatpak/Development",
            null,
            0,
            onExit,
            self,
            null,
        );
        errdefer c.g_dbus_connection_signal_unsubscribe(bus, subscription_id);

        // Go!
        const reply = c.g_dbus_connection_call_with_unix_fd_list_sync(
            bus,
            "org.freedesktop.Flatpak",
            "/org/freedesktop/Flatpak/Development",
            "org.freedesktop.Flatpak.Development",
            "HostCommand",
            params,
            c.G_VARIANT_TYPE("(u)"),
            c.G_DBUS_CALL_FLAGS_NONE,
            c.G_MAXINT,
            fd_list,
            null,
            null,
            &err,
        ) orelse {
            log.warn("Flatpak.HostCommand failed: {s}", .{err.*.message});
            return Error.FlatpakRPCFail;
        };
        defer c.g_variant_unref(reply);

        var pid: c_int = 0;
        c.g_variant_get(reply, "(u)", &pid);
        log.debug("HostCommand started pid={} subscription={}", .{
            pid,
            subscription_id,
        });

        self.updateState(.{
            .started = .{
                .pid = pid,
                .subscription = subscription_id,
                .loop = loop,
            },
        });
    }

    /// Helper to update the state and notify waiters via the cv.
    fn updateState(self: *FlatpakHostCommand, state: State) void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        defer self.state_cv.broadcast();
        self.state = state;
    }

    fn onExit(
        bus: ?*c.GDBusConnection,
        _: [*c]const u8,
        _: [*c]const u8,
        _: [*c]const u8,
        _: [*c]const u8,
        params: ?*c.GVariant,
        ud: ?*anyopaque,
    ) callconv(.C) void {
        const self = @ptrCast(*FlatpakHostCommand, @alignCast(@alignOf(FlatpakHostCommand), ud));
        const state = state: {
            self.state_mutex.lock();
            defer self.state_mutex.unlock();
            break :state self.state.started;
        };

        var pid: c_int = 0;
        var exit_status: c_int = 0;
        c.g_variant_get(params.?, "(uu)", &pid, &exit_status);
        if (state.pid != pid) return;

        // Update our state
        self.updateState(.{
            .exited = .{
                .pid = pid,
                .status = std.math.cast(u8, exit_status) orelse 255,
            },
        });
        log.debug("HostCommand exited pid={} status={}", .{ pid, exit_status });

        // We're done now, so we can unsubscribe
        c.g_dbus_connection_signal_unsubscribe(bus.?, state.subscription);

        // We are also done with our loop so we can exit.
        c.g_main_loop_quit(state.loop);
    }
};
