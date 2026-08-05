const std = @import("std");
const c = @import("c");
const types = @import("evcam_types.zig");
const storage = @import("evcam_storage.zig");
const finalize_queue = @import("evcam_finalize.zig");
const writer_mod = @import("evcam_writer.zig");
const jpeg = @import("evcam_jpeg.zig");
const files = @import("evcam_files.zig");
const playback_cache = @import("evcam_playback_cache.zig");

// Use Zig 0.16's std.Io namespace for future file/stream I/O task coordination;
// std.io was removed. NDK camera callbacks, EGL/GLES render ownership, and
// AMediaCodec surface rendering still use native workers plus explicit locks.
comptime {
    _ = std.Io;
}

const TAG = types.TAG;
const MAX_PIPES = types.MAX_PIPES;
const EGL_RECORDABLE_ANDROID = types.EGL_RECORDABLE_ANDROID;
const GL_TEXTURE_EXTERNAL_OES = types.GL_TEXTURE_EXTERNAL_OES;
const JNI_TRUE = types.JNI_TRUE;
const JNI_FALSE = types.JNI_FALSE;
const JNI_ABORT = types.JNI_ABORT;
const CHECK_RENDER_GL_ERROR = types.CHECK_RENDER_GL_ERROR;
const TICK_SHOULD_RENDER = types.TICK_SHOULD_RENDER;
const TICK_DROPPED = types.TICK_DROPPED;
const TICK_SEGMENT_DUE = types.TICK_SEGMENT_DUE;
const TICK_DRAINED_SHIFT = types.TICK_DRAINED_SHIFT;
const TICK_DRAINED_MASK = types.TICK_DRAINED_MASK;
const TICK_NEXT_INDEX_SHIFT = types.TICK_NEXT_INDEX_SHIFT;
const WORKER_ERROR_THREAD_ATTACH = types.WORKER_ERROR_THREAD_ATTACH;
const WORKER_ERROR_TICK_RENDER_DRAIN = types.WORKER_ERROR_TICK_RENDER_DRAIN;
const MAX_NATIVE_CAMERAS = types.MAX_NATIVE_CAMERAS;
const MAX_PREVIEW_TARGETS = types.MAX_PREVIEW_TARGETS;
const COMPOSITE_PREVIEW_FPS_HISTORY = types.COMPOSITE_PREVIEW_FPS_HISTORY;
const COMPOSITE_PREVIEW_FPS_WINDOW_MS = types.COMPOSITE_PREVIEW_FPS_WINDOW_MS;
const O_RDWR_ANDROID = types.O_RDWR_ANDROID;
const O_CREAT_ANDROID = types.O_CREAT_ANDROID;
const O_TRUNC_ANDROID = types.O_TRUNC_ANDROID;
const THUMBNAIL_WIDTH = types.THUMBNAIL_WIDTH;
const THUMBNAIL_HEIGHT = types.THUMBNAIL_HEIGHT;
const EglPresentationTimeAndroidFn = types.EglPresentationTimeAndroidFn;
const NativeCameraPreview = types.NativeCameraPreview;
const Input = types.Input;
const Quad = types.Quad;
const PreviewCorrection = types.PreviewCorrection;
const OverlayBatch = types.OverlayBatch;
const TexturedOverlayBatch = types.TexturedOverlayBatch;
const RECORDING_FRAME_QUEUE_CAPACITY = types.RECORDING_FRAME_QUEUE_CAPACITY;
const MAX_RENDER_COMMANDS = types.MAX_RENDER_COMMANDS;
const RecordingFrameSlot = types.RecordingFrameSlot;
const RecordingState = types.RecordingState;
const ManagedSegmentConfig = types.ManagedSegmentConfig;
const ManagedSegmentFinalize = types.ManagedSegmentFinalize;
const RenderCommand = types.RenderCommand;
const RenderRuntimeConfig = types.RenderRuntimeConfig;
const Pipe = types.Pipe;
const initZ = types.initZ;

extern fn open(path: [*c]const u8, flags: c_int, mode: c_int) c_int;
extern fn close(fd: c_int) c_int;
extern fn rename(oldpath: [*c]const u8, newpath: [*c]const u8) c_int;
extern fn unlink(path: [*c]const u8) c_int;
extern fn usleep(usec: c_uint) c_int;
extern fn gettid() c_int;
extern fn setpriority(which: c_int, who: c_int, prio: c_int) c_int;
extern fn malloc(size: usize) ?*anyopaque;
extern fn free(ptr: ?*anyopaque) void;

var g_io_instance: std.Io.Threaded = .init_single_threaded;
var g_io_threaded_ready: bool = false;
var g_lock: std.Io.Mutex = .init;
var g_metrics_lock: std.Io.Mutex = .init;
var g_pipes: [MAX_PIPES]Pipe = [_]Pipe{Pipe{}} ** MAX_PIPES;
var g_used: [MAX_PIPES]bool = [_]bool{false} ** MAX_PIPES;
var g_next_handle: c.jlong = 1;
var g_metrics_cache_handles: [MAX_PIPES]c.jlong = [_]c.jlong{0} ** MAX_PIPES;
const METRICS_COMPOSITE_PREVIEW_FPS_MILLI: usize = 112;
const METRICS_SNAPSHOT_LEN: usize = METRICS_COMPOSITE_PREVIEW_FPS_MILLI + 1;
const FPS_MILLI_SCALE: i64 = 1000;
const PRIO_PROCESS: c_int = 0;
const ANDROID_PRIORITY_FOREGROUND: c_int = -2;
var g_metrics_cache_values: [MAX_PIPES][METRICS_SNAPSHOT_LEN]c.jlong = [_][METRICS_SNAPSHOT_LEN]c.jlong{[_]c.jlong{0} ** METRICS_SNAPSHOT_LEN} ** MAX_PIPES;
var g_last_error: [256:0]u8 = initError("OK");
var g_error_scratch: [128:0]u8 = [_:0]u8{0} ** 128;
var g_presentation_time_android: ?EglPresentationTimeAndroidFn = null;
var g_native_cameras: [MAX_NATIVE_CAMERAS]NativeCameraPreview = [_]NativeCameraPreview{NativeCameraPreview{}} ** MAX_NATIVE_CAMERAS;
var g_native_camera_used: [MAX_NATIVE_CAMERAS]bool = [_]bool{false} ** MAX_NATIVE_CAMERAS;
var g_next_native_camera_handle: c.jlong = 1;
var g_java_vm: [*c]c.JavaVM = null;
var g_segment_cache_callback_class: c.jclass = null;
var g_segment_cache_callback_method: c.jmethodID = null;

export fn JNI_OnLoad(vm: [*c]c.JavaVM, _: ?*anyopaque) callconv(.c) c.jint {
    g_java_vm = vm;
    if (!g_io_threaded_ready) {
        g_io_instance = std.Io.Threaded.init(std.heap.c_allocator, .{
            .async_limit = .limited(2),
            .concurrent_limit = .limited(2),
        });
        g_io_threaded_ready = true;
    }
    finalize_queue.configure(.{
        .nativeIo = nativeIo,
        .finalizeSegment = managedFinalizeSegment,
        .logSpawnFailed = logFinalizeWorkerSpawnFailed,
    });
    writer_mod.configure(.{
        .nativeIo = nativeIo,
        .nowMs = nowMs,
        .setErrorText = setErrorFromModule,
        .logInfoText = logInfoFromModule,
    });
    return 0x00010006;
}

export fn JNI_OnUnload(vm: [*c]c.JavaVM, _: ?*anyopaque) callconv(.c) void {
    finalize_queue.stopWorker();
    if (g_segment_cache_callback_class != null) {
        var env: [*c]c.JNIEnv = null;
        if (vm.*[0].GetEnv.?(vm, @ptrCast(&env), 0x00010006) == 0 and env != null) {
            env.*[0].DeleteGlobalRef.?(env, g_segment_cache_callback_class);
        }
        g_segment_cache_callback_class = null;
        g_segment_cache_callback_method = null;
    }
    if (g_io_threaded_ready) {
        g_io_instance.deinit();
        g_io_instance = .init_single_threaded;
        g_io_threaded_ready = false;
    }
    g_java_vm = null;
}

fn initError(comptime s: []const u8) [256:0]u8 {
    var out: [256:0]u8 = [_:0]u8{0} ** 256;
    @memcpy(out[0..s.len], s);
    return out;
}

fn nativeIo() std.Io {
    return g_io_instance.io();
}

fn logFinalizeWorkerSpawnFailed(error_name: []const u8) void {
    loge("managed finalize worker spawn failed: {s}", .{error_name});
}

fn setErrorFromModule(msg: [:0]const u8) void {
    setErrorSlice(msg);
}

fn logInfoFromModule(msg: [:0]const u8) void {
    logi("{s}", .{msg});
}

fn lockGlobal() void {
    g_lock.lockUncancelable(nativeIo());
}

fn tryLockGlobal() bool {
    return g_lock.tryLock();
}

fn tryLockGlobalBounded(iterations: usize) bool {
    for (0..iterations) |_| {
        if (tryLockGlobal()) return true;
    }
    return false;
}

fn unlockGlobal() void {
    g_lock.unlock(nativeIo());
}

fn lockMetrics() void {
    g_metrics_lock.lockUncancelable(nativeIo());
}

fn unlockMetrics() void {
    g_metrics_lock.unlock(nativeIo());
}

fn lockPipe(p: *Pipe) void {
    const start_ms = nowMs();
    p.lock.lockUncancelable(nativeIo());
    const wait_ms = nowMs() - start_ms;
    p.pipe_lock_acquire_count += 1;
    if (wait_ms > 0) {
        p.pipe_lock_wait_total_ms += wait_ms;
        if (wait_ms > p.pipe_lock_wait_max_ms) p.pipe_lock_wait_max_ms = wait_ms;
    }
}

fn tryLockPipe(p: *Pipe) bool {
    if (p.lock.tryLock()) {
        p.pipe_try_lock_success_count += 1;
        return true;
    }
    _ = @atomicRmw(i64, &p.pipe_try_lock_fail_count, .Add, 1, .monotonic);
    return false;
}

fn tryLockPipeBounded(p: *Pipe, iterations: usize) bool {
    for (0..iterations) |_| {
        if (tryLockPipe(p)) return true;
    }
    return false;
}

fn unlockPipe(p: *Pipe) void {
    p.lock.unlock(nativeIo());
}

fn lockPipeForHandle(handle: c.jlong) ?*Pipe {
    lockGlobal();
    const p = getPipe(handle) orelse {
        unlockGlobal();
        return null;
    };
    lockPipe(p);
    unlockGlobal();
    return p;
}

fn lockCommandQueue(p: *Pipe) void {
    p.command_lock.lockUncancelable(nativeIo());
}

fn unlockCommandQueue(p: *Pipe) void {
    p.command_lock.unlock(nativeIo());
}

fn releaseRenderCommandResources(cmd: *RenderCommand) void {
    if (cmd.window) |window| {
        c.ANativeWindow_release(window);
        cmd.window = null;
    }
    if (cmd.watermark_pixels) |pixels| {
        free(pixels);
        cmd.watermark_pixels = null;
        cmd.watermark_bytes = 0;
    }
    cmd.* = RenderCommand{};
}

fn renderCommandCanReplaceQueued(cmd: *const RenderCommand) bool {
    return switch (cmd.kind) {
        .runtime_config, .set_preview_fps => true,
        else => false,
    };
}

fn replaceQueuedRenderCommandLocked(p: *Pipe, cmd: *RenderCommand) bool {
    if (!renderCommandCanReplaceQueued(cmd)) return false;
    var offset: usize = 0;
    while (offset < p.render_command_count) : (offset += 1) {
        const idx = (p.render_command_head + offset) % MAX_RENDER_COMMANDS;
        if (p.render_commands[idx].kind == cmd.kind) {
            releaseRenderCommandResources(&p.render_commands[idx]);
            p.render_commands[idx] = cmd.*;
            cmd.* = RenderCommand{};
            return true;
        }
    }
    return false;
}

fn enqueueRenderCommandLocked(p: *Pipe, cmd: *RenderCommand) bool {
    lockCommandQueue(p);
    defer unlockCommandQueue(p);
    if (replaceQueuedRenderCommandLocked(p, cmd)) return true;
    if (p.render_command_count >= MAX_RENDER_COMMANDS) {
        p.render_command_drop_count += 1;
        return false;
    }
    p.render_commands[p.render_command_tail] = cmd.*;
    p.render_command_tail = (p.render_command_tail + 1) % MAX_RENDER_COMMANDS;
    p.render_command_count += 1;
    cmd.* = RenderCommand{};
    return true;
}

fn popRenderCommandLocked(p: *Pipe, out: *RenderCommand) bool {
    lockCommandQueue(p);
    defer unlockCommandQueue(p);
    if (p.render_command_count == 0) return false;
    out.* = p.render_commands[p.render_command_head];
    p.render_commands[p.render_command_head] = RenderCommand{};
    p.render_command_head = (p.render_command_head + 1) % MAX_RENDER_COMMANDS;
    p.render_command_count -= 1;
    return true;
}

fn dropPendingRenderCommandsLocked(p: *Pipe) void {
    lockCommandQueue(p);
    defer unlockCommandQueue(p);
    while (p.render_command_count > 0) {
        var cmd = p.render_commands[p.render_command_head];
        p.render_commands[p.render_command_head] = RenderCommand{};
        p.render_command_head = (p.render_command_head + 1) % MAX_RENDER_COMMANDS;
        p.render_command_count -= 1;
        releaseRenderCommandResources(&cmd);
        p.render_command_drop_count += 1;
    }
    p.render_command_head = 0;
    p.render_command_tail = 0;
}

fn renderWorkerAcceptsCommandsLocked(p: *const Pipe) bool {
    return p.preview_worker_running and !p.preview_worker_stop and !p.releasing;
}

fn tryLockPipeForHandleBounded(handle: c.jlong, iterations: usize) ?*Pipe {
    if (!tryLockGlobalBounded(iterations)) return null;
    const p = getPipe(handle) orelse {
        unlockGlobal();
        return null;
    };
    if (!tryLockPipeBounded(p, iterations)) {
        unlockGlobal();
        return null;
    }
    unlockGlobal();
    return p;
}

fn attachWorkerEnv() ?[*c]c.JNIEnv {
    if (g_java_vm == null) return null;
    var env: [*c]c.JNIEnv = null;
    const rc = g_java_vm.*[0].AttachCurrentThread.?(g_java_vm, &env, null);
    if (rc != 0 or env == null) return null;
    return env;
}

fn boostRenderWorkerPriority() void {
    const tid = gettid();
    if (tid <= 0) return;
    const rc = setpriority(PRIO_PROCESS, tid, ANDROID_PRIORITY_FOREGROUND);
    if (rc != 0) {
        logd("render worker priority boost unavailable tid={} rc={}", .{ tid, rc });
    }
}

fn detachWorkerEnv() void {
    if (g_java_vm != null) _ = g_java_vm.*[0].DetachCurrentThread.?(g_java_vm);
}

fn currentOrAttachEnv(attached: *bool) ?[*c]c.JNIEnv {
    attached.* = false;
    if (g_java_vm == null) return null;
    var env: [*c]c.JNIEnv = null;
    const get_rc = g_java_vm.*[0].GetEnv.?(g_java_vm, @ptrCast(&env), 0x00010006);
    if (get_rc == 0 and env != null) return env;
    if (get_rc != -2) return null;
    const attach_rc = g_java_vm.*[0].AttachCurrentThread.?(g_java_vm, &env, null);
    if (attach_rc != 0 or env == null) return null;
    attached.* = true;
    return env;
}

fn clearJniException(env: [*c]c.JNIEnv, comptime context: []const u8) bool {
    if (env.*[0].ExceptionCheck.?(env) != JNI_TRUE) return false;
    env.*[0].ExceptionClear.?(env);
    loge("{s} threw Java exception", .{context});
    return true;
}

fn ensureSegmentCacheCallback(env: [*c]c.JNIEnv) bool {
    if (g_segment_cache_callback_class != null and g_segment_cache_callback_method != null) return true;
    const local_class = env.*[0].FindClass.?(env, "com/kooo/evcam/v2/recording/V2RecordingSegmentCacheUpdater") orelse {
        _ = clearJniException(env, "FindClass V2RecordingSegmentCacheUpdater");
        loge("segment cache callback class not found", .{});
        return false;
    };
    defer env.*[0].DeleteLocalRef.?(env, local_class);
    const method = env.*[0].GetStaticMethodID.?(env, local_class, "onNativeSegmentFinalized", "(Ljava/lang/String;)V") orelse {
        _ = clearJniException(env, "GetStaticMethodID onNativeSegmentFinalized");
        loge("segment cache callback method not found", .{});
        return false;
    };
    const global_ref = env.*[0].NewGlobalRef.?(env, local_class) orelse {
        _ = clearJniException(env, "NewGlobalRef V2RecordingSegmentCacheUpdater");
        loge("segment cache callback global ref failed", .{});
        return false;
    };
    g_segment_cache_callback_class = @ptrCast(global_ref);
    g_segment_cache_callback_method = method;
    return true;
}

fn notifySegmentCacheFinalized(final_path: [*c]const u8) void {
    if (final_path == null) return;
    var attached = false;
    const env = currentOrAttachEnv(&attached) orelse {
        loge("segment cache callback skipped: JNI env unavailable", .{});
        return;
    };
    defer {
        if (attached) detachWorkerEnv();
    }
    if (!ensureSegmentCacheCallback(env)) return;
    const path_string = env.*[0].NewStringUTF.?(env, final_path) orelse {
        _ = clearJniException(env, "NewStringUTF segment path");
        loge("segment cache callback path string failed", .{});
        return;
    };
    defer env.*[0].DeleteLocalRef.?(env, path_string);
    var args = [_]c.jvalue{.{ .l = path_string }};
    env.*[0].CallStaticVoidMethodA.?(env, g_segment_cache_callback_class, g_segment_cache_callback_method, &args);
    _ = clearJniException(env, "segment cache callback");
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_nativePrepareSegmentCacheCallback(env: [*c]c.JNIEnv, _: c.jobject) callconv(.c) c.jboolean {
    return if (ensureSegmentCacheCallback(env)) JNI_TRUE else JNI_FALSE;
}

fn sleepMs(ms: u64) void {
    const capped_ms = @min(ms, 60_000);
    const duration: std.Io.Clock.Duration = .{
        .raw = .fromMilliseconds(@intCast(capped_ms)),
        .clock = .awake,
    };
    duration.sleep(nativeIo()) catch {
        _ = usleep(@intCast(capped_ms * 1000));
    };
}

fn paceAfterTick(next_deadline_ms: *i64, interval_ms: i64) void {
    const safe_interval_ms = @max(interval_ms, 1);
    next_deadline_ms.* += safe_interval_ms;
    const now_after_tick = nowMs();
    if (next_deadline_ms.* > now_after_tick) {
        sleepMs(@intCast(next_deadline_ms.* - now_after_tick));
    } else {
        next_deadline_ms.* = now_after_tick;
    }
}

fn joinWorkerThread(thread: std.Thread, comptime name: []const u8, generation: c.jlong, timeout_ms: c.jlong) void {
    const join_start_ms = nowMs();
    thread.join();
    const join_ms = nowMs() - join_start_ms;
    if (timeout_ms > 0 and join_ms > timeout_ms) {
        loge("{s} worker join exceeded timeout generation={d} joinMs={d} timeoutMs={d}", .{ name, generation, join_ms, timeout_ms });
    } else {
        logd("{s} worker joined generation={d} joinMs={d}", .{ name, generation, join_ms });
    }
}

fn joinStalePreviewWorker(handle: c.jlong) void {
    var thread: ?std.Thread = null;
    var generation: c.jlong = 0;
    {
        const p = lockPipeForHandle(handle) orelse return;
        defer unlockPipe(p);
        if (p.preview_worker_running or p.preview_worker_thread == null) return;
        generation = p.preview_worker_generation;
        thread = p.preview_worker_thread;
        p.preview_worker_thread = null;
    }
    if (thread) |t| joinWorkerThread(t, "preview stale", generation, 2000);
}

fn loge(comptime fmt: []const u8, args: anytype) void {
    var buf: [512:0]u8 = [_:0]u8{0} ** 512;
    const msg = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch "log format error";
    _ = c.__android_log_print(c.ANDROID_LOG_ERROR, TAG, "%s", msg.ptr);
}

fn logd(comptime fmt: []const u8, args: anytype) void {
    var buf: [512:0]u8 = [_:0]u8{0} ** 512;
    const msg = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch "log format error";
    _ = c.__android_log_print(c.ANDROID_LOG_DEBUG, TAG, "%s", msg.ptr);
}

fn logi(comptime fmt: []const u8, args: anytype) void {
    var buf: [512:0]u8 = [_:0]u8{0} ** 512;
    const msg = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch "log format error";
    _ = c.__android_log_print(c.ANDROID_LOG_INFO, TAG, "%s", msg.ptr);
}

fn setError(comptime fmt: []const u8, args: anytype) void {
    @memset(g_last_error[0..], 0);
    const msg = std.fmt.bufPrintSentinel(&g_last_error, fmt, args, 0) catch "error format failed";
    loge("{s}", .{msg});
}

fn setErrorSlice(msg: [:0]const u8) void {
    @memset(g_last_error[0..], 0);
    const n = @min(msg.len, g_last_error.len - 1);
    @memcpy(g_last_error[0..n], msg[0..n]);
    loge("{s}", .{msg});
}

fn jpegWriteContext(context: ?*anyopaque, data: []const u8) bool {
    const fd_ptr: *c_int = @ptrCast(@alignCast(context orelse return false));
    return files.writeAllFd(fd_ptr.*, data);
}

const ThumbnailCapture = struct {
    path: [1024:0]u8 = [_:0]u8{0} ** 1024,
    rgb_raw: ?*anyopaque = null,
    width: usize = 0,
    height: usize = 0,
    bytes: usize = 0,
};

fn cleanupLimitReached(limit: usize) void {
    setError("native cleanup candidate limit reached limit={d}", .{limit});
}

fn cleanupDeletedOldSegment(name: [:0]const u8, freed: i64, available: i64, reserved: i64) void {
    logi("native cleanup deleted old segment {s} freed={d} available={d} reserve={d}", .{ name, freed, available, reserved });
}

fn cleanupStorageNative(dir_path: [*c]const u8, reserved_bytes: i64, available_bytes: i64, protected_path: ?[*c]const u8, out_deleted_count: *i64, out_deleted_bytes: *i64) i64 {
    return storage.cleanupStorageNative(
        dir_path,
        reserved_bytes,
        available_bytes,
        protected_path,
        .{
            .cleanupLimitReached = cleanupLimitReached,
            .deletedOldSegment = cleanupDeletedOldSegment,
        },
        out_deleted_count,
        out_deleted_bytes,
    );
}

fn releaseThumbnailCapture(capture: *ThumbnailCapture) void {
    if (capture.rgb_raw) |ptr| free(ptr);
    capture.* = .{};
}

fn captureFirstFrameThumbnailLocked(p: *Pipe, capture: *ThumbnailCapture) void {
    _ = capture;
    if (!p.recording.thumbnail_path_set or p.recording.thumbnail_written) return;
    p.recording.thumbnail_written = true;
    logi("thumbnail deferred to playback extractor path={s}", .{std.mem.sliceTo(&p.recording.thumbnail_path, 0)});
}

fn encodeThumbnailCapture(capture: *const ThumbnailCapture) bool {
    const rgb_raw = capture.rgb_raw orelse return false;
    if (capture.width == 0 or capture.height == 0 or capture.bytes == 0) return false;
    const rgb: [*]u8 = @ptrCast(rgb_raw);

    var temp_path: [1024:0]u8 = [_:0]u8{0} ** 1024;
    if (!files.appendPathSuffix(&temp_path, &capture.path, ".tmp")) {
        loge("thumbnail temp path too long path={s}", .{std.mem.sliceTo(&capture.path, 0)});
        return false;
    }
    _ = unlink(&temp_path);

    const fd = open(&temp_path, O_CREAT_ANDROID | O_TRUNC_ANDROID | O_RDWR_ANDROID, 0o644);
    if (fd < 0) {
        _ = unlink(&temp_path);
        loge("thumbnail open failed path={s}", .{std.mem.sliceTo(&temp_path, 0)});
        return false;
    }
    var fd_context = fd;
    var sink = jpeg.Sink{ .context = @ptrCast(&fd_context), .writeFn = jpegWriteContext };
    const encoded = jpeg.writeRgbJpeg(&sink, capture.width, capture.height, rgb[0..capture.bytes], 82);
    const closed = close(fd) == 0;
    if (!encoded or !closed or files.fileSize(&temp_path) <= 0) {
        _ = unlink(&temp_path);
        loge("thumbnail native jpg encode failed path={s}", .{std.mem.sliceTo(&capture.path, 0)});
        return false;
    }
    _ = unlink(&capture.path);
    if (rename(&temp_path, &capture.path) != 0) {
        _ = unlink(&temp_path);
        loge("thumbnail rename failed path={s}", .{std.mem.sliceTo(&capture.path, 0)});
        return false;
    }
    logi("thumbnail native jpg generated path={s} size={d}x{d} bytes={d}", .{ std.mem.sliceTo(&capture.path, 0), capture.width, capture.height, files.fileSize(&capture.path) });
    return true;
}

fn markThumbnailCaptureWritten(handle: c.jlong, capture: *const ThumbnailCapture) void {
    if (capture.rgb_raw == null) return;
    const p = lockPipeForHandle(handle) orelse return;
    defer unlockPipe(p);
    markThumbnailCaptureWrittenLocked(p, capture);
}

fn markThumbnailCaptureWrittenLocked(p: *Pipe, capture: *const ThumbnailCapture) void {
    if (capture.rgb_raw == null) return;
    if (std.mem.eql(u8, std.mem.sliceTo(&p.recording.thumbnail_path, 0), std.mem.sliceTo(&capture.path, 0))) {
        p.recording.thumbnail_written = true;
    }
}

fn eglError(what: []const u8) [:0]const u8 {
    @memset(g_error_scratch[0..], 0);
    return std.fmt.bufPrintSentinel(&g_error_scratch, "{s} egl=0x{x:0>4}", .{ what, c.eglGetError() }, 0) catch "egl error format failed";
}

fn glError(what: []const u8) ?[:0]const u8 {
    const err = c.glGetError();
    if (err == c.GL_NO_ERROR) return null;
    @memset(g_error_scratch[0..], 0);
    return std.fmt.bufPrintSentinel(&g_error_scratch, "{s} gl=0x{x:0>4}", .{ what, err }, 0) catch "gl error format failed";
}

const Timespec = extern struct { tv_sec: i64, tv_nsec: i64 };
extern fn clock_gettime(clock_id: c_int, ts: *Timespec) c_int;
const CLOCK_REALTIME: c_int = 0;
const CLOCK_MONOTONIC: c_int = 1;

fn nowMs() i64 {
    var ts: Timespec = undefined;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

fn wallClockMs() i64 {
    var ts: Timespec = undefined;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) return nowMs();
    return ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

fn newString(env: [*c]c.JNIEnv, s: [*:0]const u8) c.jstring {
    return env.*[0].NewStringUTF.?(env, s);
}

fn getArrayLen(env: [*c]c.JNIEnv, arr: anytype) c.jsize {
    return env.*[0].GetArrayLength.?(env, arr);
}

fn clearCurrent(p: *Pipe) void {
    if (p.display != c.EGL_NO_DISPLAY) _ = c.eglMakeCurrent(p.display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT);
    p.current_surface = c.EGL_NO_SURFACE;
}

const VERT = "attribute vec4 aPosition;attribute vec2 aTexCoord;varying vec2 vTexCoord;void main(){gl_Position=aPosition;vTexCoord=aTexCoord;}";
const FRAG = "#extension GL_OES_EGL_image_external : require\n" ++
    "precision mediump float;varying vec2 vTexCoord;uniform samplerExternalOES uTexture;uniform int uFisheyeEnabled;uniform vec4 uDistortion;uniform vec4 uLens;uniform vec4 uOpenCvIntrinsics;" ++
    "void main(){ if(uFisheyeEnabled==0){gl_FragColor=texture2D(uTexture,vTexCoord);return;} vec2 delta=(vTexCoord-uLens.yz)*uLens.x; vec2 coord=delta*uOpenCvIntrinsics.xy; float r2=dot(coord,coord); float distortion=1.0+r2*(uDistortion.x+r2*(uDistortion.y+r2*(uDistortion.z+r2*uDistortion.w))); vec2 distorted=coord*distortion; vec2 corrected=distorted*uOpenCvIntrinsics.zw+uLens.yz; if(corrected.x<0.0||corrected.x>1.0||corrected.y<0.0||corrected.y>1.0){ gl_FragColor=vec4(0.0,0.0,0.0,1.0); }else{ gl_FragColor=texture2D(uTexture,corrected); }}";
const OVERLAY_VERT = "attribute vec2 aPosition;void main(){gl_Position=vec4(aPosition,0.0,1.0);}";
const OVERLAY_FRAG = "precision mediump float;uniform vec4 uColor;void main(){gl_FragColor=uColor;}";
const OVERLAY_TEXT_VERT = "attribute vec2 aPosition;attribute vec2 aTexCoord;varying vec2 vTexCoord;void main(){gl_Position=vec4(aPosition,0.0,1.0);vTexCoord=aTexCoord;}";
const OVERLAY_TEXT_FRAG = "precision mediump float;varying vec2 vTexCoord;uniform sampler2D uTexture;uniform vec4 uColor;void main(){float a=texture2D(uTexture,vTexCoord).a;gl_FragColor=vec4(uColor.rgb,uColor.a*a);}";
const TEXTURE_FRAG = "precision mediump float;varying vec2 vTexCoord;uniform sampler2D uTexture;void main(){gl_FragColor=texture2D(uTexture,vTexCoord);}";
const TEXTURE_QUAD_POS = [_]c.GLfloat{ -1.0, 1.0, 1.0, 1.0, -1.0, -1.0, 1.0, -1.0 };
const TEXTURE_QUAD_TEX = [_]c.GLfloat{ 0.0, 1.0, 1.0, 1.0, 0.0, 0.0, 1.0, 0.0 };

fn compileShader(kind: c.GLenum, source: [*c]const u8) c.GLuint {
    const shader = c.glCreateShader(kind);
    var src = source;
    c.glShaderSource(shader, 1, &src, null);
    c.glCompileShader(shader);
    var ok: c.GLint = 0;
    c.glGetShaderiv(shader, c.GL_COMPILE_STATUS, &ok);
    if (ok == 0) {
        var log: [512]u8 = [_]u8{0} ** 512;
        c.glGetShaderInfoLog(shader, log.len, null, &log);
        setError("shader compile failed: {s}", .{std.mem.sliceTo(&log, 0)});
    }
    return shader;
}

fn createProgram() c.GLuint {
    const vs = compileShader(c.GL_VERTEX_SHADER, VERT);
    const fs = compileShader(c.GL_FRAGMENT_SHADER, FRAG);
    const program = c.glCreateProgram();
    c.glAttachShader(program, vs);
    c.glAttachShader(program, fs);
    c.glLinkProgram(program);
    var ok: c.GLint = 0;
    c.glGetProgramiv(program, c.GL_LINK_STATUS, &ok);
    if (ok == 0) {
        var log: [512]u8 = [_]u8{0} ** 512;
        c.glGetProgramInfoLog(program, log.len, null, &log);
        setError("program link failed: {s}", .{std.mem.sliceTo(&log, 0)});
    }
    c.glDeleteShader(vs);
    c.glDeleteShader(fs);
    return program;
}

fn createOverlayProgram() c.GLuint {
    const vs = compileShader(c.GL_VERTEX_SHADER, OVERLAY_VERT);
    const fs = compileShader(c.GL_FRAGMENT_SHADER, OVERLAY_FRAG);
    const program = c.glCreateProgram();
    c.glAttachShader(program, vs);
    c.glAttachShader(program, fs);
    c.glLinkProgram(program);
    var ok: c.GLint = 0;
    c.glGetProgramiv(program, c.GL_LINK_STATUS, &ok);
    if (ok == 0) {
        var log: [512]u8 = [_]u8{0} ** 512;
        c.glGetProgramInfoLog(program, log.len, null, &log);
        setError("overlay program link failed: {s}", .{std.mem.sliceTo(&log, 0)});
    }
    c.glDeleteShader(vs);
    c.glDeleteShader(fs);
    return program;
}

fn createOverlayTextProgram() c.GLuint {
    const vs = compileShader(c.GL_VERTEX_SHADER, OVERLAY_TEXT_VERT);
    const fs = compileShader(c.GL_FRAGMENT_SHADER, OVERLAY_TEXT_FRAG);
    const program = c.glCreateProgram();
    c.glAttachShader(program, vs);
    c.glAttachShader(program, fs);
    c.glLinkProgram(program);
    var ok: c.GLint = 0;
    c.glGetProgramiv(program, c.GL_LINK_STATUS, &ok);
    if (ok == 0) {
        var log: [512]u8 = [_]u8{0} ** 512;
        c.glGetProgramInfoLog(program, log.len, null, &log);
        setError("overlay text program link failed: {s}", .{std.mem.sliceTo(&log, 0)});
    }
    c.glDeleteShader(vs);
    c.glDeleteShader(fs);
    return program;
}

fn createTextureProgram() c.GLuint {
    const vs = compileShader(c.GL_VERTEX_SHADER, VERT);
    const fs = compileShader(c.GL_FRAGMENT_SHADER, TEXTURE_FRAG);
    const program = c.glCreateProgram();
    c.glAttachShader(program, vs);
    c.glAttachShader(program, fs);
    c.glLinkProgram(program);
    var ok: c.GLint = 0;
    c.glGetProgramiv(program, c.GL_LINK_STATUS, &ok);
    if (ok == 0) {
        var log: [512]u8 = [_]u8{0} ** 512;
        c.glGetProgramInfoLog(program, log.len, null, &log);
        setError("texture program link failed: {s}", .{std.mem.sliceTo(&log, 0)});
    }
    c.glDeleteShader(vs);
    c.glDeleteShader(fs);
    return program;
}

const FONT_CELL_W = 8;
const FONT_CELL_H = 9;
const FONT_GLYPHS = "0123456789-: ";
const FONT_PATTERNS = [_][7]u8{
    .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 },
    .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
    .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111 },
    .{ 0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110 },
    .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 },
    .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b00001, 0b00001, 0b11110 },
    .{ 0b01110, 0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 },
    .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 },
    .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 },
    .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b01110 },
    .{ 0b00000, 0b00000, 0b00000, 0b11110, 0b00000, 0b00000, 0b00000 },
    .{ 0b00000, 0b00100, 0b00100, 0b00000, 0b00100, 0b00100, 0b00000 },
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 },
};
comptime {
    std.debug.assert(FONT_PATTERNS.len == FONT_GLYPHS.len);
}
const FONT_COLS = FONT_GLYPHS.len;
const FONT_ATLAS_W = FONT_COLS * FONT_CELL_W;
const FONT_ATLAS_H = FONT_CELL_H;

fn glyphIndex(ch: u8) usize {
    for (FONT_GLYPHS, 0..) |glyph, index| if (glyph == ch) return index;
    return FONT_GLYPHS.len - 1;
}

fn initOverlayFontTexture(p: *Pipe) bool {
    if (p.overlay_font_texture != 0) return true;
    var pixels: [FONT_ATLAS_W * FONT_ATLAS_H]u8 = [_]u8{0} ** (FONT_ATLAS_W * FONT_ATLAS_H);
    for (FONT_PATTERNS, 0..) |pattern, glyph| {
        const base_x = glyph * FONT_CELL_W;
        for (pattern, 0..) |row_bits, row| {
            for (0..5) |col| {
                if ((row_bits & (@as(u8, 1) << @intCast(4 - col))) == 0) continue;
                const x = base_x + 1 + col;
                const y = 1 + row;
                pixels[y * FONT_ATLAS_W + x] = 255;
                if (x + 1 < base_x + FONT_CELL_W - 1) pixels[y * FONT_ATLAS_W + x + 1] = 180;
                if (y + 1 < FONT_CELL_H - 1) pixels[(y + 1) * FONT_ATLAS_W + x] = 180;
            }
        }
    }
    var texture: c.GLuint = 0;
    c.glGenTextures(1, &texture);
    if (texture == 0) {
        setError("overlay font texture allocation failed", .{});
        return false;
    }
    c.glBindTexture(c.GL_TEXTURE_2D, texture);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_ALPHA, FONT_ATLAS_W, FONT_ATLAS_H, 0, c.GL_ALPHA, c.GL_UNSIGNED_BYTE, &pixels);
    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 4);
    if (glError("initOverlayFontTexture")) |e| {
        setErrorSlice(e);
        c.glDeleteTextures(1, &texture);
        return false;
    }
    p.overlay_font_texture = texture;
    return true;
}

fn initTextureQuadBuffers(p: *Pipe) bool {
    if (p.texture_pos_vbo != 0 and p.texture_tex_vbo != 0) return true;
    if (p.texture_pos_vbo == 0) c.glGenBuffers(1, &p.texture_pos_vbo);
    if (p.texture_tex_vbo == 0) c.glGenBuffers(1, &p.texture_tex_vbo);
    if (p.texture_pos_vbo == 0 or p.texture_tex_vbo == 0) {
        if (p.texture_pos_vbo != 0) c.glDeleteBuffers(1, &p.texture_pos_vbo);
        if (p.texture_tex_vbo != 0) c.glDeleteBuffers(1, &p.texture_tex_vbo);
        p.texture_pos_vbo = 0;
        p.texture_tex_vbo = 0;
        setErrorSlice("texture quad VBO allocation failed");
        return false;
    }
    c.glBindBuffer(c.GL_ARRAY_BUFFER, p.texture_pos_vbo);
    c.glBufferData(c.GL_ARRAY_BUFFER, @intCast(@sizeOf(@TypeOf(TEXTURE_QUAD_POS))), &TEXTURE_QUAD_POS, c.GL_STATIC_DRAW);
    c.glBindBuffer(c.GL_ARRAY_BUFFER, p.texture_tex_vbo);
    c.glBufferData(c.GL_ARRAY_BUFFER, @intCast(@sizeOf(@TypeOf(TEXTURE_QUAD_TEX))), &TEXTURE_QUAD_TEX, c.GL_STATIC_DRAW);
    c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);
    if (glError("initTextureQuadBuffers")) |e| {
        setErrorSlice(e);
        c.glDeleteBuffers(1, &p.texture_pos_vbo);
        c.glDeleteBuffers(1, &p.texture_tex_vbo);
        p.texture_pos_vbo = 0;
        p.texture_tex_vbo = 0;
        return false;
    }
    return true;
}

fn initEgl(p: *Pipe) bool {
    if (p.display != c.EGL_NO_DISPLAY) return true;
    p.display = c.eglGetDisplay(c.EGL_DEFAULT_DISPLAY);
    if (p.display == c.EGL_NO_DISPLAY) {
        setError("eglGetDisplay failed", .{});
        return false;
    }
    if (c.eglInitialize(p.display, null, null) == c.EGL_FALSE) {
        setErrorSlice(eglError("eglInitialize failed"));
        return false;
    }
    if (g_presentation_time_android == null) {
        const proc = c.eglGetProcAddress("eglPresentationTimeANDROID");
        if (proc != null) g_presentation_time_android = @ptrCast(proc);
    }
    const attrs = [_]c.EGLint{ c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES2_BIT, c.EGL_SURFACE_TYPE, c.EGL_WINDOW_BIT | c.EGL_PBUFFER_BIT, c.EGL_RED_SIZE, 8, c.EGL_GREEN_SIZE, 8, c.EGL_BLUE_SIZE, 8, c.EGL_ALPHA_SIZE, 8, EGL_RECORDABLE_ANDROID, 1, c.EGL_NONE };
    var count: c.EGLint = 0;
    if (c.eglChooseConfig(p.display, &attrs, &p.config, 1, &count) == c.EGL_FALSE or count <= 0) {
        setErrorSlice(eglError("eglChooseConfig failed"));
        return false;
    }
    const ctx_attrs = [_]c.EGLint{ c.EGL_CONTEXT_CLIENT_VERSION, 2, c.EGL_NONE };
    p.context = c.eglCreateContext(p.display, p.config, c.EGL_NO_CONTEXT, &ctx_attrs);
    if (p.context == c.EGL_NO_CONTEXT) {
        setErrorSlice(eglError("eglCreateContext failed"));
        return false;
    }
    const pb_attrs = [_]c.EGLint{ c.EGL_WIDTH, 1, c.EGL_HEIGHT, 1, c.EGL_NONE };
    p.pbuffer = c.eglCreatePbufferSurface(p.display, p.config, &pb_attrs);
    if (p.pbuffer == c.EGL_NO_SURFACE) {
        setErrorSlice(eglError("eglCreatePbufferSurface failed"));
        return false;
    }
    if (c.eglMakeCurrent(p.display, p.pbuffer, p.pbuffer, p.context) == c.EGL_FALSE) {
        setErrorSlice(eglError("eglMakeCurrent pbuffer failed"));
        return false;
    }
    p.program = createProgram();
    p.overlay_program = createOverlayProgram();
    p.overlay_text_program = createOverlayTextProgram();
    p.texture_program = createTextureProgram();
    p.pos_loc = c.glGetAttribLocation(p.program, "aPosition");
    p.tex_loc = c.glGetAttribLocation(p.program, "aTexCoord");
    p.sampler_loc = c.glGetUniformLocation(p.program, "uTexture");
    p.overlay_pos_loc = c.glGetAttribLocation(p.overlay_program, "aPosition");
    p.overlay_color_loc = c.glGetUniformLocation(p.overlay_program, "uColor");
    p.overlay_text_pos_loc = c.glGetAttribLocation(p.overlay_text_program, "aPosition");
    p.overlay_text_tex_loc = c.glGetAttribLocation(p.overlay_text_program, "aTexCoord");
    p.overlay_text_sampler_loc = c.glGetUniformLocation(p.overlay_text_program, "uTexture");
    p.overlay_text_color_loc = c.glGetUniformLocation(p.overlay_text_program, "uColor");
    p.texture_pos_loc = c.glGetAttribLocation(p.texture_program, "aPosition");
    p.texture_tex_loc = c.glGetAttribLocation(p.texture_program, "aTexCoord");
    p.texture_sampler_loc = c.glGetUniformLocation(p.texture_program, "uTexture");
    p.fisheye_enabled_loc = c.glGetUniformLocation(p.program, "uFisheyeEnabled");
    p.distortion_loc = c.glGetUniformLocation(p.program, "uDistortion");
    p.lens_loc = c.glGetUniformLocation(p.program, "uLens");
    p.opencv_intrinsics_loc = c.glGetUniformLocation(p.program, "uOpenCvIntrinsics");
    if (p.program == 0 or p.pos_loc < 0 or p.tex_loc < 0 or p.sampler_loc < 0 or p.overlay_program == 0 or p.overlay_pos_loc < 0 or p.overlay_color_loc < 0 or p.overlay_text_program == 0 or p.overlay_text_pos_loc < 0 or p.overlay_text_tex_loc < 0 or p.overlay_text_sampler_loc < 0 or p.overlay_text_color_loc < 0 or p.texture_program == 0 or p.texture_pos_loc < 0 or p.texture_tex_loc < 0 or p.texture_sampler_loc < 0) {
        setError("GLES program locations unavailable", .{});
        return false;
    }
    c.glUseProgram(p.program);
    c.glUniform1i(p.sampler_loc, 0);
    c.glUseProgram(0);
    c.glUseProgram(p.texture_program);
    c.glUniform1i(p.texture_sampler_loc, 0);
    c.glUseProgram(0);
    _ = initTextureQuadBuffers(p);
    _ = initOverlayFontTexture(p);
    clearCurrent(p);
    logd("EGL initialized", .{});
    return true;
}

fn makePbufferCurrent(p: *Pipe) bool {
    if (!initEgl(p)) return false;
    if (p.pbuffer == c.EGL_NO_SURFACE) {
        setError("missing pbuffer surface", .{});
        return false;
    }
    if (p.current_surface == p.pbuffer) return true;
    if (c.eglMakeCurrent(p.display, p.pbuffer, p.pbuffer, p.context) == c.EGL_FALSE) {
        setErrorSlice(eglError("eglMakeCurrent pbuffer failed"));
        return false;
    }
    p.current_surface = p.pbuffer;
    return true;
}

fn makeCurrent(p: *Pipe, surface: c.EGLSurface) bool {
    if (!initEgl(p)) return false;
    if (surface == c.EGL_NO_SURFACE) {
        setError("missing EGL surface", .{});
        return false;
    }
    if (p.current_surface == surface) return true;
    if (c.eglMakeCurrent(p.display, surface, surface, p.context) == c.EGL_FALSE) {
        setErrorSlice(eglError("eglMakeCurrent failed"));
        return false;
    }
    p.current_surface = surface;
    return true;
}

fn setPreviewSwapInterval(p: *Pipe, initialized: *bool) void {
    if (initialized.*) return;
    // The worker already paces preview frames.  A zero EGL interval avoids
    // blocking the pipe lock on display vsync; SurfaceFlinger still handles
    // composition pacing on the consumer side.
    _ = c.eglSwapInterval(p.display, 0);
    initialized.* = true;
}

fn setEncoderSwapInterval(p: *Pipe) void {
    if (p.encoder_swap_interval_set) return;
    _ = c.eglSwapInterval(p.display, 0);
    p.encoder_swap_interval_set = true;
}

fn updateSurfaceTexture(st: ?*c.ASurfaceTexture) bool {
    const native_st = st orelse {
        setErrorSlice("missing native ASurfaceTexture");
        return false;
    };
    if (c.ASurfaceTexture_updateTexImage(native_st) != 0) {
        setErrorSlice("ASurfaceTexture_updateTexImage failed");
        return false;
    }
    return true;
}

fn inputNeedsLatch(inp: *const Input) bool {
    return inp.surface_texture_native != null and (inp.dirty or !inp.has_latched_frame);
}

fn pendingInputUpdateMask(p: *const Pipe) u8 {
    var mask: u8 = 0;
    for (&p.input, 0..) |*inp, i| {
        if (inputNeedsLatch(inp)) mask |= (@as(u8, 1) << @intCast(i));
    }
    return mask;
}

fn fillTexCoords(q: *Quad, rotation: f32) void {
    const r0 = [_]c.GLfloat{ 0, 0, 1, 0, 0, 1, 1, 1 };
    const r90 = [_]c.GLfloat{ 0, 1, 0, 0, 1, 1, 1, 0 };
    const r180 = [_]c.GLfloat{ 1, 1, 0, 1, 1, 0, 0, 0 };
    const r270 = [_]c.GLfloat{ 1, 0, 1, 1, 0, 0, 0, 1 };
    const src = if (rotation == 90.0) &r90 else if (rotation == 180.0) &r180 else if (rotation == 270.0) &r270 else &r0;
    q.tex = src.*;
}

fn buildQuadForCanvas(q: *Quad, x: f32, y: f32, w: f32, h: f32, rotation: f32, cw0: f32, ch0: f32) void {
    const cw = if (cw0 <= 0) 1.0 else cw0;
    const ch = if (ch0 <= 0) 1.0 else ch0;
    const x0 = x / cw * 2.0 - 1.0;
    const x1 = (x + w) / cw * 2.0 - 1.0;
    const y0 = 1.0 - y / ch * 2.0;
    const y1 = 1.0 - (y + h) / ch * 2.0;
    q.verts = [_]c.GLfloat{ x0, y0, x1, y0, x0, y1, x1, y1 };
    fillTexCoords(q, rotation);
}

fn updateEncoderLayout(p: *Pipe) void {
    const half_w = @as(f32, @floatFromInt(p.width)) * 0.5;
    const half_h = @as(f32, @floatFromInt(p.height)) * 0.5;
    buildQuadForCanvas(&p.encoder_quad[0], 0, 0, half_w, half_h, 0, @floatFromInt(p.width), @floatFromInt(p.height));
    buildQuadForCanvas(&p.encoder_quad[1], half_w, 0, half_w, half_h, 0, @floatFromInt(p.width), @floatFromInt(p.height));
    buildQuadForCanvas(&p.encoder_quad[2], 0, half_h, half_w, half_h, 0, @floatFromInt(p.width), @floatFromInt(p.height));
    buildQuadForCanvas(&p.encoder_quad[3], half_w, half_h, half_w, half_h, 0, @floatFromInt(p.width), @floatFromInt(p.height));
    p.config_version += 1;
}

fn applyPreviewCorrectionToQuad(q: *Quad, corr: *const PreviewCorrection) void {
    // Order must match primary overlay Matrix: scale → rotate → translate → mirror
    // 1. Scale vertices around center (0,0) in NDC
    if (corr.scale_x != 1.0 or corr.scale_y != 1.0) {
        var vi: usize = 0;
        while (vi < 4) : (vi += 1) {
            q.verts[vi * 2] *= corr.scale_x;
            q.verts[vi * 2 + 1] *= corr.scale_y;
        }
    }
    // 2. Fine rotation (arbitrary angle in degrees) around center
    if (corr.rotation != 0.0) {
        const angle_rad = corr.rotation * (std.math.pi / 180.0);
        const cos_a = @cos(angle_rad);
        const sin_a = @sin(angle_rad);
        var vi: usize = 0;
        while (vi < 4) : (vi += 1) {
            const x = q.verts[vi * 2];
            const y = q.verts[vi * 2 + 1];
            q.verts[vi * 2] = x * cos_a - y * sin_a;
            q.verts[vi * 2 + 1] = x * sin_a + y * cos_a;
        }
    }
    // 3. Translate (after rotation so direction is screen-aligned, matching primary overlay)
    if (corr.translate_x != 0.0 or corr.translate_y != 0.0) {
        const tx = corr.translate_x * 2.0;
        const ty = -(corr.translate_y * 2.0);
        var vi: usize = 0;
        while (vi < 4) : (vi += 1) {
            q.verts[vi * 2] += tx;
            q.verts[vi * 2 + 1] += ty;
        }
    }
    // 4. Mirror: flip texture coordinates
    if (corr.mirror_h) {
        var vi: usize = 0;
        while (vi < 4) : (vi += 1) {
            q.tex[vi * 2] = 1.0 - q.tex[vi * 2];
        }
    }
    if (corr.mirror_v) {
        var vi: usize = 0;
        while (vi < 4) : (vi += 1) {
            q.tex[vi * 2 + 1] = 1.0 - q.tex[vi * 2 + 1];
        }
    }
}

fn updatePreviewLayout(p: *Pipe, index: i32, width: i32, height: i32) void {
    updatePreviewLayoutTarget(p, index, 0, width, height);
}

fn updatePreviewLayoutTarget(p: *Pipe, index: i32, target: usize, width: i32, height: i32) void {
    if (index < 0 or index >= 4) return;
    if (target >= MAX_PREVIEW_TARGETS) return;
    const i: usize = @intCast(index);
    var rotation: f32 = 0;
    if (p.preview_apply_native_transform[i][target]) {
        if (index == 2) rotation = @floatFromInt(p.side_left_rotation);
        if (index == 3) rotation = @floatFromInt(p.side_right_rotation);
    }
    // Combine camera rotation with per-target display rotation (e.g. 180° for inverted secondary display)
    const display_rot_i = p.preview_rotation[i][target];
    const display_rot: f32 = @floatFromInt(display_rot_i);
    rotation = @mod(rotation + display_rot, 360.0);
    buildQuadForCanvas(&p.preview_quad[i][target], 0, 0, @floatFromInt(width), @floatFromInt(height), rotation, @floatFromInt(width), @floatFromInt(height));
    // Transform correction parameters so the visual effect matches the primary display.
    var corr = p.preview_correction[i][target];

    // Step 1: Mirror compensation (must precede display rotation compensation).
    // Primary overlay applies mirror via vertex postScale which reverses translate
    // direction (postScale(-1,1) negates x, postScale(1,-1) negates y).
    // Our native mirror is texcoord-based and does NOT affect vertex positions.
    // Compensate by negating the affected translate axis.
    if (corr.mirror_h) corr.translate_x = -corr.translate_x;
    if (corr.mirror_v) corr.translate_y = -corr.translate_y;
    // Single-axis vertex mirror also reverses visual rotation direction;
    // both mirrors cancel out (double negation).
    if (corr.mirror_h != corr.mirror_v) corr.rotation = -corr.rotation;

    // Step 2: Display rotation compensation.
    const norm_rot = @mod(@as(i32, @intCast(@mod(@as(i64, display_rot_i), 360) + 360)), 360);
    if (norm_rot == 180) {
        corr.translate_x = -corr.translate_x;
        corr.translate_y = -corr.translate_y;
        corr.rotation = -corr.rotation;
        const tmp_m = corr.mirror_h;
        corr.mirror_h = corr.mirror_v;
        corr.mirror_v = tmp_m;
    } else if (norm_rot == 90) {
        const old_tx = corr.translate_x;
        corr.translate_x = corr.translate_y;
        corr.translate_y = -old_tx;
        corr.rotation = -corr.rotation;
        const tmp_m = corr.mirror_h;
        corr.mirror_h = corr.mirror_v;
        corr.mirror_v = tmp_m;
    } else if (norm_rot == 270) {
        const old_tx = corr.translate_x;
        corr.translate_x = -corr.translate_y;
        corr.translate_y = old_tx;
        corr.rotation = -corr.rotation;
        const tmp_m = corr.mirror_h;
        corr.mirror_h = corr.mirror_v;
        corr.mirror_v = tmp_m;
    }
    applyPreviewCorrectionToQuad(&p.preview_quad[i][target], &corr);
    p.preview_quad_width[i][target] = width;
    p.preview_quad_height[i][target] = height;
}

const WindowSize = struct {
    width: i32,
    height: i32,
};

fn readWindowSize(window: ?*c.ANativeWindow, fallback_width: i32, fallback_height: i32) WindowSize {
    var width = fallback_width;
    var height = fallback_height;
    if (window) |w| {
        const native_width = c.ANativeWindow_getWidth(w);
        const native_height = c.ANativeWindow_getHeight(w);
        if (native_width > 0) width = native_width;
        if (native_height > 0) height = native_height;
    }
    if (width <= 0) width = 1;
    if (height <= 0) height = 1;
    return .{ .width = width, .height = height };
}

fn previewWindowSizeLocked(p: *Pipe, index: usize, refresh: bool) WindowSize {
    return previewWindowSizeTargetLocked(p, index, 0, refresh);
}

fn previewWindowSizeTargetLocked(p: *Pipe, index: usize, target: usize, refresh: bool) WindowSize {
    if (index >= 4 or target >= MAX_PREVIEW_TARGETS) return .{ .width = @max(p.width, 1), .height = @max(p.height, 1) };
    if (refresh or p.preview_window_width[index][target] <= 0 or p.preview_window_height[index][target] <= 0) {
        const size = readWindowSize(p.preview_window[index][target], p.width, p.height);
        p.preview_window_width[index][target] = size.width;
        p.preview_window_height[index][target] = size.height;
    }
    return .{ .width = p.preview_window_width[index][target], .height = p.preview_window_height[index][target] };
}

fn compositePreviewWindowSizeLocked(p: *Pipe, refresh: bool) WindowSize {
    if (refresh or p.composite_preview_width <= 0 or p.composite_preview_height <= 0) {
        const size = readWindowSize(p.composite_preview_window, p.width, p.height);
        p.composite_preview_width = size.width;
        p.composite_preview_height = size.height;
    }
    return .{ .width = p.composite_preview_width, .height = p.composite_preview_height };
}

fn beginDrawPass(p: *Pipe) void {
    c.glUseProgram(p.program);
    c.glEnableVertexAttribArray(@intCast(p.pos_loc));
    c.glEnableVertexAttribArray(@intCast(p.tex_loc));
    c.glActiveTexture(c.GL_TEXTURE0);
}

fn drawQuadWithFisheye(p: *Pipe, index: usize, q: *const Quad, apply_fisheye: bool, use_blind_spot_fisheye: bool) void {
    if (index >= 4) return;
    const input = &p.input[index];
    if (input.texture == 0 or input.surface_texture_native == null or !input.has_latched_frame) return;
    c.glVertexAttribPointer(@intCast(p.pos_loc), 2, c.GL_FLOAT, c.GL_FALSE, 0, &q.verts);
    c.glVertexAttribPointer(@intCast(p.tex_loc), 2, c.GL_FLOAT, c.GL_FALSE, 0, &q.tex);
    c.glBindTexture(GL_TEXTURE_EXTERNAL_OES, input.texture);
    const source_enabled = if (use_blind_spot_fisheye) p.blind_spot_fisheye_enabled[index] else p.fisheye_enabled[index];
    const fisheye_enabled = apply_fisheye and source_enabled;
    if (p.fisheye_enabled_loc >= 0) c.glUniform1i(p.fisheye_enabled_loc, if (fisheye_enabled) 1 else 0);
    if (fisheye_enabled) {
        const k1 = if (use_blind_spot_fisheye) p.blind_spot_fisheye_k1[index] else p.fisheye_k1[index];
        const k2 = if (use_blind_spot_fisheye) p.blind_spot_fisheye_k2[index] else p.fisheye_k2[index];
        const k3 = if (use_blind_spot_fisheye) p.blind_spot_fisheye_k3[index] else p.fisheye_k3[index];
        const k4 = if (use_blind_spot_fisheye) p.blind_spot_fisheye_k4[index] else p.fisheye_k4[index];
        const zoom = if (use_blind_spot_fisheye) p.blind_spot_fisheye_zoom[index] else p.fisheye_zoom[index];
        const center_x = if (use_blind_spot_fisheye) p.blind_spot_fisheye_center_x[index] else p.fisheye_center_x[index];
        const center_y = if (use_blind_spot_fisheye) p.blind_spot_fisheye_center_y[index] else p.fisheye_center_y[index];
        const fx = if (use_blind_spot_fisheye) p.blind_spot_fisheye_fx[index] else p.fisheye_fx[index];
        const fy = if (use_blind_spot_fisheye) p.blind_spot_fisheye_fy[index] else p.fisheye_fy[index];
        const source_width = if (use_blind_spot_fisheye) p.blind_spot_fisheye_source_width[index] else p.fisheye_source_width[index];
        const source_height = if (use_blind_spot_fisheye) p.blind_spot_fisheye_source_height[index] else p.fisheye_source_height[index];
        const safe_zoom = @max(if (zoom < 0.0) -zoom else zoom, 0.01);
        const safe_fx = @max(if (fx < 0.0) -fx else fx, 1.0);
        const safe_fy = @max(if (fy < 0.0) -fy else fy, 1.0);
        const safe_source_width = @max(if (source_width < 0.0) -source_width else source_width, 1.0);
        const safe_source_height = @max(if (source_height < 0.0) -source_height else source_height, 1.0);
        if (p.distortion_loc >= 0) c.glUniform4f(p.distortion_loc, k1, k2, k3, k4);
        if (p.lens_loc >= 0) c.glUniform4f(p.lens_loc, 1.0 / safe_zoom, center_x, center_y, 0.0);
        if (p.opencv_intrinsics_loc >= 0) c.glUniform4f(p.opencv_intrinsics_loc, safe_source_width / safe_fx, safe_source_height / safe_fy, safe_fx / safe_source_width, safe_fy / safe_source_height);
    }
    c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
}

fn drawQuad(p: *Pipe, index: usize, q: *const Quad) void {
    drawQuadWithFisheye(p, index, q, true, false);
}

fn civilFromDays(days_since_epoch: i64) struct { year: i64, month: i64, day: i64 } {
    const z = days_since_epoch + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    var year = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const day = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const month = mp + if (mp < 10) @as(i64, 3) else @as(i64, -9);
    if (month <= 2) year += 1;
    return .{ .year = year, .month = month, .day = day };
}

fn formatOverlayTime(buf: *[24]u8, wall_ms: i64) []const u8 {
    if (wall_ms <= 0) return "";
    const china_offset_seconds: i64 = 8 * 60 * 60;
    const local_seconds = @divTrunc(wall_ms, 1000) + china_offset_seconds;
    const day_seconds: i64 = 24 * 60 * 60;
    const days = @divTrunc(local_seconds, day_seconds);
    const seconds_of_day = @mod(local_seconds, day_seconds);
    const date = civilFromDays(days);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        date.year,
        date.month,
        date.day,
        @divTrunc(seconds_of_day, 60 * 60),
        @mod(@divTrunc(seconds_of_day, 60), 60),
        @mod(seconds_of_day, 60),
    }) catch "";
}

fn cachedOverlayTime(r: *RecordingState) []const u8 {
    if (r.overlay_wall_clock_ms <= 0) return "";
    const second = @divTrunc(r.overlay_wall_clock_ms, 1000);
    if (r.overlay_cached_second != second) {
        var buf: [24]u8 = undefined;
        const text = formatOverlayTime(&buf, r.overlay_wall_clock_ms);
        const len = @min(text.len, r.overlay_text.len);
        @memset(r.overlay_text[0..], 0);
        if (len > 0) @memcpy(r.overlay_text[0..len], text[0..len]);
        r.overlay_text_len = len;
        r.overlay_cached_second = second;
    }
    return r.overlay_text[0..r.overlay_text_len];
}

fn resetOverlayCache(r: *RecordingState, wall_clock_ms: i64) void {
    r.overlay_wall_clock_ms = wall_clock_ms;
    r.overlay_cached_second = -1;
    r.overlay_text_len = 0;
    r.overlay_geometry_second = -1;
    r.overlay_geometry_width = 0;
    r.overlay_geometry_height = 0;
    r.overlay_bg_batch.len = 0;
    r.overlay_shadow_text_batch.len = 0;
    r.overlay_text_batch.len = 0;
}

fn overlayCharAdvance(ch: u8, scale: f32) f32 {
    if (ch >= '0' and ch <= '9') return 20.0 * scale;
    if (ch == '-') return 14.0 * scale;
    if (ch == ':') return 10.0 * scale;
    if (ch == ' ') return 12.0 * scale;
    return 14.0 * scale;
}

fn appendOverlayTexturedRect(batch: *TexturedOverlayBatch, p: *Pipe, x: f32, y: f32, w: f32, h: f32, tex_u0: f32, tex_v0: f32, tex_u1: f32, tex_v1: f32) void {
    if (w <= 0 or h <= 0) return;
    if (batch.len + 12 > batch.verts.len or batch.len + 12 > batch.tex.len) return;
    const cw = if (p.width <= 0) 1.0 else @as(f32, @floatFromInt(p.width));
    const ch = if (p.height <= 0) 1.0 else @as(f32, @floatFromInt(p.height));
    const x0 = x / cw * 2.0 - 1.0;
    const x1 = (x + w) / cw * 2.0 - 1.0;
    const y0 = 1.0 - y / ch * 2.0;
    const y1 = 1.0 - (y + h) / ch * 2.0;
    const verts = [_]c.GLfloat{ x0, y0, x1, y0, x0, y1, x1, y0, x1, y1, x0, y1 };
    const tex = [_]c.GLfloat{ tex_u0, tex_v0, tex_u1, tex_v0, tex_u0, tex_v1, tex_u1, tex_v0, tex_u1, tex_v1, tex_u0, tex_v1 };
    @memcpy(batch.verts[batch.len..][0..verts.len], verts[0..]);
    @memcpy(batch.tex[batch.len..][0..tex.len], tex[0..]);
    batch.len += verts.len;
}

fn flushOverlayTextBatch(p: *Pipe, batch: *TexturedOverlayBatch, color: [4]f32) void {
    if (batch.len == 0 or p.overlay_font_texture == 0) return;
    c.glVertexAttribPointer(@intCast(p.overlay_text_pos_loc), 2, c.GL_FLOAT, c.GL_FALSE, 0, &batch.verts);
    c.glVertexAttribPointer(@intCast(p.overlay_text_tex_loc), 2, c.GL_FLOAT, c.GL_FALSE, 0, &batch.tex);
    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, p.overlay_font_texture);
    c.glUniform1i(p.overlay_text_sampler_loc, 0);
    c.glUniform4f(p.overlay_text_color_loc, color[0], color[1], color[2], color[3]);
    c.glDrawArrays(c.GL_TRIANGLES, 0, @intCast(batch.len / 2));
}

fn flushWatermarkTexture(p: *Pipe, x: f32, y: f32, w: f32, h: f32) void {
    if (p.watermark_texture == 0 or w <= 0 or h <= 0) return;
    var q = Quad{};
    buildQuadForCanvas(&q, x, y, w, h, 0, @floatFromInt(p.width), @floatFromInt(p.height));
    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
    c.glUseProgram(p.texture_program);
    c.glEnableVertexAttribArray(@intCast(p.texture_pos_loc));
    c.glEnableVertexAttribArray(@intCast(p.texture_tex_loc));
    c.glVertexAttribPointer(@intCast(p.texture_pos_loc), 2, c.GL_FLOAT, c.GL_FALSE, 0, &q.verts);
    c.glVertexAttribPointer(@intCast(p.texture_tex_loc), 2, c.GL_FLOAT, c.GL_FALSE, 0, &q.tex);
    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, p.watermark_texture);
    c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
    c.glDisableVertexAttribArray(@intCast(p.texture_tex_loc));
    c.glDisableVertexAttribArray(@intCast(p.texture_pos_loc));
    c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    c.glDisable(c.GL_BLEND);
    c.glUseProgram(p.program);
}

fn appendOverlayChar(batch: *TexturedOverlayBatch, p: *Pipe, ch: u8, x: f32, y: f32, scale: f32) void {
    if (ch == ' ') return;
    const glyph = glyphIndex(ch);
    const tex_u0 = (@as(f32, @floatFromInt(glyph * FONT_CELL_W)) + 0.5) / @as(f32, @floatFromInt(FONT_ATLAS_W));
    const tex_u1 = (@as(f32, @floatFromInt((glyph + 1) * FONT_CELL_W)) - 0.5) / @as(f32, @floatFromInt(FONT_ATLAS_W));
    const tex_v0 = 0.5 / @as(f32, @floatFromInt(FONT_ATLAS_H));
    const tex_v1 = (@as(f32, @floatFromInt(FONT_ATLAS_H)) - 0.5) / @as(f32, @floatFromInt(FONT_ATLAS_H));
    const h = 38.0 * scale;
    const w = overlayCharAdvance(ch, scale);
    appendOverlayTexturedRect(batch, p, x, y, w, h, tex_u0, tex_v0, tex_u1, tex_v1);
}

fn rebuildOverlayGeometry(p: *Pipe, text: []const u8, second: i64, scale: f32, x: f32, y: f32) void {
    const r = &p.recording;
    if (r.overlay_geometry_second == second and r.overlay_geometry_width == p.width and r.overlay_geometry_height == p.height) return;
    r.overlay_shadow_text_batch.len = 0;
    r.overlay_text_batch.len = 0;
    var cursor = x;
    for (text) |ch| {
        appendOverlayChar(&r.overlay_shadow_text_batch, p, ch, cursor + 2.0 * scale, y + 2.0 * scale, scale);
        appendOverlayChar(&r.overlay_text_batch, p, ch, cursor, y, scale);
        cursor += overlayCharAdvance(ch, scale);
    }
    r.overlay_geometry_second = second;
    r.overlay_geometry_width = p.width;
    r.overlay_geometry_height = p.height;
}

fn drawOverlay(p: *Pipe) void {
    if (!p.recording.recording or !p.overlay_enabled) return;
    if (p.watermark_texture == 0) return;
    flushWatermarkTexture(p, p.watermark_x, p.watermark_y, @floatFromInt(p.watermark_width), @floatFromInt(p.watermark_height));
}

fn releaseWatermarkTextureLocked(p: *Pipe) void {
    if (p.watermark_texture != 0) c.glDeleteTextures(1, &p.watermark_texture);
    p.watermark_texture = 0;
    p.watermark_width = 0;
    p.watermark_height = 0;
    p.watermark_x = 0;
    p.watermark_y = 0;
}

fn copyWatermarkRows(pixels: ?*anyopaque, width: usize, height: usize, stride: usize) ?*anyopaque {
    const row_bytes = width * 4;
    const bytes = row_bytes * height;
    const src_ptr = pixels orelse return null;
    const raw = malloc(bytes) orelse return null;
    const src: [*]const u8 = @ptrCast(src_ptr);
    const dst: [*]u8 = @ptrCast(raw);
    if (stride == row_bytes) {
        @memcpy(dst[0..bytes], src[0..bytes]);
        return raw;
    }
    for (0..height) |row| {
        @memcpy(dst[(row * row_bytes)..][0..row_bytes], src[(row * stride)..][0..row_bytes]);
    }
    return raw;
}

fn makeWatermarkCommandFromBitmap(env: [*c]c.JNIEnv, bitmap: c.jobject, x: c.jint, y: c.jint, out: *RenderCommand) bool {
    if (bitmap == null) {
        setErrorSlice("missing watermark bitmap");
        return false;
    }
    var info: c.AndroidBitmapInfo = undefined;
    if (c.AndroidBitmap_getInfo(env, bitmap, &info) != 0) {
        setErrorSlice("AndroidBitmap_getInfo failed");
        return false;
    }
    if (info.width == 0 or info.height == 0) {
        setError("invalid watermark bitmap size {d}x{d}", .{ info.width, info.height });
        return false;
    }
    if (info.format != c.ANDROID_BITMAP_FORMAT_RGBA_8888) {
        setError("unsupported watermark bitmap format {d}", .{info.format});
        return false;
    }

    var pixels: ?*anyopaque = null;
    if (c.AndroidBitmap_lockPixels(env, bitmap, &pixels) != 0 or pixels == null) {
        setErrorSlice("AndroidBitmap_lockPixels failed");
        return false;
    }
    defer _ = c.AndroidBitmap_unlockPixels(env, bitmap);

    const width: usize = @intCast(info.width);
    const height: usize = @intCast(info.height);
    const stride: usize = @intCast(info.stride);
    const row_bytes = width * 4;
    if (stride < row_bytes) {
        setError("invalid watermark bitmap stride {d} rowBytes={d}", .{ stride, row_bytes });
        return false;
    }
    const copied = copyWatermarkRows(pixels, width, height, stride);
    if (copied == null) {
        setError("watermark row copy allocation failed bytes={d}", .{row_bytes * height});
        return false;
    }
    out.* = RenderCommand{
        .kind = .update_watermark,
        .watermark_pixels = copied,
        .watermark_bytes = row_bytes * height,
        .watermark_width = @intCast(info.width),
        .watermark_height = @intCast(info.height),
        .watermark_x = x,
        .watermark_y = y,
    };
    return true;
}

fn uploadWatermarkPixelsLocked(p: *Pipe, pixels: ?*anyopaque, width: c.jint, height: c.jint, x: c.jint, y: c.jint) bool {
    if (pixels == null or width <= 0 or height <= 0) {
        setErrorSlice("missing watermark pixels");
        return false;
    }
    if (!makePbufferCurrent(p)) return false;
    if (p.watermark_texture == 0) {
        c.glGenTextures(1, &p.watermark_texture);
        if (p.watermark_texture == 0) {
            setErrorSlice("watermark glGenTextures returned 0");
            clearCurrent(p);
            return false;
        }
        c.glBindTexture(c.GL_TEXTURE_2D, p.watermark_texture);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    } else {
        c.glBindTexture(c.GL_TEXTURE_2D, p.watermark_texture);
    }
    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 4);
    if (p.watermark_width == width and p.watermark_height == height) {
        c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, width, height, c.GL_RGBA, c.GL_UNSIGNED_BYTE, pixels);
    } else {
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, width, height, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, pixels);
    }
    if (glError("updateWatermarkBitmap")) |e| {
        setErrorSlice(e);
        clearCurrent(p);
        return false;
    }
    p.watermark_width = width;
    p.watermark_height = height;
    p.watermark_x = @floatFromInt(x);
    p.watermark_y = @floatFromInt(y);
    clearCurrent(p);
    return true;
}

fn clearWatermarkBitmapLocked(p: *Pipe) bool {
    if (p.display != c.EGL_NO_DISPLAY and p.watermark_texture != 0) {
        if (!makePbufferCurrent(p)) return false;
        releaseWatermarkTextureLocked(p);
        clearCurrent(p);
    } else {
        releaseWatermarkTextureLocked(p);
    }
    return true;
}

fn latchInputTextureLocked(inp: *Input) bool {
    inp.dirty_count += 1;
    if (!updateSurfaceTexture(inp.surface_texture_native)) return false;
    inp.frame_generation += 1;
    inp.latched_generation = inp.frame_generation;
    inp.dirty = false;
    inp.has_latched_frame = true;
    inp.update_count += 1;
    return true;
}

fn renderPreviewLocked(env: [*c]c.JNIEnv, p: *Pipe, index: i32) bool {
    if (index < 0 or index >= 4) return false;
    const i: usize = @intCast(index);
    if (p.input[i].surface_texture_native == null) return false;
    const has_primary = p.preview_surface[i][0] != c.EGL_NO_SURFACE;
    const has_secondary = p.preview_surface[i][1] != c.EGL_NO_SURFACE;
    if (!has_primary and !has_secondary) {
        p.input[i].preview_drop_count += 1;
        return true;
    }
    const start = nowMs();
    // Latch input texture (once for all targets)
    const latch_surface = if (has_primary) p.preview_surface[i][0] else p.preview_surface[i][1];
    if (!makeCurrent(p, latch_surface)) return false;
    const latch_target: usize = if (has_primary) 0 else 1;
    setPreviewSwapInterval(p, &p.preview_swap_interval_set[i][latch_target]);
    _ = env;
    if (!latchInputTextureLocked(&p.input[i])) {
        clearCurrent(p);
        return false;
    }
    p.input[i].preview_generation = p.input[i].frame_generation;
    if (!p.input[i].has_latched_frame) return true;
    // Render to primary target [0]
    if (has_primary) {
        if (!renderPreviewTargetLocked(p, i, 0)) return false;
    }
    // Fan-out: render to secondary target [1] using already-latched OES texture
    if (has_secondary) {
        const secondary_ok = renderPreviewTargetLocked(p, i, 1);
        if (!secondary_ok and !has_primary) return false;
    }
    const end = nowMs();
    const elapsed = end - start;
    p.preview_render_count += 1;
    p.input[i].preview_render_count += 1;
    p.input[i].preview_swap_ms = elapsed;
    p.input[i].last_preview_render_ms = end;
    if (elapsed >= 20 or @mod(p.input[i].preview_render_count, 120) == 0) logi("preview perf index={d} totalMs={d} renders={d} updates={d} drops={d} targets={d}", .{ index, elapsed, p.input[i].preview_render_count, p.input[i].update_count, p.input[i].preview_drop_count, @as(i32, if (has_primary) 1 else 0) + @as(i32, if (has_secondary) 1 else 0) });
    return true;
}

fn renderPreviewTargetLocked(p: *Pipe, i: usize, target: usize) bool {
    if (i >= 4 or target >= MAX_PREVIEW_TARGETS) return false;
    if (p.preview_surface[i][target] == c.EGL_NO_SURFACE) return true;
    if (!makeCurrent(p, p.preview_surface[i][target])) return false;
    setPreviewSwapInterval(p, &p.preview_swap_interval_set[i][target]);
    const refresh = @mod(p.input[i].preview_render_count, 120) == 0;
    const size = previewWindowSizeTargetLocked(p, i, target, refresh);
    const vw = size.width;
    const vh = size.height;
    if (p.preview_quad_width[i][target] != vw or p.preview_quad_height[i][target] != vh) updatePreviewLayoutTarget(p, @intCast(i), target, vw, vh);
    c.glViewport(0, 0, vw, vh);
    const input = &p.input[i];
    const can_draw_input = input.texture != 0 and input.surface_texture_native != null and input.has_latched_frame;
    const correction = p.preview_correction[i][target];
    const correction_covers_surface = correction.scale_x == 1.0 and correction.scale_y == 1.0 and correction.rotation == 0.0 and correction.translate_x == 0.0 and correction.translate_y == 0.0;
    if (!can_draw_input or !correction_covers_surface) {
        c.glClearColor(0, 0, 0, 1);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
    }
    beginDrawPass(p);
    drawQuadWithFisheye(p, i, &p.preview_quad[i][target], p.preview_apply_fisheye[i][target], p.preview_use_blind_spot_fisheye[i][target]);
    if (CHECK_RENDER_GL_ERROR) if (glError("renderPreviewTarget")) |e| {
        setErrorSlice(e);
        clearCurrent(p);
        return false;
    };
    if (c.eglSwapBuffers(p.display, p.preview_surface[i][target]) == c.EGL_FALSE) {
        setErrorSlice(eglError("eglSwapBuffers preview target failed"));
        clearCurrent(p);
        p.input[i].preview_drop_count += 1;
        return false;
    }
    return true;
}

fn renderPreviewFromLatchedLocked(p: *Pipe, index: i32) bool {
    if (index < 0 or index >= 4) return false;
    const i: usize = @intCast(index);
    if (p.input[i].surface_texture_native == null or p.input[i].texture == 0 or !p.input[i].has_latched_frame) return false;
    const has_primary = p.preview_surface[i][0] != c.EGL_NO_SURFACE;
    const has_secondary = p.preview_surface[i][1] != c.EGL_NO_SURFACE;
    if (!has_primary and !has_secondary) {
        p.input[i].preview_drop_count += 1;
        return true;
    }
    const start = nowMs();
    p.input[i].preview_generation = p.input[i].frame_generation;
    // Render to primary target [0]
    if (has_primary) {
        if (!renderPreviewTargetLocked(p, i, 0)) return false;
    }
    // Fan-out: render to secondary target [1] using already-latched OES texture
    if (has_secondary) {
        const secondary_ok = renderPreviewTargetLocked(p, i, 1);
        if (!secondary_ok and !has_primary) return false;
    }
    const end = nowMs();
    const elapsed = end - start;
    p.preview_render_count += 1;
    p.input[i].preview_render_count += 1;
    p.input[i].preview_swap_ms = elapsed;
    p.input[i].last_preview_render_ms = end;
    if (elapsed >= 20 or @mod(p.input[i].preview_render_count, 120) == 0) logi("latched preview perf index={d} totalMs={d} renders={d} updates={d} drops={d}", .{ index, elapsed, p.input[i].preview_render_count, p.input[i].update_count, p.input[i].preview_drop_count });
    return true;
}

fn latchAllInputsLocked(p: *Pipe) bool {
    for (&p.input) |*inp| {
        if (inp.surface_texture_native == null) continue;
        if (!inputNeedsLatch(inp)) continue;
        if (!latchInputTextureLocked(inp)) return false;
        inp.encoder_generation = inp.frame_generation;
        inp.preview_generation = inp.frame_generation;
    }
    return true;
}

fn drawCompositeSceneLocked(p: *Pipe, width: i32, height: i32, include_overlay: bool) void {
    c.glViewport(0, 0, width, height);
    c.glClearColor(0, 0, 0, 1);
    c.glClear(c.GL_COLOR_BUFFER_BIT);
    beginDrawPass(p);
    drawQuad(p, 0, &p.encoder_quad[0]);
    drawQuad(p, 1, &p.encoder_quad[1]);
    drawQuad(p, 2, &p.encoder_quad[2]);
    drawQuad(p, 3, &p.encoder_quad[3]);
    if (include_overlay) drawOverlay(p);
}

fn drawTexture2DToCurrentSurfaceLocked(p: *Pipe, texture: c.GLuint, width: i32, height: i32) void {
    c.glViewport(0, 0, width, height);
    c.glUseProgram(p.texture_program);
    c.glEnableVertexAttribArray(@intCast(p.texture_pos_loc));
    c.glEnableVertexAttribArray(@intCast(p.texture_tex_loc));
    if (p.texture_pos_vbo != 0 and p.texture_tex_vbo != 0) {
        c.glBindBuffer(c.GL_ARRAY_BUFFER, p.texture_pos_vbo);
        c.glVertexAttribPointer(@intCast(p.texture_pos_loc), 2, c.GL_FLOAT, c.GL_FALSE, 0, null);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, p.texture_tex_vbo);
        c.glVertexAttribPointer(@intCast(p.texture_tex_loc), 2, c.GL_FLOAT, c.GL_FALSE, 0, null);
    } else {
        const verts = [_]c.GLfloat{ -1.0, 1.0, 1.0, 1.0, -1.0, -1.0, 1.0, -1.0 };
        const tex = [_]c.GLfloat{ 0.0, 1.0, 1.0, 1.0, 0.0, 0.0, 1.0, 0.0 };
        c.glVertexAttribPointer(@intCast(p.texture_pos_loc), 2, c.GL_FLOAT, c.GL_FALSE, 0, &verts);
        c.glVertexAttribPointer(@intCast(p.texture_tex_loc), 2, c.GL_FLOAT, c.GL_FALSE, 0, &tex);
    }
    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, texture);
    c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
    c.glDisableVertexAttribArray(@intCast(p.texture_tex_loc));
    c.glDisableVertexAttribArray(@intCast(p.texture_pos_loc));
    if (p.texture_pos_vbo != 0 and p.texture_tex_vbo != 0) c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);
}

fn resetCompositePreviewFpsLocked(p: *Pipe) void {
    @memset(p.composite_preview_fps_history[0..], 0);
    p.composite_preview_fps_head = 0;
    p.composite_preview_fps_count = 0;
    p.composite_preview_fps_milli = 0;
}

fn compositePreviewFpsMilliLocked(p: *const Pipe, newest_ms: i64) i64 {
    if (p.composite_preview_fps_count < 2) return 0;
    const oldest_ms = p.composite_preview_fps_history[p.composite_preview_fps_head];
    const elapsed_ms = newest_ms - oldest_ms;
    if (elapsed_ms <= 0) return 0;
    const intervals: i64 = @intCast(p.composite_preview_fps_count - 1);
    return @divTrunc(intervals * 1000 * FPS_MILLI_SCALE + @divTrunc(elapsed_ms, 2), elapsed_ms);
}

fn recordCompositePreviewFrameLocked(p: *Pipe, frame_ms: i64) void {
    const cutoff_ms = frame_ms - COMPOSITE_PREVIEW_FPS_WINDOW_MS;
    while (p.composite_preview_fps_count > 0) {
        const oldest_ms = p.composite_preview_fps_history[p.composite_preview_fps_head];
        if (oldest_ms > 0 and oldest_ms >= cutoff_ms) break;
        p.composite_preview_fps_history[p.composite_preview_fps_head] = 0;
        p.composite_preview_fps_head = (p.composite_preview_fps_head + 1) % COMPOSITE_PREVIEW_FPS_HISTORY;
        p.composite_preview_fps_count -= 1;
    }
    if (p.composite_preview_fps_count >= COMPOSITE_PREVIEW_FPS_HISTORY) {
        p.composite_preview_fps_history[p.composite_preview_fps_head] = 0;
        p.composite_preview_fps_head = (p.composite_preview_fps_head + 1) % COMPOSITE_PREVIEW_FPS_HISTORY;
        p.composite_preview_fps_count -= 1;
    }
    const tail = (p.composite_preview_fps_head + p.composite_preview_fps_count) % COMPOSITE_PREVIEW_FPS_HISTORY;
    p.composite_preview_fps_history[tail] = frame_ms;
    p.composite_preview_fps_count += 1;
    p.composite_preview_fps_milli = compositePreviewFpsMilliLocked(p, frame_ms);
}

fn resetRecordingFrameQueueLocked(p: *Pipe) void {
    for (&p.recording_frame_slots) |*slot| {
        slot.ready = false;
        slot.queued_for_encoder = false;
        slot.wall_clock_ms = 0;
        slot.sequence = 0;
    }
    @memset(p.recording_frame_queue_indices[0..], 0);
    p.recording_frame_queue_head = 0;
    p.recording_frame_queue_tail = 0;
    p.recording_frame_queue_count = 0;
    p.recording_frame_latest_index = -1;
    p.recording_frame_write_cursor = 0;
    p.recording_frame_queue_next_capture_ms = 0;
}

fn releaseRecordingFrameQueueLocked(p: *Pipe) void {
    for (&p.recording_frame_slots) |*slot| {
        if (slot.framebuffer != 0) {
            c.glDeleteFramebuffers(1, &slot.framebuffer);
            slot.framebuffer = 0;
        }
        if (slot.texture != 0) {
            c.glDeleteTextures(1, &slot.texture);
            slot.texture = 0;
        }
        slot.ready = false;
        slot.queued_for_encoder = false;
        slot.wall_clock_ms = 0;
        slot.sequence = 0;
    }
    p.recording_frame_queue_width = 0;
    p.recording_frame_queue_height = 0;
    resetRecordingFrameQueueLocked(p);
}

fn ensureRecordingFrameQueueLocked(p: *Pipe, width: i32, height: i32) bool {
    if (width <= 0 or height <= 0) return false;
    if (p.recording_frame_queue_width != width or p.recording_frame_queue_height != height) {
        releaseRecordingFrameQueueLocked(p);
        p.recording_frame_queue_width = width;
        p.recording_frame_queue_height = height;
        p.recording_frame_queue_fbo_recreate_count += 1;
    }
    var changed = false;
    for (&p.recording_frame_slots) |*slot| {
        var slot_changed = false;
        if (slot.texture == 0) {
            c.glGenTextures(1, &slot.texture);
            if (slot.texture == 0) {
                setErrorSlice("recording frame texture allocation failed");
                return false;
            }
            c.glBindTexture(c.GL_TEXTURE_2D, slot.texture);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
            c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, width, height, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
            slot_changed = true;
        }
        if (slot.framebuffer == 0) {
            c.glGenFramebuffers(1, &slot.framebuffer);
            if (slot.framebuffer == 0) {
                setErrorSlice("recording frame FBO allocation failed");
                return false;
            }
            slot_changed = true;
        }
        if (slot_changed) {
            changed = true;
            c.glBindFramebuffer(c.GL_FRAMEBUFFER, slot.framebuffer);
            c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, slot.texture, 0);
            if (c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) {
                c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
                setErrorSlice("recording frame FBO incomplete");
                return false;
            }
        }
    }
    if (changed) {
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        if (glError("ensureRecordingFrameQueue")) |e| {
            setErrorSlice(e);
            return false;
        }
    }
    return true;
}

fn recordingFrameCaptureDueLocked(p: *const Pipe, steady_ms: i64) bool {
    if (!p.recording.recording or !p.recording.managed_native) return false;
    if (p.encoder_surface == c.EGL_NO_SURFACE or p.encoder_window == null or p.encoder_generation == 0) return false;
    if (p.recording_frame_queue_next_capture_ms <= 0) return true;
    return steady_ms >= p.recording_frame_queue_next_capture_ms;
}

fn markRecordingFrameCaptureScheduledLocked(p: *Pipe, steady_ms: i64) void {
    const fps = @max(p.recording.fps, 1);
    const interval_ms: i64 = @max(@divTrunc(1000, fps), 1);
    if (p.recording_frame_queue_next_capture_ms <= 0 or steady_ms - p.recording_frame_queue_next_capture_ms > interval_ms * 3) {
        p.recording_frame_queue_next_capture_ms = steady_ms + interval_ms;
    } else {
        p.recording_frame_queue_next_capture_ms += interval_ms;
    }
}

fn clearFrameSlotAfterEncoderDropLocked(p: *Pipe, slot_index: usize) void {
    if (slot_index >= RECORDING_FRAME_QUEUE_CAPACITY) return;
    const latest = p.recording_frame_latest_index >= 0 and @as(usize, @intCast(p.recording_frame_latest_index)) == slot_index;
    var slot = &p.recording_frame_slots[slot_index];
    slot.queued_for_encoder = false;
    slot.wall_clock_ms = 0;
    if (!latest) slot.ready = false;
}

fn dropQueuedRecordingFrameLocked(p: *Pipe) ?usize {
    if (p.recording_frame_queue_count == 0) return null;
    const slot_index = p.recording_frame_queue_indices[p.recording_frame_queue_head];
    p.recording_frame_queue_indices[p.recording_frame_queue_head] = 0;
    p.recording_frame_queue_head = (p.recording_frame_queue_head + 1) % RECORDING_FRAME_QUEUE_CAPACITY;
    p.recording_frame_queue_count -= 1;
    clearFrameSlotAfterEncoderDropLocked(p, slot_index);
    p.recording_frame_queue_drop_count += 1;
    p.recording.dropped_frames += 1;
    return slot_index;
}

fn reserveCompositeFrameSlotLocked(p: *Pipe, enqueue_for_recording: bool) ?usize {
    var attempt: usize = 0;
    while (attempt < RECORDING_FRAME_QUEUE_CAPACITY) : (attempt += 1) {
        const idx = (p.recording_frame_write_cursor + attempt) % RECORDING_FRAME_QUEUE_CAPACITY;
        if (!p.recording_frame_slots[idx].queued_for_encoder) {
            p.recording_frame_write_cursor = (idx + 1) % RECORDING_FRAME_QUEUE_CAPACITY;
            return idx;
        }
    }

    const idx = if (enqueue_for_recording) dropQueuedRecordingFrameLocked(p) orelse return null else return null;
    p.recording_frame_write_cursor = (idx + 1) % RECORDING_FRAME_QUEUE_CAPACITY;
    return idx;
}

fn commitRecordingFrameSlotLocked(p: *Pipe, slot_index: usize, wall_clock_ms: i64) void {
    if (p.recording_frame_queue_count >= RECORDING_FRAME_QUEUE_CAPACITY) _ = dropQueuedRecordingFrameLocked(p);
    p.recording_frame_queue_sequence += 1;
    var slot = &p.recording_frame_slots[slot_index];
    slot.ready = true;
    slot.wall_clock_ms = wall_clock_ms;
    slot.sequence = p.recording_frame_queue_sequence;
    slot.queued_for_encoder = true;
    p.recording_frame_queue_indices[p.recording_frame_queue_tail] = slot_index;
    p.recording_frame_queue_tail = (p.recording_frame_queue_tail + 1) % RECORDING_FRAME_QUEUE_CAPACITY;
    p.recording_frame_queue_count += 1;
    p.recording_frame_queue_produced_count += 1;
    p.recording_frame_queue_max_depth = @max(p.recording_frame_queue_max_depth, @as(i64, @intCast(p.recording_frame_queue_count)));
}

fn produceCompositeFrameLocked(p: *Pipe, wall_clock_ms: i64, steady_ms: i64, enqueue_for_recording: bool) ?c.GLuint {
    if (!ensureRecordingFrameQueueLocked(p, p.width, p.height)) {
        return null;
    }
    if (enqueue_for_recording and p.recording_frame_queue_count >= RECORDING_FRAME_QUEUE_CAPACITY) _ = dropQueuedRecordingFrameLocked(p);
    const slot_index = reserveCompositeFrameSlotLocked(p, enqueue_for_recording) orelse return null;
    const slot = &p.recording_frame_slots[slot_index];
    slot.ready = false;
    slot.queued_for_encoder = false;
    slot.wall_clock_ms = 0;
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, slot.framebuffer);
    p.recording.overlay_wall_clock_ms = wall_clock_ms;
    drawCompositeSceneLocked(p, p.width, p.height, false);
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
    if (CHECK_RENDER_GL_ERROR) if (glError("produceCompositeFrame")) |e| {
        setErrorSlice(e);
        return null;
    };
    slot.ready = true;
    p.recording_frame_latest_index = @intCast(slot_index);
    if (enqueue_for_recording) {
        commitRecordingFrameSlotLocked(p, slot_index, wall_clock_ms);
        markRecordingFrameCaptureScheduledLocked(p, steady_ms);
    }
    return slot.texture;
}

fn renderQueuedRecordingFrameLocked(p: *Pipe) c.jlong {
    if (p.recording_frame_queue_count == 0) return 0;
    if (p.encoder_surface == c.EGL_NO_SURFACE or p.encoder_window == null or p.encoder_generation == 0) {
        p.encoder_drop_count += 1;
        p.no_surface_count += 1;
        return TICK_DROPPED;
    }
    const slot_index = p.recording_frame_queue_indices[p.recording_frame_queue_head];
    if (slot_index >= RECORDING_FRAME_QUEUE_CAPACITY) {
        _ = dropQueuedRecordingFrameLocked(p);
        return TICK_DROPPED;
    }
    const slot = &p.recording_frame_slots[slot_index];
    if (!slot.queued_for_encoder or !slot.ready or slot.texture == 0) {
        _ = dropQueuedRecordingFrameLocked(p);
        return TICK_DROPPED;
    }

    const start = nowMs();
    const frame_wall_clock_ms = slot.wall_clock_ms;
    if (!makeCurrent(p, p.encoder_surface)) return -1;
    setEncoderSwapInterval(p);
    drawTexture2DToCurrentSurfaceLocked(p, slot.texture, p.width, p.height);
    drawOverlay(p);
    if (CHECK_RENDER_GL_ERROR) if (glError("renderQueuedRecordingFrame")) |e| {
        setErrorSlice(e);
        clearCurrent(p);
        return -1;
    };
    if (g_presentation_time_android) |fnptr| {
        const fps = @max(p.recording.fps, 1);
        const min_step_ns = @max(@divTrunc(1_000_000_000, fps), 1000);
        var pts = @divTrunc(p.encoder_frame_index * 1_000_000_000, fps);
        if (pts <= p.recording.last_presentation_time_ns) pts = p.recording.last_presentation_time_ns + min_step_ns;
        p.recording.last_presentation_time_ns = pts;
        p.encoder_frame_index += 1;
        _ = fnptr(p.display, p.encoder_surface, pts);
    }
    const ok = c.eglSwapBuffers(p.display, p.encoder_surface) != c.EGL_FALSE;
    if (!ok) {
        clearCurrent(p);
        p.encoder_drop_count += 1;
        setErrorSlice(eglError("eglSwapBuffers queued encoder failed"));
        return -1;
    }

    var result: c.jlong = TICK_SHOULD_RENDER;
    p.recording_frame_queue_indices[p.recording_frame_queue_head] = 0;
    p.recording_frame_queue_head = (p.recording_frame_queue_head + 1) % RECORDING_FRAME_QUEUE_CAPACITY;
    p.recording_frame_queue_count -= 1;
    slot.queued_for_encoder = false;
    slot.wall_clock_ms = 0;
    if (!(p.recording_frame_latest_index >= 0 and @as(usize, @intCast(p.recording_frame_latest_index)) == slot_index)) {
        slot.ready = false;
    }
    p.recording_frame_queue_consumed_count += 1;
    p.recording.rendered_frames += 1;
    p.encoder_render_count += 1;
    p.render_count += 1;
    const end = nowMs();
    p.last_render_ms = end - start;
    p.recording.last_tick_steady_ms = end;
    if (!p.recording.segment_switch_pending and p.recording.next_segment_wall_clock_ms > 0 and frame_wall_clock_ms >= p.recording.next_segment_wall_clock_ms) {
        const next_index = p.recording.segment_index + 1;
        result |= TICK_SEGMENT_DUE;
        result |= (@as(c.jlong, next_index) << TICK_NEXT_INDEX_SHIFT);
    }
    if (p.last_render_ms >= 16 or @mod(p.encoder_render_count, 120) == 0) {
        logi("queued encoder perf copyMs={d} rendered={d} queue={d} produced={d} dropped={d}", .{ p.last_render_ms, p.encoder_render_count, p.recording_frame_queue_count, p.recording_frame_queue_produced_count, p.recording_frame_queue_drop_count });
    }
    return result;
}

fn renderCompositePreviewLocked(_: [*c]c.JNIEnv, p: *Pipe, update_inputs: bool) bool {
    if (p.composite_preview_surface == c.EGL_NO_SURFACE or p.composite_preview_window == null) return true;
    const start = nowMs();
    const size = compositePreviewWindowSizeLocked(p, @mod(p.preview_render_count, 120) == 0);
    const vw = size.width;
    const vh = size.height;
    const steady_ms = start;
    const capture_for_recording = recordingFrameCaptureDueLocked(p, steady_ms);
    const wall_clock_ms = if (capture_for_recording) wallClockMs() else 0;

    if (!capture_for_recording) {
        if (!makeCurrent(p, p.composite_preview_surface)) return false;
        setPreviewSwapInterval(p, &p.composite_preview_swap_interval_set);
        if (update_inputs and !latchAllInputsLocked(p)) {
            clearCurrent(p);
            return false;
        }
        drawCompositeSceneLocked(p, vw, vh, false);
        if (CHECK_RENDER_GL_ERROR) if (glError("renderCompositePreviewDirect")) |e| {
            setErrorSlice(e);
            clearCurrent(p);
            return false;
        };
        if (c.eglSwapBuffers(p.display, p.composite_preview_surface) == c.EGL_FALSE) {
            setErrorSlice(eglError("eglSwapBuffers composite preview direct failed"));
            clearCurrent(p);
            p.encoder_drop_count += 1;
            return false;
        }
        p.preview_render_count += 1;
        const end = nowMs();
        recordCompositePreviewFrameLocked(p, end);
        p.last_render_ms = end - start;
        if (p.last_render_ms >= 24 or @mod(p.preview_render_count, 120) == 0) {
            logi("composite preview perf totalMs={d} renders={d} drops={d}", .{ p.last_render_ms, p.preview_render_count, p.dropped_count });
        }
        return true;
    }

    if (!makePbufferCurrent(p)) return false;
    if (update_inputs and !latchAllInputsLocked(p)) {
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        clearCurrent(p);
        return false;
    }
    if (capture_for_recording) p.recording.requested_frames += 1;
    const composite_texture = produceCompositeFrameLocked(p, wall_clock_ms, steady_ms, capture_for_recording) orelse blk: {
        if (capture_for_recording) {
            p.recording.dropped_frames += 1;
            p.recording_frame_queue_fallback_count += 1;
            markRecordingFrameCaptureScheduledLocked(p, steady_ms);
        }
        break :blk 0;
    };

    if (composite_texture == 0) {
        clearCurrent(p);
    }

    if (!makeCurrent(p, p.composite_preview_surface)) return false;
    setPreviewSwapInterval(p, &p.composite_preview_swap_interval_set);
    if (composite_texture != 0) {
        drawTexture2DToCurrentSurfaceLocked(p, composite_texture, vw, vh);
    } else {
        drawCompositeSceneLocked(p, vw, vh, false);
    }
    if (CHECK_RENDER_GL_ERROR) if (glError("renderCompositePreview")) |e| {
        setErrorSlice(e);
        clearCurrent(p);
        return false;
    };
    if (c.eglSwapBuffers(p.display, p.composite_preview_surface) == c.EGL_FALSE) {
        setErrorSlice(eglError("eglSwapBuffers composite preview failed"));
        clearCurrent(p);
        p.encoder_drop_count += 1;
        return false;
    }
    p.preview_render_count += 1;
    const end = nowMs();
    recordCompositePreviewFrameLocked(p, end);
    p.last_render_ms = end - start;
    if (p.last_render_ms >= 24 or @mod(p.preview_render_count, 120) == 0) {
        logi("composite preview perf totalMs={d} renders={d} drops={d}", .{ p.last_render_ms, p.preview_render_count, p.dropped_count });
    }
    return true;
}

fn previewDelayMs(p: *const Pipe, input: *const Input) i64 {
    if (p.preview_min_interval_ms <= 0 or input.last_preview_render_ms <= 0) return 0;
    const remaining = p.preview_min_interval_ms - (nowMs() - input.last_preview_render_ms);
    return if (remaining > 0) remaining else 0;
}
fn floorToSegment(wall: i64, duration0: i64) i64 {
    const d = if (duration0 <= 0) 60000 else duration0;
    return wall - @mod(wall, d);
}
fn recordingTickIntervalMs(r: *const RecordingState) i64 {
    const fps = if (r.fps <= 0) 15 else r.fps;
    return @divTrunc(1000, fps);
}

fn requestEncoderRenderLocked(p: *Pipe) bool {
    p.encoder_signal_count += 1;
    if (p.encoder_surface == c.EGL_NO_SURFACE or p.encoder_window == null or p.encoder_generation == 0) {
        p.encoder_drop_count += 1;
        p.no_surface_count += 1;
        return false;
    }
    if (p.encoder_pending) {
        p.encoder_coalesced_count += 1;
        return false;
    }
    p.encoder_pending = true;
    p.encoder_scheduled_count += 1;
    return true;
}
fn hasDirtyInput(p: *const Pipe) bool {
    for (&p.input) |*inp| {
        if (inp.surface_texture_native != null and (inp.dirty or inp.encoder_generation != inp.frame_generation)) return true;
    }
    return false;
}
fn updateDirtyInputsLocked(env: [*c]c.JNIEnv, p: *Pipe) bool {
    for (&p.input, 0..) |*inp, idx| {
        const force_recording_latch = p.recording.recording;
        const preview_latches_input = p.preview_render_enabled and p.preview_worker_running and (p.preview_surface[idx][0] != c.EGL_NO_SURFACE or p.preview_surface[idx][1] != c.EGL_NO_SURFACE) and inp.has_latched_frame;
        if (inp.surface_texture_native != null and preview_latches_input) {
            inp.encoder_generation = inp.frame_generation;
            continue;
        }
        if (inp.surface_texture_native != null and (force_recording_latch or inp.encoder_generation != inp.frame_generation)) {
            _ = env;
            if (!latchInputTextureLocked(inp)) return false;
            inp.encoder_generation = inp.frame_generation;
        }
    }
    return true;
}

fn renderEncoderLocked(env: [*c]c.JNIEnv, p: *Pipe, require_dirty: bool, rendered: ?*bool, thumbnail_capture: ?*ThumbnailCapture) bool {
    if (rendered) |r| r.* = false;
    if (p.encoder_surface == c.EGL_NO_SURFACE or p.encoder_window == null or p.encoder_generation == 0) {
        p.encoder_drop_count += 1;
        p.no_surface_count += 1;
        return true;
    }
    if (require_dirty and !hasDirtyInput(p)) {
        p.encoder_drop_count += 1;
        return true;
    }
    const start = nowMs();
    if (!makeCurrent(p, p.encoder_surface)) return false;
    setEncoderSwapInterval(p);
    const update_start = nowMs();
    if (!updateDirtyInputsLocked(env, p)) {
        clearCurrent(p);
        return false;
    }
    const update_ms = nowMs() - update_start;
    p.render_count += 1;
    drawCompositeSceneLocked(p, p.width, p.height, true);
    if (thumbnail_capture) |capture| captureFirstFrameThumbnailLocked(p, capture);
    if (CHECK_RENDER_GL_ERROR) if (glError("renderEncoder")) |e| {
        setErrorSlice(e);
        clearCurrent(p);
        return false;
    };
    if (g_presentation_time_android) |fnptr| {
        var pts: i64 = undefined;
        if (p.recording.recording) {
            const fps = if (p.recording.fps <= 0) 15 else p.recording.fps;
            pts = @divTrunc(p.encoder_frame_index * 1_000_000_000, fps);
            if (pts <= p.recording.last_presentation_time_ns) pts = p.recording.last_presentation_time_ns + @max(@divTrunc(1_000_000_000, fps), 1000);
            p.recording.last_presentation_time_ns = pts;
            p.encoder_frame_index += 1;
        } else {
            const fps = if (p.encoder_fps <= 0) 15 else p.encoder_fps;
            pts = @divTrunc(p.encoder_frame_index * 1_000_000_000, fps);
            p.encoder_frame_index += 1;
        }
        _ = fnptr(p.display, p.encoder_surface, pts);
    }
    const swap_start = nowMs();
    const ok = c.eglSwapBuffers(p.display, p.encoder_surface) != c.EGL_FALSE;
    const end = nowMs();
    const swap_ms = end - swap_start;
    p.last_render_ms = end - start;
    if (ok) {
        p.encoder_render_count += 1;
        if (p.last_render_ms >= 24 or @mod(p.encoder_render_count, 120) == 0) logi("encoder perf totalMs={d} updateMs={d} swapMs={d} renders={d} drops={d}", .{ p.last_render_ms, update_ms, swap_ms, p.encoder_render_count, p.encoder_drop_count });
        _ = std.fmt.bufPrintSentinel(&p.last_render_error, "OK", .{}, 0) catch {};
        if (rendered) |r| r.* = true;
    } else {
        clearCurrent(p);
        p.encoder_drop_count += 1;
        const e = eglError("eglSwapBuffers encoder failed");
        @memset(p.last_render_error[0..], 0);
        @memcpy(p.last_render_error[0..@min(e.len, p.last_render_error.len - 1)], e[0..@min(e.len, p.last_render_error.len - 1)]);
        setErrorSlice(e);
    }
    return ok;
}

fn getPipe(handle: c.jlong) ?*Pipe {
    for (0..MAX_PIPES) |i| if (g_used[i] and g_pipes[i].handle == handle) return &g_pipes[i];
    setError("invalid native handle", .{});
    return null;
}

fn getNativeCamera(handle: c.jlong) ?*NativeCameraPreview {
    for (0..MAX_NATIVE_CAMERAS) |i| if (g_native_camera_used[i] and g_native_cameras[i].handle == handle) return &g_native_cameras[i];
    setError("invalid native camera handle", .{});
    return null;
}

fn storeMetricsCache(handle: c.jlong, values: *const [METRICS_SNAPSHOT_LEN]c.jlong) void {
    lockMetrics();
    defer unlockMetrics();
    var slot: ?usize = null;
    for (0..MAX_PIPES) |i| {
        if (g_metrics_cache_handles[i] == handle) {
            slot = i;
            break;
        }
        if (slot == null and g_metrics_cache_handles[i] == 0) slot = i;
    }
    const index = slot orelse 0;
    g_metrics_cache_handles[index] = handle;
    g_metrics_cache_values[index] = values.*;
}

fn loadMetricsCache(handle: c.jlong, values: *[METRICS_SNAPSHOT_LEN]c.jlong) bool {
    lockMetrics();
    defer unlockMetrics();
    for (0..MAX_PIPES) |i| {
        if (g_metrics_cache_handles[i] != handle) continue;
        values.* = g_metrics_cache_values[i];
        return true;
    }
    return false;
}

fn clearMetricsCache(handle: c.jlong) void {
    lockMetrics();
    defer unlockMetrics();
    for (0..MAX_PIPES) |i| {
        if (g_metrics_cache_handles[i] != handle) continue;
        g_metrics_cache_handles[i] = 0;
        g_metrics_cache_values[i] = [_]c.jlong{0} ** METRICS_SNAPSHOT_LEN;
    }
}

fn lockNativeCamera(cam: *NativeCameraPreview) void {
    cam.lock.lockUncancelable(nativeIo());
}

fn unlockNativeCamera(cam: *NativeCameraPreview) void {
    cam.lock.unlock(nativeIo());
}

fn lockNativeCameraForHandle(handle: c.jlong) ?*NativeCameraPreview {
    lockGlobal();
    var cam: ?*NativeCameraPreview = null;
    for (0..MAX_NATIVE_CAMERAS) |i| {
        if (!g_native_camera_used[i] or g_native_cameras[i].handle != handle) continue;
        cam = &g_native_cameras[i];
        break;
    }
    if (cam) |camera| lockNativeCamera(camera);
    unlockGlobal();
    if (cam == null) setError("invalid native camera handle", .{});
    return cam;
}

fn releaseNativeCameraSessionLocked(cam: *NativeCameraPreview) void {
    if (cam.session) |session| {
        _ = c.ACameraCaptureSession_stopRepeating(session);
        _ = c.ACameraCaptureSession_abortCaptures(session);
        sleepMs(120);
        c.ACameraCaptureSession_close(session);
        sleepMs(40);
    }
    cam.session = null;
    if (cam.request) |request| c.ACaptureRequest_free(request);
    cam.request = null;
    if (cam.target) |target| c.ACameraOutputTarget_free(target);
    cam.target = null;
    if (cam.output) |output| c.ACaptureSessionOutput_free(output);
    cam.output = null;
    if (cam.outputs) |outputs| c.ACaptureSessionOutputContainer_free(outputs);
    cam.outputs = null;
    cam.sequence_id = -1;
}

fn applyNativeCameraFpsRangeLocked(cam: *NativeCameraPreview) void {
    if (cam.request == null or cam.fps_range_lower <= 0 or cam.fps_range_upper < cam.fps_range_lower) return;
    var fps_range = [_]c_int{ cam.fps_range_lower, cam.fps_range_upper };
    const status = c.ACaptureRequest_setEntry_i32(cam.request.?, c.ACAMERA_CONTROL_AE_TARGET_FPS_RANGE, @intCast(fps_range.len), @ptrCast(&fps_range));
    if (status == c.ACAMERA_OK) {
        logi("NDK camera request fpsRange={d}-{d}", .{ cam.fps_range_lower, cam.fps_range_upper });
    } else {
        loge("NDK camera request fpsRange failed status={d} range={d}-{d}", .{ status, cam.fps_range_lower, cam.fps_range_upper });
    }
}

fn configureNativeCameraSessionLocked(cam: *NativeCameraPreview) bool {
    if (cam.device == null or cam.window == null) return false;
    releaseNativeCameraSessionLocked(cam);
    var status = c.ACaptureSessionOutputContainer_create(&cam.outputs);
    if (status != c.ACAMERA_OK or cam.outputs == null) {
        setError("ACaptureSessionOutputContainer_create failed status={d}", .{status});
        return false;
    }
    status = c.ACaptureSessionOutput_create(cam.window.?, &cam.output);
    if (status != c.ACAMERA_OK or cam.output == null) {
        setError("ACaptureSessionOutput_create preview failed status={d}", .{status});
        return false;
    }
    status = c.ACaptureSessionOutputContainer_add(cam.outputs.?, cam.output.?);
    if (status != c.ACAMERA_OK) {
        setError("ACaptureSessionOutputContainer_add preview failed status={d}", .{status});
        return false;
    }
    status = c.ACameraDevice_createCaptureRequest(cam.device.?, c.TEMPLATE_PREVIEW, &cam.request);
    if (status != c.ACAMERA_OK or cam.request == null) {
        setError("ACameraDevice_createCaptureRequest failed status={d}", .{status});
        return false;
    }
    applyNativeCameraFpsRangeLocked(cam);
    status = c.ACameraOutputTarget_create(cam.window.?, &cam.target);
    if (status != c.ACAMERA_OK or cam.target == null) {
        setError("ACameraOutputTarget_create preview failed status={d}", .{status});
        return false;
    }
    status = c.ACaptureRequest_addTarget(cam.request.?, cam.target.?);
    if (status != c.ACAMERA_OK) {
        setError("ACaptureRequest_addTarget preview failed status={d}", .{status});
        return false;
    }
    status = c.ACameraDevice_createCaptureSession(cam.device.?, cam.outputs.?, &g_native_camera_session_callbacks, &cam.session);
    if (status != c.ACAMERA_OK or cam.session == null) {
        setError("ACameraDevice_createCaptureSession failed status={d}", .{status});
        return false;
    }
    var request_array = [_]?*c.ACaptureRequest{cam.request.?};
    status = c.ACameraCaptureSession_setRepeatingRequest(cam.session.?, &g_native_camera_capture_callbacks, 1, @ptrCast(&request_array), &cam.sequence_id);
    if (status != c.ACAMERA_OK) {
        setError("ACameraCaptureSession_setRepeatingRequest failed status={d}", .{status});
        return false;
    }
    logi("NDK camera session configured singleStream handle={d}", .{cam.handle});
    return true;
}

fn releaseNativeCameraResources(cam: *NativeCameraPreview) void {
    releaseNativeCameraSessionLocked(cam);
    if (cam.device) |device| _ = c.ACameraDevice_close(device);
    cam.device = null;
    if (cam.window) |window| c.ANativeWindow_release(window);
    cam.window = null;
    if (cam.manager) |manager| c.ACameraManager_delete(manager);
    cam.manager = null;
}

fn onNativeCameraDisconnected(_: ?*anyopaque, _: ?*c.ACameraDevice) callconv(.c) void {
    logi("NDK camera disconnected", .{});
}

fn onNativeCameraError(_: ?*anyopaque, _: ?*c.ACameraDevice, err_code: c_int) callconv(.c) void {
    loge("NDK camera error={d}", .{err_code});
}

fn onNativeSessionClosed(_: ?*anyopaque, _: ?*c.ACameraCaptureSession) callconv(.c) void {
    logd("NDK camera session closed", .{});
}
fn onNativeSessionReady(_: ?*anyopaque, _: ?*c.ACameraCaptureSession) callconv(.c) void {
    logd("NDK camera session ready", .{});
}
fn onNativeSessionActive(_: ?*anyopaque, _: ?*c.ACameraCaptureSession) callconv(.c) void {
    logd("NDK camera session active", .{});
}

fn onNativeCaptureStarted(_: ?*anyopaque, _: ?*c.ACameraCaptureSession, _: ?*const c.ACaptureRequest, _: i64) callconv(.c) void {}
fn onNativeCaptureProgressed(_: ?*anyopaque, _: ?*c.ACameraCaptureSession, _: ?*c.ACaptureRequest, _: ?*const c.ACameraMetadata) callconv(.c) void {}
fn onNativeCaptureCompleted(_: ?*anyopaque, _: ?*c.ACameraCaptureSession, _: ?*c.ACaptureRequest, _: ?*const c.ACameraMetadata) callconv(.c) void {}
fn onNativeCaptureFailed(_: ?*anyopaque, _: ?*c.ACameraCaptureSession, _: ?*c.ACaptureRequest, _: ?*c.ACameraCaptureFailure) callconv(.c) void {}
fn onNativeCaptureSequenceCompleted(_: ?*anyopaque, _: ?*c.ACameraCaptureSession, _: c_int, _: i64) callconv(.c) void {}
fn onNativeCaptureSequenceAborted(_: ?*anyopaque, _: ?*c.ACameraCaptureSession, _: c_int) callconv(.c) void {}
fn onNativeCaptureBufferLost(_: ?*anyopaque, _: ?*c.ACameraCaptureSession, _: ?*c.ACaptureRequest, _: ?*c.ANativeWindow, _: i64) callconv(.c) void {}

var g_native_camera_device_callbacks = c.ACameraDevice_StateCallbacks{
    .context = null,
    .onDisconnected = onNativeCameraDisconnected,
    .onError = onNativeCameraError,
};

var g_native_camera_session_callbacks = c.ACameraCaptureSession_stateCallbacks{
    .context = null,
    .onClosed = onNativeSessionClosed,
    .onReady = onNativeSessionReady,
    .onActive = onNativeSessionActive,
};

var g_native_camera_capture_callbacks = c.ACameraCaptureSession_captureCallbacks{
    .context = null,
    .onCaptureStarted = onNativeCaptureStarted,
    .onCaptureProgressed = onNativeCaptureProgressed,
    .onCaptureCompleted = onNativeCaptureCompleted,
    .onCaptureFailed = onNativeCaptureFailed,
    .onCaptureSequenceCompleted = onNativeCaptureSequenceCompleted,
    .onCaptureSequenceAborted = onNativeCaptureSequenceAborted,
    .onCaptureBufferLost = onNativeCaptureBufferLost,
};

fn resetInput(env: ?[*c]c.JNIEnv, p: *Pipe, index: usize, delete_texture: bool) void {
    if (index >= 4) return;
    const inp = &p.input[index];
    if (delete_texture and inp.texture != 0 and p.display != c.EGL_NO_DISPLAY) {
        if (makePbufferCurrent(p)) {
            c.glDeleteTextures(1, &inp.texture);
            clearCurrent(p);
        }
        inp.texture = 0;
    }
    if (env) |e| {
        if (inp.surface_texture != null) e.*[0].DeleteGlobalRef.?(e, inp.surface_texture);
    }
    if (inp.surface_texture_native) |st| c.ASurfaceTexture_release(st);
    inp.surface_texture = null;
    inp.surface_texture_native = null;
    inp.dirty = false;
    inp.has_latched_frame = false;
    inp.preview_pending = false;
    inp.frame_generation = 0;
    inp.latched_generation = 0;
    inp.preview_generation = 0;
    inp.encoder_generation = 0;
}

fn applyPreviewFpsLocked(p: *Pipe, fps: c.jint) void {
    if (fps <= 0) {
        p.preview_max_fps = 0;
        p.preview_min_interval_ms = 0;
    } else {
        p.preview_max_fps = @min(@max(fps, 1), 120);
        p.preview_min_interval_ms = @divTrunc(1000, p.preview_max_fps);
    }
}

fn applyRuntimeConfigLocked(p: *Pipe, runtime: *const RenderRuntimeConfig) void {
    p.width = runtime.width;
    p.height = runtime.height;
    p.side_left_rotation = runtime.side_left_rotation;
    p.side_right_rotation = runtime.side_right_rotation;
    p.layout_mode = runtime.layout_mode;
    applyPreviewFpsLocked(p, runtime.preview_fps);
    p.encoder_fps = @min(@max(runtime.encoder_fps, 1), 120);
    if (runtime.fisheye_valid) {
        for (0..4) |i| {
            p.fisheye_enabled[i] = runtime.fisheye_enabled[i];
            p.fisheye_k1[i] = runtime.fisheye_k1[i];
            p.fisheye_k2[i] = runtime.fisheye_k2[i];
            p.fisheye_k3[i] = runtime.fisheye_k3[i];
            p.fisheye_k4[i] = runtime.fisheye_k4[i];
            p.fisheye_zoom[i] = if (runtime.fisheye_zoom[i] <= 0.01) 1.0 else runtime.fisheye_zoom[i];
            p.fisheye_center_x[i] = runtime.fisheye_center_x[i];
            p.fisheye_center_y[i] = runtime.fisheye_center_y[i];
            p.fisheye_fx[i] = if (runtime.fisheye_fx[i] <= 1.0) 1920.0 else runtime.fisheye_fx[i];
            p.fisheye_fy[i] = if (runtime.fisheye_fy[i] <= 1.0) 1536.0 else runtime.fisheye_fy[i];
            p.fisheye_source_width[i] = if (runtime.fisheye_source_width[i] <= 1.0) 1920.0 else runtime.fisheye_source_width[i];
            p.fisheye_source_height[i] = if (runtime.fisheye_source_height[i] <= 1.0) 1536.0 else runtime.fisheye_source_height[i];
            p.blind_spot_fisheye_enabled[i] = runtime.blind_spot_fisheye_enabled[i];
            p.blind_spot_fisheye_k1[i] = runtime.blind_spot_fisheye_k1[i];
            p.blind_spot_fisheye_k2[i] = runtime.blind_spot_fisheye_k2[i];
            p.blind_spot_fisheye_k3[i] = runtime.blind_spot_fisheye_k3[i];
            p.blind_spot_fisheye_k4[i] = runtime.blind_spot_fisheye_k4[i];
            p.blind_spot_fisheye_zoom[i] = if (runtime.blind_spot_fisheye_zoom[i] <= 0.01) 1.0 else runtime.blind_spot_fisheye_zoom[i];
            p.blind_spot_fisheye_center_x[i] = runtime.blind_spot_fisheye_center_x[i];
            p.blind_spot_fisheye_center_y[i] = runtime.blind_spot_fisheye_center_y[i];
            p.blind_spot_fisheye_fx[i] = if (runtime.blind_spot_fisheye_fx[i] <= 1.0) 1920.0 else runtime.blind_spot_fisheye_fx[i];
            p.blind_spot_fisheye_fy[i] = if (runtime.blind_spot_fisheye_fy[i] <= 1.0) 1536.0 else runtime.blind_spot_fisheye_fy[i];
            p.blind_spot_fisheye_source_width[i] = if (runtime.blind_spot_fisheye_source_width[i] <= 1.0) 1920.0 else runtime.blind_spot_fisheye_source_width[i];
            p.blind_spot_fisheye_source_height[i] = if (runtime.blind_spot_fisheye_source_height[i] <= 1.0) 1536.0 else runtime.blind_spot_fisheye_source_height[i];
        }
    }
    updateEncoderLayout(p);
    for (0..4) |i| {
        for (0..MAX_PREVIEW_TARGETS) |t| {
            if (p.preview_window_width[i][t] > 0 and p.preview_window_height[i][t] > 0) updatePreviewLayoutTarget(p, @intCast(i), t, p.preview_window_width[i][t], p.preview_window_height[i][t]);
        }
    }
}

fn fillRuntimeConfigCommand(env: [*c]c.JNIEnv, out: *RenderCommand, width: c.jint, height: c.jint, preview_fps: c.jint, encoder_fps: c.jint, side_left_rotation: c.jint, side_right_rotation: c.jint, layout_mode: c.jint, fisheye_enabled: c.jbooleanArray, k1: c.jfloatArray, k2: c.jfloatArray, k3: c.jfloatArray, k4: c.jfloatArray, zoom: c.jfloatArray, center_x: c.jfloatArray, center_y: c.jfloatArray, fx: c.jfloatArray, fy: c.jfloatArray, source_width: c.jfloatArray, source_height: c.jfloatArray, blind_spot_enabled: c.jbooleanArray, blind_spot_k1: c.jfloatArray, blind_spot_k2: c.jfloatArray, blind_spot_k3: c.jfloatArray, blind_spot_k4: c.jfloatArray, blind_spot_zoom: c.jfloatArray, blind_spot_center_x: c.jfloatArray, blind_spot_center_y: c.jfloatArray, blind_spot_fx: c.jfloatArray, blind_spot_fy: c.jfloatArray, blind_spot_source_width: c.jfloatArray, blind_spot_source_height: c.jfloatArray) void {
    out.* = RenderCommand{
        .kind = .runtime_config,
        .runtime = .{
            .width = width,
            .height = height,
            .preview_fps = preview_fps,
            .encoder_fps = encoder_fps,
            .side_left_rotation = side_left_rotation,
            .side_right_rotation = side_right_rotation,
            .layout_mode = layout_mode,
        },
    };
    if (fisheye_enabled != null and k1 != null and k2 != null and k3 != null and k4 != null and zoom != null and center_x != null and center_y != null and fx != null and fy != null and source_width != null and source_height != null and blind_spot_enabled != null and blind_spot_k1 != null and blind_spot_k2 != null and blind_spot_k3 != null and blind_spot_k4 != null and blind_spot_zoom != null and blind_spot_center_x != null and blind_spot_center_y != null and blind_spot_fx != null and blind_spot_fy != null and blind_spot_source_width != null and blind_spot_source_height != null and getArrayLen(env, fisheye_enabled) >= 4 and getArrayLen(env, k1) >= 4 and getArrayLen(env, k2) >= 4 and getArrayLen(env, k3) >= 4 and getArrayLen(env, k4) >= 4 and getArrayLen(env, zoom) >= 4 and getArrayLen(env, center_x) >= 4 and getArrayLen(env, center_y) >= 4 and getArrayLen(env, fx) >= 4 and getArrayLen(env, fy) >= 4 and getArrayLen(env, source_width) >= 4 and getArrayLen(env, source_height) >= 4 and getArrayLen(env, blind_spot_enabled) >= 4 and getArrayLen(env, blind_spot_k1) >= 4 and getArrayLen(env, blind_spot_k2) >= 4 and getArrayLen(env, blind_spot_k3) >= 4 and getArrayLen(env, blind_spot_k4) >= 4 and getArrayLen(env, blind_spot_zoom) >= 4 and getArrayLen(env, blind_spot_center_x) >= 4 and getArrayLen(env, blind_spot_center_y) >= 4 and getArrayLen(env, blind_spot_fx) >= 4 and getArrayLen(env, blind_spot_fy) >= 4 and getArrayLen(env, blind_spot_source_width) >= 4 and getArrayLen(env, blind_spot_source_height) >= 4) {
        const enabled = env.*[0].GetBooleanArrayElements.?(env, fisheye_enabled, null);
        const k1v = env.*[0].GetFloatArrayElements.?(env, k1, null);
        const k2v = env.*[0].GetFloatArrayElements.?(env, k2, null);
        const k3v = env.*[0].GetFloatArrayElements.?(env, k3, null);
        const k4v = env.*[0].GetFloatArrayElements.?(env, k4, null);
        const zoomv = env.*[0].GetFloatArrayElements.?(env, zoom, null);
        const cx = env.*[0].GetFloatArrayElements.?(env, center_x, null);
        const cy = env.*[0].GetFloatArrayElements.?(env, center_y, null);
        const fxv = env.*[0].GetFloatArrayElements.?(env, fx, null);
        const fyv = env.*[0].GetFloatArrayElements.?(env, fy, null);
        const sw = env.*[0].GetFloatArrayElements.?(env, source_width, null);
        const sh = env.*[0].GetFloatArrayElements.?(env, source_height, null);
        const bs_enabled = env.*[0].GetBooleanArrayElements.?(env, blind_spot_enabled, null);
        const bs_k1v = env.*[0].GetFloatArrayElements.?(env, blind_spot_k1, null);
        const bs_k2v = env.*[0].GetFloatArrayElements.?(env, blind_spot_k2, null);
        const bs_k3v = env.*[0].GetFloatArrayElements.?(env, blind_spot_k3, null);
        const bs_k4v = env.*[0].GetFloatArrayElements.?(env, blind_spot_k4, null);
        const bs_zoomv = env.*[0].GetFloatArrayElements.?(env, blind_spot_zoom, null);
        const bs_cx = env.*[0].GetFloatArrayElements.?(env, blind_spot_center_x, null);
        const bs_cy = env.*[0].GetFloatArrayElements.?(env, blind_spot_center_y, null);
        const bs_fxv = env.*[0].GetFloatArrayElements.?(env, blind_spot_fx, null);
        const bs_fyv = env.*[0].GetFloatArrayElements.?(env, blind_spot_fy, null);
        const bs_sw = env.*[0].GetFloatArrayElements.?(env, blind_spot_source_width, null);
        const bs_sh = env.*[0].GetFloatArrayElements.?(env, blind_spot_source_height, null);
        if (enabled != null and k1v != null and k2v != null and k3v != null and k4v != null and zoomv != null and cx != null and cy != null and fxv != null and fyv != null and sw != null and sh != null and bs_enabled != null and bs_k1v != null and bs_k2v != null and bs_k3v != null and bs_k4v != null and bs_zoomv != null and bs_cx != null and bs_cy != null and bs_fxv != null and bs_fyv != null and bs_sw != null and bs_sh != null) {
            out.runtime.fisheye_valid = true;
            for (0..4) |i| {
                out.runtime.fisheye_enabled[i] = enabled[i] == JNI_TRUE;
                out.runtime.fisheye_k1[i] = k1v[i];
                out.runtime.fisheye_k2[i] = k2v[i];
                out.runtime.fisheye_k3[i] = k3v[i];
                out.runtime.fisheye_k4[i] = k4v[i];
                out.runtime.fisheye_zoom[i] = zoomv[i];
                out.runtime.fisheye_center_x[i] = cx[i];
                out.runtime.fisheye_center_y[i] = cy[i];
                out.runtime.fisheye_fx[i] = fxv[i];
                out.runtime.fisheye_fy[i] = fyv[i];
                out.runtime.fisheye_source_width[i] = sw[i];
                out.runtime.fisheye_source_height[i] = sh[i];
                out.runtime.blind_spot_fisheye_enabled[i] = bs_enabled[i] == JNI_TRUE;
                out.runtime.blind_spot_fisheye_k1[i] = bs_k1v[i];
                out.runtime.blind_spot_fisheye_k2[i] = bs_k2v[i];
                out.runtime.blind_spot_fisheye_k3[i] = bs_k3v[i];
                out.runtime.blind_spot_fisheye_k4[i] = bs_k4v[i];
                out.runtime.blind_spot_fisheye_zoom[i] = bs_zoomv[i];
                out.runtime.blind_spot_fisheye_center_x[i] = bs_cx[i];
                out.runtime.blind_spot_fisheye_center_y[i] = bs_cy[i];
                out.runtime.blind_spot_fisheye_fx[i] = bs_fxv[i];
                out.runtime.blind_spot_fisheye_fy[i] = bs_fyv[i];
                out.runtime.blind_spot_fisheye_source_width[i] = bs_sw[i];
                out.runtime.blind_spot_fisheye_source_height[i] = bs_sh[i];
            }
        }
        if (enabled != null) env.*[0].ReleaseBooleanArrayElements.?(env, fisheye_enabled, enabled, c.JNI_ABORT);
        if (k1v != null) env.*[0].ReleaseFloatArrayElements.?(env, k1, k1v, c.JNI_ABORT);
        if (k2v != null) env.*[0].ReleaseFloatArrayElements.?(env, k2, k2v, c.JNI_ABORT);
        if (k3v != null) env.*[0].ReleaseFloatArrayElements.?(env, k3, k3v, c.JNI_ABORT);
        if (k4v != null) env.*[0].ReleaseFloatArrayElements.?(env, k4, k4v, c.JNI_ABORT);
        if (zoomv != null) env.*[0].ReleaseFloatArrayElements.?(env, zoom, zoomv, c.JNI_ABORT);
        if (cx != null) env.*[0].ReleaseFloatArrayElements.?(env, center_x, cx, c.JNI_ABORT);
        if (cy != null) env.*[0].ReleaseFloatArrayElements.?(env, center_y, cy, c.JNI_ABORT);
        if (fxv != null) env.*[0].ReleaseFloatArrayElements.?(env, fx, fxv, c.JNI_ABORT);
        if (fyv != null) env.*[0].ReleaseFloatArrayElements.?(env, fy, fyv, c.JNI_ABORT);
        if (sw != null) env.*[0].ReleaseFloatArrayElements.?(env, source_width, sw, c.JNI_ABORT);
        if (sh != null) env.*[0].ReleaseFloatArrayElements.?(env, source_height, sh, c.JNI_ABORT);
        if (bs_enabled != null) env.*[0].ReleaseBooleanArrayElements.?(env, blind_spot_enabled, bs_enabled, c.JNI_ABORT);
        if (bs_k1v != null) env.*[0].ReleaseFloatArrayElements.?(env, blind_spot_k1, bs_k1v, c.JNI_ABORT);
        if (bs_k2v != null) env.*[0].ReleaseFloatArrayElements.?(env, blind_spot_k2, bs_k2v, c.JNI_ABORT);
        if (bs_k3v != null) env.*[0].ReleaseFloatArrayElements.?(env, blind_spot_k3, bs_k3v, c.JNI_ABORT);
        if (bs_k4v != null) env.*[0].ReleaseFloatArrayElements.?(env, blind_spot_k4, bs_k4v, c.JNI_ABORT);
        if (bs_zoomv != null) env.*[0].ReleaseFloatArrayElements.?(env, blind_spot_zoom, bs_zoomv, c.JNI_ABORT);
        if (bs_cx != null) env.*[0].ReleaseFloatArrayElements.?(env, blind_spot_center_x, bs_cx, c.JNI_ABORT);
        if (bs_cy != null) env.*[0].ReleaseFloatArrayElements.?(env, blind_spot_center_y, bs_cy, c.JNI_ABORT);
        if (bs_fxv != null) env.*[0].ReleaseFloatArrayElements.?(env, blind_spot_fx, bs_fxv, c.JNI_ABORT);
        if (bs_fyv != null) env.*[0].ReleaseFloatArrayElements.?(env, blind_spot_fy, bs_fyv, c.JNI_ABORT);
        if (bs_sw != null) env.*[0].ReleaseFloatArrayElements.?(env, blind_spot_source_width, bs_sw, c.JNI_ABORT);
        if (bs_sh != null) env.*[0].ReleaseFloatArrayElements.?(env, blind_spot_source_height, bs_sh, c.JNI_ABORT);
    }
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_getGlesSummary(env: [*c]c.JNIEnv, _: c.jobject) callconv(.c) c.jstring {
    return newString(env, "GLES/OES Zig native compositor");
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_setCompositorRuntimeConfig(env: [*c]c.JNIEnv, _: c.jobject, handle: c.jlong, width: c.jint, height: c.jint, preview_fps: c.jint, encoder_fps: c.jint, side_left_rotation: c.jint, side_right_rotation: c.jint, layout_mode: c.jint, fisheye_enabled: c.jbooleanArray, k1: c.jfloatArray, k2: c.jfloatArray, k3: c.jfloatArray, k4: c.jfloatArray, zoom: c.jfloatArray, center_x: c.jfloatArray, center_y: c.jfloatArray, fx: c.jfloatArray, fy: c.jfloatArray, source_width: c.jfloatArray, source_height: c.jfloatArray, blind_spot_enabled: c.jbooleanArray, blind_spot_k1: c.jfloatArray, blind_spot_k2: c.jfloatArray, blind_spot_k3: c.jfloatArray, blind_spot_k4: c.jfloatArray, blind_spot_zoom: c.jfloatArray, blind_spot_center_x: c.jfloatArray, blind_spot_center_y: c.jfloatArray, blind_spot_fx: c.jfloatArray, blind_spot_fy: c.jfloatArray, blind_spot_source_width: c.jfloatArray, blind_spot_source_height: c.jfloatArray) callconv(.c) c.jboolean {
    var cmd = RenderCommand{};
    fillRuntimeConfigCommand(env, &cmd, width, height, preview_fps, encoder_fps, side_left_rotation, side_right_rotation, layout_mode, fisheye_enabled, k1, k2, k3, k4, zoom, center_x, center_y, fx, fy, source_width, source_height, blind_spot_enabled, blind_spot_k1, blind_spot_k2, blind_spot_k3, blind_spot_k4, blind_spot_zoom, blind_spot_center_x, blind_spot_center_y, blind_spot_fx, blind_spot_fy, blind_spot_source_width, blind_spot_source_height);
    const p = lockPipeForHandle(handle) orelse return JNI_FALSE;
    defer unlockPipe(p);
    if (renderWorkerAcceptsCommandsLocked(p)) {
        if (!enqueueRenderCommandLocked(p, &cmd)) {
            releaseRenderCommandResources(&cmd);
            return JNI_FALSE;
        }
    } else {
        applyRuntimeConfigLocked(p, &cmd.runtime);
    }
    logd("runtime config size={d}x{d} previewFps={d} encoderFps={d} config={d}", .{ p.width, p.height, p.preview_max_fps, p.encoder_fps, p.config_version });
    return JNI_TRUE;
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_setPreviewMaxFps(_: [*c]c.JNIEnv, _: c.jobject, handle: c.jlong, fps: c.jint) callconv(.c) c.jboolean {
    const p = lockPipeForHandle(handle) orelse return JNI_FALSE;
    defer unlockPipe(p);
    var cmd = RenderCommand{ .kind = .set_preview_fps, .runtime = .{ .preview_fps = fps } };
    if (renderWorkerAcceptsCommandsLocked(p)) {
        if (!enqueueRenderCommandLocked(p, &cmd)) return JNI_FALSE;
    } else {
        applyPreviewFpsLocked(p, fps);
    }
    logd("preview max fps={d} minIntervalMs={d}", .{ p.preview_max_fps, p.preview_min_interval_ms });
    return JNI_TRUE;
}

fn startRecordingSessionNative(handle: c.jlong, fps: c.jint, segment_duration_ms: c.jlong, wall_clock_ms: c.jlong, align_to_wall_clock_segment: bool) c.jlong {
    const p = lockPipeForHandle(handle) orelse return 0;
    defer unlockPipe(p);
    if (p.releasing) return 0;
    p.recording.recording = true;
    p.recording.generation += 1;
    p.recording.fps = @min(@max(fps, 1), 120);
    p.encoder_fps = p.recording.fps;
    p.recording.segment_duration_ms = if (segment_duration_ms <= 0) 60000 else segment_duration_ms;
    p.recording.segment_index = 0;
    p.recording.pending_segment_index = 0;
    p.recording.segment_switch_pending = false;
    p.recording.pending_segment_wall_clock_ms = 0;
    p.recording.requested_frames = 0;
    p.recording.rendered_frames = 0;
    p.recording.dropped_frames = 0;
    p.recording.encoded_samples = 0;
    p.recording.last_tick_steady_ms = 0;
    p.recording.encoder_segment_start_steady_ms = nowMs();
    p.recording.last_presentation_time_ns = -1;
    resetOverlayCache(&p.recording, wall_clock_ms);
    resetRecordingFrameQueueLocked(p);
    p.recording_frame_queue_produced_count = 0;
    p.recording_frame_queue_consumed_count = 0;
    p.recording_frame_queue_drop_count = 0;
    p.recording_frame_queue_max_depth = 0;
    p.recording_frame_queue_fallback_count = 0;
    p.recording_frame_queue_fbo_recreate_count = 0;
    p.encoder_signal_count = 0;
    p.encoder_scheduled_count = 0;
    p.encoder_coalesced_count = 0;
    const first = if (align_to_wall_clock_segment) floorToSegment(wall_clock_ms, p.recording.segment_duration_ms) else wall_clock_ms;
    p.recording.next_segment_wall_clock_ms = first + p.recording.segment_duration_ms;
    p.encoder_pending = false;
    return first;
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_startManagedRecording(env: [*c]c.JNIEnv, _: c.jobject, handle: c.jlong, output_dir: c.jstring, suffix: c.jstring, width: c.jint, height: c.jint, bitrate: c.jint, fps: c.jint, segment_duration_ms: c.jlong, wall_clock_ms: c.jlong, reserved_bytes: c.jlong, available_bytes: c.jlong) callconv(.c) c.jboolean {
    if (output_dir == null or suffix == null) return JNI_FALSE;
    if (lockPipeForHandle(handle)) |p| {
        defer unlockPipe(p);
        if (p.releasing) return JNI_FALSE;
    } else return JNI_FALSE;
    const dir_chars = env.*[0].GetStringUTFChars.?(env, output_dir, null) orelse return JNI_FALSE;
    defer env.*[0].ReleaseStringUTFChars.?(env, output_dir, dir_chars);
    const suffix_chars = env.*[0].GetStringUTFChars.?(env, suffix, null) orelse return JNI_FALSE;
    defer env.*[0].ReleaseStringUTFChars.?(env, suffix, suffix_chars);
    _ = ensureSegmentCacheCallback(env);
    var config: ManagedSegmentConfig = .{
        .width = width,
        .height = height,
        .bitrate = bitrate,
        .fps = @min(@max(fps, 1), 120),
        .segment_duration_ms = if (segment_duration_ms <= 0) 60000 else segment_duration_ms,
        .reserved_bytes = reserved_bytes,
        .available_bytes = available_bytes,
    };
    if (!files.copyCStringToBuffer(&config.output_dir, dir_chars)) return JNI_FALSE;
    if (!files.copyCStringToBuffer(&config.suffix, suffix_chars)) return JNI_FALSE;
    const align_to_wall_clock_segment = std.mem.len(suffix_chars) == 0;
    const first = startRecordingSessionNative(handle, fps, segment_duration_ms, wall_clock_ms, align_to_wall_clock_segment);
    if (first <= 0) return JNI_FALSE;
    logi("managed recording session first={d} next={d} alignWallClock={d} suffix={s}", .{ first, first + config.segment_duration_ms, if (align_to_wall_clock_segment) @as(i32, 1) else @as(i32, 0), std.mem.span(suffix_chars) });
    var final_path: [1024:0]u8 = [_:0]u8{0} ** 1024;
    const writer_handle = managedCreateStartSegment(config, first, &final_path);
    if (writer_handle == 0) {
        _ = Java_com_kooo_evcam_v2_nativebridge_GlesNative_stopManagedRecording(env, null, handle, 0, wall_clock_ms);
        return JNI_FALSE;
    }
    const input_window = acquireWriterInputWindow(writer_handle) orelse {
        _ = releaseNativeSegmentWriterHandle(writer_handle);
        _ = Java_com_kooo_evcam_v2_nativebridge_GlesNative_stopManagedRecording(env, null, handle, 0, wall_clock_ms);
        return JNI_FALSE;
    };
    var attached = false;
    var input_window_consumed = false;
    if (lockPipeForHandle(handle)) |p| {
        defer unlockPipe(p);
        if (!p.releasing) {
            p.recording.managed_native = true;
            p.recording.managed_writer_handle = 0;
            p.recording.managed_width = config.width;
            p.recording.managed_height = config.height;
            p.recording.managed_bitrate = config.bitrate;
            p.recording.managed_reserved_bytes = config.reserved_bytes;
            p.recording.managed_available_bytes = config.available_bytes;
            p.recording.managed_output_dir = config.output_dir;
            p.recording.managed_suffix = config.suffix;
            input_window_consumed = true;
            attached = managedAttachPreparedSegmentLocked(p, input_window, &final_path);
            if (attached) {
                p.recording.managed_writer_handle = writer_handle;
                p.recording.managed_last_final_path = final_path;
                p.recording.managed_last_final_start_ms = first;
                p.recording.managed_last_final_end_ms = 0;
            }
        }
    }
    if (!attached) {
        if (!input_window_consumed) c.ANativeWindow_release(input_window);
        _ = releaseNativeSegmentWriterHandle(writer_handle);
        _ = Java_com_kooo_evcam_v2_nativebridge_GlesNative_stopManagedRecording(env, null, handle, 0, wall_clock_ms);
        return JNI_FALSE;
    }
    const worker_started = startRecordingWorkerNative(handle, writer_handle, fps);
    if (worker_started != JNI_TRUE) {
        _ = Java_com_kooo_evcam_v2_nativebridge_GlesNative_stopManagedRecording(env, null, handle, 0, wall_clock_ms);
        return JNI_FALSE;
    }
    return JNI_TRUE;
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_stopManagedRecording(_: [*c]c.JNIEnv, _: c.jobject, handle: c.jlong, timeout_ms: c.jlong, stop_wall_clock_ms: c.jlong) callconv(.c) c.jboolean {
    _ = stopRecordingWorkerNative(handle, timeout_ms);
    var finalize: ManagedSegmentFinalize = .{};
    if (lockPipeForHandle(handle)) |p| {
        finalize = .{
            .writer_handle = p.recording.managed_writer_handle,
            .final_path = p.recording.managed_last_final_path,
            .start_ms = p.recording.managed_last_final_start_ms,
            .end_ms = stop_wall_clock_ms,
            .config = managedConfigFromRecording(p),
        };
        p.recording.managed_writer_handle = 0;
        p.recording.managed_native = false;
        p.recording.recording = false;
        p.recording.segment_switch_pending = false;
        resetOverlayCache(&p.recording, 0);
        p.recording.generation += 1;
        detachEncoderSurfaceLocked(p);
        unlockPipe(p);
    }
    if (finalize.writer_handle != 0) {
        if (!finalize_queue.submit(finalize)) {
            finalize_queue.recordFallback();
            _ = managedFinalizeSegment(finalize);
        }
        _ = finalize_queue.drain();
    } else {
        _ = finalize_queue.drain();
    }
    return JNI_TRUE;
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_updateWatermarkBitmap(env: [*c]c.JNIEnv, _: c.jobject, handle: c.jlong, bitmap: c.jobject, x: c.jint, y: c.jint) callconv(.c) c.jboolean {
    var cmd = RenderCommand{};
    if (!makeWatermarkCommandFromBitmap(env, bitmap, x, y, &cmd)) return JNI_FALSE;
    defer releaseRenderCommandResources(&cmd);
    const p = lockPipeForHandle(handle) orelse return JNI_FALSE;
    defer unlockPipe(p);
    if (renderWorkerAcceptsCommandsLocked(p)) {
        if (!enqueueRenderCommandLocked(p, &cmd)) {
            releaseRenderCommandResources(&cmd);
            return JNI_FALSE;
        }
        return JNI_TRUE;
    }
    return if (uploadWatermarkPixelsLocked(p, cmd.watermark_pixels, cmd.watermark_width, cmd.watermark_height, cmd.watermark_x, cmd.watermark_y)) JNI_TRUE else JNI_FALSE;
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_clearWatermarkBitmap(_: [*c]c.JNIEnv, _: c.jobject, handle: c.jlong) callconv(.c) c.jboolean {
    const p = lockPipeForHandle(handle) orelse return JNI_FALSE;
    defer unlockPipe(p);
    var cmd = RenderCommand{ .kind = .clear_watermark };
    if (renderWorkerAcceptsCommandsLocked(p)) {
        if (!enqueueRenderCommandLocked(p, &cmd)) return JNI_FALSE;
        return JNI_TRUE;
    } else {
        return if (clearWatermarkBitmapLocked(p)) JNI_TRUE else JNI_FALSE;
    }
}

fn recordingTickRenderLocked(env: [*c]c.JNIEnv, p: *Pipe, wall_clock_ms: c.jlong) c.jlong {
    var result: c.jlong = 0;
    var rendered = false;
    if (!p.recording.recording) return 0;

    p.recording.requested_frames += 1;
    p.recording.overlay_wall_clock_ms = wall_clock_ms;
    if (!renderEncoderLocked(env, p, false, &rendered, null)) return -1;
    if (rendered) {
        p.recording.rendered_frames += 1;
        result |= TICK_SHOULD_RENDER;
        if (!p.preview_worker_running and !renderCompositePreviewLocked(env, p, false)) {
            p.dropped_count += 1;
            if (@mod(p.dropped_count, 60) == 0) loge("composite preview mirror failed drops={d}", .{p.dropped_count});
        }
    } else {
        p.recording.dropped_frames += 1;
        result |= TICK_DROPPED;
    }
    if (!p.recording.segment_switch_pending and p.recording.next_segment_wall_clock_ms > 0 and wall_clock_ms >= p.recording.next_segment_wall_clock_ms) {
        const next_index = p.recording.segment_index + 1;
        result |= TICK_SEGMENT_DUE;
        result |= (@as(c.jlong, next_index) << TICK_NEXT_INDEX_SHIFT);
    }
    p.recording.last_tick_steady_ms = nowMs();
    return result;
}

fn applyRecordingWorkerEventLocked(p: *Pipe, generation: c.jlong, event: c.jlong) bool {
    if (p.recording_worker_generation != generation or !p.recording_worker_running) return false;
    if (event < 0) {
        p.recording_worker_last_event = WORKER_ERROR_TICK_RENDER_DRAIN;
        p.recording_worker_stop = true;
        return false;
    }
    if (event == 0) return false;

    const drained_samples: i64 = @intCast((event >> TICK_DRAINED_SHIFT) & TICK_DRAINED_MASK);
    if (drained_samples > 0) p.recording.encoded_samples += drained_samples;
    return p.recording.managed_native and (event & TICK_SEGMENT_DUE) != 0;
}

fn setRecordingWorkerTickErrorLocked(p: *Pipe, generation: c.jlong) void {
    if (p.recording_worker_generation != generation or !p.recording_worker_running) return;
    p.recording_worker_last_event = WORKER_ERROR_TICK_RENDER_DRAIN;
    p.recording_worker_stop = true;
}

fn activePreviewCount(p: *const Pipe) usize {
    var count: usize = 0;
    for (0..4) |idx| {
        if (hasAnyPreviewSurface(p, idx) and p.input[idx].surface_texture_native != null) count += 1;
    }
    return count;
}

fn activeInputCount(p: *const Pipe) usize {
    var count: usize = 0;
    for (p.input) |inp| {
        if (inp.surface_texture_native != null) count += 1;
    }
    return count;
}

fn hasAnyPreviewSurface(p: *const Pipe, idx: usize) bool {
    if (idx >= 4) return false;
    for (0..MAX_PREVIEW_TARGETS) |t| {
        if (p.preview_surface[idx][t] != c.EGL_NO_SURFACE) return true;
    }
    return false;
}

fn nextPreviewIndex(p: *const Pipe, start_index: usize) ?usize {
    var step: usize = 0;
    while (step < 4) : (step += 1) {
        const idx = (start_index + step) % 4;
        if (hasAnyPreviewSurface(p, idx) and p.input[idx].surface_texture_native != null) return idx;
    }
    return null;
}

fn nextPendingPreviewIndex(p: *const Pipe, start_index: usize) ?usize {
    var step: usize = 0;
    while (step < 4) : (step += 1) {
        const idx = (start_index + step) % 4;
        if (hasAnyPreviewSurface(p, idx) and inputNeedsLatch(&p.input[idx])) return idx;
    }
    return null;
}

fn nextPreviewIndexInMask(p: *const Pipe, start_index: usize, mask: u8) ?usize {
    var step: usize = 0;
    while (step < 4) : (step += 1) {
        const idx = (start_index + step) % 4;
        if ((mask & (@as(u8, 1) << @intCast(idx))) != 0 and hasAnyPreviewSurface(p, idx) and p.input[idx].surface_texture_native != null) return idx;
    }
    return null;
}

fn consumePendingFrameSignalsLocked(p: *Pipe) void {
    const mask = @atomicRmw(u32, &p.pending_frame_mask, .Xchg, 0, .acquire);
    if (mask == 0) return;
    for (0..4) |i| {
        if ((mask & (@as(u32, 1) << @intCast(i))) == 0) continue;
        const signals = @atomicRmw(i64, &p.pending_frame_signal_counts[i], .Xchg, 0, .acquire);
        if (p.input[i].surface_texture_native == null) continue;
        const safe_signals = @max(signals, 1);
        p.input[i].dirty = true;
        p.input[i].frame_signal_count += safe_signals;
        if (hasAnyPreviewSurface(p, i) and p.preview_worker_running and !p.preview_worker_stop) {
            if (p.input[i].preview_pending) {
                p.input[i].preview_coalesced_count += safe_signals;
            } else {
                p.input[i].preview_pending = true;
                p.input[i].preview_scheduled_count += 1;
                if (safe_signals > 1) p.input[i].preview_coalesced_count += safe_signals - 1;
            }
        }
    }
}

fn recordingSchedulerActiveLocked(p: *const Pipe) bool {
    return p.recording_worker_running and
        !p.recording_worker_stop and
        !p.recording_worker_paused_for_segment and
        p.recording.recording and
        p.recording.managed_native and
        p.recording_worker_writer_handle != 0;
}

fn renderRecordingDueLocked(env: [*c]c.JNIEnv, p: *Pipe, steady_ms: i64) c.jlong {
    if (!recordingFrameCaptureDueLocked(p, steady_ms)) return 0;
    const wall_clock_ms = wallClockMs();
    p.recording.requested_frames += 1;

    // Without a composite preview there is no consumer for an intermediate
    // full-size RGBA frame.  Render the scene directly into the encoder
    // surface and avoid the FBO/texture write followed by a texture blit.
    const has_composite_preview = p.composite_preview_surface != c.EGL_NO_SURFACE and p.composite_preview_window != null;
    if (!has_composite_preview) {
        // Release a queue left behind by a previously attached composite
        // preview.  This is a one-time transition cost and prevents keeping
        // two full-resolution RGBA textures alive during direct recording.
        if (p.recording_frame_queue_width != 0 and p.recording_frame_queue_count == 0) {
            if (makePbufferCurrent(p)) releaseRecordingFrameQueueLocked(p);
        }
        p.recording.overlay_wall_clock_ms = wall_clock_ms;
        var rendered = false;
        const ok = renderEncoderLocked(env, p, false, &rendered, null);
        markRecordingFrameCaptureScheduledLocked(p, steady_ms);
        if (!ok) return -1;
        if (!rendered) {
            p.recording.dropped_frames += 1;
            p.recording.last_tick_steady_ms = nowMs();
            return TICK_DROPPED;
        }
        p.recording.rendered_frames += 1;
        const end = nowMs();
        p.recording.last_tick_steady_ms = end;
        var result: c.jlong = TICK_SHOULD_RENDER;
        if (!p.recording.segment_switch_pending and p.recording.next_segment_wall_clock_ms > 0 and wall_clock_ms >= p.recording.next_segment_wall_clock_ms) {
            const next_index = p.recording.segment_index + 1;
            result |= TICK_SEGMENT_DUE;
            result |= (@as(c.jlong, next_index) << TICK_NEXT_INDEX_SHIFT);
        }
        return result;
    }

    if (!makePbufferCurrent(p)) return -1;
    if (!latchAllInputsLocked(p)) {
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        clearCurrent(p);
        return -1;
    }
    if (produceCompositeFrameLocked(p, wall_clock_ms, steady_ms, true) == null) {
        p.recording.dropped_frames += 1;
        p.recording_frame_queue_fallback_count += 1;
        markRecordingFrameCaptureScheduledLocked(p, steady_ms);
        return TICK_DROPPED;
    }
    _ = env;
    return renderQueuedRecordingFrameLocked(p);
}

fn previewWorkerLoop(handle: c.jlong, generation: c.jlong) void {
    const env = attachWorkerEnv() orelse {
        setErrorSlice("preview worker failed to attach JNI env");
        if (lockPipeForHandle(handle)) |p| {
            defer unlockPipe(p);
            if (p.preview_worker_generation == generation) {
                p.preview_worker_running = false;
                p.preview_worker_stop = true;
            }
            if (p.recording_worker_running) {
                p.recording_worker_last_event = WORKER_ERROR_THREAD_ATTACH;
                p.recording_worker_running = false;
                p.recording_worker_stop = true;
                p.recording_worker_writer_handle = 0;
                p.recording_worker_next_deadline_ms = 0;
            }
        }
        return;
    };
    defer detachWorkerEnv();
    boostRenderWorkerPriority();

    const worker_pipe = lockPipeForHandle(handle) orelse return;
    unlockPipe(worker_pipe);

    var next_deadline_ms = nowMs();
    var next_index: usize = 0;
    while (true) {
        var interval_ms: i64 = 33;
        var rendered_any = false;
        var recording_event: c.jlong = 0;
        var recording_writer_handle: c.jlong = 0;
        var recording_generation: c.jlong = 0;
        if (!tryLockPipe(worker_pipe)) {
            sleepMs(2);
            next_deadline_ms = nowMs();
            continue;
        }
        applyPendingRenderCommandsLocked(worker_pipe);
        consumePendingFrameSignalsLocked(worker_pipe);
        if (!worker_pipe.preview_worker_running or worker_pipe.preview_worker_generation != generation or worker_pipe.preview_worker_stop) {
            dropPendingRenderCommandsLocked(worker_pipe);
            clearCurrent(worker_pipe);
            unlockPipe(worker_pipe);
            break;
        }
        const preview_enabled = worker_pipe.preview_render_enabled;
        const recording_active = recordingSchedulerActiveLocked(worker_pipe);
        if (recording_active) {
            recording_writer_handle = worker_pipe.recording_worker_writer_handle;
            recording_generation = worker_pipe.recording_worker_generation;
            interval_ms = recordingTickIntervalMs(&worker_pipe.recording);
        }

        const input_update_mask = pendingInputUpdateMask(worker_pipe);
        const input_update_pending = input_update_mask != 0;
        const recording_capture_due = recording_active and recordingFrameCaptureDueLocked(worker_pipe, nowMs());
        const has_composite_preview = preview_enabled and worker_pipe.composite_preview_surface != c.EGL_NO_SURFACE and worker_pipe.composite_preview_window != null;
        if (preview_enabled and has_composite_preview) {
            interval_ms = @max(worker_pipe.preview_min_interval_ms, 1);
            const has_active_inputs = activeInputCount(worker_pipe) > 0;
            if (has_active_inputs and (input_update_pending or recording_capture_due) and (!makePbufferCurrent(worker_pipe) or !latchAllInputsLocked(worker_pipe))) {
                worker_pipe.dropped_count += 1;
            } else if (has_active_inputs and (input_update_pending or recording_capture_due)) {
                if (nextPreviewIndexInMask(worker_pipe, next_index, input_update_mask) orelse nextPreviewIndex(worker_pipe, next_index)) |idx| {
                    if (renderPreviewFromLatchedLocked(worker_pipe, @intCast(idx))) rendered_any = true;
                    worker_pipe.input[idx].preview_pending = false;
                    next_index = (idx + 1) % 4;
                }
                if (renderCompositePreviewLocked(env, worker_pipe, false)) {
                    rendered_any = true;
                } else {
                    worker_pipe.dropped_count += 1;
                }
            } else if (!has_active_inputs and recording_capture_due and renderCompositePreviewLocked(env, worker_pipe, true)) {
                rendered_any = true;
            } else if (!has_active_inputs and recording_capture_due) {
                worker_pipe.dropped_count += 1;
            }
        } else if (preview_enabled) {
            const active_count = activePreviewCount(worker_pipe);
            if (active_count > 0) {
                const base_interval_ms = @max(worker_pipe.preview_min_interval_ms, 1);
                interval_ms = @max(@divTrunc(base_interval_ms, @as(i64, @intCast(active_count))), 1);
                if (nextPendingPreviewIndex(worker_pipe, next_index)) |idx| {
                    if (renderPreviewLocked(env, worker_pipe, @intCast(idx))) rendered_any = true;
                    worker_pipe.input[idx].preview_pending = false;
                    next_index = (idx + 1) % 4;
                }
            }
        }

        if (recording_active) {
            const steady_ms = nowMs();
            if (worker_pipe.recording_frame_queue_count > 0) {
                recording_event = renderQueuedRecordingFrameLocked(worker_pipe);
            } else {
                recording_event = renderRecordingDueLocked(env, worker_pipe, steady_ms);
            }
            if (recording_event != 0) rendered_any = true;
            worker_pipe.recording_worker_next_deadline_ms = worker_pipe.recording_frame_queue_next_capture_ms;
        } else {
            worker_pipe.recording_worker_next_deadline_ms = 0;
        }
        worker_pipe.preview_worker_next_deadline_ms = next_deadline_ms + interval_ms;
        unlockPipe(worker_pipe);

        if (recording_writer_handle != 0) {
            if (recording_event >= 0 and (recording_event & TICK_SHOULD_RENDER) != 0 and !writer_mod.requestAsyncDrain(recording_writer_handle)) {
                recording_event = -1;
            }
            const drain_result = writer_mod.consumeAsyncDrainResult(recording_writer_handle);
            if (drain_result.failed) {
                recording_event = -1;
            } else if (drain_result.drained_samples > 0 and recording_event >= 0) {
                const drained_capped: c.jlong = @min(drain_result.drained_samples, TICK_DRAINED_MASK);
                recording_event |= (drained_capped << TICK_DRAINED_SHIFT);
            }
        }

        var should_switch = false;
        if (recording_generation != 0 and recording_event != 0) {
            lockPipe(worker_pipe);
            should_switch = applyRecordingWorkerEventLocked(worker_pipe, recording_generation, recording_event);
            unlockPipe(worker_pipe);
        }

        if (should_switch) {
            const switched = managedSwitchSegment(handle);
            if (!switched) {
                lockPipe(worker_pipe);
                setRecordingWorkerTickErrorLocked(worker_pipe, recording_generation);
                unlockPipe(worker_pipe);
            }
        }

        if (rendered_any) {
            paceAfterTick(&next_deadline_ms, interval_ms);
        } else {
            sleepMs(@intCast(@min(interval_ms, 10)));
            next_deadline_ms = nowMs();
        }
    }

    if (lockPipeForHandle(handle)) |p| {
        defer unlockPipe(p);
        if (p.preview_worker_generation == generation) {
            p.preview_worker_running = false;
            p.preview_worker_stop = true;
            p.preview_worker_next_deadline_ms = 0;
        }
    }
}

fn startRenderWorkerNative(handle: c.jlong, fps: c.jint, enable_preview: bool) c.jboolean {
    joinStalePreviewWorker(handle);
    var generation: c.jlong = 0;
    var should_join_preview_thread = false;
    {
        const p = lockPipeForHandle(handle) orelse return JNI_FALSE;
        defer unlockPipe(p);
        if (p.releasing) return JNI_FALSE;
        if (enable_preview) p.preview_render_enabled = true;
        if (p.preview_worker_running) {
            if (!p.preview_worker_stop) return JNI_TRUE;
            setErrorSlice("preview worker is stopping");
            return JNI_FALSE;
        }
        if (p.preview_worker_thread != null) {
            setErrorSlice("preview worker join pending");
            return JNI_FALSE;
        }
        p.preview_worker_running = true;
        p.preview_worker_stop = false;
        p.preview_worker_generation += 1;
        if (fps > 0) {
            p.preview_max_fps = @min(@max(fps, 1), 120);
            p.preview_min_interval_ms = @divTrunc(1000, p.preview_max_fps);
        }
        generation = p.preview_worker_generation;
    }
    const thread = std.Thread.spawn(.{}, previewWorkerLoop, .{ handle, generation }) catch |err| {
        if (lockPipeForHandle(handle)) |p| {
            defer unlockPipe(p);
            if (p.preview_worker_generation == generation) {
                p.preview_worker_running = false;
                p.preview_worker_stop = true;
            }
        }
        setError("preview worker spawn failed: {}", .{err});
        return JNI_FALSE;
    };
    if (lockPipeForHandle(handle)) |p| {
        defer unlockPipe(p);
        if (p.preview_worker_generation == generation and p.preview_worker_running and !p.preview_worker_stop and !p.releasing) {
            p.preview_worker_thread = thread;
        } else {
            p.preview_worker_running = false;
            p.preview_worker_stop = true;
            should_join_preview_thread = true;
        }
    } else {
        should_join_preview_thread = true;
    }
    if (should_join_preview_thread) {
        thread.join();
        return JNI_FALSE;
    }
    logd("render worker started fps={d} generation={d} preview={d}", .{ fps, generation, if (enable_preview) @as(i32, 1) else @as(i32, 0) });
    return JNI_TRUE;
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_startPreviewWorker(_: [*c]c.JNIEnv, _: c.jobject, handle: c.jlong, fps: c.jint) callconv(.c) c.jboolean {
    return startRenderWorkerNative(handle, fps, true);
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_stopPreviewWorker(_: [*c]c.JNIEnv, _: c.jobject, handle: c.jlong, timeout_ms: c.jlong) callconv(.c) c.jboolean {
    var thread: ?std.Thread = null;
    var generation: c.jlong = 0;
    {
        const p = lockPipeForHandle(handle) orelse return JNI_FALSE;
        defer unlockPipe(p);
        p.preview_render_enabled = false;
        if (recordingSchedulerActiveLocked(p)) {
            return JNI_TRUE;
        }
        generation = p.preview_worker_generation;
        p.preview_worker_running = false;
        p.preview_worker_stop = true;
        thread = p.preview_worker_thread;
        p.preview_worker_thread = null;
    }
    if (thread) |t| joinWorkerThread(t, "preview", generation, timeout_ms);
    return JNI_TRUE;
}

fn startRecordingWorkerNative(handle: c.jlong, writer_handle: c.jlong, fps: c.jint) c.jboolean {
    var generation: c.jlong = 0;
    {
        const p = lockPipeForHandle(handle) orelse return JNI_FALSE;
        defer unlockPipe(p);
        if (p.releasing) return JNI_FALSE;
        if (!p.recording.recording or !p.recording.managed_native or writer_handle == 0 or p.recording_worker_running) {
            setErrorSlice("recording scheduler start requires managed recording, writer, and idle scheduler");
            return JNI_FALSE;
        }
        p.recording_worker_running = true;
        p.recording_worker_stop = false;
        p.recording_worker_paused_for_segment = false;
        p.recording_worker_writer_handle = writer_handle;
        p.recording_worker_next_deadline_ms = 0;
        p.recording_worker_last_event = 0;
        p.recording_worker_generation += 1;
        p.recording.fps = @min(@max(fps, 1), 120);
        generation = p.recording_worker_generation;
    }
    const worker_started = startRenderWorkerNative(handle, fps, false);
    if (worker_started != JNI_TRUE) {
        if (lockPipeForHandle(handle)) |p| {
            defer unlockPipe(p);
            if (p.recording_worker_generation == generation) {
                p.recording_worker_running = false;
                p.recording_worker_stop = true;
                p.recording_worker_writer_handle = 0;
                p.recording_worker_next_deadline_ms = 0;
            }
        }
        return JNI_FALSE;
    }
    logd("recording scheduler attached writer={d} fps={d} generation={d}", .{ writer_handle, fps, generation });
    return JNI_TRUE;
}

fn stopRecordingWorkerNative(handle: c.jlong, timeout_ms: c.jlong) c.jlong {
    var thread: ?std.Thread = null;
    var event: c.jlong = 0;
    var generation: c.jlong = 0;
    {
        const p = lockPipeForHandle(handle) orelse return -1;
        defer unlockPipe(p);
        event = p.recording_worker_last_event;
        generation = p.recording_worker_generation;
        p.recording_worker_running = false;
        p.recording_worker_stop = true;
        p.recording_worker_paused_for_segment = false;
        p.recording_worker_writer_handle = 0;
        p.recording_worker_next_deadline_ms = 0;
        if (!p.preview_render_enabled) {
            thread = p.preview_worker_thread;
            p.preview_worker_thread = null;
            p.preview_worker_running = false;
            p.preview_worker_stop = true;
            generation = p.preview_worker_generation;
        }
    }
    if (thread) |t| {
        joinWorkerThread(t, "render", generation, timeout_ms);
        if (lockPipeForHandle(handle)) |p| {
            defer unlockPipe(p);
            if (p.recording_worker_last_event != 0) {
                event = p.recording_worker_last_event;
                p.recording_worker_last_event = 0;
            }
        }
    }
    return event;
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_snapshotRecordingWorker(env: [*c]c.JNIEnv, _: c.jobject, handle: c.jlong) callconv(.c) c.jlongArray {
    var values: [8]c.jlong = [_]c.jlong{0} ** 8;
    if (lockPipeForHandle(handle)) |p| {
        defer unlockPipe(p);
        values[0] = if (p.recording_worker_running) 1 else 0;
        values[1] = if (p.recording_worker_stop) 1 else 0;
        values[2] = if (p.recording_worker_paused_for_segment) 1 else 0;
        values[3] = p.recording_worker_writer_handle;
        values[4] = p.recording_worker_last_event;
        values[5] = p.recording_worker_generation;
        values[6] = p.recording.requested_frames;
        values[7] = p.recording.rendered_frames;
    }
    const arr = env.*[0].NewLongArray.?(env, values.len) orelse return null;
    env.*[0].SetLongArrayRegion.?(env, arr, 0, values.len, &values);
    return arr;
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_nativeCleanupStorage(env: [*c]c.JNIEnv, _: c.jobject, output_dir: c.jstring, reserved_bytes: c.jlong, available_bytes: c.jlong) callconv(.c) c.jlongArray {
    var values: [3]c.jlong = [_]c.jlong{0} ** 3;
    if (output_dir != null) {
        const chars = env.*[0].GetStringUTFChars.?(env, output_dir, null);
        if (chars != null) {
            defer env.*[0].ReleaseStringUTFChars.?(env, output_dir, chars);
            var deleted_count: i64 = 0;
            var deleted_bytes: i64 = 0;
            const available = cleanupStorageNative(chars, reserved_bytes, available_bytes, null, &deleted_count, &deleted_bytes);
            values[0] = deleted_count;
            values[1] = deleted_bytes;
            values[2] = available;
        }
    }
    const arr = env.*[0].NewLongArray.?(env, values.len) orelse return null;
    env.*[0].SetLongArrayRegion.?(env, arr, 0, values.len, &values);
    return arr;
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_nativeListPlaybackVideos(env: [*c]c.JNIEnv, _: c.jobject, scan_dirs: c.jobjectArray) callconv(.c) c.jobjectArray {
    return playback_cache.listVideos(env, scan_dirs);
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_nativeListPlaybackImages(env: [*c]c.JNIEnv, _: c.jobject, scan_dirs: c.jobjectArray) callconv(.c) c.jobjectArray {
    return playback_cache.listImages(env, scan_dirs);
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_nativeBuildPlaybackCache(env: [*c]c.JNIEnv, _: c.jobject, scan_dirs: c.jobjectArray) callconv(.c) c.jstring {
    return playback_cache.buildCacheJson(env, scan_dirs, false);
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_nativeBuildPlaybackCacheWithThumbnails(env: [*c]c.JNIEnv, _: c.jobject, scan_dirs: c.jobjectArray) callconv(.c) c.jstring {
    return playback_cache.buildCacheJson(env, scan_dirs, true);
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_nativeBuildPlaybackEntry(env: [*c]c.JNIEnv, _: c.jobject, video_path: c.jstring) callconv(.c) c.jstring {
    return playback_cache.buildEntry(env, video_path);
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_nativeEnsurePlaybackThumbnail(env: [*c]c.JNIEnv, _: c.jobject, video_path: c.jstring) callconv(.c) c.jstring {
    return playback_cache.ensureThumbnail(env, video_path);
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_nativeDeleteVideoAndSidecars(env: [*c]c.JNIEnv, _: c.jobject, video_path: c.jstring) callconv(.c) c.jboolean {
    return playback_cache.deleteVideoAndSidecars(env, video_path);
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_nativeDeleteVideosAndBuildPlaybackCache(env: [*c]c.JNIEnv, _: c.jobject, video_paths: c.jobjectArray, scan_dirs: c.jobjectArray) callconv(.c) c.jstring {
    return playback_cache.deleteVideosAndBuildCache(env, video_paths, scan_dirs);
}
fn createNativeSegmentWriterForMime(width: c.jint, height: c.jint, fps: c.jint, bitrate: c.jint, mime_chars: [*c]const u8) c.jlong {
    return writer_mod.createForMime(width, height, fps, bitrate, mime_chars);
}

fn startNativeSegmentWriter(writer_handle: c.jlong, dir_chars: [*c]const u8, suffix_chars: [*c]const u8, wall_clock_ms: c.jlong, out_final_path: *[1024:0]u8) bool {
    return writer_mod.startSegment(writer_handle, dir_chars, suffix_chars, wall_clock_ms, out_final_path);
}

fn setRecordingThumbnailPathForVideo(p: *Pipe, final_path: [*c]const u8) bool {
    if (!files.thumbnailPathForVideo(&p.recording.thumbnail_path, final_path)) {
        setError("thumbnail path too long", .{});
        return false;
    }
    p.recording.thumbnail_path_set = true;
    p.recording.thumbnail_written = false;
    return true;
}

fn acquireWriterInputWindowLockedNoGlobal(writer_handle: c.jlong) ?*c.ANativeWindow {
    return writer_mod.acquireInputWindowNoGlobal(writer_handle);
}

fn acquireWriterInputWindow(writer_handle: c.jlong) ?*c.ANativeWindow {
    return writer_mod.acquireInputWindow(writer_handle);
}

fn attachEncoderWindowLocked(p: *Pipe, new_window: *c.ANativeWindow) c.jboolean {
    if (!initEgl(p)) {
        c.ANativeWindow_release(new_window);
        return JNI_FALSE;
    }
    const new_surface = c.eglCreateWindowSurface(p.display, p.config, new_window, null);
    if (new_surface == c.EGL_NO_SURFACE) {
        setErrorSlice(eglError("eglCreateWindowSurface encoder failed"));
        c.ANativeWindow_release(new_window);
        return JNI_FALSE;
    }

    const old_surface = p.encoder_surface;
    const old_window = p.encoder_window;
    p.encoder_surface = new_surface;
    p.encoder_window = new_window;
    p.encoder_swap_interval_set = false;
    if (old_surface != c.EGL_NO_SURFACE) {
        if (p.current_surface == old_surface) clearCurrent(p);
        _ = c.eglDestroySurface(p.display, old_surface);
    }
    if (old_window) |w| c.ANativeWindow_release(w);
    p.encoder_frame_index = 0;
    if (p.recording.recording) {
        p.recording.encoder_segment_start_steady_ms = nowMs();
        p.recording.last_presentation_time_ns = -1;
    }
    resetRecordingFrameQueueLocked(p);
    p.encoder_pending = false;
    p.encoder_generation += 1;
    return JNI_TRUE;
}

fn detachEncoderSurfaceLocked(p: *Pipe) void {
    if (p.display != c.EGL_NO_DISPLAY and p.context != c.EGL_NO_CONTEXT and p.pbuffer != c.EGL_NO_SURFACE) {
        _ = makePbufferCurrent(p);
        releaseRecordingFrameQueueLocked(p);
    } else {
        resetRecordingFrameQueueLocked(p);
    }
    if (p.encoder_surface != c.EGL_NO_SURFACE) {
        if (p.current_surface == p.encoder_surface) clearCurrent(p);
        _ = c.eglDestroySurface(p.display, p.encoder_surface);
        p.encoder_surface = c.EGL_NO_SURFACE;
    }
    if (p.encoder_window) |w| {
        c.ANativeWindow_release(w);
        p.encoder_window = null;
    }
    p.encoder_generation = 0;
    p.encoder_frame_index = 0;
    p.encoder_pending = false;
    p.encoder_swap_interval_set = false;
}

fn managedConfigFromRecording(p: *Pipe) ManagedSegmentConfig {
    return .{
        .output_dir = p.recording.managed_output_dir,
        .suffix = p.recording.managed_suffix,
        .width = p.recording.managed_width,
        .height = p.recording.managed_height,
        .bitrate = p.recording.managed_bitrate,
        .fps = p.recording.fps,
        .segment_duration_ms = p.recording.segment_duration_ms,
        .reserved_bytes = p.recording.managed_reserved_bytes,
        .available_bytes = p.recording.managed_available_bytes,
    };
}

fn managedFinalizeSegment(finalize: ManagedSegmentFinalize) i64 {
    if (finalize.writer_handle == 0) return finalize.config.available_bytes;
    const final_path_ptr: [*c]const u8 = &finalize.final_path;
    const ok = finishNativeSegmentWriterToPath(finalize.writer_handle, final_path_ptr);
    if (ok) {
        var deleted_count: i64 = 0;
        var deleted_bytes: i64 = 0;
        const available = cleanupStorageNative(&finalize.config.output_dir, finalize.config.reserved_bytes, finalize.config.available_bytes, final_path_ptr, &deleted_count, &deleted_bytes);
        if (deleted_count > 0) logi("managed cleanup deleted={d} freed={d} available={d}", .{ deleted_count, deleted_bytes, available });
        notifySegmentCacheFinalized(final_path_ptr);
        return available;
    } else {
        loge("managed segment finalize failed writer={d} path={s}", .{ finalize.writer_handle, final_path_ptr });
        return finalize.config.available_bytes;
    }
}

fn managedFinalizeSegmentKeepWriter(finalize: ManagedSegmentFinalize) i64 {
    if (finalize.writer_handle == 0) return finalize.config.available_bytes;
    const final_path_ptr: [*c]const u8 = &finalize.final_path;
    switch (finishNativeSegmentWriterSegmentOnly(finalize.writer_handle, final_path_ptr)) {
        .finalized => {
            var deleted_count: i64 = 0;
            var deleted_bytes: i64 = 0;
            const available = cleanupStorageNative(&finalize.config.output_dir, finalize.config.reserved_bytes, finalize.config.available_bytes, final_path_ptr, &deleted_count, &deleted_bytes);
            if (deleted_count > 0) logi("camera cleanup deleted={d} freed={d} available={d}", .{ deleted_count, deleted_bytes, available });
            notifySegmentCacheFinalized(final_path_ptr);
            return available;
        },
        .skipped_empty => {
            logd("camera segment skipped empty writer={d} path={s}", .{ finalize.writer_handle, final_path_ptr });
            return finalize.config.available_bytes;
        },
        .failed => {
            loge("camera segment finalize failed writer={d} path={s}", .{ finalize.writer_handle, final_path_ptr });
            return finalize.config.available_bytes;
        },
    }
}

fn managedCreateStartSegment(config: ManagedSegmentConfig, wall_clock_ms: i64, out_final_path: *[1024:0]u8) c.jlong {
    const writer_handle = createNativeSegmentWriterForMime(config.width, config.height, config.fps, config.bitrate, "video/avc");
    if (writer_handle == 0) return 0;
    if (!startNativeSegmentWriter(writer_handle, &config.output_dir, &config.suffix, wall_clock_ms, out_final_path)) {
        _ = releaseNativeSegmentWriterHandle(writer_handle);
        return 0;
    }
    if (!writer_mod.startAsyncDrain(writer_handle)) {
        _ = releaseNativeSegmentWriterHandle(writer_handle);
        return 0;
    }
    return writer_handle;
}

fn managedAttachPreparedSegmentLocked(p: *Pipe, input_window: *c.ANativeWindow, final_path: [*c]const u8) bool {
    if (!setRecordingThumbnailPathForVideo(p, final_path)) {
        c.ANativeWindow_release(input_window);
        return false;
    }
    return attachEncoderWindowLocked(p, input_window) == JNI_TRUE;
}

fn submitManagedFinalize(finalize: ManagedSegmentFinalize, drain_after_submit: bool) void {
    if (finalize.writer_handle == 0) return;
    if (!finalize_queue.submit(finalize)) {
        finalize_queue.recordFallback();
        _ = managedFinalizeSegment(finalize);
    }
    if (drain_after_submit) _ = finalize_queue.drain();
}

fn managedSwitchSegment(handle: c.jlong) bool {
    var config: ManagedSegmentConfig = .{};
    var old_finalize: ManagedSegmentFinalize = .{};
    var segment_wall: i64 = 0;
    if (lockPipeForHandle(handle)) |p| {
        defer unlockPipe(p);
        if (!p.recording.managed_native or p.recording.managed_writer_handle == 0 or !p.recording.recording) return false;
        config = managedConfigFromRecording(p);
        old_finalize = .{
            .writer_handle = p.recording.managed_writer_handle,
            .final_path = p.recording.managed_last_final_path,
            .start_ms = p.recording.managed_last_final_start_ms,
            .end_ms = p.recording.next_segment_wall_clock_ms,
            .config = config,
        };
        segment_wall = p.recording.next_segment_wall_clock_ms;
    } else return false;

    var new_final_path: [1024:0]u8 = [_:0]u8{0} ** 1024;
    const next_writer = managedCreateStartSegment(config, segment_wall, &new_final_path);
    if (next_writer == 0) return false;
    const input_window = acquireWriterInputWindow(next_writer) orelse {
        _ = releaseNativeSegmentWriterHandle(next_writer);
        return false;
    };

    var attached = false;
    var input_window_consumed = false;
    if (lockPipeForHandle(handle)) |p| {
        defer unlockPipe(p);
        if (!p.releasing and p.recording.managed_native and p.recording.recording and p.recording.managed_writer_handle == old_finalize.writer_handle) {
            input_window_consumed = true;
            attached = managedAttachPreparedSegmentLocked(p, input_window, &new_final_path);
            if (attached) {
                p.recording.managed_writer_handle = next_writer;
                p.recording_worker_writer_handle = next_writer;
                p.recording.segment_index += 1;
                p.recording.next_segment_wall_clock_ms = segment_wall + p.recording.segment_duration_ms;
                p.recording.encoder_segment_start_steady_ms = nowMs();
                p.recording.last_presentation_time_ns = -1;
                p.recording.managed_last_final_path = new_final_path;
                p.recording.managed_last_final_start_ms = segment_wall;
                p.recording.managed_last_final_end_ms = 0;
            }
        }
    }
    if (!attached) {
        if (!input_window_consumed) c.ANativeWindow_release(input_window);
        _ = releaseNativeSegmentWriterHandle(next_writer);
        return false;
    }

    var available: i64 = old_finalize.config.available_bytes;
    const finalized_async = finalize_queue.submit(old_finalize);
    if (!finalized_async) {
        finalize_queue.recordFallback();
        available = managedFinalizeSegment(old_finalize);
    }
    if (lockPipeForHandle(handle)) |p| {
        defer unlockPipe(p);
        if (!finalized_async and p.recording.managed_native and p.recording.managed_writer_handle == next_writer) p.recording.managed_available_bytes = available;
    }
    return true;
}

fn finishNativeSegmentWriterToPath(writer_handle: c.jlong, final_chars: [*c]const u8) bool {
    return writer_mod.finishToPath(writer_handle, final_chars);
}

fn finishNativeSegmentWriterSegmentOnly(writer_handle: c.jlong, final_chars: [*c]const u8) writer_mod.SegmentFinishResult {
    return writer_mod.finishSegment(writer_handle, final_chars);
}

fn releaseNativeSegmentWriterHandle(writer_handle: c.jlong) bool {
    return writer_mod.releaseHandle(writer_handle);
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_createNativeCameraPreview(env: [*c]c.JNIEnv, _: c.jobject, camera_id: c.jstring, surface: c.jobject, pipe_handle: c.jlong, input_index: c.jint, fps_range_lower: c.jint, fps_range_upper: c.jint) callconv(.c) c.jlong {
    if (camera_id == null or surface == null or pipe_handle == 0 or input_index < 0 or input_index >= 4) {
        setError("invalid native camera args", .{});
        return 0;
    }
    if (lockPipeForHandle(pipe_handle)) |p| {
        const i: usize = @intCast(input_index);
        const input_ready = p.input[i].surface_texture_native != null and p.input[i].texture != 0;
        unlockPipe(p);
        if (!input_ready) {
            setError("native camera input not ready pipe={d} input={d}", .{ pipe_handle, input_index });
            return 0;
        }
    } else return 0;
    const camera_id_chars = env.*[0].GetStringUTFChars.?(env, camera_id, null) orelse {
        setError("native camera id unavailable", .{});
        return 0;
    };
    defer env.*[0].ReleaseStringUTFChars.?(env, camera_id, camera_id_chars);

    var cam = NativeCameraPreview{};
    cam.pipe_handle = pipe_handle;
    cam.input_index = input_index;
    if (fps_range_lower > 0 and fps_range_upper >= fps_range_lower) {
        cam.fps_range_lower = fps_range_lower;
        cam.fps_range_upper = fps_range_upper;
    }
    cam.manager = c.ACameraManager_create() orelse {
        setError("ACameraManager_create failed", .{});
        return 0;
    };
    cam.window = c.ANativeWindow_fromSurface(env, surface) orelse {
        releaseNativeCameraResources(&cam);
        setError("native camera window unavailable", .{});
        return 0;
    };
    var device: ?*c.ACameraDevice = null;
    const status = c.ACameraManager_openCamera(cam.manager.?, camera_id_chars, &g_native_camera_device_callbacks, &device);
    if (status != c.ACAMERA_OK or device == null) {
        releaseNativeCameraResources(&cam);
        setError("ACameraManager_openCamera failed status={d}", .{status});
        return 0;
    }
    cam.device = device;

    if (!configureNativeCameraSessionLocked(&cam)) {
        releaseNativeCameraResources(&cam);
        return 0;
    }

    lockGlobal();
    defer unlockGlobal();
    var slot_index: ?usize = null;
    for (0..MAX_NATIVE_CAMERAS) |i| {
        if (!g_native_camera_used[i]) {
            slot_index = i;
            break;
        }
    }
    const index = slot_index orelse {
        releaseNativeCameraResources(&cam);
        setError("no free native camera slots", .{});
        return 0;
    };
    const handle = g_next_native_camera_handle;
    g_next_native_camera_handle += 1;
    cam.handle = handle;
    g_native_camera_used[index] = true;
    g_native_cameras[index] = cam;
    logi("NDK camera preview started handle={d} singleStream pipe={d} input={d}", .{ handle, pipe_handle, input_index });
    return handle;
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_releaseNativeCameraPreview(_: [*c]c.JNIEnv, _: c.jobject, camera_handle: c.jlong) callconv(.c) c.jboolean {
    lockGlobal();
    var camera: ?*NativeCameraPreview = null;
    var camera_index: usize = 0;
    for (0..MAX_NATIVE_CAMERAS) |i| {
        if (!g_native_camera_used[i] or g_native_cameras[i].handle != camera_handle) continue;
        g_native_cameras[i].handle = 0;
        camera = &g_native_cameras[i];
        camera_index = i;
        break;
    }
    unlockGlobal();
    const cam = camera orelse {
        setError("native camera release missing handle", .{});
        return JNI_FALSE;
    };
    lockNativeCamera(cam);
    releaseNativeCameraResources(cam);
    unlockNativeCamera(cam);
    lockGlobal();
    if (g_native_camera_used[camera_index] and &g_native_cameras[camera_index] == cam and g_native_cameras[camera_index].handle == 0) {
        g_native_cameras[camera_index] = NativeCameraPreview{};
        g_native_camera_used[camera_index] = false;
    }
    unlockGlobal();
    return JNI_TRUE;
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_getMetricsSnapshot(env: [*c]c.JNIEnv, _: c.jobject, handle: c.jlong) callconv(.c) c.jlongArray {
    var values = [_]c.jlong{0} ** METRICS_SNAPSHOT_LEN;
    if (tryLockPipeForHandleBounded(handle, 2)) |p| {
        values[0] = p.preview_render_count;
        values[1] = p.encoder_render_count;
        values[2] = p.encoder_drop_count;
        values[3] = p.no_surface_count;
        values[4] = p.last_render_ms;
        values[5] = p.recording.requested_frames;
        values[6] = p.recording.rendered_frames;
        values[7] = p.recording.dropped_frames;
        values[8] = p.recording.segment_index;
        values[9] = if (p.recording.segment_switch_pending) 1 else 0;
        values[10] = p.recording.pending_segment_index;
        values[11] = p.recording.next_segment_wall_clock_ms;
        values[12] = p.encoder_signal_count;
        values[13] = p.encoder_scheduled_count;
        values[14] = p.encoder_coalesced_count;
        values[15] = p.preview_max_fps;
        values[16] = p.preview_min_interval_ms;
        values[17] = p.recording.encoded_samples;
        values[18] = if (p.encoder_pending) 1 else 0;
        values[19] = p.recording.generation;
        for (0..4) |i| {
            const base = 20 + i * 7;
            values[base] = @max(p.input[i].frame_signal_count, p.input[i].update_count);
            values[base + 1] = p.input[i].preview_scheduled_count;
            values[base + 2] = p.input[i].preview_delayed_count;
            values[base + 3] = p.input[i].preview_coalesced_count;
            values[base + 4] = p.input[i].update_count;
            values[base + 5] = p.input[i].preview_render_count;
            values[base + 6] = p.input[i].preview_drop_count;

            const input_base = 80 + i * 8;
            values[input_base] = p.input[i].frame_generation;
            values[input_base + 1] = p.input[i].latched_generation;
            values[input_base + 2] = p.input[i].preview_generation;
            values[input_base + 3] = p.input[i].encoder_generation;
            values[input_base + 4] = if (p.input[i].has_latched_frame) 1 else 0;
            values[input_base + 5] = if (p.input[i].dirty) 1 else 0;
            values[input_base + 6] = if (p.input[i].surface_texture_native != null and p.input[i].texture != 0) 1 else 0;
            values[input_base + 7] = p.input[i].update_count;
        }
        values[48] = if (p.recording_worker_running) 1 else 0;
        values[49] = if (p.recording_worker_paused_for_segment) 1 else 0;
        values[50] = p.recording_worker_writer_handle;
        values[51] = p.recording_worker_generation;
        values[52] = if (p.recording.thumbnail_path_set) 1 else 0;
        values[53] = if (p.recording.thumbnail_written) 1 else 0;
        values[64] = p.pipe_lock_acquire_count;
        values[65] = p.pipe_lock_wait_total_ms;
        values[66] = p.pipe_lock_wait_max_ms;
        values[67] = p.pipe_try_lock_success_count;
        values[68] = @atomicLoad(i64, &p.pipe_try_lock_fail_count, .monotonic);
        values[69] = p.render_command_drop_count;
        values[70] = p.render_command_applied_count;
        values[71] = p.preview_worker_next_deadline_ms;
        values[72] = p.recording_frame_queue_produced_count;
        values[73] = p.recording_frame_queue_consumed_count;
        values[74] = p.recording_frame_queue_drop_count;
        values[75] = @intCast(p.recording_frame_queue_count);
        values[76] = p.recording_frame_queue_max_depth;
        values[77] = p.recording_frame_queue_fallback_count;
        values[78] = p.recording_frame_queue_fbo_recreate_count;
        values[79] = p.recording_frame_queue_next_capture_ms;
        values[METRICS_COMPOSITE_PREVIEW_FPS_MILLI] = p.composite_preview_fps_milli;
        unlockPipe(p);
        storeMetricsCache(handle, &values);
    } else {
        _ = loadMetricsCache(handle, &values);
    }
    const finalize_metrics = finalize_queue.snapshotMetrics();
    values[56] = @intCast(finalize_metrics.depth);
    values[57] = @intCast(finalize_metrics.active);
    values[58] = if (finalize_metrics.running) 1 else 0;
    values[59] = finalize_metrics.last_available_bytes;
    values[60] = finalize_metrics.submitted_count;
    values[61] = finalize_metrics.completed_count;
    values[62] = finalize_metrics.fallback_count;
    values[63] = if (finalize_metrics.accepting) 1 else 0;
    const result = env.*[0].NewLongArray.?(env, values.len);
    if (result != null) env.*[0].SetLongArrayRegion.?(env, result, 0, values.len, &values);
    return result;
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_createCompositor(_: [*c]c.JNIEnv, _: c.jobject, width: c.jint, height: c.jint) callconv(.c) c.jlong {
    lockGlobal();
    var slot: ?usize = null;
    for (0..MAX_PIPES) |i| {
        if (!g_used[i]) {
            g_pipes[i] = Pipe{};
            g_pipes[i].width = width;
            g_pipes[i].height = height;
            g_used[i] = true;
            slot = i;
            break;
        }
    }
    unlockGlobal();

    const i = slot orelse {
        setError("no free native pipe slots", .{});
        return 0;
    };
    const p = &g_pipes[i];
    lockPipe(p);
    const ok = initEgl(p);
    if (ok) updateEncoderLayout(p);
    unlockPipe(p);
    if (!ok) {
        lockGlobal();
        g_used[i] = false;
        g_pipes[i] = Pipe{};
        unlockGlobal();
        return 0;
    }

    lockGlobal();
    const handle = g_next_handle;
    g_next_handle += 1;
    p.handle = handle;
    unlockGlobal();
    return handle;
}
export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_createOesTexture(_: [*c]c.JNIEnv, _: c.jobject, handle: c.jlong, index: c.jint) callconv(.c) c.jint {
    const p = lockPipeForHandle(handle) orelse return 0;
    defer unlockPipe(p);
    if (p.releasing or index < 0 or index >= 4 or !initEgl(p) or !makePbufferCurrent(p)) return 0;
    const i: usize = @intCast(index);
    if (p.input[i].texture != 0) {
        c.glDeleteTextures(1, &p.input[i].texture);
        p.input[i].texture = 0;
    }
    var tex: c.GLuint = 0;
    c.glGenTextures(1, &tex);
    if (tex == 0) {
        setError("glGenTextures returned 0", .{});
        clearCurrent(p);
        return 0;
    }
    c.glBindTexture(GL_TEXTURE_EXTERNAL_OES, tex);
    c.glTexParameteri(GL_TEXTURE_EXTERNAL_OES, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    c.glTexParameteri(GL_TEXTURE_EXTERNAL_OES, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    c.glTexParameteri(GL_TEXTURE_EXTERNAL_OES, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(GL_TEXTURE_EXTERNAL_OES, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    if (glError("createOesTexture")) |e| {
        setErrorSlice(e);
        c.glDeleteTextures(1, &tex);
        clearCurrent(p);
        return 0;
    }
    p.input[i].texture = tex;
    clearCurrent(p);
    logd("created OES texture index={d} tex={d}", .{ index, tex });
    return @intCast(tex);
}
export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_destroyOesInput(env: [*c]c.JNIEnv, _: c.jobject, handle: c.jlong, index: c.jint) callconv(.c) c.jboolean {
    const p = lockPipeForHandle(handle) orelse return JNI_FALSE;
    defer unlockPipe(p);
    if (index < 0 or index >= 4) return JNI_FALSE;
    resetInput(env, p, @intCast(index), true);
    logd("destroyed OES input index={d}", .{index});
    return JNI_TRUE;
}
export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_createOesInput(env: [*c]c.JNIEnv, _: c.jobject, handle: c.jlong, index: c.jint, surface_texture: c.jobject) callconv(.c) c.jboolean {
    const p = lockPipeForHandle(handle) orelse return JNI_FALSE;
    defer unlockPipe(p);
    if (p.releasing or index < 0 or index >= 4 or surface_texture == null) return JNI_FALSE;
    const i: usize = @intCast(index);
    resetInput(env, p, i, false);
    const native_st = c.ASurfaceTexture_fromSurfaceTexture(env, surface_texture) orelse {
        setErrorSlice("ASurfaceTexture_fromSurfaceTexture failed");
        return JNI_FALSE;
    };
    p.input[i].surface_texture = env.*[0].NewGlobalRef.?(env, surface_texture);
    p.input[i].surface_texture_native = native_st;
    p.input[i].dirty = false;
    p.input[i].has_latched_frame = false;
    p.input[i].preview_pending = false;
    p.input[i].frame_generation = 0;
    p.input[i].latched_generation = 0;
    p.input[i].preview_generation = 0;
    p.input[i].encoder_generation = 0;
    logd("created OES input index={d}", .{index});
    return JNI_TRUE;
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_markOesFrameAvailable(_: [*c]c.JNIEnv, _: c.jobject, handle: c.jlong, index: c.jint) callconv(.c) c.jboolean {
    if (handle == 0 or index < 0 or index >= 4) return JNI_FALSE;
    const i: usize = @intCast(index);
    lockGlobal();
    const p = getPipe(handle) orelse {
        unlockGlobal();
        return JNI_FALSE;
    };
    _ = @atomicRmw(i64, &p.pending_frame_signal_counts[i], .Add, 1, .monotonic);
    _ = @atomicRmw(u32, &p.pending_frame_mask, .Or, @as(u32, 1) << @intCast(i), .release);
    unlockGlobal();
    return JNI_TRUE;
}

fn detachPreviewSurfaceIndexLocked(p: *Pipe, i: usize) void {
    if (i >= 4) return;
    for (0..MAX_PREVIEW_TARGETS) |t| {
        detachPreviewSurfaceTargetLocked(p, i, t);
    }
    p.input[i].preview_pending = false;
}

fn detachPreviewSurfaceTargetLocked(p: *Pipe, i: usize, target: usize) void {
    if (i >= 4 or target >= MAX_PREVIEW_TARGETS) return;
    if (p.preview_surface[i][target] != c.EGL_NO_SURFACE) {
        if (p.current_surface == p.preview_surface[i][target]) clearCurrent(p);
        _ = c.eglDestroySurface(p.display, p.preview_surface[i][target]);
        p.preview_surface[i][target] = c.EGL_NO_SURFACE;
    }
    if (p.preview_window[i][target]) |w| {
        c.ANativeWindow_release(w);
        p.preview_window[i][target] = null;
    }
    p.preview_window_width[i][target] = 0;
    p.preview_window_height[i][target] = 0;
    p.preview_swap_interval_set[i][target] = false;
    p.preview_use_blind_spot_fisheye[i][target] = false;
    p.preview_rotation[i][target] = 0;
    p.preview_correction[i][target] = PreviewCorrection{};
}

fn attachPreviewWindowLocked(p: *Pipe, index: c.jint, window: ?*c.ANativeWindow, apply_fisheye: bool, apply_native_transform: bool, use_blind_spot_fisheye: bool) c.jboolean {
    return attachPreviewWindowTargetLocked(p, index, 0, window, apply_fisheye, apply_native_transform, use_blind_spot_fisheye, 0);
}

fn attachPreviewWindowTargetLocked(p: *Pipe, index: c.jint, target: usize, window: ?*c.ANativeWindow, apply_fisheye: bool, apply_native_transform: bool, use_blind_spot_fisheye: bool, rotation: i32) c.jboolean {
    if (p.releasing or index < 0 or index >= 4 or target >= MAX_PREVIEW_TARGETS or window == null or !initEgl(p)) {
        if (window) |w| c.ANativeWindow_release(w);
        return JNI_FALSE;
    }
    const i: usize = @intCast(index);
    const new_surface = c.eglCreateWindowSurface(p.display, p.config, window, null);
    if (new_surface == c.EGL_NO_SURFACE) {
        setErrorSlice(eglError("eglCreateWindowSurface preview failed"));
        if (window) |w| c.ANativeWindow_release(w);
        return JNI_FALSE;
    }
    detachPreviewSurfaceTargetLocked(p, i, target);
    p.preview_window[i][target] = window;
    p.preview_surface[i][target] = new_surface;
    p.preview_apply_fisheye[i][target] = apply_fisheye;
    p.preview_apply_native_transform[i][target] = apply_native_transform;
    p.preview_use_blind_spot_fisheye[i][target] = use_blind_spot_fisheye;
    p.preview_rotation[i][target] = rotation;
    const size = previewWindowSizeTargetLocked(p, i, target, true);
    updatePreviewLayoutTarget(p, index, target, size.width, size.height);
    logd("attached preview surface index={d} target={d} size={d}x{d} fisheye={d} blindSpotFisheye={d} nativeTransform={d} rotation={d}", .{ index, @as(i32, @intCast(target)), size.width, size.height, if (apply_fisheye) @as(i32, 1) else @as(i32, 0), if (use_blind_spot_fisheye) @as(i32, 1) else @as(i32, 0), if (apply_native_transform) @as(i32, 1) else @as(i32, 0), rotation });
    return JNI_TRUE;
}

fn detachCompositePreviewSurfaceLocked(p: *Pipe) void {
    if (p.composite_preview_surface != c.EGL_NO_SURFACE) {
        if (p.current_surface == p.composite_preview_surface) clearCurrent(p);
        _ = c.eglDestroySurface(p.display, p.composite_preview_surface);
        p.composite_preview_surface = c.EGL_NO_SURFACE;
    }
    if (p.composite_preview_window) |w| {
        c.ANativeWindow_release(w);
        p.composite_preview_window = null;
    }
    p.composite_preview_swap_interval_set = false;
    p.composite_preview_width = 0;
    p.composite_preview_height = 0;
    resetCompositePreviewFpsLocked(p);
}

fn attachCompositePreviewWindowLocked(p: *Pipe, window: ?*c.ANativeWindow) c.jboolean {
    if (p.releasing or window == null or !initEgl(p)) {
        if (window) |w| c.ANativeWindow_release(w);
        return JNI_FALSE;
    }
    if (p.composite_preview_surface != c.EGL_NO_SURFACE and p.composite_preview_window == window) {
        if (window) |w| c.ANativeWindow_release(w);
        logd("attach composite preview skipped: same native window already attached", .{});
        return JNI_TRUE;
    }
    const new_surface = c.eglCreateWindowSurface(p.display, p.config, window, null);
    if (new_surface == c.EGL_NO_SURFACE) {
        setErrorSlice(eglError("eglCreateWindowSurface composite preview failed"));
        if (window) |w| c.ANativeWindow_release(w);
        return JNI_FALSE;
    }
    detachCompositePreviewSurfaceLocked(p);
    p.composite_preview_window = window;
    p.composite_preview_surface = new_surface;
    const size = compositePreviewWindowSizeLocked(p, true);
    logd("attached composite preview surface size={d}x{d}", .{ size.width, size.height });
    return JNI_TRUE;
}

fn applyRenderCommandLocked(p: *Pipe, cmd: *RenderCommand) bool {
    const ok = switch (cmd.kind) {
        .none => true,
        .runtime_config => blk: {
            applyRuntimeConfigLocked(p, &cmd.runtime);
            break :blk true;
        },
        .set_preview_fps => blk: {
            applyPreviewFpsLocked(p, cmd.runtime.preview_fps);
            break :blk true;
        },
        .attach_preview => blk: {
            const window = cmd.window;
            cmd.window = null;
            break :blk attachPreviewWindowLocked(p, cmd.index, window, cmd.apply_fisheye, cmd.apply_native_transform, cmd.use_blind_spot_fisheye) == JNI_TRUE;
        },
        .detach_preview => blk: {
            if (cmd.index >= 0 and cmd.index < 4) detachPreviewSurfaceIndexLocked(p, @intCast(cmd.index));
            break :blk true;
        },
        .detach_previews => blk: {
            for (0..4) |i| {
                if ((cmd.indexes_mask & (@as(u8, 1) << @intCast(i))) != 0) detachPreviewSurfaceIndexLocked(p, i);
            }
            break :blk true;
        },
        .attach_composite_preview => blk: {
            const window = cmd.window;
            cmd.window = null;
            break :blk attachCompositePreviewWindowLocked(p, window) == JNI_TRUE;
        },
        .detach_composite_preview => blk: {
            detachCompositePreviewSurfaceLocked(p);
            break :blk true;
        },
        .attach_secondary_preview => blk: {
            const window = cmd.window;
            cmd.window = null;
            break :blk attachPreviewWindowTargetLocked(p, cmd.index, 1, window, cmd.apply_fisheye, cmd.apply_native_transform, cmd.use_blind_spot_fisheye, cmd.rotation) == JNI_TRUE;
        },
        .detach_secondary_preview => blk: {
            if (cmd.index >= 0 and cmd.index < 4) detachPreviewSurfaceTargetLocked(p, @intCast(cmd.index), 1);
            break :blk true;
        },
        .set_secondary_correction => blk: {
            if (cmd.index >= 0 and cmd.index < 4) {
                const i: usize = @intCast(cmd.index);
                p.preview_correction[i][1] = cmd.correction;
                // Force quad rebuild with new correction
                p.preview_quad_width[i][1] = 0;
                p.preview_quad_height[i][1] = 0;
            }
            break :blk true;
        },
        .update_watermark => uploadWatermarkPixelsLocked(p, cmd.watermark_pixels, cmd.watermark_width, cmd.watermark_height, cmd.watermark_x, cmd.watermark_y),
        .clear_watermark => clearWatermarkBitmapLocked(p),
    };
    releaseRenderCommandResources(cmd);
    p.render_command_applied_count += 1;
    return ok;
}

fn applyPendingRenderCommandsLocked(p: *Pipe) void {
    var applied: usize = 0;
    while (applied < MAX_RENDER_COMMANDS) : (applied += 1) {
        var cmd = RenderCommand{};
        if (!popRenderCommandLocked(p, &cmd)) return;
        const kind = cmd.kind;
        if (!applyRenderCommandLocked(p, &cmd)) {
            p.render_command_drop_count += 1;
            if (@mod(p.render_command_drop_count, 8) == 0) loge("render command failed kind={s}", .{@tagName(kind)});
        }
    }
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_attachCompositePreviewSurface(env: [*c]c.JNIEnv, _: c.jobject, handle: c.jlong, surface: c.jobject) callconv(.c) c.jboolean {
    if (surface == null) return JNI_FALSE;
    var cmd = RenderCommand{
        .kind = .attach_composite_preview,
        .window = c.ANativeWindow_fromSurface(env, surface),
    };
    if (cmd.window == null) {
        setError("composite preview window unavailable", .{});
        return JNI_FALSE;
    }
    defer releaseRenderCommandResources(&cmd);
    const p = lockPipeForHandle(handle) orelse return JNI_FALSE;
    defer unlockPipe(p);
    if (renderWorkerAcceptsCommandsLocked(p)) {
        return if (enqueueRenderCommandLocked(p, &cmd)) JNI_TRUE else JNI_FALSE;
    }
    const window = cmd.window;
    cmd.window = null;
    return attachCompositePreviewWindowLocked(p, window);
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_detachCompositePreviewSurface(_: [*c]c.JNIEnv, _: c.jobject, handle: c.jlong) callconv(.c) c.jboolean {
    const p = lockPipeForHandle(handle) orelse return JNI_FALSE;
    defer unlockPipe(p);
    var cmd = RenderCommand{ .kind = .detach_composite_preview };
    if (renderWorkerAcceptsCommandsLocked(p)) {
        return if (enqueueRenderCommandLocked(p, &cmd)) JNI_TRUE else JNI_FALSE;
    }
    detachCompositePreviewSurfaceLocked(p);
    return JNI_TRUE;
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_attachPreviewSurfaceWithMode(env: [*c]c.JNIEnv, _: c.jobject, handle: c.jlong, index: c.jint, surface: c.jobject, apply_fisheye: c.jboolean, apply_native_transform: c.jboolean, use_blind_spot_fisheye: c.jboolean) callconv(.c) c.jboolean {
    if (surface == null) return JNI_FALSE;
    var cmd = RenderCommand{
        .kind = .attach_preview,
        .index = index,
        .window = c.ANativeWindow_fromSurface(env, surface),
        .apply_fisheye = apply_fisheye == JNI_TRUE,
        .apply_native_transform = apply_native_transform == JNI_TRUE,
        .use_blind_spot_fisheye = use_blind_spot_fisheye == JNI_TRUE,
    };
    if (cmd.window == null) {
        setError("preview window unavailable", .{});
        return JNI_FALSE;
    }
    defer releaseRenderCommandResources(&cmd);
    const p = lockPipeForHandle(handle) orelse return JNI_FALSE;
    defer unlockPipe(p);
    if (renderWorkerAcceptsCommandsLocked(p)) {
        return if (enqueueRenderCommandLocked(p, &cmd)) JNI_TRUE else JNI_FALSE;
    }
    const window = cmd.window;
    cmd.window = null;
    return attachPreviewWindowLocked(p, index, window, cmd.apply_fisheye, cmd.apply_native_transform, cmd.use_blind_spot_fisheye);
}
export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_detachPreviewSurface(_: [*c]c.JNIEnv, _: c.jobject, handle: c.jlong, index: c.jint) callconv(.c) c.jboolean {
    const p = lockPipeForHandle(handle) orelse return JNI_FALSE;
    defer unlockPipe(p);
    if (index < 0 or index >= 4) return JNI_FALSE;
    var cmd = RenderCommand{ .kind = .detach_preview, .index = index };
    if (renderWorkerAcceptsCommandsLocked(p)) {
        return if (enqueueRenderCommandLocked(p, &cmd)) JNI_TRUE else JNI_FALSE;
    }
    detachPreviewSurfaceIndexLocked(p, @intCast(index));
    return JNI_TRUE;
}
export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_detachPreviewSurfaces(env: [*c]c.JNIEnv, _: c.jobject, handle: c.jlong, indexes: c.jintArray) callconv(.c) c.jboolean {
    const p = lockPipeForHandle(handle) orelse return JNI_FALSE;
    defer unlockPipe(p);
    if (indexes == null) return JNI_TRUE;
    const count = getArrayLen(env, indexes);
    const raw = env.*[0].GetIntArrayElements.?(env, indexes, null) orelse return JNI_FALSE;
    defer env.*[0].ReleaseIntArrayElements.?(env, indexes, raw, c.JNI_ABORT);
    var mask: u8 = 0;
    var n: c.jsize = 0;
    while (n < count) : (n += 1) {
        const index = raw[@intCast(n)];
        if (index < 0 or index >= 4) continue;
        mask |= (@as(u8, 1) << @intCast(index));
    }
    if (mask == 0) return JNI_TRUE;
    var cmd = RenderCommand{ .kind = .detach_previews, .indexes_mask = mask };
    if (renderWorkerAcceptsCommandsLocked(p)) {
        return if (enqueueRenderCommandLocked(p, &cmd)) JNI_TRUE else JNI_FALSE;
    }
    for (0..4) |i| if ((mask & (@as(u8, 1) << @intCast(i))) != 0) detachPreviewSurfaceIndexLocked(p, i);
    return JNI_TRUE;
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_attachSecondaryPreviewSurface(env: [*c]c.JNIEnv, _: c.jobject, handle: c.jlong, index: c.jint, surface: c.jobject, apply_fisheye: c.jboolean, apply_native_transform: c.jboolean, use_blind_spot_fisheye: c.jboolean, rotation: c.jint) callconv(.c) c.jboolean {
    if (surface == null) return JNI_FALSE;
    var cmd = RenderCommand{
        .kind = .attach_secondary_preview,
        .index = index,
        .target = 1,
        .window = c.ANativeWindow_fromSurface(env, surface),
        .apply_fisheye = apply_fisheye == JNI_TRUE,
        .apply_native_transform = apply_native_transform == JNI_TRUE,
        .use_blind_spot_fisheye = use_blind_spot_fisheye == JNI_TRUE,
        .rotation = rotation,
    };
    if (cmd.window == null) {
        setError("secondary preview window unavailable", .{});
        return JNI_FALSE;
    }
    defer releaseRenderCommandResources(&cmd);
    const p = lockPipeForHandle(handle) orelse return JNI_FALSE;
    defer unlockPipe(p);
    if (renderWorkerAcceptsCommandsLocked(p)) {
        return if (enqueueRenderCommandLocked(p, &cmd)) JNI_TRUE else JNI_FALSE;
    }
    const window = cmd.window;
    cmd.window = null;
    return attachPreviewWindowTargetLocked(p, index, 1, window, cmd.apply_fisheye, cmd.apply_native_transform, cmd.use_blind_spot_fisheye, rotation);
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_detachSecondaryPreviewSurface(_: [*c]c.JNIEnv, _: c.jobject, handle: c.jlong, index: c.jint) callconv(.c) c.jboolean {
    const p = lockPipeForHandle(handle) orelse return JNI_FALSE;
    defer unlockPipe(p);
    if (index < 0 or index >= 4) return JNI_FALSE;
    var cmd = RenderCommand{ .kind = .detach_secondary_preview, .index = index, .target = 1 };
    if (renderWorkerAcceptsCommandsLocked(p)) {
        return if (enqueueRenderCommandLocked(p, &cmd)) JNI_TRUE else JNI_FALSE;
    }
    detachPreviewSurfaceTargetLocked(p, @intCast(index), 1);
    return JNI_TRUE;
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_setSecondaryPreviewCorrection(_: [*c]c.JNIEnv, _: c.jobject, handle: c.jlong, index: c.jint, scale_x: c.jfloat, scale_y: c.jfloat, translate_x: c.jfloat, translate_y: c.jfloat, rotation: c.jfloat, mirror_h: c.jboolean, mirror_v: c.jboolean) callconv(.c) c.jboolean {
    if (index < 0 or index >= 4) return JNI_FALSE;
    var cmd = RenderCommand{
        .kind = .set_secondary_correction,
        .index = index,
        .correction = PreviewCorrection{
            .scale_x = scale_x,
            .scale_y = scale_y,
            .translate_x = translate_x,
            .translate_y = translate_y,
            .rotation = rotation,
            .mirror_h = mirror_h == JNI_TRUE,
            .mirror_v = mirror_v == JNI_TRUE,
        },
    };
    const p = lockPipeForHandle(handle) orelse return JNI_FALSE;
    defer unlockPipe(p);
    if (renderWorkerAcceptsCommandsLocked(p)) {
        return if (enqueueRenderCommandLocked(p, &cmd)) JNI_TRUE else JNI_FALSE;
    }
    const i: usize = @intCast(index);
    p.preview_correction[i][1] = cmd.correction;
    p.preview_quad_width[i][1] = 0;
    p.preview_quad_height[i][1] = 0;
    return JNI_TRUE;
}

fn stopCompositorWorkersForRelease(env: [*c]c.JNIEnv, obj: c.jobject, handle: c.jlong) void {
    var managed_recording = false;
    var recording_worker = false;
    var preview_worker = false;
    if (lockPipeForHandle(handle)) |p| {
        managed_recording = p.recording.managed_native or p.recording.managed_writer_handle != 0;
        recording_worker = p.recording_worker_running;
        preview_worker = p.preview_worker_running or p.preview_worker_thread != null;
        unlockPipe(p);
    } else return;

    if (managed_recording) {
        _ = Java_com_kooo_evcam_v2_nativebridge_GlesNative_stopManagedRecording(env, obj, handle, 2000, nowMs());
    } else if (recording_worker) {
        _ = stopRecordingWorkerNative(handle, 2000);
    }
    if (preview_worker) {
        _ = Java_com_kooo_evcam_v2_nativebridge_GlesNative_stopPreviewWorker(env, obj, handle, 2000);
    }
    if (lockPipeForHandle(handle)) |p| {
        defer unlockPipe(p);
        detachEncoderSurfaceLocked(p);
    }
}

export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_releaseCompositor(env: [*c]c.JNIEnv, _: c.jobject, handle: c.jlong) callconv(.c) void {
    clearMetricsCache(handle);
    if (lockPipeForHandle(handle)) |p| {
        p.releasing = true;
        unlockPipe(p);
    }
    stopCompositorWorkersForRelease(env, null, handle);

    lockGlobal();
    var pipe: ?*Pipe = null;
    var pipe_index: usize = 0;
    for (0..MAX_PIPES) |idx| {
        if (!g_used[idx] or g_pipes[idx].handle != handle) continue;
        pipe = &g_pipes[idx];
        pipe_index = idx;
        break;
    }
    if (pipe) |p| lockPipe(p);
    if (pipe != null and g_used[pipe_index] and g_pipes[pipe_index].handle == handle) g_pipes[pipe_index].handle = 0;
    unlockGlobal();

    const p = pipe orelse return;
    dropPendingRenderCommandsLocked(p);
    if (p.display != c.EGL_NO_DISPLAY) {
        _ = makePbufferCurrent(p);
        releaseRecordingFrameQueueLocked(p);
        for (0..4) |i| {
            for (0..MAX_PREVIEW_TARGETS) |t| {
                if (p.preview_surface[i][t] != c.EGL_NO_SURFACE) _ = c.eglDestroySurface(p.display, p.preview_surface[i][t]);
                p.preview_surface[i][t] = c.EGL_NO_SURFACE;
            }
            if (p.input[i].texture != 0) c.glDeleteTextures(1, &p.input[i].texture);
            p.input[i].texture = 0;
        }
        if (p.composite_preview_surface != c.EGL_NO_SURFACE) _ = c.eglDestroySurface(p.display, p.composite_preview_surface);
        p.composite_preview_surface = c.EGL_NO_SURFACE;
        if (p.encoder_surface != c.EGL_NO_SURFACE) _ = c.eglDestroySurface(p.display, p.encoder_surface);
        p.encoder_surface = c.EGL_NO_SURFACE;
        if (p.overlay_font_texture != 0) c.glDeleteTextures(1, &p.overlay_font_texture);
        p.overlay_font_texture = 0;
        if (p.texture_pos_vbo != 0) c.glDeleteBuffers(1, &p.texture_pos_vbo);
        if (p.texture_tex_vbo != 0) c.glDeleteBuffers(1, &p.texture_tex_vbo);
        p.texture_pos_vbo = 0;
        p.texture_tex_vbo = 0;
        releaseWatermarkTextureLocked(p);
        if (p.program != 0) c.glDeleteProgram(p.program);
        p.program = 0;
        if (p.overlay_program != 0) c.glDeleteProgram(p.overlay_program);
        p.overlay_program = 0;
        if (p.overlay_text_program != 0) c.glDeleteProgram(p.overlay_text_program);
        p.overlay_text_program = 0;
        if (p.texture_program != 0) c.glDeleteProgram(p.texture_program);
        p.texture_program = 0;
        clearCurrent(p);
        if (p.pbuffer != c.EGL_NO_SURFACE) _ = c.eglDestroySurface(p.display, p.pbuffer);
        p.pbuffer = c.EGL_NO_SURFACE;
        if (p.context != c.EGL_NO_CONTEXT) _ = c.eglDestroyContext(p.display, p.context);
        p.context = c.EGL_NO_CONTEXT;
        _ = c.eglTerminate(p.display);
        p.display = c.EGL_NO_DISPLAY;
        p.config = null;
        p.current_surface = c.EGL_NO_SURFACE;
    }
    for (0..4) |i| {
        if (p.input[i].surface_texture_native) |st| c.ASurfaceTexture_release(st);
        if (p.input[i].surface_texture != null) env.*[0].DeleteGlobalRef.?(env, p.input[i].surface_texture);
        p.input[i] = Input{};
        for (0..MAX_PREVIEW_TARGETS) |t| {
            if (p.preview_window[i][t]) |w| c.ANativeWindow_release(w);
            p.preview_window[i][t] = null;
        }
    }
    if (p.encoder_window) |w| c.ANativeWindow_release(w);
    p.encoder_window = null;
    if (p.composite_preview_window) |w| c.ANativeWindow_release(w);
    p.composite_preview_window = null;
    p.recording_worker_running = false;
    p.recording_worker_stop = true;
    p.recording_worker_paused_for_segment = false;
    p.recording_worker_writer_handle = 0;
    p.recording_worker_next_deadline_ms = 0;
    p.preview_worker_running = false;
    p.preview_worker_stop = true;
    p.preview_worker_next_deadline_ms = 0;
    p.preview_worker_thread = null;
    p.recording = RecordingState{};
    p.encoder_pending = false;

    unlockPipe(p);
    lockGlobal();
    if (g_used[pipe_index] and &g_pipes[pipe_index] == p and p.handle == 0) g_used[pipe_index] = false;
    unlockGlobal();
}
export fn Java_com_kooo_evcam_v2_nativebridge_GlesNative_getLastError(env: [*c]c.JNIEnv, _: c.jobject) callconv(.c) c.jstring {
    return newString(env, &g_last_error);
}
