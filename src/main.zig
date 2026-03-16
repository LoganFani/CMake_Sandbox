const std = @import("std");

const zigai = @import("zigai");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: cmc <command> [args]\nCommands: init, pull <url>\n", .{});
        return;
    }

    // Grab Command
    const command = args[1];

    // Check for action
    if (std.mem.eql(u8, command, "init")) {
        try handleInit(allocator);
    } else if (std.mem.eql(u8, command, "pull")) {
        if (args.len < 3) return error.MissingRepoUrl;
        try handlePull();
    }
}

fn scanDirRecursive(allocator: std.mem.Allocator, dir: std.fs.Dir, list: *std.ArrayList([]const u8), path_prefix: []const u8) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Build the full path
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ path_prefix, entry.name });

        if (entry.kind == .directory) {
            // Open the sub-directory
            var sub_dir = try dir.openDir(entry.name, .{ .iterate = true });
            defer sub_dir.close();

            try scanDirRecursive(allocator, sub_dir, list, full_path);
        } else if (entry.kind == .file) {
            if (std.mem.endsWith(u8, entry.name, ".cpp") or std.mem.endsWith(u8, entry.name, ".h")) {
                try list.append(full_path);
            }
        }
    }
}

fn handleInit(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var file_list = std.ArrayList([]const u8).init(arena_allocator);

    var root_dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer root_dir.close();

    // Start the recursion from the current directory "."
    try scanDirRecursive(arena_allocator, root_dir, &file_list, "");

    const all_files = try std.mem.join(arena_allocator, ", ", file_list.items);
    std.debug.print("Prompting with files: {s}\n", .{all_files});

    const response = try sendToLLM(arena_allocator, all_files);

    const CMakeFile = try std.fs.cwd().createFile("CMakeLists.txt", .{ .read = true });
    defer CMakeFile.close();

    try CMakeFile.writeAll(response);
}

fn sendToLLM(allocator: std.mem.Allocator, file_list: []const u8) ![]const u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // 1. Construct the prompt
    const prompt = try std.fmt.allocPrint(allocator, "You are a CMake generator. Files: {s}. " ++
        "Rules: " ++
        "1. Output ONLY raw CMake code. " ++
        "2. Do NOT use markdown code blocks (no backticks). " ++
        "3. No explanations or comments. " ++
        "4. Use modern target-based CMake.", .{file_list});

    // 2. Setup the URI
    const uri = try std.Uri.parse("http://localhost:11434/api/generate");

    // 3. Prepare the JSON payload
    // We'll use a simple anonymous struct for the JSON
    const payload = .{
        .model = "codellama:7b", // Make sure you have this model pulled in Ollama!
        .prompt = prompt,
        .stream = false,
    };

    var string_payload = std.ArrayList(u8).init(allocator);
    try std.json.stringify(payload, .{}, string_payload.writer());

    // 4. Send the Request
    var server_header_buffer: [16384]u8 = undefined;
    var req = try client.open(.POST, uri, .{
        .server_header_buffer = &server_header_buffer,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = string_payload.items.len };
    try req.send();
    try req.writeAll(string_payload.items);
    try req.finish();

    // 5. Read the Response
    try req.wait();

    const body = try req.reader().readAllAlloc(allocator, 1024 * 1024); // 1MB limit
    const parsed = try std.json.parseFromSlice(
        struct { response: []const u8 },
        allocator,
        body,
        .{ .ignore_unknown_fields = true },
    );

    const raw_content = parsed.value.response;

    return stripMarkdown(raw_content);
}

fn stripMarkdown(content: []const u8) []const u8 {
    var result = std.mem.trim(u8, content, " \n\r\t");

    // Remove opening backticks
    if (std.mem.startsWith(u8, result, "```")) {
        // Find the end of the first line (e.g., "```cmake\n")
        if (std.mem.indexOf(u8, result, "\n")) |newline_idx| {
            result = result[newline_idx + 1 ..];
        }
    }

    // Remove closing backticks
    if (std.mem.endsWith(u8, result, "```")) {
        result = result[0 .. result.len - 3];
    }

    return std.mem.trim(u8, result, " \n\r\t");
}

pub fn handlePull() !void {
    return;
}
