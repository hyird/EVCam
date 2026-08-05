const std = @import("std");
const c = @import("c");
const types = @import("evcam_types.zig");
const files = @import("evcam_files.zig");
const storage = @import("evcam_storage.zig");
const playback_thumbnail = @import("evcam_playback_thumbnail.zig");

const TAG = types.TAG;
const JNI_TRUE = types.JNI_TRUE;
const JNI_FALSE = types.JNI_FALSE;
const PLAYBACK_CACHE_BUFFER_BYTES = types.PLAYBACK_CACHE_BUFFER_BYTES;

const PlaybackScanResult = storage.PlaybackScanResult;
const PlaybackCacheEntry = storage.PlaybackCacheEntry;
const PlaybackCacheBuildResult = storage.PlaybackCacheBuildResult;

extern fn malloc(size: usize) ?*anyopaque;
extern fn free(ptr: ?*anyopaque) void;

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

fn getArrayLen(env: [*c]c.JNIEnv, arr: anytype) c.jsize {
    return env.*[0].GetArrayLength.?(env, arr);
}

fn playbackCacheEntryNewerFirst(_: void, a: PlaybackCacheEntry, b: PlaybackCacheEntry) bool {
    return std.mem.order(u8, std.mem.sliceTo(&a.name, 0), std.mem.sliceTo(&b.name, 0)) == .gt;
}

fn sortPlaybackCacheEntries(entries: []PlaybackCacheEntry) void {
    if (entries.len < 2) return;
    std.mem.sort(PlaybackCacheEntry, entries, {}, playbackCacheEntryNewerFirst);
}

fn ensureThumbnails(env: [*c]c.JNIEnv, result: *PlaybackCacheBuildResult) void {
    const jni = playback_thumbnail.loadJni(env) orelse {
        logd("native playback thumbnail jni unavailable", .{});
        return;
    };
    defer playback_thumbnail.releaseJni(env, &jni);

    var generated: i64 = 0;
    for (result.entries[0..result.count]) |*entry| {
        if (entry.thumbnail_size > 0) continue;
        if (!playback_thumbnail.generateWithJni(env, &jni, &entry.path)) {
            logd("native playback thumbnail skipped path={s}", .{std.mem.sliceTo(&entry.path, 0)});
            continue;
        }
        var refreshed = PlaybackCacheEntry{};
        if (!storage.playbackEntryFromVideoPath(&refreshed, &entry.path) or refreshed.thumbnail_size <= 0) continue;
        entry.* = refreshed;
        generated += 1;
    }
    if (generated > 0) logi("native playback thumbnails generated={d}", .{generated});
}

fn scanDirsIntoPlaybackScan(env: [*c]c.JNIEnv, scan_dirs: c.jobjectArray, result: *PlaybackScanResult, comptime scanFn: fn (*PlaybackScanResult, [*c]const u8) void) void {
    const dir_count_jsize = getArrayLen(env, scan_dirs);
    var i: c.jsize = 0;
    while (i < dir_count_jsize and result.count < result.paths.len) : (i += 1) {
        const obj = env.*[0].GetObjectArrayElement.?(env, scan_dirs, i);
        if (obj == null) continue;
        defer env.*[0].DeleteLocalRef.?(env, obj);
        const chars = env.*[0].GetStringUTFChars.?(env, obj, null) orelse continue;
        defer env.*[0].ReleaseStringUTFChars.?(env, obj, chars);
        scanFn(result, chars);
    }
}

fn listPlaybackPaths(env: [*c]c.JNIEnv, scan_dirs: c.jobjectArray, comptime scanFn: fn (*PlaybackScanResult, [*c]const u8) void) c.jobjectArray {
    const string_class = env.*[0].FindClass.?(env, "java/lang/String") orelse return null;
    if (scan_dirs == null) return env.*[0].NewObjectArray.?(env, 0, string_class, null);
    const result_raw = malloc(@sizeOf(PlaybackScanResult)) orelse return env.*[0].NewObjectArray.?(env, 0, string_class, null);
    defer free(result_raw);
    const result: *PlaybackScanResult = @ptrCast(@alignCast(result_raw));
    result.* = PlaybackScanResult{};
    scanDirsIntoPlaybackScan(env, scan_dirs, result, scanFn);

    const arr = env.*[0].NewObjectArray.?(env, @intCast(result.count), string_class, null) orelse return null;
    var out_i: usize = 0;
    while (out_i < result.count) : (out_i += 1) {
        const s = env.*[0].NewStringUTF.?(env, &result.paths[out_i]);
        if (s != null) {
            env.*[0].SetObjectArrayElement.?(env, arr, @intCast(out_i), s);
            env.*[0].DeleteLocalRef.?(env, s);
        }
    }
    return arr;
}

pub fn listVideos(env: [*c]c.JNIEnv, scan_dirs: c.jobjectArray) c.jobjectArray {
    return listPlaybackPaths(env, scan_dirs, storage.scanPlaybackVideosNative);
}

pub fn listImages(env: [*c]c.JNIEnv, scan_dirs: c.jobjectArray) c.jobjectArray {
    return listPlaybackPaths(env, scan_dirs, storage.scanPlaybackImagesNative);
}

pub fn buildCacheJson(env: [*c]c.JNIEnv, scan_dirs: c.jobjectArray, ensure_thumbnails: bool) c.jstring {
    if (scan_dirs == null) return env.*[0].NewStringUTF.?(env, "[]");
    const dir_count_jsize = getArrayLen(env, scan_dirs);
    const result_raw = malloc(@sizeOf(PlaybackCacheBuildResult)) orelse return null;
    defer free(result_raw);
    const result: *PlaybackCacheBuildResult = @ptrCast(@alignCast(result_raw));
    result.* = PlaybackCacheBuildResult{};
    var i: c.jsize = 0;
    while (i < dir_count_jsize and result.count < result.entries.len) : (i += 1) {
        const obj = env.*[0].GetObjectArrayElement.?(env, scan_dirs, i);
        if (obj == null) continue;
        defer env.*[0].DeleteLocalRef.?(env, obj);
        const chars = env.*[0].GetStringUTFChars.?(env, obj, null) orelse continue;
        defer env.*[0].ReleaseStringUTFChars.?(env, obj, chars);
        storage.buildPlaybackCacheNative(result, chars);
    }
    if (ensure_thumbnails) ensureThumbnails(env, result);
    sortPlaybackCacheEntries(result.entries[0..result.count]);

    const raw = malloc(PLAYBACK_CACHE_BUFFER_BYTES) orelse return null;
    defer free(raw);
    const buffer: [*]u8 = @ptrCast(raw);
    var offset: usize = 0;
    if (!storage.appendJsonLiteral(buffer[0..PLAYBACK_CACHE_BUFFER_BYTES], &offset, "[")) return null;
    for (result.entries[0..result.count], 0..) |entry, idx| {
        if (idx > 0 and !storage.appendJsonLiteral(buffer[0..PLAYBACK_CACHE_BUFFER_BYTES], &offset, ",")) return null;
        if (!storage.appendPlaybackCacheEntryJson(buffer[0..PLAYBACK_CACHE_BUFFER_BYTES], &offset, &entry)) return null;
    }
    if (!storage.appendJsonLiteral(buffer[0..PLAYBACK_CACHE_BUFFER_BYTES], &offset, "]")) return null;
    if (offset >= PLAYBACK_CACHE_BUFFER_BYTES) return null;
    buffer[offset] = 0;
    return env.*[0].NewStringUTF.?(env, @ptrCast(buffer));
}

pub fn buildEntry(env: [*c]c.JNIEnv, video_path: c.jstring) c.jstring {
    if (video_path == null) return null;
    const chars = env.*[0].GetStringUTFChars.?(env, video_path, null) orelse return null;
    defer env.*[0].ReleaseStringUTFChars.?(env, video_path, chars);
    var entry = PlaybackCacheEntry{};
    if (!storage.playbackEntryFromVideoPath(&entry, chars)) return null;
    var buffer: [2048:0]u8 = [_:0]u8{0} ** 2048;
    var offset: usize = 0;
    if (!storage.appendPlaybackCacheEntryJson(buffer[0..], &offset, &entry)) return null;
    if (offset >= buffer.len) return null;
    buffer[offset] = 0;
    return env.*[0].NewStringUTF.?(env, &buffer);
}

pub fn ensureThumbnail(env: [*c]c.JNIEnv, video_path: c.jstring) c.jstring {
    if (video_path == null) return null;
    const chars = env.*[0].GetStringUTFChars.?(env, video_path, null) orelse return null;
    defer env.*[0].ReleaseStringUTFChars.?(env, video_path, chars);

    var target_path: [1024:0]u8 = [_:0]u8{0} ** 1024;
    if (!files.thumbnailPathForVideo(&target_path, chars)) return null;
    if (files.fileSize(&target_path) <= 0) {
        const jni = playback_thumbnail.loadJni(env) orelse {
            logd("native playback thumbnail jni unavailable path={s}", .{std.mem.span(chars)});
            return null;
        };
        defer playback_thumbnail.releaseJni(env, &jni);
        if (!playback_thumbnail.generateWithJni(env, &jni, chars)) {
            logd("native playback thumbnail ensure failed path={s}", .{std.mem.span(chars)});
            return null;
        }
    }
    if (files.fileSize(&target_path) <= 0) return null;
    return env.*[0].NewStringUTF.?(env, &target_path);
}

pub fn deleteVideoAndSidecars(env: [*c]c.JNIEnv, video_path: c.jstring) c.jboolean {
    if (video_path == null) return JNI_FALSE;
    const chars = env.*[0].GetStringUTFChars.?(env, video_path, null) orelse return JNI_FALSE;
    defer env.*[0].ReleaseStringUTFChars.?(env, video_path, chars);
    const deleted_video = files.deleteFile(chars);
    _ = files.deleteThumbnailSidecars(chars);
    return if (deleted_video > 0) JNI_TRUE else JNI_FALSE;
}

pub fn deleteVideosAndBuildCache(env: [*c]c.JNIEnv, video_paths: c.jobjectArray, scan_dirs: c.jobjectArray) c.jstring {
    if (video_paths != null) {
        const path_count = getArrayLen(env, video_paths);
        var i: c.jsize = 0;
        while (i < path_count) : (i += 1) {
            const obj = env.*[0].GetObjectArrayElement.?(env, video_paths, i);
            if (obj == null) continue;
            defer env.*[0].DeleteLocalRef.?(env, obj);
            const chars = env.*[0].GetStringUTFChars.?(env, obj, null) orelse continue;
            defer env.*[0].ReleaseStringUTFChars.?(env, obj, chars);
            _ = files.deleteFile(chars);
            _ = files.deleteThumbnailSidecars(chars);
        }
    }
    return buildCacheJson(env, scan_dirs, false);
}
