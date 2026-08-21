const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const pathRelativeTo = @import("utils.zig").pathRelativeTo;

const log = std.log.scoped(.videoplayer);

// Videos are decoded by piping raw frames from an external `ffmpeg` process,
// so any format ffmpeg understands plays without linking codec libraries.
// Pipe reads happen on per-player reader threads that fill small rings; the
// main thread only pops rings and uploads textures, so a slow decode or a
// stalled file can never block a frame. A paused player simply stops
// consuming; full rings park the reader threads, and the pipe's backpressure
// suspends ffmpeg without any process signalling.

pub const audio_sample_rate: u32 = 48000;
pub const audio_channels: u32 = 2;
pub const audio_stream_buffer_frames: i32 = 4096;
const audio_bytes_per_frame: usize = audio_channels * 2; // s16le
const audio_chunk_bytes: usize = @as(usize, @intCast(audio_stream_buffer_frames)) * audio_bytes_per_frame;
const audio_ring_bytes: usize = 256 * 1024; // ~1.3s of 48kHz stereo s16
const pipe_read_buffer_bytes: usize = 64 * 1024;
const frame_ring_len: usize = 3;

var ffmpeg_exe: ?[]const u8 = null;
var ffprobe_exe: ?[]const u8 = null;

/// GUI apps launched from Finder don't inherit a shell PATH, so a plain
/// "ffmpeg" often fails inside the .app even though a terminal finds it.
fn resolveTool(io: std.Io, gpa: std.mem.Allocator, comptime name: []const u8) ?[]const u8 {
    const candidates = [_][]const u8{
        name,
        "/opt/homebrew/bin/" ++ name,
        "/usr/local/bin/" ++ name,
        "/usr/bin/" ++ name,
    };
    for (candidates) |candidate| {
        const result = std.process.run(gpa, io, .{
            .argv = &.{ candidate, "-version" },
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        }) catch continue;
        gpa.free(result.stdout);
        gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code == 0) return candidate,
            else => {},
        }
    }
    return null;
}

fn requireTools(io: std.Io, gpa: std.mem.Allocator) !void {
    if (ffmpeg_exe == null) ffmpeg_exe = resolveTool(io, gpa, "ffmpeg");
    if (ffprobe_exe == null) ffprobe_exe = resolveTool(io, gpa, "ffprobe");
    if (ffmpeg_exe == null or ffprobe_exe == null) {
        log.err("video playback requires ffmpeg + ffprobe (e.g. `brew install ffmpeg`)", .{});
        return error.FfmpegNotFound;
    }
}

/// Terminate the process without reaping or closing our pipe ends, so a
/// reader thread blocked on the pipe wakes with EOF instead of racing a
/// concurrent close of the descriptor it is reading. `Child.kill` reaps and
/// cleans up afterwards, once the reader threads have been joined.
fn terminateChildProcess(child: *std.process.Child) void {
    const id = child.id orelse return;
    if (builtin.os.tag == .windows) {
        std.os.windows.TerminateProcess(id, 1) catch {};
    } else {
        std.posix.kill(id, std.posix.SIG.KILL) catch {};
    }
}

pub const PlayState = enum {
    stopped,
    playing,
    paused,
    finished,
};

const ProbeResult = struct {
    width: i32,
    height: i32,
    fps: f64,
    has_audio: bool,
    /// 0 when the container doesn't report one; seeking is disabled then.
    duration: f64,
};

fn parseFrameRate(value: []const u8) ?f64 {
    var it = std.mem.tokenizeScalar(u8, value, '/');
    const num_str = it.next() orelse return null;
    const num = std.fmt.parseFloat(f64, num_str) catch return null;
    const den = if (it.next()) |den_str| std.fmt.parseFloat(f64, den_str) catch return null else 1.0;
    if (num <= 0 or den <= 0) return null;
    return num / den;
}

fn probe(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !ProbeResult {
    const video_result = try std.process.run(gpa, io, .{
        .argv = &.{
            ffprobe_exe.?,          "-v",  "error",
            "-select_streams",      "v:0", "-show_entries",
            "stream=width,height,avg_frame_rate,r_frame_rate,duration:format=duration", "-of", "default=noprint_wrappers=1",
            path,
        },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer gpa.free(video_result.stdout);
    defer gpa.free(video_result.stderr);
    switch (video_result.term) {
        .exited => |code| if (code != 0) return error.VideoProbeFailed,
        else => return error.VideoProbeFailed,
    }

    var width: ?i32 = null;
    var height: ?i32 = null;
    var avg_fps: ?f64 = null;
    var raw_fps: ?f64 = null;
    var duration: ?f64 = null;
    var lines = std.mem.tokenizeAny(u8, video_result.stdout, "\r\n");
    while (lines.next()) |line| {
        var kv = std.mem.tokenizeScalar(u8, line, '=');
        const key = kv.next() orelse continue;
        const value = kv.next() orelse continue;
        if (std.mem.eql(u8, key, "width")) {
            width = std.fmt.parseInt(i32, value, 10) catch null;
        } else if (std.mem.eql(u8, key, "height")) {
            height = std.fmt.parseInt(i32, value, 10) catch null;
        } else if (std.mem.eql(u8, key, "avg_frame_rate")) {
            avg_fps = parseFrameRate(value);
        } else if (std.mem.eql(u8, key, "r_frame_rate")) {
            raw_fps = parseFrameRate(value);
        } else if (std.mem.eql(u8, key, "duration")) {
            // The stream line comes first; the format-section fallback only
            // fills in when the stream reports N/A (e.g. webm).
            if (duration == null) duration = std.fmt.parseFloat(f64, value) catch null;
        }
    }
    const w = width orelse return error.VideoProbeFailed;
    const h = height orelse return error.VideoProbeFailed;
    if (w <= 0 or h <= 0) return error.VideoProbeFailed;

    const audio_result = try std.process.run(gpa, io, .{
        .argv = &.{
            ffprobe_exe.?,     "-v",  "error",
            "-select_streams", "a:0", "-show_entries",
            "stream=codec_type", "-of", "default=noprint_wrappers=1",
            path,
        },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer gpa.free(audio_result.stdout);
    defer gpa.free(audio_result.stderr);
    const has_audio = std.mem.indexOf(u8, audio_result.stdout, "codec_type=audio") != null;

    return .{
        .width = w,
        .height = h,
        .fps = avg_fps orelse raw_fps orelse 30.0,
        .has_audio = has_audio,
        .duration = @max(0, duration orelse 0),
    };
}

/// Everything that exists only while a video is playing or paused: the two
/// ffmpeg children, their reader threads, and the rings they fill. Heap
/// allocated so the File.Readers and thread pointers stay stable, and freed
/// on stop, so an idle player costs only its poster frame.
const Pipeline = struct {
    io: std.Io,
    frame_size: usize,

    video_child: std.process.Child,
    audio_child: ?std.process.Child = null,
    video_reader: std.Io.File.Reader = undefined,
    audio_reader: std.Io.File.Reader = undefined,
    video_reader_buf: []u8 = &.{},
    audio_reader_buf: []u8 = &.{},
    video_thread: ?std.Thread = null,
    audio_thread: ?std.Thread = null,
    audio_stream: ?rl.AudioStream = null,
    audio_chunk: []u8 = &.{},

    mutex: std.Io.Mutex = .init,
    /// Reader threads wait here for ring space; broadcast on consume and stop.
    space_cond: std.Io.Condition = .init,
    stop: bool = false,

    frames: [frame_ring_len][]u8 = @splat(&.{}),
    frame_head: usize = 0,
    frame_count: usize = 0,
    video_eof: bool = false,

    audio_ring: []u8 = &.{},
    audio_head: usize = 0,
    audio_count: usize = 0,
    audio_eof: bool = false,

    fn videoThreadMain(self: *Pipeline) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (!self.stop and self.frame_count == frame_ring_len) {
                self.space_cond.waitUncancelable(self.io, &self.mutex);
            }
            if (self.stop) {
                self.mutex.unlock(self.io);
                return;
            }
            const slot = (self.frame_head + self.frame_count) % frame_ring_len;
            self.mutex.unlock(self.io);

            // The blocking read happens outside the lock; only this thread
            // ever writes to free slots.
            self.video_reader.interface.readSliceAll(self.frames[slot]) catch {
                self.mutex.lockUncancelable(self.io);
                self.video_eof = true;
                self.mutex.unlock(self.io);
                return;
            };

            self.mutex.lockUncancelable(self.io);
            self.frame_count += 1;
            self.mutex.unlock(self.io);
        }
    }

    fn audioThreadMain(self: *Pipeline) void {
        var chunk: [16 * 1024]u8 = undefined;
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (!self.stop and self.audio_ring.len - self.audio_count < chunk.len) {
                self.space_cond.waitUncancelable(self.io, &self.mutex);
            }
            if (self.stop) {
                self.mutex.unlock(self.io);
                return;
            }
            self.mutex.unlock(self.io);

            const n = self.audio_reader.interface.readSliceShort(&chunk) catch 0;

            self.mutex.lockUncancelable(self.io);
            // Space can only have grown since the wait: this is the sole
            // depositor, and the main thread only consumes.
            var write_pos = (self.audio_head + self.audio_count) % self.audio_ring.len;
            for (chunk[0..n]) |byte| {
                self.audio_ring[write_pos] = byte;
                write_pos = (write_pos + 1) % self.audio_ring.len;
            }
            self.audio_count += n;
            if (n < chunk.len) self.audio_eof = true;
            const done = self.audio_eof;
            self.mutex.unlock(self.io);
            if (done) return;
        }
    }
};

pub const VideoPlayer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    width: i32,
    height: i32,
    fps: f64,
    has_audio: bool,
    /// 0 when unknown; the overlay hides its seek bar then.
    duration: f64,
    // Set from the initiating item's element each time playback starts;
    // players are shared per file, so this is not authoring state.
    loop: bool = false,

    texture: rl.Texture2D,
    /// First frame, kept so stop() can rewind the on-screen texture without
    /// restarting ffmpeg, and so exports capture a deterministic poster.
    poster: []u8,

    state: PlayState = .stopped,
    /// Seconds since the current pipeline was spawned; the presented
    /// position is seek_offset + clock.
    clock: f64 = 0,
    last_tick: f64 = 0,
    frames_shown: u64 = 0,
    seek_offset: f64 = 0,
    /// After a paused seek, present the first decoded frame once so the
    /// sought position becomes visible without running the clock.
    awaiting_paused_frame: bool = false,

    pipeline: ?*Pipeline = null,

    const Self = @This();

    pub fn create(gpa: std.mem.Allocator, io: std.Io, realpath: []const u8) !*Self {
        try requireTools(io, gpa);
        const meta = try probe(io, gpa, realpath);
        const frame_size: usize = @as(usize, @intCast(meta.width)) * @as(usize, @intCast(meta.height)) * 3;

        const poster_result = try std.process.run(gpa, io, .{
            .argv = &.{
                ffmpeg_exe.?, "-v",         "error",
                "-noautorotate", "-i",      realpath,
                "-frames:v",  "1",          "-f",
                "rawvideo",   "-pix_fmt",   "rgb24",
                "-",
            },
            .stdout_limit = .limited(frame_size),
            .stderr_limit = .limited(4096),
        });
        errdefer gpa.free(poster_result.stdout);
        gpa.free(poster_result.stderr);
        if (poster_result.stdout.len != frame_size) return error.VideoPosterFailed;

        const image = rl.Image{
            .data = poster_result.stdout.ptr,
            .width = meta.width,
            .height = meta.height,
            .mipmaps = 1,
            .format = .uncompressed_r8g8b8,
        };
        const texture = try rl.loadTextureFromImage(image);
        errdefer rl.unloadTexture(texture);

        const self = try gpa.create(Self);
        errdefer gpa.destroy(self);
        self.* = .{
            .allocator = gpa,
            .io = io,
            .path = try gpa.dupe(u8, realpath),
            .width = meta.width,
            .height = meta.height,
            .fps = meta.fps,
            .has_audio = meta.has_audio,
            .duration = meta.duration,
            .texture = texture,
            .poster = poster_result.stdout,
        };
        log.info("video {s}: {d}x{d} @ {d:.2} fps, audio: {}", .{
            realpath, meta.width, meta.height, meta.fps, meta.has_audio,
        });
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.killPipeline();
        rl.unloadTexture(self.texture);
        self.allocator.free(self.poster);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    pub fn play(self: *Self, now: f64) void {
        switch (self.state) {
            .playing => {},
            .paused => {
                self.last_tick = now;
                if (self.pipeline) |p| {
                    if (p.audio_stream) |stream| rl.resumeAudioStream(stream);
                }
                self.state = .playing;
            },
            .stopped, .finished => self.startPipeline(now),
        }
    }

    pub fn pause(self: *Self, now: f64) void {
        if (self.state != .playing) return;
        self.clock += now - self.last_tick;
        self.last_tick = now;
        if (self.pipeline) |p| {
            if (p.audio_stream) |stream| rl.pauseAudioStream(stream);
        }
        self.state = .paused;
    }

    pub fn togglePlayPause(self: *Self, now: f64) void {
        if (self.state == .playing) {
            self.pause(now);
        } else {
            self.play(now);
        }
    }

    /// Rewind to the poster frame and release the decoding pipeline.
    pub fn stop(self: *Self) void {
        if (self.state == .stopped) return;
        self.killPipeline();
        self.state = .stopped;
        self.clock = 0;
        self.frames_shown = 0;
        self.seek_offset = 0;
        self.awaiting_paused_frame = false;
        rl.updateTexture(self.texture, self.poster.ptr);
    }

    /// Presented position in seconds, for the overlay's seek bar.
    pub fn position(self: *const Self) f64 {
        const pos = self.seek_offset + self.clock;
        if (self.duration > 0) return @min(pos, self.duration);
        return pos;
    }

    /// Restart the pipeline at t while preserving play/pause state. A paused
    /// seek shows the sought frame as soon as it is decoded.
    pub fn seekTo(self: *Self, t: f64, now: f64) void {
        const target = if (self.duration > 0) std.math.clamp(t, 0, @max(0, self.duration - 0.1)) else @max(0, t);
        const was_playing = self.state == .playing;
        self.killPipeline();
        self.pipeline = self.buildPipeline(target) catch |err| {
            log.warn("could not seek {s}: {}", .{ self.path, err });
            self.state = .stopped;
            return;
        };
        self.seek_offset = target;
        self.clock = 0;
        self.frames_shown = 0;
        self.last_tick = now;
        if (was_playing) {
            self.state = .playing;
            self.awaiting_paused_frame = false;
        } else {
            self.state = .paused;
            self.awaiting_paused_frame = true;
            if (self.pipeline) |p| {
                if (p.audio_stream) |stream| rl.pauseAudioStream(stream);
            }
        }
    }

    pub fn tick(self: *Self, now: f64) void {
        if (self.state == .paused and self.awaiting_paused_frame) self.presentPausedFrame();
        if (self.state != .playing) return;
        self.clock += now - self.last_tick;
        self.last_tick = now;
        const p = self.pipeline orelse return;
        self.feedAudio(p);
        self.presentDueFrames(p);
    }

    fn startPipeline(self: *Self, now: f64) void {
        self.killPipeline();
        self.pipeline = self.buildPipeline(0) catch |err| {
            log.warn("could not start playback for {s}: {}", .{ self.path, err });
            return;
        };
        self.seek_offset = 0;
        self.clock = 0;
        self.frames_shown = 0;
        self.last_tick = now;
        self.state = .playing;
        self.awaiting_paused_frame = false;
    }

    fn buildPipeline(self: *Self, start_at: f64) !*Pipeline {
        const gpa = self.allocator;
        const frame_size: usize = @as(usize, @intCast(self.width)) * @as(usize, @intCast(self.height)) * 3;

        // `-ss` before `-i` seeks by keyframe, then decodes precisely up to
        // the target, so pipeline start stays fast even deep into a file.
        var seek_buf: [32]u8 = undefined;
        const seek_arg: ?[]const u8 = if (start_at > 0.001)
            std.fmt.bufPrint(&seek_buf, "{d:.3}", .{start_at}) catch null
        else
            null;

        var video_argv_buf: [16][]const u8 = undefined;
        var video_argv_len: usize = 0;
        for ([_][]const u8{ ffmpeg_exe.?, "-v", "error", "-noautorotate" }) |arg| {
            video_argv_buf[video_argv_len] = arg;
            video_argv_len += 1;
        }
        if (seek_arg) |arg| {
            video_argv_buf[video_argv_len] = "-ss";
            video_argv_buf[video_argv_len + 1] = arg;
            video_argv_len += 2;
        }
        for ([_][]const u8{ "-i", self.path, "-f", "rawvideo", "-pix_fmt", "rgb24", "-" }) |arg| {
            video_argv_buf[video_argv_len] = arg;
            video_argv_len += 1;
        }

        var video_child = try std.process.spawn(self.io, .{
            .argv = video_argv_buf[0..video_argv_len],
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        errdefer video_child.kill(self.io);

        const p = try gpa.create(Pipeline);
        errdefer gpa.destroy(p);
        p.* = .{
            .io = self.io,
            .frame_size = frame_size,
            .video_child = video_child,
        };
        errdefer {
            for (p.frames) |frame| gpa.free(frame);
            gpa.free(p.video_reader_buf);
            gpa.free(p.audio_reader_buf);
            gpa.free(p.audio_ring);
            gpa.free(p.audio_chunk);
        }
        errdefer if (p.audio_child) |*child| child.kill(self.io);
        errdefer if (p.audio_stream) |stream| rl.unloadAudioStream(stream);
        for (&p.frames) |*frame| frame.* = try gpa.alloc(u8, frame_size);
        p.video_reader_buf = try gpa.alloc(u8, pipe_read_buffer_bytes);
        p.video_reader = p.video_child.stdout.?.readerStreaming(self.io, p.video_reader_buf);

        if (self.has_audio) audio: {
            var audio_argv_buf: [18][]const u8 = undefined;
            var audio_argv_len: usize = 0;
            for ([_][]const u8{ ffmpeg_exe.?, "-v", "error" }) |arg| {
                audio_argv_buf[audio_argv_len] = arg;
                audio_argv_len += 1;
            }
            if (seek_arg) |arg| {
                audio_argv_buf[audio_argv_len] = "-ss";
                audio_argv_buf[audio_argv_len + 1] = arg;
                audio_argv_len += 2;
            }
            for ([_][]const u8{ "-i", self.path, "-vn", "-f", "s16le", "-acodec", "pcm_s16le", "-ar", "48000", "-ac", "2", "-" }) |arg| {
                audio_argv_buf[audio_argv_len] = arg;
                audio_argv_len += 1;
            }
            const audio_child = std.process.spawn(self.io, .{
                .argv = audio_argv_buf[0..audio_argv_len],
                .stdin = .ignore,
                .stdout = .pipe,
                .stderr = .ignore,
            }) catch |err| {
                log.warn("no audio for {s}: could not start ffmpeg: {}", .{ self.path, err });
                break :audio;
            };
            p.audio_child = audio_child;
            p.audio_reader_buf = try gpa.alloc(u8, pipe_read_buffer_bytes);
            p.audio_ring = try gpa.alloc(u8, audio_ring_bytes);
            p.audio_chunk = try gpa.alloc(u8, audio_chunk_bytes);
            p.audio_reader = p.audio_child.?.stdout.?.readerStreaming(self.io, p.audio_reader_buf);
            if (rl.loadAudioStream(audio_sample_rate, 16, audio_channels)) |stream| {
                p.audio_stream = stream;
                rl.playAudioStream(stream);
            } else |err| {
                log.warn("no audio for {s}: could not open audio stream: {}", .{ self.path, err });
            }
        }

        // Spawn threads last; from here on p is fully initialized and
        // teardown must go through killPipeline.
        p.video_thread = try std.Thread.spawn(.{}, Pipeline.videoThreadMain, .{p});
        if (p.audio_child != null) {
            p.audio_thread = std.Thread.spawn(.{}, Pipeline.audioThreadMain, .{p}) catch |err| blk: {
                log.warn("no audio for {s}: could not spawn reader thread: {}", .{ self.path, err });
                break :blk null;
            };
        }
        return p;
    }

    fn killPipeline(self: *Self) void {
        const p = self.pipeline orelse return;
        self.pipeline = null;

        // Kill the processes first: a reader blocked on the pipe wakes with
        // EOF, so joining below cannot hang even on a stalled source.
        terminateChildProcess(&p.video_child);
        if (p.audio_child) |*child| terminateChildProcess(child);
        p.mutex.lockUncancelable(p.io);
        p.stop = true;
        p.mutex.unlock(p.io);
        p.space_cond.broadcast(p.io);
        if (p.video_thread) |thread| thread.join();
        if (p.audio_thread) |thread| thread.join();

        // Reap and release the pipe ends now that no thread reads them.
        p.video_child.kill(self.io);
        if (p.audio_child) |*child| child.kill(self.io);
        if (p.audio_stream) |stream| {
            rl.stopAudioStream(stream);
            rl.unloadAudioStream(stream);
        }
        for (p.frames) |frame| self.allocator.free(frame);
        self.allocator.free(p.video_reader_buf);
        self.allocator.free(p.audio_reader_buf);
        self.allocator.free(p.audio_ring);
        self.allocator.free(p.audio_chunk);
        self.allocator.destroy(p);
    }

    fn feedAudio(self: *Self, p: *Pipeline) void {
        _ = self;
        const stream = p.audio_stream orelse return;
        while (rl.isAudioStreamProcessed(stream)) {
            p.mutex.lockUncancelable(p.io);
            var n = @min(p.audio_count, p.audio_chunk.len);
            n -= n % audio_bytes_per_frame;
            if (n == 0) {
                p.mutex.unlock(p.io);
                return;
            }
            const first = @min(n, p.audio_ring.len - p.audio_head);
            @memcpy(p.audio_chunk[0..first], p.audio_ring[p.audio_head..][0..first]);
            if (n > first) @memcpy(p.audio_chunk[first..n], p.audio_ring[0 .. n - first]);
            p.audio_head = (p.audio_head + n) % p.audio_ring.len;
            p.audio_count -= n;
            p.mutex.unlock(p.io);
            p.space_cond.broadcast(p.io);
            rl.updateAudioStream(stream, p.audio_chunk.ptr, @intCast(n / audio_bytes_per_frame));
        }
    }

    fn presentPausedFrame(self: *Self) void {
        const p = self.pipeline orelse {
            self.awaiting_paused_frame = false;
            return;
        };
        p.mutex.lockUncancelable(p.io);
        const has_frame = p.frame_count > 0;
        const head = p.frame_head;
        p.mutex.unlock(p.io);
        if (!has_frame) return; // decoder not there yet; retry next tick
        rl.updateTexture(self.texture, p.frames[head].ptr);
        self.frames_shown += 1;
        p.mutex.lockUncancelable(p.io);
        p.frame_head = (head + 1) % frame_ring_len;
        p.frame_count -= 1;
        p.mutex.unlock(p.io);
        p.space_cond.broadcast(p.io);
        self.awaiting_paused_frame = false;
    }

    fn presentDueFrames(self: *Self, p: *Pipeline) void {
        // The poster already showed frame 0, so by clock t the pipeline
        // should have delivered floor(t*fps)+1 frames. Catching up after a
        // hiccup pops several frames but uploads only the newest.
        const target: u64 = @intFromFloat(@max(0.0, self.clock * self.fps + 1.0));
        p.mutex.lockUncancelable(p.io);
        const available = p.frame_count;
        const head = p.frame_head;
        const eof = p.video_eof;
        p.mutex.unlock(p.io);

        const due: usize = @intCast(@min(target -| self.frames_shown, available));
        if (due > 0) {
            // Occupied slots are never written by the reader thread, so the
            // upload can safely happen outside the lock before consuming.
            const newest = (head + due - 1) % frame_ring_len;
            rl.updateTexture(self.texture, p.frames[newest].ptr);
            self.frames_shown += due;
            p.mutex.lockUncancelable(p.io);
            p.frame_head = (head + due) % frame_ring_len;
            p.frame_count -= due;
            p.mutex.unlock(p.io);
            p.space_cond.broadcast(p.io);
        } else if (available == 0 and eof) {
            self.finishPlayback();
        }
    }

    fn finishPlayback(self: *Self) void {
        if (self.loop) {
            self.startPipeline(self.last_tick);
        } else {
            self.killPipeline();
            self.state = .finished;
        }
    }
};

/// Caches one VideoPlayer per resolved video path, like TextureCache does for
/// images. Lives on the renderer's long-lived allocator so playback state and
/// decoded textures survive re-parses. Players hold decoder handles and one
/// poster frame, never video content, so cost is per-file and
/// duration-independent. A failed load is cached as null so Studio keystrokes
/// don't re-run ffprobe against a broken path.
pub const VideoCache = struct {
    allocator: std.mem.Allocator,
    /// Set by the app after construction. Renderer unit tests leave it null,
    /// which turns video items into no-ops instead of spawning processes.
    io: ?std.Io = null,
    path2player: std.StringHashMap(?*VideoPlayer),

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .allocator = alloc,
            .path2player = std.StringHashMap(?*VideoPlayer).init(alloc),
        };
    }

    pub fn getVideoPlayer(self: *Self, p: []const u8, refpath: ?[]const u8) !?*VideoPlayer {
        const io = self.io orelse return null;
        const realpath = try pathRelativeTo(p, refpath);
        if (self.path2player.get(realpath)) |cached| return cached;

        // pathRelativeTo returns a shared static buffer; own the key now.
        const owned_path = try self.allocator.dupe(u8, realpath);
        errdefer self.allocator.free(owned_path);
        const player: ?*VideoPlayer = VideoPlayer.create(self.allocator, io, owned_path) catch |err| blk: {
            log.warn("could not load video {s}: {}", .{ owned_path, err });
            break :blk null;
        };
        try self.path2player.put(owned_path, player);
        return player;
    }

    pub fn tickAll(self: *Self, now: f64) void {
        var it = self.path2player.valueIterator();
        while (it.next()) |entry| {
            if (entry.*) |player| player.tick(now);
        }
    }

    pub fn stopAll(self: *Self) void {
        var it = self.path2player.valueIterator();
        while (it.next()) |entry| {
            if (entry.*) |player| player.stop();
        }
    }

    pub fn deinit(self: *Self) void {
        var it = self.path2player.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |player| player.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.path2player.deinit();
    }
};
