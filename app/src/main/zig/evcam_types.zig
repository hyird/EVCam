const std = @import("std");
const c = @import("c");

pub const TAG = "EVCamGLES";
pub const MAX_PIPES = 8;
pub const EGL_RECORDABLE_ANDROID: c.EGLint = 0x3142;
pub const GL_TEXTURE_EXTERNAL_OES: c.GLenum = 0x8D65;
pub const JNI_TRUE: c.jboolean = 1;
pub const JNI_FALSE: c.jboolean = 0;
pub const JNI_ABORT: c.jint = 2;
pub const CHECK_RENDER_GL_ERROR = false;
pub const TICK_SHOULD_RENDER: c.jlong = 1;
pub const TICK_DROPPED: c.jlong = 2;
pub const TICK_SEGMENT_DUE: c.jlong = 4;
pub const TICK_DRAINED_SHIFT = 8;
pub const TICK_DRAINED_MASK: c.jlong = 0x00FF_FFFF;
pub const TICK_NEXT_INDEX_SHIFT = 32;
pub const WORKER_ERROR_THREAD_ATTACH: c.jlong = -10;
pub const WORKER_ERROR_TICK_RENDER_DRAIN: c.jlong = -11;
pub const MAX_NATIVE_WRITERS = 8;
pub const MAX_NATIVE_CAMERAS = 4;
pub const MAX_PREVIEW_TARGETS: usize = 2;
pub const COMPOSITE_PREVIEW_FPS_HISTORY: usize = 256;
pub const COMPOSITE_PREVIEW_FPS_WINDOW_MS: i64 = 1000;
pub const COLOR_FORMAT_SURFACE: i32 = 0x7F000789;
pub const O_RDWR_ANDROID: c_int = 2;
pub const O_RDONLY_ANDROID: c_int = 0;
pub const O_CREAT_ANDROID: c_int = 64;
pub const O_TRUNC_ANDROID: c_int = 512;
pub const SAMPLE_BUFFER_BYTES: usize = 8 * 1024 * 1024;
pub const THUMBNAIL_WIDTH: usize = 240;
pub const THUMBNAIL_HEIGHT: usize = 135;
pub const MAX_CLEANUP_FILES: usize = 4096;
pub const PLAYBACK_CACHE_BUFFER_BYTES: usize = 2 * 1024 * 1024;
pub const SEEK_SET_ANDROID: c_int = 0;
pub const SEEK_END_ANDROID: c_int = 2;

pub const NativeTm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: [*c]const u8,
};

pub const EglPresentationTimeAndroidFn = *const fn (c.EGLDisplay, c.EGLSurface, c.EGLnsecsANDROID) callconv(.c) c.EGLBoolean;

pub const NativeSegmentWriter = struct {
    lock: std.Io.Mutex = .init,
    handle: c.jlong = 0,
    codec: ?*c.AMediaCodec = null,
    muxer: ?*c.AMediaMuxer = null,
    input_window: ?*c.ANativeWindow = null,
    fd: c_int = -1,
    output_path: [1024:0]u8 = [_:0]u8{0} ** 1024,
    output_path_set: bool = false,
    track_index: c_int = -1,
    width: i32 = 0,
    height: i32 = 0,
    fps: i32 = 0,
    bitrate: i32 = 0,
    started: bool = false,
    muxer_started: bool = false,
    segment_first_pts_us: i64 = -1,
    segment_last_pts_us: i64 = -1,
    segment_samples: i64 = 0,
    writer_lock_wait_total_ms: i64 = 0,
    writer_lock_wait_max_ms: i64 = 0,
    drain_calls: i64 = 0,
    drain_samples: i64 = 0,
    drain_total_ms: i64 = 0,
    drain_max_ms: i64 = 0,
    muxer_write_total_ms: i64 = 0,
    muxer_write_max_ms: i64 = 0,
    async_drain_thread: ?std.Thread = null,
    async_drain_running: bool = false,
    async_drain_stop: bool = false,
    async_drain_pending: bool = false,
    async_drain_generation: c.jlong = 0,
    async_drained_samples: i64 = 0,
    async_drain_error_count: i64 = 0,
    async_drain_request_count: i64 = 0,
    async_drain_defer_count: i64 = 0,
};

pub const NativeCameraPreview = struct {
    lock: std.Io.Mutex = .init,
    handle: c.jlong = 0,
    manager: ?*c.ACameraManager = null,
    device: ?*c.ACameraDevice = null,
    session: ?*c.ACameraCaptureSession = null,
    pipe_handle: c.jlong = 0,
    input_index: c_int = -1,
    fps_range_lower: c_int = 0,
    fps_range_upper: c_int = 0,
    window: ?*c.ANativeWindow = null,
    outputs: ?*c.ACaptureSessionOutputContainer = null,
    output: ?*c.ACaptureSessionOutput = null,
    target: ?*c.ACameraOutputTarget = null,
    request: ?*c.ACaptureRequest = null,
    sequence_id: c_int = -1,
};

pub const Input = struct {
    surface_texture: c.jobject = null,
    surface_texture_native: ?*c.ASurfaceTexture = null,
    texture: c.GLuint = 0,
    dirty: bool = false,
    has_latched_frame: bool = false,
    preview_pending: bool = false,
    frame_generation: i64 = 0,
    latched_generation: i64 = 0,
    preview_generation: i64 = 0,
    encoder_generation: i64 = 0,
    dirty_count: i64 = 0,
    update_count: i64 = 0,
    frame_signal_count: i64 = 0,
    preview_scheduled_count: i64 = 0,
    preview_coalesced_count: i64 = 0,
    preview_delayed_count: i64 = 0,
    preview_render_count: i64 = 0,
    preview_drop_count: i64 = 0,
    preview_swap_ms: i64 = 0,
    last_preview_render_ms: i64 = 0,
    last_preview_error: i64 = 0,
};

pub const Quad = struct {
    verts: [8]c.GLfloat = [_]c.GLfloat{0} ** 8,
    tex: [8]c.GLfloat = [_]c.GLfloat{ 0, 0, 1, 0, 0, 1, 1, 1 },
};

pub const PreviewCorrection = struct {
    scale_x: f32 = 1.0,
    scale_y: f32 = 1.0,
    translate_x: f32 = 0.0,
    translate_y: f32 = 0.0,
    rotation: f32 = 0.0,
    mirror_h: bool = false,
    mirror_v: bool = false,
};

pub const OverlayBatch = struct {
    verts: [2048]c.GLfloat = [_]c.GLfloat{0} ** 2048,
    len: usize = 0,
};

pub const TexturedOverlayBatch = struct {
    verts: [4096]c.GLfloat = [_]c.GLfloat{0} ** 4096,
    tex: [4096]c.GLfloat = [_]c.GLfloat{0} ** 4096,
    len: usize = 0,
};

// Two slots are enough to decouple the composite-preview render from the
// encoder while avoiding an extra full-resolution RGBA frame of latency and
// memory pressure.
pub const RECORDING_FRAME_QUEUE_CAPACITY: usize = 2;

pub const RecordingFrameSlot = struct {
    texture: c.GLuint = 0,
    framebuffer: c.GLuint = 0,
    ready: bool = false,
    queued_for_encoder: bool = false,
    wall_clock_ms: i64 = 0,
    sequence: i64 = 0,
};

pub const RecordingState = struct {
    recording: bool = false,
    segment_switch_pending: bool = false,
    generation: c.jlong = 0,
    fps: i32 = 15,
    segment_index: i32 = 0,
    pending_segment_index: i32 = 0,
    segment_duration_ms: i64 = 60000,
    next_segment_wall_clock_ms: i64 = 0,
    pending_segment_wall_clock_ms: i64 = 0,
    requested_frames: i64 = 0,
    rendered_frames: i64 = 0,
    dropped_frames: i64 = 0,
    encoded_samples: i64 = 0,
    last_tick_steady_ms: i64 = 0,
    encoder_segment_start_steady_ms: i64 = 0,
    last_presentation_time_ns: i64 = -1,
    overlay_wall_clock_ms: i64 = 0,
    overlay_cached_second: i64 = -1,
    overlay_text: [24]u8 = [_]u8{0} ** 24,
    overlay_text_len: usize = 0,
    overlay_geometry_second: i64 = -1,
    overlay_geometry_width: i32 = 0,
    overlay_geometry_height: i32 = 0,
    overlay_bg_batch: OverlayBatch = OverlayBatch{},
    overlay_shadow_text_batch: TexturedOverlayBatch = TexturedOverlayBatch{},
    overlay_text_batch: TexturedOverlayBatch = TexturedOverlayBatch{},
    thumbnail_path: [1024:0]u8 = [_:0]u8{0} ** 1024,
    thumbnail_path_set: bool = false,
    thumbnail_written: bool = false,
    managed_native: bool = false,
    managed_writer_handle: c.jlong = 0,
    managed_output_dir: [1024:0]u8 = [_:0]u8{0} ** 1024,
    managed_suffix: [64:0]u8 = [_:0]u8{0} ** 64,
    managed_width: i32 = 0,
    managed_height: i32 = 0,
    managed_bitrate: i32 = 0,
    managed_reserved_bytes: i64 = 0,
    managed_available_bytes: i64 = 0,
    managed_last_final_path: [1024:0]u8 = [_:0]u8{0} ** 1024,
    managed_last_final_start_ms: i64 = 0,
    managed_last_final_end_ms: i64 = 0,
};

pub const ManagedSegmentConfig = struct {
    output_dir: [1024:0]u8 = [_:0]u8{0} ** 1024,
    suffix: [64:0]u8 = [_:0]u8{0} ** 64,
    width: i32 = 0,
    height: i32 = 0,
    bitrate: i32 = 0,
    fps: i32 = 15,
    segment_duration_ms: i64 = 60000,
    reserved_bytes: i64 = 0,
    available_bytes: i64 = 0,
};

pub const ManagedSegmentFinalize = struct {
    writer_handle: c.jlong = 0,
    final_path: [1024:0]u8 = [_:0]u8{0} ** 1024,
    start_ms: i64 = 0,
    end_ms: i64 = 0,
    config: ManagedSegmentConfig = .{},
};

pub const MAX_RENDER_COMMANDS: usize = 32;

pub const RenderCommandKind = enum(u8) {
    none,
    runtime_config,
    set_preview_fps,
    attach_preview,
    detach_preview,
    detach_previews,
    attach_composite_preview,
    detach_composite_preview,
    attach_secondary_preview,
    detach_secondary_preview,
    set_secondary_correction,
    update_watermark,
    clear_watermark,
};

pub const RenderRuntimeConfig = struct {
    width: i32 = 0,
    height: i32 = 0,
    preview_fps: i32 = 0,
    encoder_fps: i32 = 0,
    side_left_rotation: i32 = 270,
    side_right_rotation: i32 = 90,
    layout_mode: i32 = 0,
    fisheye_valid: bool = false,
    fisheye_enabled: [4]bool = [_]bool{false} ** 4,
    fisheye_k1: [4]f32 = [_]f32{0.35} ** 4,
    fisheye_k2: [4]f32 = [_]f32{-0.18} ** 4,
    fisheye_k3: [4]f32 = [_]f32{0.0} ** 4,
    fisheye_k4: [4]f32 = [_]f32{0.0} ** 4,
    fisheye_zoom: [4]f32 = [_]f32{1.0} ** 4,
    fisheye_center_x: [4]f32 = [_]f32{0.5} ** 4,
    fisheye_center_y: [4]f32 = [_]f32{0.5} ** 4,
    fisheye_fx: [4]f32 = [_]f32{1920.0} ** 4,
    fisheye_fy: [4]f32 = [_]f32{1536.0} ** 4,
    fisheye_source_width: [4]f32 = [_]f32{1920.0} ** 4,
    fisheye_source_height: [4]f32 = [_]f32{1536.0} ** 4,
    blind_spot_fisheye_enabled: [4]bool = [_]bool{false} ** 4,
    blind_spot_fisheye_k1: [4]f32 = [_]f32{0.35} ** 4,
    blind_spot_fisheye_k2: [4]f32 = [_]f32{-0.18} ** 4,
    blind_spot_fisheye_k3: [4]f32 = [_]f32{0.0} ** 4,
    blind_spot_fisheye_k4: [4]f32 = [_]f32{0.0} ** 4,
    blind_spot_fisheye_zoom: [4]f32 = [_]f32{1.0} ** 4,
    blind_spot_fisheye_center_x: [4]f32 = [_]f32{0.5} ** 4,
    blind_spot_fisheye_center_y: [4]f32 = [_]f32{0.5} ** 4,
    blind_spot_fisheye_fx: [4]f32 = [_]f32{1920.0} ** 4,
    blind_spot_fisheye_fy: [4]f32 = [_]f32{1536.0} ** 4,
    blind_spot_fisheye_source_width: [4]f32 = [_]f32{1920.0} ** 4,
    blind_spot_fisheye_source_height: [4]f32 = [_]f32{1536.0} ** 4,
};

pub const RenderCommand = struct {
    kind: RenderCommandKind = .none,
    runtime: RenderRuntimeConfig = .{},
    index: c.jint = -1,
    target: u8 = 0,
    indexes_mask: u8 = 0,
    window: ?*c.ANativeWindow = null,
    apply_fisheye: bool = true,
    apply_native_transform: bool = true,
    use_blind_spot_fisheye: bool = false,
    rotation: i32 = 0,
    correction: PreviewCorrection = PreviewCorrection{},
    watermark_pixels: ?*anyopaque = null,
    watermark_bytes: usize = 0,
    watermark_width: c.jint = 0,
    watermark_height: c.jint = 0,
    watermark_x: c.jint = 0,
    watermark_y: c.jint = 0,
};

pub const FinalizeQueue = struct {
    lock: std.Io.Mutex = .init,
    group: std.Io.Group = .init,
    active_count: usize = 0,
    group_pending: bool = false,
    accepting: bool = true,
    draining: bool = false,
    last_available_bytes: i64 = 0,
    submitted_count: i64 = 0,
    completed_count: i64 = 0,
    fallback_count: i64 = 0,
};

pub const Pipe = struct {
    lock: std.Io.Mutex = .init,
    command_lock: std.Io.Mutex = .init,
    handle: c.jlong = 0,
    releasing: bool = false,
    display: c.EGLDisplay = c.EGL_NO_DISPLAY,
    context: c.EGLContext = c.EGL_NO_CONTEXT,
    config: c.EGLConfig = null,
    pbuffer: c.EGLSurface = c.EGL_NO_SURFACE,
    current_surface: c.EGLSurface = c.EGL_NO_SURFACE,
    preview_surface: [4][MAX_PREVIEW_TARGETS]c.EGLSurface = [_][MAX_PREVIEW_TARGETS]c.EGLSurface{[_]c.EGLSurface{c.EGL_NO_SURFACE} ** MAX_PREVIEW_TARGETS} ** 4,
    preview_swap_interval_set: [4][MAX_PREVIEW_TARGETS]bool = [_][MAX_PREVIEW_TARGETS]bool{[_]bool{false} ** MAX_PREVIEW_TARGETS} ** 4,
    composite_preview_surface: c.EGLSurface = c.EGL_NO_SURFACE,
    composite_preview_swap_interval_set: bool = false,
    preview_apply_fisheye: [4][MAX_PREVIEW_TARGETS]bool = [_][MAX_PREVIEW_TARGETS]bool{[_]bool{true} ** MAX_PREVIEW_TARGETS} ** 4,
    preview_apply_native_transform: [4][MAX_PREVIEW_TARGETS]bool = [_][MAX_PREVIEW_TARGETS]bool{[_]bool{true} ** MAX_PREVIEW_TARGETS} ** 4,
    preview_use_blind_spot_fisheye: [4][MAX_PREVIEW_TARGETS]bool = [_][MAX_PREVIEW_TARGETS]bool{[_]bool{false} ** MAX_PREVIEW_TARGETS} ** 4,
    encoder_surface: c.EGLSurface = c.EGL_NO_SURFACE,
    encoder_swap_interval_set: bool = false,
    preview_window: [4][MAX_PREVIEW_TARGETS]?*c.ANativeWindow = [_][MAX_PREVIEW_TARGETS]?*c.ANativeWindow{[_]?*c.ANativeWindow{null} ** MAX_PREVIEW_TARGETS} ** 4,
    composite_preview_window: ?*c.ANativeWindow = null,
    encoder_window: ?*c.ANativeWindow = null,
    encoder_generation: c.jlong = 0,
    input: [4]Input = [_]Input{ Input{}, Input{}, Input{}, Input{} },
    encoder_quad: [4]Quad = [_]Quad{ Quad{}, Quad{}, Quad{}, Quad{} },
    preview_quad: [4][MAX_PREVIEW_TARGETS]Quad = [_][MAX_PREVIEW_TARGETS]Quad{[_]Quad{Quad{}} ** MAX_PREVIEW_TARGETS} ** 4,
    preview_quad_width: [4][MAX_PREVIEW_TARGETS]i32 = [_][MAX_PREVIEW_TARGETS]i32{[_]i32{0} ** MAX_PREVIEW_TARGETS} ** 4,
    preview_quad_height: [4][MAX_PREVIEW_TARGETS]i32 = [_][MAX_PREVIEW_TARGETS]i32{[_]i32{0} ** MAX_PREVIEW_TARGETS} ** 4,
    preview_window_width: [4][MAX_PREVIEW_TARGETS]i32 = [_][MAX_PREVIEW_TARGETS]i32{[_]i32{0} ** MAX_PREVIEW_TARGETS} ** 4,
    preview_window_height: [4][MAX_PREVIEW_TARGETS]i32 = [_][MAX_PREVIEW_TARGETS]i32{[_]i32{0} ** MAX_PREVIEW_TARGETS} ** 4,
    preview_rotation: [4][MAX_PREVIEW_TARGETS]i32 = [_][MAX_PREVIEW_TARGETS]i32{[_]i32{0} ** MAX_PREVIEW_TARGETS} ** 4,
    preview_correction: [4][MAX_PREVIEW_TARGETS]PreviewCorrection = [_][MAX_PREVIEW_TARGETS]PreviewCorrection{[_]PreviewCorrection{PreviewCorrection{}} ** MAX_PREVIEW_TARGETS} ** 4,
    composite_preview_width: i32 = 0,
    composite_preview_height: i32 = 0,
    config_version: i64 = 0,
    program: c.GLuint = 0,
    overlay_program: c.GLuint = 0,
    overlay_text_program: c.GLuint = 0,
    overlay_font_texture: c.GLuint = 0,
    texture_pos_vbo: c.GLuint = 0,
    texture_tex_vbo: c.GLuint = 0,
    watermark_texture: c.GLuint = 0,
    watermark_width: i32 = 0,
    watermark_height: i32 = 0,
    watermark_x: f32 = 0,
    watermark_y: f32 = 0,
    pos_loc: c.GLint = -1,
    tex_loc: c.GLint = -1,
    sampler_loc: c.GLint = -1,
    overlay_pos_loc: c.GLint = -1,
    overlay_color_loc: c.GLint = -1,
    overlay_text_pos_loc: c.GLint = -1,
    overlay_text_tex_loc: c.GLint = -1,
    overlay_text_sampler_loc: c.GLint = -1,
    overlay_text_color_loc: c.GLint = -1,
    texture_program: c.GLuint = 0,
    texture_pos_loc: c.GLint = -1,
    texture_tex_loc: c.GLint = -1,
    texture_sampler_loc: c.GLint = -1,
    fisheye_enabled_loc: c.GLint = -1,
    distortion_loc: c.GLint = -1,
    lens_loc: c.GLint = -1,
    opencv_intrinsics_loc: c.GLint = -1,
    width: i32 = 1280,
    height: i32 = 720,
    layout_mode: i32 = 0,
    side_left_rotation: i32 = 270,
    side_right_rotation: i32 = 90,
    overlay_enabled: bool = true,
    encoder_fps: i32 = 15,
    encoder_pending: bool = false,
    recording_worker_running: bool = false,
    recording_worker_stop: bool = false,
    recording_worker_paused_for_segment: bool = false,
    recording_worker_writer_handle: c.jlong = 0,
    recording_worker_last_event: c.jlong = 0,
    recording_worker_generation: c.jlong = 0,
    recording_worker_next_deadline_ms: i64 = 0,
    recording_frame_slots: [RECORDING_FRAME_QUEUE_CAPACITY]RecordingFrameSlot = [_]RecordingFrameSlot{RecordingFrameSlot{}} ** RECORDING_FRAME_QUEUE_CAPACITY,
    recording_frame_queue_indices: [RECORDING_FRAME_QUEUE_CAPACITY]usize = [_]usize{0} ** RECORDING_FRAME_QUEUE_CAPACITY,
    recording_frame_queue_head: usize = 0,
    recording_frame_queue_tail: usize = 0,
    recording_frame_queue_count: usize = 0,
    recording_frame_latest_index: c_int = -1,
    recording_frame_write_cursor: usize = 0,
    recording_frame_queue_width: i32 = 0,
    recording_frame_queue_height: i32 = 0,
    recording_frame_queue_next_capture_ms: i64 = 0,
    recording_frame_queue_sequence: i64 = 0,
    render_commands: [MAX_RENDER_COMMANDS]RenderCommand = [_]RenderCommand{RenderCommand{}} ** MAX_RENDER_COMMANDS,
    render_command_head: usize = 0,
    render_command_tail: usize = 0,
    render_command_count: usize = 0,
    preview_render_enabled: bool = true,
    preview_worker_running: bool = false,
    preview_worker_stop: bool = false,
    preview_worker_generation: c.jlong = 0,
    preview_worker_next_deadline_ms: i64 = 0,
    preview_worker_thread: ?std.Thread = null,
    pending_frame_mask: u32 = 0,
    pending_frame_signal_counts: [4]i64 = [_]i64{0} ** 4,
    recording: RecordingState = RecordingState{},
    encoder_frame_index: i64 = 0,
    encoder_signal_count: i64 = 0,
    encoder_scheduled_count: i64 = 0,
    encoder_coalesced_count: i64 = 0,
    render_count: i64 = 0,
    preview_render_count: i64 = 0,
    composite_preview_fps_history: [COMPOSITE_PREVIEW_FPS_HISTORY]i64 = [_]i64{0} ** COMPOSITE_PREVIEW_FPS_HISTORY,
    composite_preview_fps_head: usize = 0,
    composite_preview_fps_count: usize = 0,
    composite_preview_fps_milli: i64 = 0,
    encoder_render_count: i64 = 0,
    encoder_drop_count: i64 = 0,
    dropped_count: i64 = 0,
    no_surface_count: i64 = 0,
    last_render_ms: i64 = 0,
    preview_max_fps: i32 = 0,
    preview_min_interval_ms: i64 = 0,
    pipe_lock_acquire_count: i64 = 0,
    pipe_lock_wait_total_ms: i64 = 0,
    pipe_lock_wait_max_ms: i64 = 0,
    pipe_try_lock_success_count: i64 = 0,
    pipe_try_lock_fail_count: i64 = 0,
    render_command_drop_count: i64 = 0,
    render_command_applied_count: i64 = 0,
    recording_frame_queue_produced_count: i64 = 0,
    recording_frame_queue_consumed_count: i64 = 0,
    recording_frame_queue_drop_count: i64 = 0,
    recording_frame_queue_max_depth: i64 = 0,
    recording_frame_queue_fbo_recreate_count: i64 = 0,
    recording_frame_queue_fallback_count: i64 = 0,
    last_render_error: [128:0]u8 = initZ("OK"),
    fisheye_enabled: [4]bool = [_]bool{false} ** 4,
    fisheye_k1: [4]f32 = [_]f32{0.35} ** 4,
    fisheye_k2: [4]f32 = [_]f32{0.10} ** 4,
    fisheye_k3: [4]f32 = [_]f32{0.0} ** 4,
    fisheye_k4: [4]f32 = [_]f32{0.0} ** 4,
    fisheye_zoom: [4]f32 = [_]f32{1.15} ** 4,
    fisheye_center_x: [4]f32 = [_]f32{0.5} ** 4,
    fisheye_center_y: [4]f32 = [_]f32{0.5} ** 4,
    fisheye_fx: [4]f32 = [_]f32{1920.0} ** 4,
    fisheye_fy: [4]f32 = [_]f32{1536.0} ** 4,
    fisheye_source_width: [4]f32 = [_]f32{1920.0} ** 4,
    fisheye_source_height: [4]f32 = [_]f32{1536.0} ** 4,
    blind_spot_fisheye_enabled: [4]bool = [_]bool{false} ** 4,
    blind_spot_fisheye_k1: [4]f32 = [_]f32{0.35} ** 4,
    blind_spot_fisheye_k2: [4]f32 = [_]f32{0.10} ** 4,
    blind_spot_fisheye_k3: [4]f32 = [_]f32{0.0} ** 4,
    blind_spot_fisheye_k4: [4]f32 = [_]f32{0.0} ** 4,
    blind_spot_fisheye_zoom: [4]f32 = [_]f32{1.15} ** 4,
    blind_spot_fisheye_center_x: [4]f32 = [_]f32{0.5} ** 4,
    blind_spot_fisheye_center_y: [4]f32 = [_]f32{0.5} ** 4,
    blind_spot_fisheye_fx: [4]f32 = [_]f32{1920.0} ** 4,
    blind_spot_fisheye_fy: [4]f32 = [_]f32{1536.0} ** 4,
    blind_spot_fisheye_source_width: [4]f32 = [_]f32{1920.0} ** 4,
    blind_spot_fisheye_source_height: [4]f32 = [_]f32{1536.0} ** 4,
};

pub fn initZ(comptime s: []const u8) [128:0]u8 {
    var out: [128:0]u8 = [_:0]u8{0} ** 128;
    @memcpy(out[0..s.len], s);
    return out;
}
