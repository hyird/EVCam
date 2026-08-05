const std = @import("std");

pub const Sink = struct {
    context: ?*anyopaque,
    writeFn: *const fn (?*anyopaque, []const u8) bool,
};

const HuffmanEntry = struct {
    code: u16 = 0,
    len: u8 = 0,
};

const ZIGZAG = [_]usize{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

const BASE_LUMA_Q = [_]u8{
    16, 11, 10, 16, 24,  40,  51,  61,
    12, 12, 14, 19, 26,  58,  60,  55,
    14, 13, 16, 24, 40,  57,  69,  56,
    14, 17, 22, 29, 51,  87,  80,  62,
    18, 22, 37, 56, 68,  109, 103, 77,
    24, 35, 55, 64, 81,  104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101,
    72, 92, 95, 98, 112, 100, 103, 99,
};

const BASE_CHROMA_Q = [_]u8{
    17, 18, 24, 47, 99, 99, 99, 99,
    18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
};

const DC_LUMA_BITS = [_]u8{ 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 };
const DC_LUMA_VALS = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };

const DC_CHROMA_BITS = [_]u8{ 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 };
const DC_CHROMA_VALS = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };

const AC_LUMA_BITS = [_]u8{ 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d };
const AC_LUMA_VALS = [_]u8{
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12,
    0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08,
    0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16,
    0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
    0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
    0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
    0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
    0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
    0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
    0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
    0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4,
    0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea,
    0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
};

const AC_CHROMA_BITS = [_]u8{ 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77 };
const AC_CHROMA_VALS = [_]u8{
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21,
    0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
    0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
    0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
    0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34,
    0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
    0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38,
    0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
    0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
    0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78,
    0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96,
    0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
    0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4,
    0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
    0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2,
    0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
    0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9,
    0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
};

comptime {
    std.debug.assert(sumBits(&DC_LUMA_BITS) == DC_LUMA_VALS.len);
    std.debug.assert(sumBits(&DC_CHROMA_BITS) == DC_CHROMA_VALS.len);
    std.debug.assert(sumBits(&AC_LUMA_BITS) == AC_LUMA_VALS.len);
    std.debug.assert(sumBits(&AC_CHROMA_BITS) == AC_CHROMA_VALS.len);
}

const DCT_C = [_]f64{
    0.7071067811865476, 1.0, 1.0, 1.0,
    1.0,                1.0, 1.0, 1.0,
};

const DCT_COS = [_][8]f64{
    .{ 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0 },
    .{ 0.9807852804032304, 0.8314696123025452, 0.5555702330196023, 0.19509032201612833, -0.1950903220161282, -0.555570233019602, -0.8314696123025453, -0.9807852804032304 },
    .{ 0.9238795325112867, 0.38268343236508984, -0.3826834323650897, -0.9238795325112867, -0.9238795325112868, -0.38268343236509034, 0.38268343236509, 0.9238795325112865 },
    .{ 0.8314696123025452, -0.1950903220161282, -0.9807852804032304, -0.5555702330196022, 0.5555702330196018, 0.9807852804032304, 0.19509032201612878, -0.8314696123025451 },
    .{ 0.7071067811865476, -0.7071067811865475, -0.7071067811865477, 0.7071067811865474, 0.7071067811865477, -0.7071067811865467, -0.7071067811865471, 0.7071067811865474 },
    .{ 0.5555702330196023, -0.9807852804032304, 0.1950903220161283, 0.8314696123025455, -0.831469612302545, -0.19509032201612803, 0.9807852804032307, -0.5555702330196015 },
    .{ 0.38268343236508984, -0.9238795325112868, 0.9238795325112865, -0.3826834323650899, -0.38268343236509056, 0.9238795325112864, -0.9238795325112866, 0.38268343236509 },
    .{ 0.19509032201612833, -0.5555702330196022, 0.8314696123025455, -0.9807852804032307, 0.9807852804032304, -0.8314696123025451, 0.5555702330196015, -0.19509032201612866 },
};

// The JPEG path is kept portable at the Zig source level.  On the arm64
// Android target these fixed-width vectors lower to Advanced SIMD, while
// other targets still get a correct scalarized implementation from Zig.
const Simd4 = @Vector(4, f64);
const Simd8 = @Vector(8, f64);

const Component = enum { y, cb, cr };

const BufferedWriter = struct {
    sink: *Sink,
    buffer: [512]u8 = undefined,
    len: usize = 0,

    fn init(sink: *Sink) BufferedWriter {
        return .{ .sink = sink };
    }

    fn flush(self: *BufferedWriter) bool {
        if (self.len == 0) return true;
        if (!self.sink.writeFn(self.sink.context, self.buffer[0..self.len])) return false;
        self.len = 0;
        return true;
    }

    fn byte(self: *BufferedWriter, value: u8) bool {
        if (self.len == self.buffer.len and !self.flush()) return false;
        self.buffer[self.len] = value;
        self.len += 1;
        return true;
    }

    fn bytes(self: *BufferedWriter, data: []const u8) bool {
        for (data) |value| {
            if (!self.byte(value)) return false;
        }
        return true;
    }

    fn u16be(self: *BufferedWriter, value: u16) bool {
        return self.byte(@truncate(value >> 8)) and self.byte(@truncate(value));
    }

    fn marker(self: *BufferedWriter, value: u8) bool {
        return self.byte(0xff) and self.byte(value);
    }
};

const BitWriter = struct {
    writer: *BufferedWriter,
    bits: u32 = 0,
    count: u8 = 0,

    fn writeBits(self: *BitWriter, code: u16, len: u8) bool {
        if (len == 0) return true;
        self.bits = (self.bits << @as(u5, @intCast(len))) | code;
        self.count += len;
        while (self.count >= 8) {
            const shift = self.count - 8;
            const value: u8 = @truncate(self.bits >> @as(u5, @intCast(shift)));
            if (!self.writer.byte(value)) return false;
            if (value == 0xff and !self.writer.byte(0x00)) return false;
            self.count = shift;
            self.bits &= lowMask(shift);
        }
        return true;
    }

    fn flush(self: *BitWriter) bool {
        if (self.count > 0) {
            const padding = 8 - self.count;
            const value: u8 = @truncate((self.bits << @as(u5, @intCast(padding))) | lowMask(padding));
            if (!self.writer.byte(value)) return false;
            if (value == 0xff and !self.writer.byte(0x00)) return false;
        }
        self.bits = 0;
        self.count = 0;
        return true;
    }
};

pub fn writeRgbJpeg(sink: *Sink, width: usize, height: usize, rgb: []const u8, quality: u8) bool {
    if (width == 0 or height == 0 or width > 65535 or height > 65535) return false;
    if (rgb.len < width * height * 3) return false;

    var luma_q = scaledQuantTable(&BASE_LUMA_Q, quality);
    var chroma_q = scaledQuantTable(&BASE_CHROMA_Q, quality);
    const dc_luma_huff = buildHuffmanTable(&DC_LUMA_BITS, &DC_LUMA_VALS);
    const ac_luma_huff = buildHuffmanTable(&AC_LUMA_BITS, &AC_LUMA_VALS);
    const dc_chroma_huff = buildHuffmanTable(&DC_CHROMA_BITS, &DC_CHROMA_VALS);
    const ac_chroma_huff = buildHuffmanTable(&AC_CHROMA_BITS, &AC_CHROMA_VALS);

    var writer = BufferedWriter.init(sink);
    if (!writeHeaders(&writer, width, height, &luma_q, &chroma_q)) return false;

    var bit_writer = BitWriter{ .writer = &writer };
    var prev_y: i32 = 0;
    var prev_cb: i32 = 0;
    var prev_cr: i32 = 0;
    var block_y: usize = 0;
    while (block_y < height) : (block_y += 8) {
        var block_x: usize = 0;
        while (block_x < width) : (block_x += 8) {
            if (!encodeBlock(&bit_writer, rgb, width, height, block_x, block_y, .y, &luma_q, &prev_y, &dc_luma_huff, &ac_luma_huff)) return false;
            if (!encodeBlock(&bit_writer, rgb, width, height, block_x, block_y, .cb, &chroma_q, &prev_cb, &dc_chroma_huff, &ac_chroma_huff)) return false;
            if (!encodeBlock(&bit_writer, rgb, width, height, block_x, block_y, .cr, &chroma_q, &prev_cr, &dc_chroma_huff, &ac_chroma_huff)) return false;
        }
    }

    if (!bit_writer.flush()) return false;
    if (!writer.marker(0xd9)) return false;
    return writer.flush();
}

fn writeHeaders(writer: *BufferedWriter, width: usize, height: usize, luma_q: *const [64]u8, chroma_q: *const [64]u8) bool {
    if (!writer.marker(0xd8)) return false;
    if (!writer.marker(0xe0)) return false;
    if (!writer.u16be(16)) return false;
    if (!writer.bytes("JFIF\x00")) return false;
    if (!writer.bytes(&[_]u8{ 1, 1, 0, 0, 1, 0, 1, 0, 0 })) return false;

    if (!writer.marker(0xdb)) return false;
    if (!writer.u16be(132)) return false;
    if (!writer.byte(0)) return false;
    for (ZIGZAG) |idx| if (!writer.byte(luma_q[idx])) return false;
    if (!writer.byte(1)) return false;
    for (ZIGZAG) |idx| if (!writer.byte(chroma_q[idx])) return false;

    if (!writer.marker(0xc0)) return false;
    if (!writer.u16be(17)) return false;
    if (!writer.byte(8)) return false;
    if (!writer.u16be(@intCast(height))) return false;
    if (!writer.u16be(@intCast(width))) return false;
    if (!writer.byte(3)) return false;
    if (!writer.bytes(&[_]u8{ 1, 0x11, 0, 2, 0x11, 1, 3, 0x11, 1 })) return false;

    if (!writeDht(writer, 0x00, &DC_LUMA_BITS, &DC_LUMA_VALS)) return false;
    if (!writeDht(writer, 0x10, &AC_LUMA_BITS, &AC_LUMA_VALS)) return false;
    if (!writeDht(writer, 0x01, &DC_CHROMA_BITS, &DC_CHROMA_VALS)) return false;
    if (!writeDht(writer, 0x11, &AC_CHROMA_BITS, &AC_CHROMA_VALS)) return false;

    if (!writer.marker(0xda)) return false;
    if (!writer.u16be(12)) return false;
    if (!writer.byte(3)) return false;
    if (!writer.bytes(&[_]u8{ 1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0 })) return false;
    return true;
}

fn writeDht(writer: *BufferedWriter, table_info: u8, bits: []const u8, values: []const u8) bool {
    if (!writer.marker(0xc4)) return false;
    if (!writer.u16be(@intCast(2 + 1 + 16 + values.len))) return false;
    if (!writer.byte(table_info)) return false;
    if (!writer.bytes(bits)) return false;
    return writer.bytes(values);
}

fn encodeBlock(
    bit_writer: *BitWriter,
    rgb: []const u8,
    width: usize,
    height: usize,
    block_x: usize,
    block_y: usize,
    component: Component,
    qtable: *const [64]u8,
    prev_dc: *i32,
    dc_huff: *const [256]HuffmanEntry,
    ac_huff: *const [256]HuffmanEntry,
) bool {
    var samples: [64]f64 = undefined;
    var y: usize = 0;
    while (y < 8) : (y += 1) {
        const src_y = @min(block_y + y, height - 1);
        var x: usize = 0;
        while (x < 8) : (x += 4) {
            var r: Simd4 = undefined;
            var g: Simd4 = undefined;
            var b: Simd4 = undefined;
            inline for (0..4) |lane| {
                const src_x = @min(block_x + x + lane, width - 1);
                const src = (src_y * width + src_x) * 3;
                r[lane] = @floatFromInt(rgb[src]);
                g[lane] = @floatFromInt(rgb[src + 1]);
                b[lane] = @floatFromInt(rgb[src + 2]);
            }
            const value: Simd4 = switch (component) {
                .y => @as(Simd4, @splat(0.299)) * r + @as(Simd4, @splat(0.587)) * g + @as(Simd4, @splat(0.114)) * b,
                .cb => @as(Simd4, @splat(128.0)) - @as(Simd4, @splat(0.168736)) * r - @as(Simd4, @splat(0.331264)) * g + @as(Simd4, @splat(0.5)) * b,
                .cr => @as(Simd4, @splat(128.0)) + @as(Simd4, @splat(0.5)) * r - @as(Simd4, @splat(0.418688)) * g - @as(Simd4, @splat(0.081312)) * b,
            };
            inline for (0..4) |lane| samples[y * 8 + x + lane] = value[lane] - 128.0;
        }
    }

    var coeffs: [64]i32 = undefined;
    fdctQuantize(&samples, qtable, &coeffs);
    const dc = coeffs[0];
    const diff = dc - prev_dc.*;
    prev_dc.* = dc;
    const dc_cat = magnitudeCategory(diff);
    if (!writeHuffman(bit_writer, dc_huff, dc_cat)) return false;
    if (dc_cat > 0 and !bit_writer.writeBits(magnitudeBits(diff, dc_cat), dc_cat)) return false;

    var zero_run: u8 = 0;
    var i: usize = 1;
    while (i < 64) : (i += 1) {
        const ac = coeffs[ZIGZAG[i]];
        if (ac == 0) {
            zero_run += 1;
            continue;
        }
        while (zero_run > 15) {
            if (!writeHuffman(bit_writer, ac_huff, 0xf0)) return false;
            zero_run -= 16;
        }
        const ac_cat = magnitudeCategory(ac);
        const symbol: u8 = (zero_run << 4) | ac_cat;
        if (!writeHuffman(bit_writer, ac_huff, symbol)) return false;
        if (!bit_writer.writeBits(magnitudeBits(ac, ac_cat), ac_cat)) return false;
        zero_run = 0;
    }
    if (zero_run > 0 and !writeHuffman(bit_writer, ac_huff, 0x00)) return false;
    return true;
}

fn fdctQuantize(samples: *const [64]f64, qtable: *const [64]u8, out: *[64]i32) void {
    var v: usize = 0;
    while (v < 8) : (v += 1) {
        var u: usize = 0;
        while (u < 8) : (u += 1) {
            var sum: f64 = 0.0;
            var y: usize = 0;
            while (y < 8) : (y += 1) {
                var sample_vec: Simd8 = undefined;
                var cos_x: Simd8 = undefined;
                inline for (0..8) |x| {
                    sample_vec[x] = samples[y * 8 + x];
                    cos_x[x] = DCT_COS[u][x];
                }
                const cos_y: Simd8 = @splat(DCT_COS[v][y]);
                sum += @reduce(.Add, sample_vec * cos_x * cos_y);
            }
            const index = v * 8 + u;
            const scaled = 0.25 * DCT_C[u] * DCT_C[v] * sum;
            out[index] = @intFromFloat(@round(scaled / @as(f64, @floatFromInt(qtable[index]))));
        }
    }
}

fn writeHuffman(bit_writer: *BitWriter, table: *const [256]HuffmanEntry, symbol: u8) bool {
    const entry = table[symbol];
    if (entry.len == 0) return false;
    return bit_writer.writeBits(entry.code, entry.len);
}

fn buildHuffmanTable(bits: []const u8, values: []const u8) [256]HuffmanEntry {
    var table = [_]HuffmanEntry{.{}} ** 256;
    var code: u16 = 0;
    var value_index: usize = 0;
    for (bits, 0..) |count, i| {
        const len: u8 = @intCast(i + 1);
        var j: u8 = 0;
        while (j < count) : (j += 1) {
            table[values[value_index]] = .{ .code = code, .len = len };
            code += 1;
            value_index += 1;
        }
        code <<= 1;
    }
    return table;
}

fn scaledQuantTable(base: *const [64]u8, quality_raw: u8) [64]u8 {
    const quality = std.math.clamp(@as(i32, quality_raw), 1, 100);
    const scale = if (quality < 50) @divTrunc(5000, quality) else 200 - quality * 2;
    var table: [64]u8 = undefined;
    for (base, 0..) |value, i| {
        const scaled = std.math.clamp(@divTrunc(@as(i32, value) * scale + 50, 100), 1, 255);
        table[i] = @intCast(scaled);
    }
    return table;
}

fn magnitudeCategory(value: i32) u8 {
    var magnitude: u32 = @intCast(if (value < 0) -value else value);
    var count: u8 = 0;
    while (magnitude != 0) : (magnitude >>= 1) {
        count += 1;
    }
    return count;
}

fn magnitudeBits(value: i32, category: u8) u16 {
    if (category == 0) return 0;
    if (value >= 0) return @intCast(value);
    const mask = (@as(i32, 1) << @as(u5, @intCast(category))) - 1;
    return @intCast(mask + value);
}

fn lowMask(bits: u8) u32 {
    if (bits == 0) return 0;
    return (@as(u32, 1) << @as(u5, @intCast(bits))) - 1;
}

fn sumBits(comptime bits: []const u8) usize {
    var total: usize = 0;
    for (bits) |value| total += value;
    return total;
}
