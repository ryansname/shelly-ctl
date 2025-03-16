const builtin = @import("builtin");
const fmt = std.fmt;
const http = std.http;
const json = std.json;
const mem = std.mem;
const std = @import("std");

var debug_allocator: std.heap.DebugAllocator(.{ .safety = false }) = .init;
var gpa: std.mem.Allocator = undefined;

const Config = struct {
    service: []const u8,
    payloads: []const []const u8,
};

const Targets = struct {
    byGen: struct {
        gen1: []const Config,
        gen2: []const Config,
    },
    byMac: []const struct {
        mac: []const u8,
        name: []const u8,
        configs: []const Config,
    },
};

const Device = struct {
    ip: []const u8 = undefined,
    mac: []const u8,
    id: ?[]const u8 = null,
    longid: ?u64 = null,
    name: ?[]const u8 = null,
    slot: ?u64 = null,
    type: ?[]const u8 = null,
    model: ?[]const u8 = null,
    gen: u64 = 1,
    fw: ?[]const u8 = null,
    fw_id: ?[]const u8 = null,
    ver: ?[]const u8 = null,
    app: ?[]const u8 = null,
    auth: ?bool = null,
    auth_en: ?bool = null,
    auth_domain: ?[]const u8 = null,
    discoverable: ?bool = null,
    num_inputs: ?u64 = null,
    num_outputs: ?u64 = null,
    num_meters: ?u64 = null,
    num_emeters: ?u64 = null,
    num_rollers: ?u64 = null,
    mode: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    report_period: ?u64 = null,
};

pub fn main() !void {
    gpa, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();

    const cwd = std.fs.cwd();
    const config_zon = try cwd.openFile("config.zon", .{});
    const zon = try config_zon.readToEndAllocOptions(gpa, std.math.maxInt(u32), null, @alignOf(u8), 0);
    defer gpa.free(zon);

    var zon_parse_status: std.zon.parse.Status = .{};
    const targets = try std.zon.parse.fromSlice(Targets, gpa, zon, &zon_parse_status, .{});

    var progress_root = std.Progress.start(.{
        .estimated_total_items = 256,
        .root_name = "Shelly Control",
    });
    defer progress_root.end();

    var client = http.Client{
        .allocator = gpa,
    };
    defer client.deinit();
    try client.initDefaultProxies(gpa);

    var tp: std.Thread.Pool = undefined;
    try tp.init(.{
        .allocator = gpa,
        .n_jobs = 25,
    });
    defer tp.deinit();

    var wg = std.Thread.WaitGroup{};
    while (args.next()) |ip| {
        tp.spawnWg(&wg, spawnWorker, .{ targets, ip, &client, progress_root });
    }
    wg.wait();
}

fn fetchShelly(client: *http.Client, ip: []const u8, json_buf: *std.ArrayList(u8)) !Device {
    var url_buf: [128]u8 = undefined;
    const url = try fmt.bufPrint(&url_buf, "http://{s}/shelly", .{ip});

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_storage = .{ .dynamic = json_buf },
    });

    if (result.status != .ok) return error.NoDevice;

    var device_parse = json.parseFromSlice(Device, gpa, json_buf.items, .{}) catch |err| {
        std.log.err("Failed to parse JSON from {s}: {}", .{ url, err });
        return error.JsonParseError;
    };
    // Leak!
    // defer device_parse.deinit();

    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.log.info("Found at: {s}: {?s} {?s}", .{ url, device_parse.value.type, device_parse.value.model });
    device_parse.value.ip = ip;

    return device_parse.value;
}

fn spawnWorker(targets: Targets, ip: []const u8, client: *http.Client, parent_progress: std.Progress.Node) void {
    _spawnWorker(targets, ip, client, parent_progress) catch |err| std.debug.panic("For Shelly at {s}:\n{}", .{ ip, err });
}

fn _spawnWorker(targets: Targets, ip: []const u8, client: *http.Client, parent_progress: std.Progress.Node) !void {
    const progress = parent_progress.start(ip, 4);
    defer progress.end();

    var json_buf = std.ArrayList(u8).init(gpa);
    defer json_buf.deinit();
    const shelly = fetchShelly(client, ip, &json_buf) catch return;

    try applyGenConfig(targets, shelly, client, progress);
    try applyDeviceConfig(targets, shelly, client, progress);

    try reboot(progress, shelly, client);
}

fn applyGenConfig(targets: Targets, shelly: Device, client: *http.Client, parent_progress: std.Progress.Node) !void {
    const progress = parent_progress.start("Applying config for device generation", 0);
    defer progress.end();

    const config = switch (shelly.gen) {
        1 => targets.byGen.gen1,
        2, 3 => targets.byGen.gen2,
        else => |g| std.debug.panic("Unconfigured generation {}", .{g}),
    };
    for (config) |c| for (c.payloads) |payload| {
        try sendPayload(progress, shelly, client, c.service, payload);
    };
}

fn applyDeviceConfig(targets: Targets, shelly: Device, client: *http.Client, parent_progress: std.Progress.Node) !void {
    const progress = parent_progress.start("Applying config for device", 0);
    defer progress.end();

    const device_config = for (targets.byMac) |config| if (mem.eql(u8, config.mac, shelly.mac)) {
        break config;
    } else continue else return;

    const name_service, const name_payload_root = switch (shelly.gen) {
        1 => .{ "", "name=" },
        2, 3 => .{ "Sys.SetConfig", "config.device.name=" },
        else => |g| std.debug.panic("Unconfigured generation {}", .{g}),
    };
    var name_buf: [128]u8 = undefined;
    const name_payload = try fmt.bufPrint(&name_buf, "{s}{s}", .{ name_payload_root, device_config.name });

    try sendPayload(progress, shelly, client, name_service, name_payload);
    for (device_config.configs) |c| for (c.payloads) |payload| {
        try sendPayload(progress, shelly, client, c.service, payload);
    };
}

fn reboot(parent_progress: std.Progress.Node, shelly: Device, client: *http.Client) !void {
    try switch (shelly.gen) {
        1 => {},
        2, 3 => sendPayload(parent_progress, shelly, client, "Shelly.Reboot", ""),
        else => |g| std.debug.panic("Unconfigured generation {}", .{g}),
    };
}

fn sendPayload(parent_progress: std.Progress.Node, shelly: Device, client: *http.Client, service: []const u8, payload: []const u8) !void {
    const p = parent_progress.start(payload, 0);
    defer p.end();

    var uri = std.Uri{
        .scheme = "http",
        .host = .{ .raw = shelly.ip },
        .query = .{ .raw = payload },
    };

    var url_buf: [256]u8 = undefined;
    switch (shelly.gen) {
        1 => {
            uri.path = .{ .raw = try fmt.bufPrint(&url_buf, "{s}", .{service}) };
        },
        2, 3 => {
            uri.path = .{ .raw = try fmt.bufPrint(&url_buf, "/rpc/{s}", .{service}) };
        },
        else => |g| std.debug.panic("Unconfigured generation {}", .{g}),
    }

    // std.log.debug("Sending {}", .{uri});
    const result = try client.fetch(.{
        .location = .{ .uri = uri },
    });
    std.log.info("{} - {}", .{ uri, result.status });

    if (mem.startsWith(u8, payload, "eco_mode_enabled")) {
        const sleep_s = 5;
        const p_sleep = p.start("Waiting for reboot", 5);
        defer p_sleep.end();

        for (0..sleep_s) |_| {
            std.Thread.sleep(std.time.ns_per_s);
            p_sleep.completeOne();
        }
    }
}
