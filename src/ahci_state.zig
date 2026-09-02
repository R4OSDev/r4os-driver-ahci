const std = @import("std");

pub const max_command_slots: usize = 16;
pub const max_prdt_entries: usize = 64;
pub const prdt_entry_max_bytes: u32 = 4 * 1024 * 1024;

pub const irq_dhrs: u32 = 1 << 0;
pub const irq_pss: u32 = 1 << 1;
pub const irq_dss: u32 = 1 << 2;
pub const irq_sdbs: u32 = 1 << 3;
pub const irq_ufs: u32 = 1 << 4;
pub const irq_dps: u32 = 1 << 5;
pub const irq_pcs: u32 = 1 << 6;
pub const irq_prcs: u32 = 1 << 22;
pub const irq_ofs: u32 = 1 << 24;
pub const irq_infs: u32 = 1 << 26;
pub const irq_ifs: u32 = 1 << 27;
pub const irq_hbds: u32 = 1 << 28;
pub const irq_hbfs: u32 = 1 << 29;
pub const irq_tfes: u32 = 1 << 30;
pub const irq_cpds: u32 = 1 << 31;

pub const completion_irq_mask: u32 = irq_dhrs | irq_pss | irq_dss | irq_sdbs | irq_dps;
pub const link_irq_mask: u32 = irq_pcs | irq_prcs | irq_cpds;
pub const error_irq_mask: u32 = irq_ufs | irq_ofs | irq_infs | irq_ifs | irq_hbds | irq_hbfs | irq_tfes;
pub const enabled_irq_mask: u32 = completion_irq_mask | link_irq_mask | error_irq_mask;

pub const tfd_err: u32 = 1 << 0;
pub const tfd_drq: u32 = 1 << 3;
pub const tfd_bsy: u32 = 1 << 7;

pub const DriveIdentity = struct {
    sector_size: u32 = 512,
    sector_count: u64 = 0,
    lba48: bool = false,
    dma: bool = false,
    ncq: bool = false,
    queue_depth: u8 = 1,
    write_cache_supported: bool = false,
    write_cache_enabled: bool = false,
    flush_cache: bool = false,
    flush_cache_ext: bool = false,
};

/// Parse the ATA IDENTIFY DEVICE words used by the block contract. Optional
/// checksum validation is applied when word 255 advertises the A5h signature.
/// Devices without both LBA and DMA are not suitable for this AHCI data path.
pub fn parseIdentify(words: []const u16) ?DriveIdentity {
    if (words.len < 256 or !identifyChecksumValid(words[0..256])) return null;
    if ((words[0] & 0x8000) != 0) return null;

    const capabilities = words[49];
    const dma = (capabilities & (1 << 8)) != 0;
    const lba = (capabilities & (1 << 9)) != 0;
    if (!dma or !lba) return null;

    const command_sets_valid = validityWord(words[83]);
    const reports_lba48 = command_sets_valid and (words[83] & (1 << 10)) != 0;
    const lba28_count = @as(u64, words[60]) | (@as(u64, words[61]) << 16);
    const lba48_count = @as(u64, words[100]) |
        (@as(u64, words[101]) << 16) |
        (@as(u64, words[102]) << 32) |
        (@as(u64, words[103]) << 48);
    const use_lba48 = reports_lba48 and lba48_count != 0;
    const sector_count = if (use_lba48) lba48_count else lba28_count;
    if (sector_count == 0) return null;

    var sector_size: u32 = 512;
    const sector_word = words[106];
    if (validityWord(sector_word) and (sector_word & (1 << 12)) != 0) {
        const logical_words = @as(u64, words[117]) | (@as(u64, words[118]) << 16);
        const logical_bytes = std.math.mul(u64, logical_words, 2) catch return null;
        if (logical_bytes < 512 or logical_bytes > 4096 or !std.math.isPowerOfTwo(logical_bytes)) return null;
        sector_size = @intCast(logical_bytes);
    }

    const queue_word = words[75];
    const queue_depth: u8 = if (queue_word == 0xFFFF)
        1
    else
        @intCast(@min(@as(u16, 32), (queue_word & 0x1F) + 1));
    const sata_caps = words[76];
    const ncq = use_lba48 and sata_caps != 0 and sata_caps != 0xFFFF and (sata_caps & (1 << 8)) != 0;

    return .{
        .sector_size = sector_size,
        .sector_count = sector_count,
        .lba48 = use_lba48,
        .dma = dma,
        .ncq = ncq,
        .queue_depth = if (ncq) queue_depth else 1,
        .write_cache_supported = (words[82] & (1 << 5)) != 0,
        .write_cache_enabled = (words[85] & (1 << 5)) != 0,
        .flush_cache = command_sets_valid and (words[83] & (1 << 12)) != 0,
        .flush_cache_ext = command_sets_valid and (words[83] & (1 << 13)) != 0,
    };
}

fn identifyChecksumValid(words: []const u16) bool {
    if (@as(u8, @truncate(words[255] >> 8)) != 0xA5) return true;
    var sum: u8 = 0;
    for (words[0..256]) |word| {
        sum +%= @truncate(word);
        sum +%= @truncate(word >> 8);
    }
    return sum == 0;
}

fn validityWord(word: u16) bool {
    return (word & 0xC000) == 0x4000;
}

pub const QueueContract = struct {
    slots: u8,
    ncq: bool,
    depth_one_fallback: bool,
};

/// NCQ is enabled only when both sides advertise it and more than one tag is
/// genuinely usable. Otherwise slot zero remains the complete non-NCQ path.
pub fn queueContract(
    hba_slots: u8,
    hba_ncq: bool,
    drive_depth: u8,
    drive_ncq: bool,
    hard_limit: u8,
) ?QueueContract {
    if (hba_slots == 0 or drive_depth == 0 or hard_limit == 0) return null;
    const candidate = @min(hba_slots, @min(drive_depth, hard_limit));
    const ncq = hba_ncq and drive_ncq and candidate > 1;
    const slots: u8 = if (ncq) candidate else 1;
    return .{ .slots = slots, .ncq = ncq, .depth_one_fallback = slots == 1 };
}

pub fn allocateSlot(owned_mask: u32, limit: u8) ?u5 {
    if (limit == 0 or limit > 32) return null;
    var slot: u8 = 0;
    while (slot < limit) : (slot += 1) {
        const bit = @as(u32, 1) << @as(u5, @truncate(slot));
        if ((owned_mask & bit) == 0) return @truncate(slot);
    }
    return null;
}

/// AHCI defines a command as complete only after hardware has cleared the
/// slot in both CI and SACT. This is valid for queued and non-queued commands.
pub fn slotCompleted(ci: u32, sact: u32, slot: u5) bool {
    const bit = @as(u32, 1) << slot;
    return (ci & bit) == 0 and (sact & bit) == 0;
}

/// Some AHCI implementations leave PRDBC at zero for a successful queued
/// command. A non-zero value is still required to describe the full transfer.
pub fn transferCountValid(expected: u32, reported: u32) bool {
    return reported == 0 or reported == expected;
}

pub const PhysicalSegment = struct {
    phys_addr: u64,
    bytes: u32,
};

pub const PrdtEntry = struct {
    phys_addr: u64 = 0,
    bytes: u32 = 0,
};

pub const PrdtPlan = struct {
    count: u16 = 0,
    total_bytes: u32 = 0,
    entries: [max_prdt_entries]PrdtEntry = .{PrdtEntry{}} ** max_prdt_entries,
};

pub const PrdtError = error{
    InvalidArgument,
    IncompleteMapping,
    TooManyEntries,
    Overflow,
};

/// AHCI PRDs carry an even byte count of at most 4 MiB. Mapping segments may
/// be larger and are split without changing their physical order.
pub fn buildPrdtPlan(segments: []const PhysicalSegment, requested_bytes: u32) PrdtError!PrdtPlan {
    if (segments.len == 0 or requested_bytes == 0 or (requested_bytes & 1) != 0) return error.InvalidArgument;
    var plan = PrdtPlan{};
    var remaining: u64 = requested_bytes;
    for (segments) |segment| {
        if (remaining == 0) break;
        if (segment.phys_addr == 0 or segment.bytes == 0 or (segment.phys_addr & 1) != 0) {
            return error.InvalidArgument;
        }
        var address = segment.phys_addr;
        var available: u64 = @min(@as(u64, segment.bytes), remaining);
        while (available != 0) {
            if (plan.count >= max_prdt_entries) return error.TooManyEntries;
            const take: u32 = @intCast(@min(available, @as(u64, prdt_entry_max_bytes)));
            if ((take & 1) != 0) return error.InvalidArgument;
            plan.entries[plan.count] = .{ .phys_addr = address, .bytes = take };
            plan.count += 1;
            plan.total_bytes = std.math.add(u32, plan.total_bytes, take) catch return error.Overflow;
            address = std.math.add(u64, address, take) catch return error.Overflow;
            available -= take;
            remaining -= take;
        }
    }
    if (remaining != 0 or plan.total_bytes != requested_bytes) return error.IncompleteMapping;
    return plan;
}

pub const FisError = error{
    InvalidArgument,
    LbaOutOfRange,
};

pub fn buildNonDataFis(command: u8) [20]u8 {
    var fis: [20]u8 = .{0} ** 20;
    fis[0] = 0x27;
    fis[1] = 1 << 7;
    fis[2] = command;
    return fis;
}

/// Build a Register H2D FIS for DMA, DMA EXT, or FPDMA QUEUED. For NCQ the
/// transfer count occupies Features and the tag is exactly the command slot.
pub fn buildDataFis(command: u8, lba: u64, sectors: u32, slot: u5, ncq: bool, lba48: bool) FisError![20]u8 {
    if (sectors == 0) return error.InvalidArgument;
    var fis = buildNonDataFis(command);
    fis[4] = @truncate(lba);
    fis[5] = @truncate(lba >> 8);
    fis[6] = @truncate(lba >> 16);
    fis[7] = 1 << 6;

    if (ncq) {
        if (!lba48 or sectors > 65_535 or lba > 0x0000_FFFF_FFFF_FFFF) return error.LbaOutOfRange;
        fis[8] = @truncate(lba >> 24);
        fis[9] = @truncate(lba >> 32);
        fis[10] = @truncate(lba >> 40);
        fis[3] = @truncate(sectors);
        fis[11] = @truncate(sectors >> 8);
        fis[12] = @as(u8, slot) << 3;
        return fis;
    }

    if (lba48) {
        if (sectors > 65_535 or lba > 0x0000_FFFF_FFFF_FFFF) return error.LbaOutOfRange;
        fis[8] = @truncate(lba >> 24);
        fis[9] = @truncate(lba >> 32);
        fis[10] = @truncate(lba >> 40);
        fis[12] = @truncate(sectors);
        fis[13] = @truncate(sectors >> 8);
        return fis;
    }

    if (lba > 0x0FFF_FFFF or sectors > 256) return error.LbaOutOfRange;
    fis[7] |= @truncate((lba >> 24) & 0x0F);
    fis[12] = if (sectors == 256) 0 else @truncate(sectors);
    return fis;
}

pub fn transferSectors(byte_limit: u32, sector_size: u32, lba48: bool) u16 {
    if (byte_limit == 0 or sector_size == 0) return 0;
    const ata_limit: u64 = if (lba48) 65_535 else 256;
    return @intCast(@min(@as(u64, byte_limit / sector_size), ata_limit));
}

pub fn linkReady(ssts: u32) bool {
    const det = ssts & 0x0F;
    const ipm = (ssts >> 8) & 0x0F;
    return det == 3 and (ipm == 1 or ipm == 2);
}

/// DET=1 already proves physical presence even though communication has not
/// completed.  In particular, a staggered-spin-up port may remain below the
/// linkReady boundary until software raises PxCMD.SUD after an HBA reset.
pub fn linkDetected(ssts: u32) bool {
    const det = ssts & 0x0F;
    return det == 1 or det == 3;
}

pub fn needsRecovery(irq_status: u32, tfd: u32, ssts: u32) bool {
    return (irq_status & (error_irq_mask | link_irq_mask)) != 0 or
        (tfd & (tfd_err | tfd_bsy | tfd_drq)) != 0 or
        !linkReady(ssts);
}

pub fn identityMatches(expected: DriveIdentity, observed: DriveIdentity) bool {
    return expected.sector_size == observed.sector_size and
        expected.sector_count == observed.sector_count and
        expected.lba48 == observed.lba48 and
        expected.dma == observed.dma and
        expected.ncq == observed.ncq and
        expected.queue_depth == observed.queue_depth and
        expected.write_cache_supported == observed.write_cache_supported and
        expected.write_cache_enabled == observed.write_cache_enabled and
        expected.flush_cache == observed.flush_cache and
        expected.flush_cache_ext == observed.flush_cache_ext;
}

pub fn ticksFromMilliseconds(timer_hz: u32, milliseconds: u64) u64 {
    if (timer_hz == 0 or milliseconds == 0) return 0;
    const numerator = @as(u128, timer_hz) * @as(u128, milliseconds) + 999;
    return @intCast(@min(numerator / 1000, @as(u128, std.math.maxInt(u64))));
}

pub fn deadlineExpired(start_tick: u64, timeout_ticks: u64, now: u64) bool {
    return timeout_ticks != 0 and now -% start_tick >= timeout_ticks;
}

fn identifyFixture() [256]u16 {
    var words: [256]u16 = .{0} ** 256;
    words[0] = 0x0040;
    words[49] = (1 << 8) | (1 << 9);
    words[60] = 0x5678;
    words[61] = 0x1234;
    words[75] = 31;
    words[76] = 1 << 8;
    words[82] = 1 << 5;
    words[83] = 0x4000 | (1 << 10) | (1 << 12) | (1 << 13);
    words[85] = 1 << 5;
    words[100] = 0x4321;
    words[101] = 0x8765;
    words[102] = 0x0001;
    words[103] = 0;
    return words;
}

test "IDENTIFY selects LBA48, NCQ, cache, and 4Kn properties" {
    var words = identifyFixture();
    words[106] = 0x4000 | (1 << 12);
    words[117] = 2048;
    const identity = parseIdentify(&words) orelse return error.InvalidIdentify;
    try std.testing.expectEqual(@as(u32, 4096), identity.sector_size);
    try std.testing.expectEqual(@as(u64, 0x0001_8765_4321), identity.sector_count);
    try std.testing.expect(identity.lba48 and identity.dma and identity.ncq);
    try std.testing.expectEqual(@as(u8, 32), identity.queue_depth);
    try std.testing.expect(identity.write_cache_supported and identity.write_cache_enabled);
    try std.testing.expect(identity.flush_cache and identity.flush_cache_ext);
}

test "IDENTIFY retains a bounded LBA28 non-NCQ fallback" {
    var words = identifyFixture();
    words[83] = 0x4000;
    words[76] = 0;
    const identity = parseIdentify(&words) orelse return error.InvalidIdentify;
    try std.testing.expect(!identity.lba48 and !identity.ncq);
    try std.testing.expectEqual(@as(u64, 0x1234_5678), identity.sector_count);
    try std.testing.expectEqual(@as(u8, 1), identity.queue_depth);
    try std.testing.expectEqual(@as(u32, 512), identity.sector_size);
}

test "IDENTIFY rejects unsupported logical sectors and a bad advertised checksum" {
    var words = identifyFixture();
    words[106] = 0x4000 | (1 << 12);
    words[117] = 768;
    try std.testing.expect(parseIdentify(&words) == null);

    words = identifyFixture();
    words[255] = 0xA500;
    try std.testing.expect(parseIdentify(&words) == null);
}

test "HBA and drive capability intersection preserves depth one" {
    const parallel = queueContract(32, true, 32, true, 16) orelse return error.NoQueueContract;
    try std.testing.expectEqual(@as(u8, 16), parallel.slots);
    try std.testing.expect(parallel.ncq and !parallel.depth_one_fallback);

    const no_drive_ncq = queueContract(32, true, 32, false, 16) orelse return error.NoFallback;
    try std.testing.expectEqual(@as(u8, 1), no_drive_ncq.slots);
    try std.testing.expect(!no_drive_ncq.ncq and no_drive_ncq.depth_one_fallback);
    try std.testing.expect(queueContract(0, true, 32, true, 16) == null);
}

test "slot allocation and dual-register completion are tag exact" {
    try std.testing.expectEqual(@as(?u5, 1), allocateSlot(0b0101, 4));
    try std.testing.expect(allocateSlot(0b1111, 4) == null);
    try std.testing.expect(!slotCompleted(0, 1 << 2, 2));
    try std.testing.expect(!slotCompleted(1 << 2, 0, 2));
    try std.testing.expect(slotCompleted(0, 0, 2));
    try std.testing.expect(transferCountValid(512, 0));
    try std.testing.expect(transferCountValid(512, 512));
    try std.testing.expect(!transferCountValid(512, 256));
}

test "PRDT planning splits large segments and preserves exact byte ownership" {
    const segments = [_]PhysicalSegment{
        .{ .phys_addr = 0x2000, .bytes = 5 * 1024 * 1024 },
        .{ .phys_addr = 0x9000_0000, .bytes = 4096 },
    };
    const plan = try buildPrdtPlan(&segments, 5 * 1024 * 1024 + 4096);
    try std.testing.expectEqual(@as(u16, 3), plan.count);
    try std.testing.expectEqual(prdt_entry_max_bytes, plan.entries[0].bytes);
    try std.testing.expectEqual(@as(u32, 1024 * 1024), plan.entries[1].bytes);
    try std.testing.expectEqual(@as(u32, 4096), plan.entries[2].bytes);
    try std.testing.expectEqual(@as(u32, 5 * 1024 * 1024 + 4096), plan.total_bytes);
    try std.testing.expectError(error.IncompleteMapping, buildPrdtPlan(segments[0..1], 6 * 1024 * 1024));
}

test "DMA EXT and FPDMA FIS layouts keep count, tag, and LBA distinct" {
    const dma = try buildDataFis(0x25, 0x1234_5678_9ABC, 0x345, 0, false, true);
    try std.testing.expectEqual(@as(u8, 0x25), dma[2]);
    try std.testing.expectEqual(@as(u8, 0x45), dma[12]);
    try std.testing.expectEqual(@as(u8, 0x03), dma[13]);
    try std.testing.expectEqual(@as(u8, 0x12), dma[10]);

    const ncq = try buildDataFis(0x60, 0x1234_5678_9ABC, 0x345, 7, true, true);
    try std.testing.expectEqual(@as(u8, 0x45), ncq[3]);
    try std.testing.expectEqual(@as(u8, 0x03), ncq[11]);
    try std.testing.expectEqual(@as(u8, 7 << 3), ncq[12]);
    try std.testing.expectEqual(@as(u8, 0), ncq[13]);

    const lba28 = try buildDataFis(0xC8, 0x0ABC_DEF0, 256, 0, false, false);
    try std.testing.expectEqual(@as(u8, 0x4A), lba28[7]);
    try std.testing.expectEqual(@as(u8, 0), lba28[12]);
}

test "range, reset trigger, identity, and wrapped deadline rules are bounded" {
    try std.testing.expectEqual(@as(u16, 4096), transferSectors(2 * 1024 * 1024, 512, true));
    try std.testing.expectEqual(@as(u16, 256), transferSectors(2 * 1024 * 1024, 512, false));
    try std.testing.expect(!linkDetected(0));
    try std.testing.expect(linkDetected(1));
    try std.testing.expect(linkDetected(3));
    try std.testing.expect(!linkReady(1));
    try std.testing.expect(linkReady(3 | (1 << 8)));
    try std.testing.expect(needsRecovery(irq_tfes, 0, 3 | (1 << 8)));
    try std.testing.expect(needsRecovery(0, tfd_bsy, 3 | (1 << 8)));
    try std.testing.expect(!needsRecovery(irq_dhrs, 0, 3 | (1 << 8)));

    const identity = parseIdentify(&identifyFixture()) orelse return error.InvalidIdentify;
    try std.testing.expect(identityMatches(identity, identity));
    var changed = identity;
    changed.sector_count += 1;
    try std.testing.expect(!identityMatches(identity, changed));

    try std.testing.expectEqual(@as(u64, 3), ticksFromMilliseconds(1000, 3));
    try std.testing.expect(deadlineExpired(std.math.maxInt(u64) - 2, 5, 2));
}
