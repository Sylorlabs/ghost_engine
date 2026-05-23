const std = @import("std");
const vsa = @import("vsa");

// --- GHOST ABSOLUTE: SHARDED DICTIONARY WALKER ---
// Principle: mmap-backed bit-mixed lookups with 8 independent 4KB shards.
// Objective: make the core measurable without SIMD or bit reversal.

pub const AbsoluteCore = struct {
    pub const DefaultStatePath = "state/ghost_absolute.bin";
    pub const DefaultTrainedHvPath = "state/trained_hv.bin";
    pub const TrainedHvTableMagic: u64 = 0x3154425648534731;
    pub const TrainedHvTableVersion: u32 = 1;
    // Manifold of 64-bit voxels (2^21 * 8 bytes = 16MB)
    pub const ManifoldSize = 2097152;
    pub const AddressMask = ManifoldSize - 1;
    pub const ShardCount = 8;
    pub const ShardBytes = 4 * 1024;
    pub const ShardSize = ShardBytes / @sizeOf(u64);
    pub const ShardMask = ShardSize - 1;
    // 32KB L1 window: 8 shards x 4KB. Each walker owns exactly one shard.
    pub const WindowSize = ShardCount * ShardSize;
    pub const WindowMask = WindowSize - 1;
    pub const BatchSize = 1024;

    pub const IngestReport = struct {
        bytes: usize = 0,
        writes: usize = 0,
        dominant_edge: usize = 0,
        dominant_delta: u64 = 0,
        edge_fingerprint: u64 = 0xBE496F1695F15480,

        pub fn absorb(self: *IngestReport, report: IngestReport) void {
            self.bytes += report.bytes;
            self.writes += report.writes;
            if (report.dominant_delta > self.dominant_delta) {
                self.dominant_delta = report.dominant_delta;
                self.dominant_edge = report.dominant_edge;
            }
            self.edge_fingerprint = std.math.rotl(u64, self.edge_fingerprint ^ report.edge_fingerprint, 13);
        }
    };

    pub const TrainedHvMode = enum(u32) {
        legacy_word = 0,
        word = 1,
        ngram = 2,
    };

    pub const TrainedHvLoadInfo = struct {
        path: []const u8,
        loaded: bool,
        mode: TrainedHvMode,
        count: usize,
        flags: u32,
        checksum: u64,
        expected_checksum: u64,
        checksum_ok: bool,
    };

    field: []u64,
    file: std.fs.File,
    field_count: usize,
    address_mask: usize,
    kernel: u64 = 0xBE496F1695F15480,
    trained_hvs_loaded: bool = false,
    trained_hvs: ?std.AutoHashMap(u64, vsa.Hypervector) = null,
    trained_hv_path: []const u8 = DefaultTrainedHvPath,
    trained_hv_mode: TrainedHvMode = .legacy_word,
    trained_hv_count: usize = 0,
    trained_hv_flags: u32 = 0,
    trained_hv_checksum: u64 = 0,
    trained_hv_expected_checksum: u64 = 0,
    trained_hv_checksum_ok: bool = false,
    allocator: std.mem.Allocator = std.heap.page_allocator,

    pub fn init(size_bytes: usize) !AbsoluteCore {
        return initAt(DefaultStatePath, size_bytes);
    }

    pub fn initAt(state_path: []const u8, size_bytes: usize) !AbsoluteCore {
        if (std.fs.path.dirname(state_path)) |dir| {
            if (dir.len != 0) {
                if (std.fs.path.isAbsolute(dir)) {
                    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
                        error.PathAlreadyExists => {},
                        else => return err,
                    };
                } else {
                    try std.fs.cwd().makePath(dir);
                }
            }
        }
        const requested_count = @max(WindowSize, size_bytes / @sizeOf(u64));
        const count = std.math.ceilPowerOfTwo(usize, requested_count) catch ManifoldSize;
        var file = if (std.fs.path.isAbsolute(state_path))
            try std.fs.createFileAbsolute(state_path, .{ .read = true, .truncate = false })
        else
            try std.fs.cwd().createFile(state_path, .{ .read = true, .truncate = false });
        try file.setEndPos(count * 8);

        const data = try std.posix.mmap(
            null,
            count * 8,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );

        const field = std.mem.bytesAsSlice(u64, data);
        if (needsSeed(field)) seedField(field);

        return .{
            .field = field,
            .file = file,
            .field_count = count,
            .address_mask = count - 1,
        };
    }

    pub fn deinit(self: *AbsoluteCore) void {
        if (self.trained_hvs) |*map| map.deinit();
        std.posix.munmap(@alignCast(std.mem.sliceAsBytes(self.field)));
        self.file.close();
    }

    pub fn flush(self: *AbsoluteCore) !void {
        try std.posix.msync(@alignCast(std.mem.sliceAsBytes(self.field)), std.posix.MSF.SYNC);
    }

    pub fn reset(self: *AbsoluteCore) void {
        seedField(self.field);
    }

    /// 8-walker bit-spill ingestion. The 32KB active window is split into
    /// 8 independent 4KB shards, so m1..m8 never write each other's slots.
    pub fn ingest(self: *AbsoluteCore, data: []const u8) void {
        _ = self.ingestMeasured(data);
    }

    pub fn setTrainedHypervectorPath(self: *AbsoluteCore, path: []const u8) void {
        if (self.trained_hvs) |*map| {
            map.deinit();
            self.trained_hvs = null;
        }
        self.trained_hv_path = path;
        self.trained_hvs_loaded = false;
        self.trained_hv_mode = .legacy_word;
        self.trained_hv_count = 0;
        self.trained_hv_flags = 0;
        self.trained_hv_checksum = 0;
        self.trained_hv_expected_checksum = 0;
        self.trained_hv_checksum_ok = false;
    }

    pub fn trainedHypervectorInfo(self: *const AbsoluteCore) TrainedHvLoadInfo {
        return .{
            .path = self.trained_hv_path,
            .loaded = self.trained_hvs_loaded and self.trained_hvs != null,
            .mode = self.trained_hv_mode,
            .count = self.trained_hv_count,
            .flags = self.trained_hv_flags,
            .checksum = self.trained_hv_checksum,
            .expected_checksum = self.trained_hv_expected_checksum,
            .checksum_ok = self.trained_hv_checksum_ok,
        };
    }

    pub fn loadTrainedHypervectors(self: *AbsoluteCore) void {
        if (self.trained_hvs_loaded) return;
        self.trained_hvs_loaded = true;
        var file = std.fs.cwd().openFile(self.trained_hv_path, .{}) catch return;
        defer file.close();
        var map = std.AutoHashMap(u64, vsa.Hypervector).init(self.allocator);
        var reader = file.reader();
        const first = reader.readInt(u64, .little) catch return;
        var checksum: u64 = 0;
        var expected_checksum: u64 = 0;
        var loaded: usize = 0;
        if (first == TrainedHvTableMagic) {
            const version = reader.readInt(u32, .little) catch return;
            const raw_mode = reader.readInt(u32, .little) catch return;
            const flags = reader.readInt(u32, .little) catch return;
            _ = reader.readInt(u32, .little) catch return;
            const expected_count = reader.readInt(u64, .little) catch return;
            expected_checksum = reader.readInt(u64, .little) catch return;
            if (version != TrainedHvTableVersion) return;
            const mode: TrainedHvMode = switch (raw_mode) {
                1 => .word,
                2 => .ngram,
                else => return,
            };
            checksum = checksumSeed(mode, expected_count);
            while (loaded < expected_count) : (loaded += 1) {
                const h = reader.readInt(u64, .little) catch break;
                var hv = vsa.Hypervector.initEmpty();
                for (&hv.data) |*w| w.* = reader.readInt(u64, .little) catch break;
                map.put(h, hv) catch break;
                checksum = checksumEntry(checksum, h, hv);
            }
            self.trained_hv_mode = mode;
            self.trained_hv_flags = flags;
        } else {
            file.seekTo(0) catch return;
            checksum = splitMix64(0xA11CE5A11CE5A11C);
            while (true) {
                const h = reader.readInt(u64, .little) catch break;
                var hv = vsa.Hypervector.initEmpty();
                for (&hv.data) |*w| w.* = reader.readInt(u64, .little) catch break;
                map.put(h, hv) catch break;
                checksum = checksumEntry(checksum, h, hv);
                loaded += 1;
            }
            self.trained_hv_mode = .legacy_word;
            self.trained_hv_flags = 0;
        }
        self.trained_hv_count = loaded;
        self.trained_hv_checksum = checksum;
        self.trained_hv_expected_checksum = expected_checksum;
        self.trained_hv_checksum_ok = expected_checksum == 0 or checksum == expected_checksum;
        self.trained_hvs = map;
    }

    pub fn ingestSemanticTrained(self: *AbsoluteCore, text: []const u8) IngestReport {
        if (!self.trained_hvs_loaded) self.loadTrainedHypervectors();
        var total = IngestReport{};
        var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
        while (it.next()) |word| {
            var clean_buf: [64]u8 = undefined;
            const query_word = cleanWord(word, &clean_buf);
            if (query_word.len < 2) continue;
            const hv = self.trainedVectorForWord(query_word) orelse vsa.Hypervector.initRandom(hashWord(query_word));
            total.absorb(self.ingestMeasured(std.mem.sliceAsBytes(hv.data[0..])));
        }
        return total;
    }

    pub fn ingestContextualized(self: *AbsoluteCore, text: []const u8) IngestReport {
        if (!self.trained_hvs_loaded) self.loadTrainedHypervectors();
        var token_storage: [128][64]u8 = undefined;
        var token_lens: [128]usize = [_]usize{0} ** 128;
        var token_count: usize = 0;
        var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
        while (it.next()) |word| {
            if (token_count >= token_storage.len) break;
            const clean = cleanWord(word, &token_storage[token_count]);
            if (clean.len < 2) continue;
            token_lens[token_count] = clean.len;
            token_count += 1;
        }

        var total = IngestReport{};
        var idx: usize = 0;
        while (idx < token_count) : (idx += 1) {
            const word = token_storage[idx][0..token_lens[idx]];
            var hv = self.trainedVectorForWord(word) orelse vsa.Hypervector.initRandom(hashWord(word));
            var ctx = vsa.Hypervector.initEmpty();
            var ctx_count: usize = 0;

            const left = if (idx >= 3) idx - 3 else 0;
            const right = @min(token_count, idx + 4);
            var j: usize = left;
            while (j < right) : (j += 1) {
                if (j == idx) continue;
                const neighbor = token_storage[j][0..token_lens[j]];
                const neighbor_hv = self.trainedVectorForWord(neighbor) orelse vsa.Hypervector.initRandom(hashWord(neighbor));
                ctx = xorHypervectors(ctx, permuteHypervector(neighbor_hv, contextualShift(idx, j)));
                ctx_count += 1;
            }

            if (ctx_count > 0) hv = hv.bind(ctx);
            hv = permuteHypervector(hv, ((idx + 1) * 31) % vsa.Dim);
            total.absorb(self.ingestMeasured(std.mem.sliceAsBytes(hv.data[0..])));
        }
        return total;
    }

    pub fn ingestSemantic(self: *AbsoluteCore, text: []const u8) IngestReport {
        var total = IngestReport{};
        var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
        while (it.next()) |word| {
            const hv = vsa.Hypervector.initRandom(hashWord(word));
            const bytes = std.mem.sliceAsBytes(hv.data[0..]);
            const report = self.ingestMeasured(bytes);
            total.absorb(report);
        }
        return total;
    }

    pub fn ingestMeasured(self: *AbsoluteCore, data: []const u8) IngestReport {
        var report = IngestReport{ .bytes = data.len };
        var m1: usize = @truncate(self.kernel);
        var m2: usize = m1 ^ 0xAAAAAAAAAAAAAAAA;
        var m3: usize = m1 ^ 0x5555555555555555;
        var m4: usize = m1 ^ 0x3333333333333333;
        var m5: usize = m1 ^ 0xCCCCCCCCCCCCCCCC;
        var m6: usize = m1 ^ 0x6666666666666666;
        var m7: usize = m1 ^ 0x9999999999999999;
        var m8: usize = m1 ^ 0x7777777777777777;
        // Shared n-gram context register: rolling 8-byte history of ingested
        // bytes. Updated per byte, mixed into every walker so consecutive-byte
        // context (not just the current byte) drives the manifold collision.
        var context: u64 = 0;

        const field_mask = self.address_mask & ~@as(usize, WindowMask);
        var i: usize = 0;
        const total_len = data.len;

        while (i < total_len) {
            const window_start = m1 & field_mask;
            const window = self.field[window_start .. window_start + WindowSize];

            const batch_limit = if (i + BatchSize < total_len) BatchSize else total_len - i;
            const batch = data[i .. i + batch_limit];

            var j: usize = 0;
            while (j + 8 <= batch.len) : (j += 8) {
                context = (context << 8) | @as(u64, batch[j]);
                mixWalker(window, window_start, 0, &m1, context, 7, 0xBE496F1695F15480, &report);
                context = (context << 8) | @as(u64, batch[j + 1]);
                mixWalker(window, window_start, 1, &m2, context, 11, 0xC2B2AE3D27D4EB4F, &report);
                context = (context << 8) | @as(u64, batch[j + 2]);
                mixWalker(window, window_start, 2, &m3, context, 13, 0x165667B19E3779F9, &report);
                context = (context << 8) | @as(u64, batch[j + 3]);
                mixWalker(window, window_start, 3, &m4, context, 17, 0x85EBCA77C2B2AE63, &report);
                context = (context << 8) | @as(u64, batch[j + 4]);
                mixWalker(window, window_start, 4, &m5, context, 19, 0x27D4EB2F165667C5, &report);
                context = (context << 8) | @as(u64, batch[j + 5]);
                mixWalker(window, window_start, 5, &m6, context, 23, 0x94D049BB133111EB, &report);
                context = (context << 8) | @as(u64, batch[j + 6]);
                mixWalker(window, window_start, 6, &m7, context, 29, 0xD6E8FEB86659FD93, &report);
                context = (context << 8) | @as(u64, batch[j + 7]);
                mixWalker(window, window_start, 7, &m8, context, 31, 0x9E3779B97F4A7C15, &report);
            }
            if (j < batch.len) {
                context = (context << 8) | @as(u64, batch[j]);
                mixWalker(window, window_start, 0, &m1, context, 7, 0xBE496F1695F15480, &report);
                j += 1;
            }
            if (j < batch.len) {
                context = (context << 8) | @as(u64, batch[j]);
                mixWalker(window, window_start, 1, &m2, context, 11, 0xC2B2AE3D27D4EB4F, &report);
                j += 1;
            }
            if (j < batch.len) {
                context = (context << 8) | @as(u64, batch[j]);
                mixWalker(window, window_start, 2, &m3, context, 13, 0x165667B19E3779F9, &report);
                j += 1;
            }
            if (j < batch.len) {
                context = (context << 8) | @as(u64, batch[j]);
                mixWalker(window, window_start, 3, &m4, context, 17, 0x85EBCA77C2B2AE63, &report);
                j += 1;
            }
            if (j < batch.len) {
                context = (context << 8) | @as(u64, batch[j]);
                mixWalker(window, window_start, 4, &m5, context, 19, 0x27D4EB2F165667C5, &report);
                j += 1;
            }
            if (j < batch.len) {
                context = (context << 8) | @as(u64, batch[j]);
                mixWalker(window, window_start, 5, &m6, context, 23, 0x94D049BB133111EB, &report);
                j += 1;
            }
            if (j < batch.len) {
                context = (context << 8) | @as(u64, batch[j]);
                mixWalker(window, window_start, 6, &m7, context, 29, 0xD6E8FEB86659FD93, &report);
                j += 1;
            }
            if (j < batch.len) {
                context = (context << 8) | @as(u64, batch[j]);
                mixWalker(window, window_start, 7, &m8, context, 31, 0x9E3779B97F4A7C15, &report);
            }
            i += batch_limit;
        }
        return report;
    }

    pub fn resolve(self: *AbsoluteCore, intent: []const u8, dictionary: []const []const u8, writer: anytype) !void {
        self.ingest(intent);

        // Mark starts from a prompt-derived hash so different intents produce
        // different walks even when the field state shares structure.
        var h: u64 = self.kernel;
        for (intent) |b| h = (h ^ b) *% 0x100000001B3;
        var mark: usize = @as(usize, self.kernel) ^ @as(usize, h);

        var words: usize = 0;
        while (words < 20) : (words += 1) {
            const raw_voxel = self.field[mark & self.address_mask];
            // High 32 bits for the dictionary index: uncorrelated with the
            // rotation/walk math, so word selection isn't locked to the orbit.
            const word_idx = @as(usize, @truncate(raw_voxel >> 32)) % dictionary.len;
            try writer.writeAll(dictionary[word_idx]);
            if (words < 19) try writer.writeByte(' ');
            // Mix the iteration counter into the mark update so forward motion
            // is guaranteed even if raw_voxel happens to repeat across steps.
            mark = std.math.rotl(usize, mark ^ raw_voxel ^ @as(usize, words), 31);
        }
        try writer.writeAll(".\n");
    }

    fn seedField(field: []u64) void {
        var s: u64 = 0xBE496F1695F15480;
        for (field) |*v| {
            s = (s ^ (s >> 31)) ^ 0x9E3779B97F4A7C15;
            v.* = s;
        }
    }

    fn needsSeed(field: []const u64) bool {
        if (field.len == 0) return false;
        const probes = [_]usize{
            0,
            field.len / 7,
            field.len / 3,
            field.len / 2,
            field.len - 1,
        };
        for (probes) |idx| {
            if (field[idx] != 0) return false;
        }
        return true;
    }

    fn hashWord(word: []const u8) u64 {
        var h: u64 = 0xCBF29CE484222325;
        for (word) |b| {
            h ^= @as(u64, b);
            h *%= 0x100000001B3;
        }
        return h;
    }

    fn splitMix64(x: u64) u64 {
        var z = x +% 0x9E3779B97F4A7C15;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    fn checksumSeed(mode: TrainedHvMode, count: u64) u64 {
        return splitMix64(TrainedHvTableMagic ^ count ^ @as(u64, @intFromEnum(mode)));
    }

    fn checksumEntry(checksum: u64, key: u64, hv: vsa.Hypervector) u64 {
        var c = splitMix64(checksum ^ key);
        for (hv.data) |w| c = splitMix64(c ^ w);
        return c;
    }

    fn cleanWord(word: []const u8, out: *[64]u8) []const u8 {
        var len: usize = 0;
        for (word) |c| {
            const is_alpha = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
            if (is_alpha and len < out.len) {
                out[len] = if (c >= 'A' and c <= 'Z') c + 32 else c;
                len += 1;
            }
        }
        return out[0..len];
    }

    fn paddedChar(word: []const u8, idx: usize) u8 {
        if (idx == 0) return '<';
        if (idx == word.len + 1) return '>';
        return word[idx - 1];
    }

    fn hashNgramAt(word: []const u8, pos: usize) u64 {
        var h: u64 = 0xCBF29CE484222325;
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            h ^= @as(u64, paddedChar(word, pos + i));
            h *%= 0x100000001B3;
        }
        return h;
    }

    fn xorHypervectors(a: vsa.Hypervector, b: vsa.Hypervector) vsa.Hypervector {
        var out = vsa.Hypervector.initEmpty();
        for (&out.data, a.data, b.data) |*dst, aw, bw| dst.* = aw ^ bw;
        return out;
    }

    fn permuteHypervector(hv: vsa.Hypervector, shift: usize) vsa.Hypervector {
        const s = shift % vsa.Dim;
        if (s == 0) return hv;
        var out = vsa.Hypervector.initEmpty();
        const word_shift = s / 64;
        const bit_shift: u6 = @intCast(s % 64);
        var i: usize = 0;
        while (i < vsa.WordCount) : (i += 1) {
            const src_idx = (i + word_shift) % vsa.WordCount;
            if (bit_shift == 0) {
                out.data[i] = hv.data[src_idx];
            } else {
                const next_idx = (src_idx + 1) % vsa.WordCount;
                const right_shift: u6 = 0 -% bit_shift;
                out.data[i] = (hv.data[src_idx] << bit_shift) | (hv.data[next_idx] >> right_shift);
            }
        }
        return out;
    }

    fn contextualShift(center: usize, neighbor: usize) usize {
        if (neighbor > center) return ((neighbor - center) * 17) % vsa.Dim;
        const back = ((center - neighbor) * 17) % vsa.Dim;
        return if (back == 0) 0 else vsa.Dim - back;
    }

    fn trainedVectorForWord(self: *AbsoluteCore, word: []const u8) ?vsa.Hypervector {
        const map = self.trained_hvs orelse return null;
        return switch (self.trained_hv_mode) {
            .legacy_word, .word => map.get(hashWord(word)),
            .ngram => self.ngramVectorForWord(word),
        };
    }

    fn ngramVectorForWord(self: *AbsoluteCore, word: []const u8) ?vsa.Hypervector {
        const map = self.trained_hvs orelse return null;
        if (word.len == 0) return null;
        var out = vsa.Hypervector.initEmpty();
        var found: usize = 0;
        var pos: usize = 0;
        while (pos < word.len) : (pos += 1) {
            if (map.get(hashNgramAt(word, pos))) |hv| {
                out = xorHypervectors(out, permuteHypervector(hv, ((pos + 1) * 19) % vsa.Dim));
                found += 1;
            }
        }
        return if (found == 0) null else out;
    }

    fn mixWalker(
        window: []u64,
        window_start: usize,
        comptime shard: usize,
        m: *usize,
        context: u64,
        rot: u6,
        lane_salt: u64,
        report: *IngestReport,
    ) void {
        const idx = (shard * ShardSize) + ((m.* ^ @as(usize, @truncate(context))) & ShardMask);
        const prior = window[idx];
        const mixed = std.math.rotl(u64, context ^ lane_salt, rot);
        const next = prior ^ mixed;
        window[idx] = next;

        const absolute_idx = window_start + idx;
        const delta = prior ^ next;
        report.writes += 1;
        if (delta > report.dominant_delta) {
            report.dominant_delta = delta;
            report.dominant_edge = absolute_idx;
        }
        report.edge_fingerprint = std.math.rotl(
            u64,
            report.edge_fingerprint ^ @as(u64, @intCast(absolute_idx)) ^ next ^ mixed,
            rot,
        );

        m.* = std.math.rotl(
            usize,
            m.* ^ @as(usize, @truncate(prior)) ^ @as(usize, @truncate(mixed)) ^ absolute_idx,
            rot,
        );
    }
};
