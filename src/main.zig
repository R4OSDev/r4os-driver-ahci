const std = @import("std");
const r4os = @import("r4os");
const ahci_state = @import("ahci_state.zig");

const CLASS_MASS_STORAGE: u8 = 0x01;
const SUBCLASS_AHCI: u8 = 0x06;
const PROGIF_AHCI: u8 = 0x01;

const REG_CAP: u64 = 0x00;
const REG_GHC: u64 = 0x04;
const REG_IS: u64 = 0x08;
const REG_PI: u64 = 0x0C;
const REG_CAP2: u64 = 0x24;
const REG_BOHC: u64 = 0x28;

const PORT_BASE: u64 = 0x100;
const PORT_STRIDE: u64 = 0x80;
const PORT_CLB: u64 = 0x00;
const PORT_CLBU: u64 = 0x04;
const PORT_FB: u64 = 0x08;
const PORT_FBU: u64 = 0x0C;
const PORT_IS: u64 = 0x10;
const PORT_IE: u64 = 0x14;
const PORT_CMD: u64 = 0x18;
const PORT_TFD: u64 = 0x20;
const PORT_SIG: u64 = 0x24;
const PORT_SSTS: u64 = 0x28;
const PORT_SCTL: u64 = 0x2C;
const PORT_SERR: u64 = 0x30;
const PORT_SACT: u64 = 0x34;
const PORT_CI: u64 = 0x38;

const HBA_GHC_HR: u32 = 1 << 0;
const HBA_GHC_IE: u32 = 1 << 1;
const HBA_GHC_AE: u32 = 1 << 31;
const HBA_CAP_NCQ: u32 = 1 << 30;
const HBA_CAP_64BIT: u32 = 1 << 31;
const HBA_CAP2_BOH: u32 = 1 << 0;
const BOHC_BOS: u32 = 1 << 0;
const BOHC_OOS: u32 = 1 << 1;
const BOHC_BB: u32 = 1 << 4;

const PORT_CMD_ST: u32 = 1 << 0;
const PORT_CMD_SUD: u32 = 1 << 1;
const PORT_CMD_POD: u32 = 1 << 2;
const PORT_CMD_FRE: u32 = 1 << 4;
const PORT_CMD_FR: u32 = 1 << 14;
const PORT_CMD_CR: u32 = 1 << 15;

const SIG_SATA: u32 = 0x0000_0101;

const ATA_IDENTIFY_DEVICE: u8 = 0xEC;
const ATA_READ_DMA: u8 = 0xC8;
const ATA_WRITE_DMA: u8 = 0xCA;
const ATA_READ_DMA_EXT: u8 = 0x25;
const ATA_WRITE_DMA_EXT: u8 = 0x35;
const ATA_READ_FPDMA_QUEUED: u8 = 0x60;
const ATA_WRITE_FPDMA_QUEUED: u8 = 0x61;
const ATA_FLUSH_CACHE: u8 = 0xE7;
const ATA_FLUSH_CACHE_EXT: u8 = 0xEA;

const PAGE_SIZE: u32 = 4096;
const MAP_BYTES: u32 = 8192;
const MAX_CONTROLLERS: usize = 8;
const MAX_BACKENDS: usize = 8;
const MAX_SLOTS: usize = ahci_state.max_command_slots;
const MAX_TRANSFER_BYTES: u32 = 2 * 1024 * 1024;
const WORK_HANDLE_COUNT: usize = 3;
const IRQ_ROUTE_CAPACITY: usize = 9;
const COMMAND_LIST_OFFSET: u32 = 0;
const RECEIVED_FIS_OFFSET: u32 = PAGE_SIZE;
const COMMAND_TABLE_OFFSET: u32 = 2 * PAGE_SIZE;
const IDENTIFY_OFFSET: u32 = COMMAND_TABLE_OFFSET + MAX_SLOTS * PAGE_SIZE;
const PORT_REGION_BYTES: u32 = IDENTIFY_OFFSET + PAGE_SIZE;

const INIT_TIMEOUT_MS: u64 = 1000;
const IDENTIFY_TIMEOUT_MS: u64 = 5000;
const IO_TIMEOUT_MS: u64 = 5000;

const ControllerPhase = enum(u8) {
    cold,
    initializing,
    ready,
    recovering,
    failed,
    stopped,
};

const SlotPhase = enum(u8) {
    free,
    preparing,
    active,
    completing,
};

const PortInitOutcome = enum(u8) {
    ready,
    absent,
    unsupported,
    failed,
};

const SignatureOutcome = enum(u8) {
    sata,
    absent,
    unsupported,
    timeout,
};

const CommandHeader = extern struct {
    flags: u16 = 0,
    prdtl: u16 = 0,
    prdbc: u32 = 0,
    ctba: u32 = 0,
    ctbau: u32 = 0,
    reserved: [4]u32 = .{0} ** 4,
};

const PrdtDescriptor = extern struct {
    dba: u32 = 0,
    dbau: u32 = 0,
    reserved: u32 = 0,
    dbc_i: u32 = 0,
};

const IoSlot = struct {
    phase: SlotPhase = .free,
    generation: u32 = 0,
    port_generation: u32 = 0,
    handle: u64 = 0,
    operation: u32 = r4os.abi.storage_request_op_none,
    lba: u64 = 0,
    sectors: u16 = 0,
    bytes: u32 = 0,
    start_tick: u64 = 0,
    requires_ready_wait: bool = false,
    cancel_reason: u32 = 0,
    complete: ?r4os.abi.StorageRequestComplete = null,
    pin: r4os.abi.DmaPinnedBuffer = .{},
    mapping: r4os.abi.DmaMapping = .{},
    shared_buffer: ?*r4os.r4dev.SharedDmaBuffer = null,
};

const PortState = struct {
    used: bool = false,
    index: u8 = 0,
    controller_index: u8 = 0,
    hardware_port: u8 = 0,
    configured: bool = false,
    accepting: bool = false,
    recovering: bool = false,
    shutting_down: bool = false,
    generation: u32 = 1,
    identity: ahci_state.DriveIdentity = .{},
    queue_slots: u8 = 1,
    ncq: bool = false,
    max_sectors: u16 = 0,
    owned_count: u8 = 0,
    region: r4os.abi.DmaBuffer = .{},
    slots: [MAX_SLOTS]IoSlot = .{IoSlot{}} ** MAX_SLOTS,
    pending_irq: u32 = 0,
    block_registered: bool = false,
    block_index: i32 = -1,
    name: [16:0]u8 = .{0} ** 16,
    backend: r4os.abi.StorageBackend = .{},
    commands: u64 = 0,
    completions: u64 = 0,
    failures: u64 = 0,
    timeouts: u64 = 0,
    recoveries: u64 = 0,
    recovery_failures: u64 = 0,
    last_error: u32 = 0,
    last_lba: u64 = 0,
    last_sectors: u32 = 0,
    last_tfd: u32 = 0,
    last_serr: u32 = 0,
    last_irq: u32 = 0,
};

const ControllerState = struct {
    used: bool = false,
    index: u8 = 0,
    api: ?*const r4os.r4dev.DriverApi = null,
    info: r4os.abi.PciDeviceInfo = .{},
    phase: ControllerPhase = .cold,
    present: bool = false,
    mapped: bool = false,
    mmio: r4os.abi.MmioRegion = .{},
    cap: u32 = 0,
    pi: u32 = 0,
    hba_slots: u8 = 0,
    supports_ncq: bool = false,
    supports_64bit: bool = false,
    timer_hz: u32 = 0,
    lock: u8 = 0,
    recovering: bool = false,
    shutting_down: bool = false,
    shutdown_done: bool = false,
    shutdown_safe: bool = false,
    port_indices: [MAX_BACKENDS]u8 = .{0} ** MAX_BACKENDS,
    port_count: usize = 0,
    irq_registered: bool = false,
    interrupts_attempted: bool = false,
    interrupts_armed: bool = false,
    irq_mode: u8 = 0,
    irq_routes: [IRQ_ROUTE_CAPACITY]u8 = .{0xFF} ** IRQ_ROUTE_CAPACITY,
    irq_route_count: usize = 0,
    work_pending: bool = false,
    work_generation: u64 = 0,
    work_handles: [WORK_HANDLE_COUNT]u32 = .{0} ** WORK_HANDLE_COUNT,
    sync_busy: bool = false,
    sync_done: bool = false,
    sync_handle: u64 = 0,
    sync_result: i32 = r4os.abi.storage_request_result_error,
    sync_bytes: u32 = 0,
    recoveries: u64 = 0,
    recovery_failures: u64 = 0,
    last_error: u32 = 0,
};

var driver_api: ?*const r4os.r4dev.DriverApi = null;
var controllers: [MAX_CONTROLLERS]ControllerState = .{ControllerState{}} ** MAX_CONTROLLERS;
var ports: [MAX_BACKENDS]PortState = .{PortState{}} ** MAX_BACKENDS;
var controller_count: usize = 0;
var port_count: usize = 0;
var registered_backends: usize = 0;
var active_sata_candidates: usize = 0;
var inventory_complete: bool = true;
var next_sync_sequence: u64 = 1;

comptime {
    asm (r4os.r4dev.driverEntriesAsm("ahci_init", "ahci_shutdown"));
}

export fn ahci_init(api: *const r4os.r4dev.DriverApi) callconv(.c) i32 {
    var ctx = r4os.r4dev.DriverContext.init(api);
    if (!ctx.apiCompatible()) {
        ctx.logError("AHCI.R4D driver api mismatch");
        return -3;
    }
    resetDriverState();
    driver_api = api;
    if (ctx.timerFrequency() == 0) {
        ctx.logError("AHCI.R4D monotonic timer unavailable");
        return -4;
    }

    var infos: [MAX_CONTROLLERS]r4os.abi.PciDeviceInfo = .{r4os.abi.PciDeviceInfo{}} ** MAX_CONTROLLERS;
    var info_count: usize = 0;
    if (!discoverControllers(&ctx, &infos, &info_count)) {
        ctx.logError("AHCI.R4D controller inventory exceeds supported platform capacity");
        return -5;
    }
    if (info_count == 0) {
        ctx.logWarn("AHCI.R4D no AHCI controller found; preload boundary only");
        return 0;
    }

    controller_count = info_count;
    for (infos[0..info_count], 0..) |info, index| {
        const controller = &controllers[index];
        controller.* = .{
            .used = true,
            .index = @intCast(index),
            .api = api,
            .info = info,
            .phase = .initializing,
            .present = true,
            .timer_hz = ctx.timerFrequency(),
        };
        if (!initializeController(controller, &ctx)) inventory_complete = false;
    }

    if (!inventory_complete) {
        ctx.logError("AHCI.R4D no complete usable SATA inventory registered");
        _ = shutdownAllControllers(&ctx);
        return -6;
    }
    if (active_sata_candidates == 0) {
        ctx.logWarn("AHCI.R4D no active SATA drive found; preload boundary only");
        return 0;
    }
    if (registered_backends == 0) {
        ctx.logError("AHCI.R4D no complete usable SATA inventory registered");
        _ = shutdownAllControllers(&ctx);
        return -6;
    }
    ctx.logInfo("AHCI.R4D IDENTIFY-backed parallel storage backends ready");
    return 0;
}

export fn ahci_shutdown() callconv(.c) i32 {
    const api = driver_api orelse return 0;
    var ctx = r4os.r4dev.DriverContext.init(api);
    return if (shutdownAllControllers(&ctx)) 0 else -1;
}

fn resetDriverState() void {
    controllers = .{ControllerState{}} ** MAX_CONTROLLERS;
    ports = .{PortState{}} ** MAX_BACKENDS;
    controller_count = 0;
    port_count = 0;
    registered_backends = 0;
    active_sata_candidates = 0;
    inventory_complete = true;
    next_sync_sequence = 1;
    driver_api = null;
}

fn discoverControllers(
    ctx: *const r4os.r4dev.DriverContext,
    out: *[MAX_CONTROLLERS]r4os.abi.PciDeviceInfo,
    out_count: *usize,
) bool {
    out_count.* = 0;
    var start_index: u32 = 0;
    while (true) {
        var info: r4os.abi.PciDeviceInfo = .{};
        const found = ctx.pciFindByClass(CLASS_MASS_STORAGE, SUBCLASS_AHCI, start_index, &info);
        if (found < 0) return true;
        const found_index: u32 = @intCast(found);
        if (found_index == std.math.maxInt(u32)) return false;
        start_index = found_index + 1;
        if (info.prog_if != PROGIF_AHCI and info.prog_if != 0) continue;
        if (out_count.* >= out.len) return false;
        out[out_count.*] = info;
        out_count.* += 1;
    }
}

fn initializeController(controller: *ControllerState, ctx: *const r4os.r4dev.DriverContext) bool {
    if (ctx.pciEnableBusMaster(controller.info, r4os.abi.pci_enable_memory_space) != 0) {
        return failController(controller, 1);
    }
    if (ctx.pciMapBar(controller.info, 5, MAP_BYTES, 0, &controller.mmio) != 0 or controller.mmio.virt_addr == 0) {
        return failController(controller, 2);
    }
    controller.mapped = true;
    controller.cap = read32(controller, REG_CAP);
    controller.pi = read32(controller, REG_PI);
    controller.hba_slots = @intCast(((controller.cap >> 8) & 0x1F) + 1);
    controller.supports_ncq = (controller.cap & HBA_CAP_NCQ) != 0;
    controller.supports_64bit = (controller.cap & HBA_CAP_64BIT) != 0;
    if (!biosHandoff(controller) or !resetHba(controller)) return failController(controller, 3);
    controller.cap = read32(controller, REG_CAP);
    controller.pi = read32(controller, REG_PI);

    var hardware_port: u8 = 0;
    while (hardware_port < 32) : (hardware_port += 1) {
        const bit = @as(u32, 1) << @as(u5, @truncate(hardware_port));
        if ((controller.pi & bit) == 0) continue;
        if (port_count >= ports.len or controller.port_count >= controller.port_indices.len) {
            inventory_complete = false;
            return failController(controller, 4);
        }
        const index = port_count;
        const port = &ports[index];
        port.* = .{
            .used = true,
            .index = @intCast(index),
            .controller_index = controller.index,
            .hardware_port = hardware_port,
        };
        const outcome = initializePort(controller, port, ctx);
        if (outcome == .absent or outcome == .unsupported) {
            port.* = .{};
            continue;
        }
        port_count += 1;
        controller.port_indices[controller.port_count] = @intCast(index);
        controller.port_count += 1;
        if (outcome == .failed) return failController(controller, 5);
    }

    if (controller.port_count != 0) {
        // Preload runs before local/controller identity and IRQ routing are
        // confirmed. Keep sources masked and bind IRQs at the v2 boundary.
        disableControllerInterrupts(controller);
        if (!registerControllerBackends(controller, ctx)) return failController(controller, 6);
    }
    controller.phase = .ready;
    return true;
}

fn initializePort(
    controller: *ControllerState,
    port: *PortState,
    ctx: *const r4os.r4dev.DriverContext,
) PortInitOutcome {
    const max_phys: u64 = if (controller.supports_64bit) std.math.maxInt(u64) else std.math.maxInt(u32);
    if (ctx.allocDmaRegionConstrained(PORT_REGION_BYTES, PAGE_SIZE, max_phys, &port.region) != 0 or
        port.region.phys_addr == 0 or port.region.virt_addr == 0 or port.region.bytes < PORT_REGION_BYTES)
    {
        port.last_error = 10;
        return .failed;
    }
    if (!preparePortForDiscovery(controller, port)) {
        port.last_error = 11;
        return .failed;
    }
    switch (waitPortSignature(controller, port)) {
        .sata => active_sata_candidates += 1,
        .absent, .unsupported => |outcome| {
            if (!releaseUnsupportedPort(controller, port, ctx)) return .failed;
            return if (outcome == .absent) .absent else .unsupported;
        },
        .timeout => {
            port.last_error = 16;
            return .failed;
        },
    }
    clearPortStatus(controller, port);
    if (!waitPortReady(controller, portBase(port.hardware_port), INIT_TIMEOUT_MS)) {
        port.last_error = 17;
        return .failed;
    }
    if (!startCommandEngine(controller, portBase(port.hardware_port))) {
        port.last_error = 18;
        return .failed;
    }
    const identity = identifyDrive(controller, port) orelse {
        port.last_error = 12;
        return .failed;
    };
    if (identity.write_cache_enabled and !identity.flush_cache and !identity.flush_cache_ext) {
        port.last_error = 15;
        return .failed;
    }
    const queue = ahci_state.queueContract(
        controller.hba_slots,
        controller.supports_ncq,
        identity.queue_depth,
        identity.ncq,
        @intCast(MAX_SLOTS),
    ) orelse {
        port.last_error = 13;
        return .failed;
    };
    port.identity = identity;
    port.queue_slots = queue.slots;
    port.ncq = queue.ncq;
    port.max_sectors = ahci_state.transferSectors(MAX_TRANSFER_BYTES, identity.sector_size, identity.lba48);
    if (port.max_sectors == 0) {
        port.last_error = 14;
        return .failed;
    }
    port.configured = true;
    return .ready;
}

fn waitPortSignature(controller: *ControllerState, port: *PortState) SignatureOutcome {
    const ctx = controllerContext(controller);
    const base = portBase(port.hardware_port);
    const start = ctx.tickCount();
    const timeout = ahci_state.ticksFromMilliseconds(controller.timer_hz, INIT_TIMEOUT_MS);
    var presence_seen = false;
    while (true) {
        const ssts = readPort32(controller, base, PORT_SSTS);
        presence_seen = presence_seen or ahci_state.linkDetected(ssts);
        if (ahci_state.linkReady(ssts)) {
            const signature = readPort32(controller, base, PORT_SIG);
            if (signature == SIG_SATA) return .sata;
            if (signature != 0 and signature != 0xFFFF_FFFF) return .unsupported;
        }
        if (ahci_state.deadlineExpired(start, timeout, ctx.tickCount()))
            return if (presence_seen) .timeout else .absent;
        ctx.waitTicks(1);
    }
}

fn releaseUnsupportedPort(
    controller: *ControllerState,
    port: *PortState,
    ctx: *const r4os.r4dev.DriverContext,
) bool {
    const base = portBase(port.hardware_port);
    if (!stopPort(controller, base)) return false;
    writePort32(controller, base, PORT_CLB, 0);
    writePort32(controller, base, PORT_CLBU, 0);
    writePort32(controller, base, PORT_FB, 0);
    writePort32(controller, base, PORT_FBU, 0);
    if (port.region.phys_addr != 0) ctx.freeDmaRegion(&port.region);
    return true;
}

fn registerControllerBackends(controller: *ControllerState, ctx: *const r4os.r4dev.DriverContext) bool {
    for (controller.port_indices[0..controller.port_count]) |port_index| {
        const port = &ports[port_index];
        setPortName(port, registered_backends);
        port.backend = .{
            .flags = r4os.abi.storage_backend_flag_writable,
            .source = r4os.abi.storage_backend_source_preload,
            .bus = r4os.abi.storage_backend_bus_ahci,
            .sector_size = port.identity.sector_size,
            .max_sectors_per_request = port.max_sectors,
            .queue_depth = port.queue_slots,
            .timeout_ticks = ioTimeoutTicks(controller),
            .sector_count = port.identity.sector_count,
            .context = port,
            .read = storageRead,
            .write = storageWrite,
            .flush = storageFlush,
            .shutdown = storageShutdown,
            .status = storageStatus,
            .submit = storageSubmit,
            .cancel = storageCancel,
            .reset = storageReset,
        };
        setControllerName(&port.backend.controller, controller.index);
        const block_index = ctx.registerStorageBackend(&port.name, &port.backend);
        if (block_index < 0) return false;
        port.block_registered = true;
        port.block_index = block_index;
        port.accepting = true;
        registered_backends += 1;
    }
    return true;
}

fn setPortName(port: *PortState, index: usize) void {
    @memset(port.name[0..], 0);
    const prefix = "ahci";
    @memcpy(port.name[0..prefix.len], prefix);
    port.name[prefix.len] = @intCast('0' + index);
}

fn setControllerName(out: *[32]u8, index: u8) void {
    @memset(out[0..], 0);
    const prefix = "AHCI";
    @memcpy(out[0..prefix.len], prefix);
    out[prefix.len] = '0' + index;
}

fn failController(controller: *ControllerState, code: u32) bool {
    controller.last_error = code;
    controller.phase = .failed;
    return false;
}

fn biosHandoff(controller: *ControllerState) bool {
    if ((read32(controller, REG_CAP2) & HBA_CAP2_BOH) == 0) return true;
    write32(controller, REG_BOHC, read32(controller, REG_BOHC) | BOHC_OOS);
    const ctx = controllerContext(controller);
    const start = ctx.tickCount();
    const timeout = ahci_state.ticksFromMilliseconds(controller.timer_hz, 2000);
    while ((read32(controller, REG_BOHC) & (BOHC_BOS | BOHC_BB)) != 0) {
        if (ahci_state.deadlineExpired(start, timeout, ctx.tickCount())) return false;
        ctx.waitTicks(1);
    }
    return true;
}

fn resetHba(controller: *ControllerState) bool {
    write32(controller, REG_GHC, (read32(controller, REG_GHC) | HBA_GHC_AE | HBA_GHC_HR) & ~HBA_GHC_IE);
    if (!waitControllerClear(controller, REG_GHC, HBA_GHC_HR, INIT_TIMEOUT_MS)) return false;
    write32(controller, REG_GHC, HBA_GHC_AE);
    write32(controller, REG_IS, 0xFFFF_FFFF);
    return true;
}

/// Programs the DMA bases and starts FIS reception while command processing
/// remains stopped.  PxCMD.SUD/POD must be raised in this idle window: on a
/// staggered-spin-up HBA, checking PxSSTS before this step can hide a real
/// attached disk immediately after HBA reset.
fn preparePortForDiscovery(controller: *ControllerState, port: *PortState) bool {
    const base = portBase(port.hardware_port);
    writePort32(controller, base, PORT_IE, 0);
    if (!stopPort(controller, base)) return false;
    zeroBytes(port.region.virt_addr, port.region.bytes);
    const command_list = port.region.phys_addr + COMMAND_LIST_OFFSET;
    const received_fis = port.region.phys_addr + RECEIVED_FIS_OFFSET;
    writePort32(controller, base, PORT_CLB, @truncate(command_list));
    writePort32(controller, base, PORT_CLBU, @truncate(command_list >> 32));
    writePort32(controller, base, PORT_FB, @truncate(received_fis));
    writePort32(controller, base, PORT_FBU, @truncate(received_fis >> 32));
    clearPortStatus(controller, port);
    const command = readPort32(controller, base, PORT_CMD);
    if ((command & (PORT_CMD_ST | PORT_CMD_CR | PORT_CMD_FR)) != 0) return false;
    writePort32(controller, base, PORT_CMD, command | PORT_CMD_FRE | PORT_CMD_SUD | PORT_CMD_POD);
    return true;
}

fn rebasePort(controller: *ControllerState, port: *PortState) bool {
    if (!preparePortForDiscovery(controller, port)) return false;
    const base = portBase(port.hardware_port);
    if (!ahci_state.linkReady(readPort32(controller, base, PORT_SSTS)) or
        !waitPortReady(controller, base, INIT_TIMEOUT_MS)) return false;
    return startCommandEngine(controller, base);
}

fn stopPort(controller: *ControllerState, base: u64) bool {
    writePort32(controller, base, PORT_CMD, readPort32(controller, base, PORT_CMD) & ~PORT_CMD_ST);
    if (!waitPortClear(controller, base, PORT_CMD, PORT_CMD_CR, INIT_TIMEOUT_MS)) return false;
    writePort32(controller, base, PORT_CMD, readPort32(controller, base, PORT_CMD) & ~PORT_CMD_FRE);
    return waitPortClear(controller, base, PORT_CMD, PORT_CMD_FR, INIT_TIMEOUT_MS);
}

fn startCommandEngine(controller: *ControllerState, base: u64) bool {
    const command = readPort32(controller, base, PORT_CMD);
    if ((command & (PORT_CMD_ST | PORT_CMD_CR)) != 0 or (command & PORT_CMD_FRE) == 0) return false;
    writePort32(controller, base, PORT_CMD, command | PORT_CMD_ST);
    return true;
}

fn identifyDrive(controller: *ControllerState, port: *PortState) ?ahci_state.DriveIdentity {
    const base = portBase(port.hardware_port);
    if (!waitPortReady(controller, base, INIT_TIMEOUT_MS)) return null;
    zeroBytes(identifyVirt(port), PAGE_SIZE);
    const segments = [_]ahci_state.PhysicalSegment{
        .{ .phys_addr = identifyPhys(port), .bytes = 512 },
    };
    const plan = ahci_state.buildPrdtPlan(&segments, 512) catch return null;
    const fis = ahci_state.buildNonDataFis(ATA_IDENTIFY_DEVICE);
    prepareHardwareCommand(port, 0, &fis, &plan, false);
    clearPortStatus(controller, port);
    dmaFence();
    writePort32(controller, base, PORT_CI, 1);

    const ctx = controllerContext(controller);
    const start = ctx.tickCount();
    const timeout = ahci_state.ticksFromMilliseconds(controller.timer_hz, IDENTIFY_TIMEOUT_MS);
    while (true) {
        dmaFence();
        const ci = readPort32(controller, base, PORT_CI);
        const sact = readPort32(controller, base, PORT_SACT);
        const irq_status = readPort32(controller, base, PORT_IS);
        const tfd = readPort32(controller, base, PORT_TFD);
        const ssts = readPort32(controller, base, PORT_SSTS);
        if ((irq_status & ahci_state.error_irq_mask) != 0 or
            (tfd & ahci_state.tfd_err) != 0 or !ahci_state.linkReady(ssts))
        {
            capturePortError(controller, port, irq_status, tfd);
            clearPortStatus(controller, port);
            return null;
        }
        if (ahci_state.slotCompleted(ci, sact, 0)) break;
        if (ahci_state.deadlineExpired(start, timeout, ctx.tickCount())) {
            port.timeouts +%= 1;
            port.last_error = 20;
            return null;
        }
        ctx.waitTicks(1);
    }
    clearPortStatus(controller, port);
    if (commandHeader(port, 0).prdbc != 512) {
        port.last_error = 21;
        return null;
    }
    const words: [*]const u16 = @ptrFromInt(identifyVirt(port));
    return ahci_state.parseIdentify(words[0..256]);
}

fn prepareHardwareCommand(
    port: *const PortState,
    slot_index: usize,
    fis: *const [20]u8,
    plan: ?*const ahci_state.PrdtPlan,
    write: bool,
) void {
    const table_virt = commandTableVirt(port, slot_index);
    zeroBytes(table_virt, PAGE_SIZE);
    const table: [*]u8 = @ptrFromInt(table_virt);
    @memcpy(table[0..fis.len], fis[0..]);
    var prdt_count: u16 = 0;
    if (plan) |value| {
        const descriptors: [*]PrdtDescriptor = @ptrFromInt(table_virt + 128);
        var index: usize = 0;
        while (index < value.count) : (index += 1) {
            const entry = value.entries[index];
            descriptors[index] = .{
                .dba = @truncate(entry.phys_addr),
                .dbau = @truncate(entry.phys_addr >> 32),
                .dbc_i = (entry.bytes - 1) | if (index + 1 == value.count) @as(u32, 1 << 31) else 0,
            };
        }
        prdt_count = value.count;
    }
    const table_phys = commandTablePhys(port, slot_index);
    commandHeader(port, slot_index).* = .{
        .flags = @as(u16, 5) | if (write) @as(u16, 1 << 6) else 0,
        .prdtl = prdt_count,
        .ctba = @truncate(table_phys),
        .ctbau = @truncate(table_phys >> 32),
    };
}

fn setupInterrupts(controller: *ControllerState, ctx: *const r4os.r4dev.DriverContext) bool {
    disableControllerInterrupts(controller);
    controller.irq_registered = false;
    controller.interrupts_armed = false;
    controller.irq_mode = 0;
    controller.irq_route_count = 0;
    controller.irq_routes = .{0xFF} ** IRQ_ROUTE_CAPACITY;

    const msi_irq = ctx.pciEnableMsi(controller.info);
    if (msi_irq >= 0) {
        controller.irq_mode = 2;
        if (msi_irq < 32) {
            const route: u8 = @intCast(msi_irq);
            if (ctx.irqRegister(route, irqHandler, @intFromPtr(controller), r4os.abi.irq_flag_msi) == 0) {
                controller.irq_routes[0] = route;
                controller.irq_route_count = 1;
                controller.irq_registered = true;
            }
        }
        if (!controller.irq_registered) {
            if (ctx.pciDisableMsi(controller.info) != 0) return false;
            controller.irq_mode = 0;
        }
    }

    if (!controller.irq_registered) {
        if (controller.info.interrupt_line < 32) _ = registerIrqRoute(controller, ctx, controller.info.interrupt_line);
        var route: u8 = 16;
        while (route < 24) : (route += 1) _ = registerIrqRoute(controller, ctx, route);
        if (controller.irq_route_count != 0) {
            controller.irq_mode = 1;
            controller.irq_registered = true;
        }
    }
    return controller.irq_registered;
}

fn registerIrqRoute(controller: *ControllerState, ctx: *const r4os.r4dev.DriverContext, route: u8) bool {
    if (route >= 32 or controller.irq_route_count >= controller.irq_routes.len) return false;
    for (controller.irq_routes[0..controller.irq_route_count]) |existing| {
        if (existing == route) return true;
    }
    if (ctx.irqRegister(
        route,
        irqHandler,
        @intFromPtr(controller),
        r4os.abi.irq_flag_shared | r4os.abi.irq_flag_level_low,
    ) != 0) return false;
    controller.irq_routes[controller.irq_route_count] = route;
    controller.irq_route_count += 1;
    return true;
}

fn enableControllerInterrupts(controller: *ControllerState) void {
    for (controller.port_indices[0..controller.port_count]) |port_index| {
        const port = &ports[port_index];
        clearPortStatus(controller, port);
        writePort32(
            controller,
            portBase(port.hardware_port),
            PORT_IE,
            if (controller.irq_registered) ahci_state.enabled_irq_mask else 0,
        );
    }
    var ghc = read32(controller, REG_GHC) | HBA_GHC_AE;
    if (controller.irq_registered) ghc |= HBA_GHC_IE else ghc &= ~HBA_GHC_IE;
    write32(controller, REG_GHC, ghc);
}

fn armRuntimeInterrupts(controller: *ControllerState) bool {
    if (@atomicLoad(bool, &controller.interrupts_armed, .acquire)) return true;
    if (!acquireController(controller)) return false;
    defer releaseController(controller);
    if (controller.shutting_down) return false;
    if (!controller.interrupts_attempted) {
        const ctx = controllerContext(controller);
        controller.interrupts_attempted = true;
        if (!setupInterrupts(controller, &ctx)) {
            ctx.logWarn("AHCI.R4D IRQ route unavailable; bounded polling fallback active");
        }
    }
    if (controller.irq_registered and !controller.interrupts_armed) {
        // Scheduler/deferred workers and the interrupt controller now have
        // their real runtime identity. Polling remains active on refusal.
        enableControllerInterrupts(controller);
        @atomicStore(bool, &controller.interrupts_armed, true, .release);
    }
    return true;
}

fn disableControllerInterrupts(controller: *ControllerState) void {
    if (!controller.mapped) return;
    write32(controller, REG_GHC, (read32(controller, REG_GHC) | HBA_GHC_AE) & ~HBA_GHC_IE);
    for (controller.port_indices[0..controller.port_count]) |port_index| {
        const port = &ports[port_index];
        writePort32(controller, portBase(port.hardware_port), PORT_IE, 0);
    }
}

fn clearPortStatus(controller: *ControllerState, port: *PortState) void {
    const base = portBase(port.hardware_port);
    writePort32(controller, base, PORT_SERR, 0xFFFF_FFFF);
    writePort32(controller, base, PORT_IS, 0xFFFF_FFFF);
    write32(controller, REG_IS, @as(u32, 1) << @as(u5, @truncate(port.hardware_port)));
    @atomicStore(u32, &port.pending_irq, 0, .release);
}

fn capturePortError(controller: *ControllerState, port: *PortState, irq_status: u32, tfd: u32) void {
    port.last_irq = irq_status;
    port.last_tfd = tfd;
    port.last_serr = readPort32(controller, portBase(port.hardware_port), PORT_SERR);
    port.last_error = 0x1000_0000 | (irq_status & 0x0FFF_FFFF) | ((tfd & 0xFF) << 20);
}

fn storageRead(raw: ?*anyopaque, lba: u64, sectors: u32, out: [*]u8, len: u32) callconv(.c) i32 {
    const port = portFromContext(raw) orelse return -1;
    if (sectors == 0 or sectors > std.math.maxInt(u16)) return -2;
    return syncIo(port, r4os.abi.storage_request_op_read, lba, @intCast(sectors), @intFromPtr(out), len, false);
}

fn storageWrite(raw: ?*anyopaque, lba: u64, sectors: u32, data: [*]const u8, len: u32) callconv(.c) i32 {
    const port = portFromContext(raw) orelse return -1;
    if (sectors == 0 or sectors > std.math.maxInt(u16)) return -2;
    return syncIo(port, r4os.abi.storage_request_op_write, lba, @intCast(sectors), @intFromPtr(data), len, false);
}

fn storageFlush(raw: ?*anyopaque) callconv(.c) i32 {
    const port = portFromContext(raw) orelse return -1;
    if (!port.identity.write_cache_enabled) return 0;
    return syncIo(port, r4os.abi.storage_request_op_flush, 0, 0, 0, 0, false);
}

fn storageShutdown(raw: ?*anyopaque) callconv(.c) i32 {
    _ = raw;
    const api = driver_api orelse return 0;
    var ctx = r4os.r4dev.DriverContext.init(api);
    return if (shutdownAllControllers(&ctx)) 0 else -1;
}

fn storageStatus(raw: ?*anyopaque, out: *r4os.abi.StorageBackendStatus) callconv(.c) i32 {
    const port = portFromContext(raw) orelse return -1;
    const controller = controllerForPort(port) orelse return -1;
    out.* = .{
        .state = if (port.configured and controller.phase == .ready and
            !@atomicLoad(bool, &port.shutting_down, .acquire)) 1 else 0,
        .last_error = port.last_error,
        .last_lba = port.last_lba,
        .last_sectors = port.last_sectors,
        .recoveries = port.recoveries,
        .recovery_failures = port.recovery_failures,
    };
    return 0;
}

fn storageSubmit(raw: ?*anyopaque, request: *const r4os.abi.StorageRequest) callconv(.c) i32 {
    const port = portFromContext(raw) orelse return -1;
    if (request.operation == r4os.abi.storage_request_op_flush and !port.identity.write_cache_enabled) {
        if (!validRequestHeader(request) or request.sectors != 0 or request.buffer_bytes != 0 or request.buffer_addr != 0) return -1;
        const controller = controllerForPort(port) orelse return -1;
        if (!@atomicLoad(bool, &port.accepting, .acquire) or
            @atomicLoad(bool, &port.shutting_down, .acquire) or controller.phase != .ready)
        {
            return -2;
        }
        request.complete(request.handle, r4os.abi.storage_request_result_ok, 0);
        return 0;
    }
    const controller = controllerForPort(port) orelse return -1;
    if (!armRuntimeInterrupts(controller)) return -4;
    const accepted = submitRequest(port, request, false);
    if (accepted != 0) return accepted;
    if (!scheduleControllerWork(controller, false)) pollControllerInline(controller, request.handle);
    return 0;
}

fn storageCancel(raw: ?*anyopaque, handle: u64, reason: u32) callconv(.c) i32 {
    const port = portFromContext(raw) orelse return -1;
    const controller = controllerForPort(port) orelse return -1;
    if (handle == 0 or !validCancelReason(reason) or !acquireController(controller)) return -1;
    var found = false;
    var active = false;
    for (&port.slots) |*slot| {
        if (slot.phase == .free or slot.handle != handle) continue;
        if (slot.cancel_reason == 0) slot.cancel_reason = reason;
        found = true;
        active = slot.phase == .active;
        break;
    }
    releaseController(controller);
    if (!found) return -1;
    if (!active) return 0;
    if (!scheduleControllerWork(controller, false)) pollControllerInline(controller, handle);
    return 0;
}

fn storageReset(raw: ?*anyopaque, reason: u32) callconv(.c) i32 {
    const port = portFromContext(raw) orelse return -1;
    return if (recoverPort(port, 0, r4os.abi.storage_request_result_reset, reason)) 0 else -1;
}

fn submitRequest(port: *PortState, request: *const r4os.abi.StorageRequest, bypass_admission: bool) i32 {
    return submitRequestWithBuffer(port, request, bypass_admission, null);
}

fn submitRequestWithBuffer(port: *PortState, request: *const r4os.abi.StorageRequest, bypass_admission: bool, shared_buffer: ?*r4os.r4dev.SharedDmaBuffer) i32 {
    const controller = controllerForPort(port) orelse return -1;
    if (!validRequestHeader(request)) return -1;
    if (!bypass_admission and (!@atomicLoad(bool, &port.accepting, .acquire) or
        @atomicLoad(bool, &port.shutting_down, .acquire)))
    {
        return -2;
    }
    if (!validateTransfer(port, request.operation, request.lba, request.sectors, request.buffer_bytes, request.buffer_addr)) {
        return -3;
    }
    if (!acquireController(controller)) return -4;
    const slot_index = reserveSlotLocked(port, request) orelse {
        releaseController(controller);
        return 1;
    };
    if (shared_buffer) |buffer| {
        buffer.retain();
        port.slots[slot_index].shared_buffer = buffer;
    }
    releaseController(controller);

    if (!prepareRequest(controller, port, slot_index, request)) {
        rejectPreparedSlot(controller, port, slot_index);
        return -5;
    }
    if (port.slots[slot_index].requires_ready_wait and
        !waitPortReady(controller, portBase(port.hardware_port), INIT_TIMEOUT_MS))
    {
        rejectPreparedSlot(controller, port, slot_index);
        return -6;
    }

    if (!acquireController(controller)) {
        rejectPreparedSlot(controller, port, slot_index);
        return -7;
    }
    const slot = &port.slots[slot_index];
    if (slot.phase != .preparing or slot.handle != request.handle or
        slot.port_generation != port.generation or controller.phase != .ready or controller.recovering or
        port.recovering or (!bypass_admission and (!port.accepting or port.shutting_down)))
    {
        releaseController(controller);
        rejectPreparedSlot(controller, port, slot_index);
        return -8;
    }
    if (slot.cancel_reason != 0) {
        const result = cancelResult(slot.cancel_reason);
        slot.phase = .completing;
        if (port.owned_count != 0) port.owned_count -= 1;
        releaseController(controller);
        finishSlot(controller, port, slot_index, result, 0);
        return 0;
    }

    const base = portBase(port.hardware_port);
    const tfd = readPort32(controller, base, PORT_TFD);
    const ssts = readPort32(controller, base, PORT_SSTS);
    if ((tfd & ahci_state.tfd_err) != 0 or !ahci_state.linkReady(ssts)) {
        releaseController(controller);
        rejectPreparedSlot(controller, port, slot_index);
        return -9;
    }
    slot.phase = .active;
    slot.start_tick = controllerContext(controller).tickCount();
    port.commands +%= 1;
    port.last_lba = slot.lba;
    port.last_sectors = slot.sectors;
    port.last_error = 0;
    const bit = @as(u32, 1) << @as(u5, @truncate(slot_index));
    dmaFence();
    if (port.ncq and slot.operation != r4os.abi.storage_request_op_flush) {
        writePort32(controller, base, PORT_SACT, bit);
    }
    writePort32(controller, base, PORT_CI, bit);
    releaseController(controller);
    return 0;
}

fn validRequestHeader(request: *const r4os.abi.StorageRequest) bool {
    return request.version == r4os.abi.storage_request_version and
        request.size >= @sizeOf(r4os.abi.StorageRequest) and request.handle != 0 and request.flags == 0;
}

fn reserveSlotLocked(port: *PortState, request: *const r4os.abi.StorageRequest) ?usize {
    if (!port.configured or port.owned_count >= port.queue_slots) return null;
    for (&port.slots) |*existing| {
        if (existing.phase == .free) continue;
        if (request.operation == r4os.abi.storage_request_op_flush or
            existing.operation == r4os.abi.storage_request_op_flush)
        {
            return null;
        }
    }
    var owned_mask: u32 = 0;
    for (port.slots[0..port.queue_slots], 0..) |slot, index| {
        if (slot.phase != .free) owned_mask |= @as(u32, 1) << @as(u5, @truncate(index));
    }
    const requires_ready_wait = port.owned_count == 0;
    const slot_number = ahci_state.allocateSlot(owned_mask, port.queue_slots) orelse return null;
    const slot_index: usize = slot_number;
    const generation = nextGeneration(port.slots[slot_index].generation);
    port.slots[slot_index] = .{
        .phase = .preparing,
        .generation = generation,
        .port_generation = port.generation,
        .handle = request.handle,
        .operation = request.operation,
        .lba = request.lba,
        .sectors = @intCast(request.sectors),
        .bytes = request.buffer_bytes,
        .requires_ready_wait = requires_ready_wait,
        .complete = request.complete,
    };
    port.owned_count += 1;
    return slot_index;
}

fn prepareRequest(
    controller: *ControllerState,
    port: *PortState,
    slot_index: usize,
    request: *const r4os.abi.StorageRequest,
) bool {
    const slot_number: u5 = @truncate(slot_index);
    if (request.operation == r4os.abi.storage_request_op_flush) {
        const command = if (port.identity.flush_cache_ext) ATA_FLUSH_CACHE_EXT else ATA_FLUSH_CACHE;
        const fis = ahci_state.buildNonDataFis(command);
        prepareHardwareCommand(port, slot_index, &fis, null, false);
        return true;
    }

    const slot = &port.slots[slot_index];
    const ctx = controllerContext(controller);
    const bytes: usize = request.buffer_bytes;
    if (request.operation == r4os.abi.storage_request_op_read) {
        const buffer: [*]u8 = @ptrFromInt(request.buffer_addr);
        if (ctx.pinDmaBuffer(buffer[0..bytes], &slot.pin) != 0) return false;
    } else {
        const buffer: [*]const u8 = @ptrFromInt(request.buffer_addr);
        if (ctx.pinDmaConstBuffer(buffer[0..bytes], &slot.pin) != 0) return false;
    }
    const constraints = r4os.abi.DmaConstraints{
        .dma_mask = if (controller.supports_64bit) std.math.maxInt(u64) else std.math.maxInt(u32),
        .boundary = 0,
        .max_segment_bytes = ahci_state.prdt_entry_max_bytes,
        .alignment = 2,
        .max_segments = @intCast(ahci_state.max_prdt_entries),
        .flags = r4os.abi.dma_flag_streaming | r4os.abi.dma_flag_allow_bounce,
    };
    const direction = if (request.operation == r4os.abi.storage_request_op_read)
        r4os.abi.dma_direction_from_device
    else
        r4os.abi.dma_direction_to_device;
    if (ctx.mapDmaPinned(&slot.pin, &constraints, direction, &slot.mapping) != 0) {
        _ = ctx.unpinDmaBuffer(&slot.pin);
        slot.pin = .{};
        return false;
    }

    var segments: [ahci_state.max_prdt_entries]ahci_state.PhysicalSegment = undefined;
    if (slot.mapping.segment_count == 0 or slot.mapping.segment_count > segments.len) {
        releaseSlotMapping(controller, slot);
        return false;
    }
    var index: usize = 0;
    while (index < slot.mapping.segment_count) : (index += 1) {
        segments[index] = .{
            .phys_addr = slot.mapping.segments[index].phys_addr,
            .bytes = slot.mapping.segments[index].bytes,
        };
    }
    const plan = ahci_state.buildPrdtPlan(segments[0..index], request.buffer_bytes) catch {
        releaseSlotMapping(controller, slot);
        return false;
    };
    const command = dataCommand(port, request.operation);
    const fis = ahci_state.buildDataFis(
        command,
        request.lba,
        request.sectors,
        slot_number,
        port.ncq,
        port.identity.lba48,
    ) catch {
        releaseSlotMapping(controller, slot);
        return false;
    };
    prepareHardwareCommand(port, slot_index, &fis, &plan, request.operation == r4os.abi.storage_request_op_write);
    return true;
}

fn dataCommand(port: *const PortState, operation: u32) u8 {
    if (port.ncq) {
        return if (operation == r4os.abi.storage_request_op_read) ATA_READ_FPDMA_QUEUED else ATA_WRITE_FPDMA_QUEUED;
    }
    if (port.identity.lba48) {
        return if (operation == r4os.abi.storage_request_op_read) ATA_READ_DMA_EXT else ATA_WRITE_DMA_EXT;
    }
    return if (operation == r4os.abi.storage_request_op_read) ATA_READ_DMA else ATA_WRITE_DMA;
}

fn rejectPreparedSlot(controller: *ControllerState, port: *PortState, slot_index: usize) void {
    if (slot_index >= port.slots.len) return;
    const slot = &port.slots[slot_index];
    releaseSlotMapping(controller, slot);
    if (!acquireController(controller)) return;
    if (slot.phase == .preparing) {
        const generation = slot.generation;
        slot.* = .{ .generation = generation };
        if (port.owned_count != 0) port.owned_count -= 1;
    }
    releaseController(controller);
}

fn releaseSlotMapping(controller: *ControllerState, slot: *IoSlot) void {
    const ctx = controllerContext(controller);
    if (slot.mapping.handle != 0) _ = ctx.unmapDma(&slot.mapping);
    if (slot.pin.handle != 0) _ = ctx.unpinDmaBuffer(&slot.pin);
    slot.mapping = .{};
    slot.pin = .{};
    if (slot.shared_buffer) |buffer| {
        slot.shared_buffer = null;
        buffer.release(&ctx);
    }
}

fn finishSlot(
    controller: *ControllerState,
    port: *PortState,
    slot_index: usize,
    result: i32,
    bytes: u32,
) void {
    if (slot_index >= port.slots.len) return;
    const slot = &port.slots[slot_index];
    if (slot.phase != .completing) return;
    releaseSlotMapping(controller, slot);
    const complete = slot.complete;
    const handle = slot.handle;
    if (complete) |callback| callback(handle, result, bytes);
    if (!acquireController(controller)) return;
    if (slot.phase == .completing and slot.handle == handle) {
        const generation = slot.generation;
        slot.* = .{ .generation = generation };
    }
    releaseController(controller);
}

fn validateTransfer(port: *const PortState, operation: u32, lba: u64, sectors: u32, bytes: u32, buffer_addr: u64) bool {
    switch (operation) {
        r4os.abi.storage_request_op_flush => {
            return sectors == 0 and bytes == 0 and buffer_addr == 0 and
                (!port.identity.write_cache_enabled or port.identity.flush_cache or port.identity.flush_cache_ext);
        },
        r4os.abi.storage_request_op_read, r4os.abi.storage_request_op_write => {},
        else => return false,
    }
    if (sectors == 0 or sectors > port.max_sectors or sectors > std.math.maxInt(u16) or buffer_addr == 0) return false;
    const expected = std.math.mul(u64, sectors, port.identity.sector_size) catch return false;
    if (expected != bytes or expected > MAX_TRANSFER_BYTES) return false;
    if (lba >= port.identity.sector_count or sectors > port.identity.sector_count - lba) return false;
    return true;
}

fn irqHandler(irq: u8, raw_context: usize) callconv(.c) u32 {
    _ = irq;
    const controller: *ControllerState = @ptrFromInt(raw_context);
    if (!controller.mapped or @atomicLoad(bool, &controller.shutting_down, .acquire)) return 0;
    const global_status = read32(controller, REG_IS);
    var acknowledged: u32 = 0;
    var handled = false;
    for (controller.port_indices[0..controller.port_count]) |port_index| {
        const port = &ports[port_index];
        const bit = @as(u32, 1) << @as(u5, @truncate(port.hardware_port));
        const status = readPort32(controller, portBase(port.hardware_port), PORT_IS);
        if ((global_status & bit) == 0 and status == 0) continue;
        if (status != 0) {
            _ = @atomicRmw(u32, &port.pending_irq, .Or, status, .acq_rel);
            writePort32(controller, portBase(port.hardware_port), PORT_IS, status);
        }
        acknowledged |= bit;
        handled = true;
    }
    if (acknowledged != 0) write32(controller, REG_IS, acknowledged);
    if (!handled) return 0;
    _ = scheduleControllerWork(controller, true);
    return r4os.abi.irq_result_handled;
}

fn scheduleControllerWork(controller: *ControllerState, from_irq: bool) bool {
    if (@atomicLoad(bool, &controller.shutting_down, .acquire)) return false;
    // Submission, cancellation and IRQ all publish an event before testing
    // pending. An event during a drain therefore survives its final handoff.
    _ = @atomicRmw(u64, &controller.work_generation, .Add, 1, .acq_rel);
    if (@atomicRmw(bool, &controller.work_pending, .Xchg, true, .acq_rel)) return true;
    const ctx = controllerContext(controller);
    releaseCompletedWork(controller, &ctx);
    var free_index: ?usize = null;
    for (&controller.work_handles, 0..) |*stored, index| {
        if (@atomicLoad(u32, stored, .acquire) == 0) {
            free_index = index;
            break;
        }
    }
    const index = free_index orelse {
        @atomicStore(bool, &controller.work_pending, false, .release);
        return false;
    };
    var handle: u32 = 0;
    const flags = if (from_irq) r4os.abi.driver_work_flag_from_irq else r4os.abi.driver_work_flag_none;
    if (ctx.workSubmit(controllerWork, @intFromPtr(controller), flags, &handle) != 0 or handle == 0) {
        @atomicStore(bool, &controller.work_pending, false, .release);
        return false;
    }
    @atomicStore(u32, &controller.work_handles[index], handle, .release);
    return true;
}

fn controllerWork(raw_context: usize) callconv(.c) i32 {
    const controller: *ControllerState = @ptrFromInt(raw_context);
    const ctx = controllerContext(controller);
    releaseCompletedWork(controller, &ctx);
    const observed_generation = @atomicLoad(u64, &controller.work_generation, .acquire);
    if (@atomicLoad(bool, &controller.shutting_down, .acquire)) {
        @atomicStore(bool, &controller.work_pending, false, .release);
        return 0;
    }

    // A driver-work callback may have been woken from an interrupt. Keep each
    // pass finite so the interrupted frame can return and issue its APIC EOI;
    // sleeping here can otherwise block the timer interrupt needed to wake it.
    drainControllerCompletions(controller);
    if (recoveryTrigger(controller)) |trigger| {
        _ = recoverPort(&ports[trigger.port_index], trigger.handle, trigger.result, trigger.reason);
    }
    @atomicStore(bool, &controller.work_pending, false, .release);
    switch (ahci_state.runtimeWorkDecision(
        @atomicLoad(bool, &controller.interrupts_armed, .acquire),
        @atomicLoad(u64, &controller.work_generation, .acquire) != observed_generation,
        controllerOwnsRequests(controller),
        @atomicLoad(bool, &controller.shutting_down, .acquire),
    )) {
        .stop => {},
        .event => {
            // Never wait from an IRQ-originated handoff. If the bounded work
            // queue is full, the block owner's published request timeout
            // calls storageCancel, whose task-context inline drain recovers
            // both a missed completion and a device that stopped responding.
            _ = scheduleControllerWork(controller, false);
        },
        .poll => {
            // No interrupt route: keep the old fallback, with a real wait
            // between finite passes instead of immediately requeueing.
            ctx.waitTicks(1);
            if (!scheduleControllerWork(controller, false)) pollControllerInline(controller, 0);
        },
    }
    return 0;
}

fn releaseCompletedWork(controller: *ControllerState, ctx: *const r4os.r4dev.DriverContext) void {
    for (&controller.work_handles) |*stored| {
        const handle = @atomicLoad(u32, stored, .acquire);
        if (handle == 0) continue;
        var status: r4os.abi.DriverCompletionStatus = .{};
        if (ctx.completionStatus(handle, &status) != 0) continue;
        if (status.state != r4os.abi.driver_work_state_completed and
            status.state != r4os.abi.driver_work_state_cancelled)
        {
            continue;
        }
        if (ctx.completionRelease(handle) == 0) @atomicStore(u32, stored, 0, .release);
    }
}

const CompletionRecord = struct {
    slot_index: usize,
    result: i32,
    bytes: u32,
};

fn drainControllerCompletions(controller: *ControllerState) void {
    for (controller.port_indices[0..controller.port_count]) |port_index| {
        drainPortCompletions(controller, &ports[port_index]);
    }
}

fn drainPortCompletions(controller: *ControllerState, port: *PortState) void {
    var records: [MAX_SLOTS]CompletionRecord = undefined;
    var record_count: usize = 0;
    if (!acquireController(controller)) return;
    if (!port.configured or port.recovering) {
        releaseController(controller);
        return;
    }

    const base = portBase(port.hardware_port);
    const pending = @atomicRmw(u32, &port.pending_irq, .Xchg, 0, .acq_rel);
    const visible = readPort32(controller, base, PORT_IS);
    if (visible != 0) writePort32(controller, base, PORT_IS, visible);
    const status = pending | visible;
    if (status != 0) {
        port.last_irq = status;
        write32(controller, REG_IS, @as(u32, 1) << @as(u5, @truncate(port.hardware_port)));
    }
    const tfd = readPort32(controller, base, PORT_TFD);
    const ssts = readPort32(controller, base, PORT_SSTS);
    const fatal_status = status & (ahci_state.error_irq_mask | ahci_state.link_irq_mask);
    if (fatal_status != 0 or (tfd & ahci_state.tfd_err) != 0 or !ahci_state.linkReady(ssts)) {
        capturePortError(controller, port, status, tfd);
        _ = @atomicRmw(u32, &port.pending_irq, .Or, fatal_status, .acq_rel);
        releaseController(controller);
        return;
    }

    dmaFence();
    const ci = readPort32(controller, base, PORT_CI);
    const sact = readPort32(controller, base, PORT_SACT);
    for (&port.slots, 0..) |*slot, slot_index| {
        if (slot.phase != .active or !ahci_state.slotCompleted(ci, sact, @truncate(slot_index))) continue;
        var result = r4os.abi.storage_request_result_ok;
        var bytes: u32 = if (slot.operation == r4os.abi.storage_request_op_flush) 0 else slot.bytes;
        if (slot.cancel_reason != 0) {
            result = cancelResult(slot.cancel_reason);
            bytes = 0;
        } else if (slot.port_generation != port.generation) {
            result = r4os.abi.storage_request_result_reset;
            bytes = 0;
        } else if (!ahci_state.transferCountValid(bytes, commandHeader(port, slot_index).prdbc)) {
            result = r4os.abi.storage_request_result_error;
            bytes = 0;
            port.last_error = 30;
        }
        slot.phase = .completing;
        if (port.owned_count != 0) port.owned_count -= 1;
        port.completions +%= 1;
        if (result != r4os.abi.storage_request_result_ok) port.failures +%= 1;
        records[record_count] = .{ .slot_index = slot_index, .result = result, .bytes = bytes };
        record_count += 1;
    }
    releaseController(controller);

    for (records[0..record_count]) |record| {
        finishSlot(controller, port, record.slot_index, record.result, record.bytes);
    }
}

const RecoveryTrigger = struct {
    port_index: usize,
    handle: u64,
    result: i32,
    reason: u32,
};

fn recoveryTrigger(controller: *ControllerState) ?RecoveryTrigger {
    if (!acquireController(controller)) return null;
    defer releaseController(controller);
    const now = controllerContext(controller).tickCount();
    for (controller.port_indices[0..controller.port_count]) |port_index| {
        const port = &ports[port_index];
        if (!port.configured or port.recovering or port.shutting_down) continue;
        const base = portBase(port.hardware_port);
        const pending = @atomicLoad(u32, &port.pending_irq, .acquire);
        const tfd = readPort32(controller, base, PORT_TFD);
        const ssts = readPort32(controller, base, PORT_SSTS);
        for (&port.slots) |*slot| {
            if (slot.phase != .active) continue;
            if (slot.cancel_reason != 0) {
                return .{
                    .port_index = port_index,
                    .handle = slot.handle,
                    .result = cancelResult(slot.cancel_reason),
                    .reason = slot.cancel_reason,
                };
            }
            if (ahci_state.deadlineExpired(slot.start_tick, ioTimeoutTicks(controller), now)) {
                port.timeouts +%= 1;
                return .{
                    .port_index = port_index,
                    .handle = slot.handle,
                    .result = r4os.abi.storage_request_result_timeout,
                    .reason = r4os.abi.storage_cancel_reason_timeout,
                };
            }
        }
        if ((pending & (ahci_state.error_irq_mask | ahci_state.link_irq_mask)) != 0 or
            (tfd & ahci_state.tfd_err) != 0 or !ahci_state.linkReady(ssts))
        {
            return .{
                .port_index = port_index,
                .handle = 0,
                .result = r4os.abi.storage_request_result_error,
                .reason = r4os.abi.storage_cancel_reason_reset,
            };
        }
    }
    return null;
}

fn pollControllerInline(controller: *ControllerState, wait_handle: u64) void {
    while (!@atomicLoad(bool, &controller.shutting_down, .acquire)) {
        drainControllerCompletions(controller);
        if (wait_handle != 0 and !controllerOwnsHandle(controller, wait_handle)) return;
        if (wait_handle == 0 and !controllerOwnsRequests(controller)) return;
        if (recoveryTrigger(controller)) |trigger| {
            if (!recoverPort(&ports[trigger.port_index], trigger.handle, trigger.result, trigger.reason)) return;
            if (wait_handle != 0 and !controllerOwnsHandle(controller, wait_handle)) return;
        }
        controllerContext(controller).waitTicks(1);
    }
}

fn controllerOwnsRequests(controller: *ControllerState) bool {
    if (!acquireController(controller)) return true;
    defer releaseController(controller);
    for (controller.port_indices[0..controller.port_count]) |port_index| {
        if (ports[port_index].owned_count != 0) return true;
    }
    return false;
}

fn controllerOwnsHandle(controller: *ControllerState, handle: u64) bool {
    if (!acquireController(controller)) return true;
    defer releaseController(controller);
    for (controller.port_indices[0..controller.port_count]) |port_index| {
        for (&ports[port_index].slots) |*slot| {
            if (slot.phase != .free and slot.handle == handle) return true;
        }
    }
    return false;
}

fn recoverPort(port: *PortState, trigger_handle: u64, trigger_result: i32, reason: u32) bool {
    const controller = controllerForPort(port) orelse return false;
    if (@atomicLoad(bool, &controller.recovering, .acquire) or
        @atomicRmw(bool, &port.recovering, .Xchg, true, .acq_rel))
    {
        return false;
    }
    defer @atomicStore(bool, &port.recovering, false, .release);
    if (port.shutting_down or controller.shutting_down or controller.phase != .ready) return false;
    @atomicStore(bool, &port.accepting, false, .release);
    port.recoveries +%= 1;
    announcePortRecovery(port, false, false);

    if (!waitForPreparingPort(controller, port)) {
        port.recovery_failures +%= 1;
        announcePortRecovery(port, true, false);
        return false;
    }
    const base = portBase(port.hardware_port);
    writePort32(controller, base, PORT_IE, 0);
    if (!stopPort(controller, base)) {
        port.recovery_failures +%= 1;
        announcePortRecovery(port, true, false);
        @atomicStore(bool, &port.recovering, false, .release);
        return recoverController(controller, port, trigger_handle, trigger_result, reason);
    }
    if (!comReset(controller, port)) {
        port.recovery_failures +%= 1;
        announcePortRecovery(port, true, false);
        @atomicStore(bool, &port.recovering, false, .release);
        return recoverController(controller, port, trigger_handle, trigger_result, reason);
    }

    port.generation = nextGeneration(port.generation);
    finishAllOwnedPort(controller, port, trigger_handle, trigger_result, r4os.abi.storage_request_result_reset);
    if (!rebasePort(controller, port)) {
        port.recovery_failures +%= 1;
        announcePortRecovery(port, true, false);
        @atomicStore(bool, &port.recovering, false, .release);
        return recoverController(controller, port, 0, r4os.abi.storage_request_result_reset, reason);
    }
    const observed = identifyDrive(controller, port) orelse {
        port.recovery_failures +%= 1;
        announcePortRecovery(port, true, false);
        @atomicStore(bool, &port.recovering, false, .release);
        return recoverController(controller, port, 0, r4os.abi.storage_request_result_reset, reason);
    };
    if (!ahci_state.identityMatches(port.identity, observed)) {
        port.configured = false;
        port.recovery_failures +%= 1;
        announcePortRecovery(port, true, false);
        return false;
    }
    clearPortStatus(controller, port);
    writePort32(
        controller,
        base,
        PORT_IE,
        if (controller.irq_registered and controller.interrupts_armed) ahci_state.enabled_irq_mask else 0,
    );
    port.last_error = 0;
    @atomicStore(bool, &port.accepting, true, .release);
    announcePortRecovery(port, true, true);
    return true;
}

fn recoverController(
    controller: *ControllerState,
    trigger_port: *PortState,
    trigger_handle: u64,
    trigger_result: i32,
    reason: u32,
) bool {
    if (@atomicRmw(bool, &controller.recovering, .Xchg, true, .acq_rel)) return false;
    defer @atomicStore(bool, &controller.recovering, false, .release);
    if (controller.shutting_down or controller.phase == .stopped) return false;
    controller.phase = .recovering;
    controller.recoveries +%= 1;
    for (controller.port_indices[0..controller.port_count]) |port_index| {
        const port = &ports[port_index];
        @atomicStore(bool, &port.accepting, false, .release);
        @atomicStore(bool, &port.recovering, true, .release);
        announcePortRecovery(port, false, false);
    }
    disableControllerInterrupts(controller);

    var preparations_done = true;
    for (controller.port_indices[0..controller.port_count]) |port_index| {
        const port = &ports[port_index];
        if (!waitForPreparingPort(controller, port)) {
            preparations_done = false;
            continue;
        }
        // A stuck command engine is precisely why the HBA reset is needed.
        _ = stopPort(controller, portBase(port.hardware_port));
    }
    const reset_ok = preparations_done and resetHba(controller);
    var safe_to_release = reset_ok;
    if (reset_ok) {
        for (controller.port_indices[0..controller.port_count]) |port_index| {
            const port = &ports[port_index];
            if (!stopPort(controller, portBase(port.hardware_port))) safe_to_release = false;
        }
    }
    if (safe_to_release) {
        for (controller.port_indices[0..controller.port_count]) |port_index| {
            const port = &ports[port_index];
            port.generation = nextGeneration(port.generation);
            finishAllOwnedPort(
                controller,
                port,
                if (port == trigger_port) trigger_handle else 0,
                if (port == trigger_port) trigger_result else r4os.abi.storage_request_result_reset,
                r4os.abi.storage_request_result_reset,
            );
        }
    }

    var recovered = reset_ok and safe_to_release;
    if (recovered) {
        for (controller.port_indices[0..controller.port_count]) |port_index| {
            const port = &ports[port_index];
            if (!rebasePort(controller, port)) {
                recovered = false;
                break;
            }
            const observed = identifyDrive(controller, port) orelse {
                recovered = false;
                break;
            };
            if (!ahci_state.identityMatches(port.identity, observed)) {
                recovered = false;
                break;
            }
        }
    }

    if (recovered) {
        controller.phase = .ready;
        controller.last_error = 0;
        if (@atomicLoad(bool, &controller.interrupts_armed, .acquire)) {
            enableControllerInterrupts(controller);
        } else {
            disableControllerInterrupts(controller);
        }
    } else {
        controller.phase = .failed;
        controller.recovery_failures +%= 1;
    }
    for (controller.port_indices[0..controller.port_count]) |port_index| {
        const port = &ports[port_index];
        if (!recovered) {
            port.configured = false;
            port.recovery_failures +%= 1;
        }
        @atomicStore(bool, &port.recovering, false, .release);
        @atomicStore(bool, &port.accepting, recovered, .release);
        announcePortRecovery(port, true, recovered);
    }
    _ = reason;
    return recovered;
}

fn comReset(controller: *ControllerState, port: *PortState) bool {
    const base = portBase(port.hardware_port);
    clearPortStatus(controller, port);
    const sctl = readPort32(controller, base, PORT_SCTL) & ~@as(u32, 0x0F);
    writePort32(controller, base, PORT_SCTL, sctl | 1);
    const ctx = controllerContext(controller);
    ctx.waitTicks(@max(@as(u64, 1), ahci_state.ticksFromMilliseconds(controller.timer_hz, 1)));
    writePort32(controller, base, PORT_SCTL, sctl);
    const start = ctx.tickCount();
    const timeout = ahci_state.ticksFromMilliseconds(controller.timer_hz, INIT_TIMEOUT_MS);
    while (!ahci_state.linkReady(readPort32(controller, base, PORT_SSTS))) {
        if (ahci_state.deadlineExpired(start, timeout, ctx.tickCount())) return false;
        ctx.waitTicks(1);
    }
    clearPortStatus(controller, port);
    return true;
}

fn waitForPreparingPort(controller: *ControllerState, port: *PortState) bool {
    const ctx = controllerContext(controller);
    const start = ctx.tickCount();
    const timeout = ahci_state.ticksFromMilliseconds(controller.timer_hz, INIT_TIMEOUT_MS);
    while (true) {
        var preparing = false;
        if (!acquireController(controller)) return false;
        for (&port.slots) |*slot| {
            if (slot.phase == .preparing) preparing = true;
        }
        releaseController(controller);
        if (!preparing) return true;
        if (ahci_state.deadlineExpired(start, timeout, ctx.tickCount())) return false;
        ctx.waitTicks(1);
    }
}

fn finishAllOwnedPort(
    controller: *ControllerState,
    port: *PortState,
    trigger_handle: u64,
    trigger_result: i32,
    fallback_result: i32,
) void {
    var slot_index: usize = 0;
    while (slot_index < port.slots.len) : (slot_index += 1) {
        if (!acquireController(controller)) return;
        const slot = &port.slots[slot_index];
        if (slot.phase == .active or slot.phase == .preparing) {
            const result = if (slot.handle == trigger_handle and trigger_handle != 0)
                trigger_result
            else if (slot.cancel_reason != 0)
                cancelResult(slot.cancel_reason)
            else
                fallback_result;
            slot.phase = .completing;
            if (port.owned_count != 0) port.owned_count -= 1;
            releaseController(controller);
            finishSlot(controller, port, slot_index, result, 0);
            continue;
        }
        releaseController(controller);
    }
}

fn announcePortRecovery(port: *PortState, finishing: bool, ok: bool) void {
    if (!port.block_registered) return;
    const controller = controllerForPort(port) orelse return;
    const ctx = controllerContext(controller);
    if (finishing) {
        _ = ctx.storageBackendRecoveryFinish(&port.name, ok);
    } else {
        _ = ctx.storageBackendRecoveryBegin(&port.name);
    }
}

fn syncIo(
    port: *PortState,
    operation: u32,
    lba: u64,
    sectors: u16,
    buffer_addr: u64,
    buffer_bytes: u32,
    bypass_admission: bool,
) i32 {
    const controller = controllerForPort(port) orelse return -1;
    if (@atomicRmw(bool, &controller.sync_busy, .Xchg, true, .acq_rel)) return -2;
    defer @atomicStore(bool, &controller.sync_busy, false, .release);
    if (!validateTransfer(port, operation, lba, sectors, buffer_bytes, buffer_addr)) return -3;
    const ctx = controllerContext(controller);
    const buffer = if (operation == r4os.abi.storage_request_op_flush) null else r4os.r4dev.SharedDmaBuffer.create(&ctx, buffer_bytes, if (controller.supports_64bit) std.math.maxInt(u64) else std.math.maxInt(u32)) orelse return -3;
    defer if (buffer) |owned| owned.release(&ctx);
    if (operation == r4os.abi.storage_request_op_write) {
        const source: [*]const u8 = @ptrFromInt(buffer_addr);
        @memcpy(buffer.?.data(), source[0..buffer_bytes]);
    }
    var sequence: u64 = 0;
    while (sequence == 0)
        sequence = (@atomicRmw(u64, &next_sync_sequence, .Add, 1, .monotonic) +% 1) & 0x0000_3FFF_FFFF_FFFF;
    // Low two bits belong to the completion claim; request handles keep them zero.
    const handle = 0xFFFD_0000_0000_0000 | (sequence << 2);
    @atomicStore(bool, &controller.sync_done, false, .monotonic);
    controller.sync_result = r4os.abi.storage_request_result_error;
    controller.sync_bytes = 0;
    @atomicStore(u64, &controller.sync_handle, handle | 1, .release);
    const request = r4os.abi.StorageRequest{
        .handle = handle,
        .operation = operation,
        .lba = lba,
        .sectors = sectors,
        .buffer_bytes = buffer_bytes,
        .buffer_addr = if (buffer) |owned| @intFromPtr(owned.data().ptr) else 0,
        .complete = syncComplete,
    };
    const submitted = submitRequestWithBuffer(port, &request, bypass_admission, buffer);
    if (submitted != 0) {
        finishSyncClaim(controller, handle);
        return submitted;
    }

    while (!@atomicLoad(bool, &controller.sync_done, .acquire)) {
        drainControllerCompletions(controller);
        if (recoveryTrigger(controller)) |trigger| {
            if (!recoverPort(&ports[trigger.port_index], trigger.handle, trigger.result, trigger.reason)) break;
        }
        if (!controllerOwnsHandle(controller, handle) and !@atomicLoad(bool, &controller.sync_done, .acquire)) break;
        controllerContext(controller).waitTicks(1);
    }
    finishSyncClaim(controller, handle);
    const expected_bytes: u32 = if (operation == r4os.abi.storage_request_op_flush) 0 else buffer_bytes;
    const ok = @atomicLoad(bool, &controller.sync_done, .acquire) and controller.sync_result == r4os.abi.storage_request_result_ok and
        controller.sync_bytes == expected_bytes;
    if (ok and operation == r4os.abi.storage_request_op_read) {
        const destination: [*]u8 = @ptrFromInt(buffer_addr);
        @memcpy(destination[0..buffer_bytes], buffer.?.data());
    }
    return if (ok) 0 else -3;
}

// Completion and detach claim the same generation. A late callback cannot
// publish into the result fields of a subsequent synchronous request.
fn syncComplete(handle: u64, result: i32, bytes: u32) callconv(.c) void {
    for (controllers[0..controller_count]) |*controller| {
        if (@cmpxchgStrong(u64, &controller.sync_handle, handle | 1, handle | 2, .acq_rel, .acquire) != null) continue;
        controller.sync_result = result;
        controller.sync_bytes = bytes;
        @atomicStore(bool, &controller.sync_done, true, .release);
        @atomicStore(u64, &controller.sync_handle, handle | 3, .release);
        return;
    }
}

fn finishSyncClaim(controller: *ControllerState, handle: u64) void {
    while (true) {
        const claim = @atomicLoad(u64, &controller.sync_handle, .acquire);
        if ((claim & ~@as(u64, 3)) != handle) return;
        if (claim == (handle | 2)) {
            controllerContext(controller).waitTicks(1);
            continue;
        }
        if (@cmpxchgStrong(u64, &controller.sync_handle, claim, 0, .acq_rel, .acquire) == null) return;
    }
}

fn shutdownAllControllers(ctx: *const r4os.r4dev.DriverContext) bool {
    for (ports[0..port_count]) |*port| @atomicStore(bool, &port.accepting, false, .release);
    var safe = true;
    var index = controller_count;
    while (index != 0) {
        index -= 1;
        if (controllers[index].used and !shutdownController(&controllers[index], ctx)) safe = false;
    }
    return safe;
}

fn shutdownController(controller: *ControllerState, ctx: *const r4os.r4dev.DriverContext) bool {
    if (controller.shutdown_done) return controller.shutdown_safe;
    for (controller.port_indices[0..controller.port_count]) |port_index| {
        const port = &ports[port_index];
        @atomicStore(bool, &port.accepting, false, .release);
        if (!waitForPreparingPort(controller, port)) return false;
    }

    if (controller.phase == .ready and !controller.recovering) {
        for (controller.port_indices[0..controller.port_count]) |port_index| {
            const port = &ports[port_index];
            if (port.block_registered and port.identity.write_cache_enabled) {
                _ = syncIo(port, r4os.abi.storage_request_op_flush, 0, 0, 0, 0, true);
            }
        }
    }

    @atomicStore(bool, &controller.shutting_down, true, .release);
    for (controller.port_indices[0..controller.port_count]) |port_index| {
        @atomicStore(bool, &ports[port_index].shutting_down, true, .release);
    }
    disableControllerInterrupts(controller);
    const work_safe = releaseDriverWork(controller, ctx);

    var stopped = true;
    if (controller.mapped) {
        for (controller.port_indices[0..controller.port_count]) |port_index| {
            const port = &ports[port_index];
            if (!stopPort(controller, portBase(port.hardware_port))) stopped = false;
        }
        if (stopped) {
            for (controller.port_indices[0..controller.port_count]) |port_index| {
                const port = &ports[port_index];
                finishAllOwnedPort(
                    controller,
                    port,
                    0,
                    r4os.abi.storage_request_result_shutdown,
                    r4os.abi.storage_request_result_shutdown,
                );
                writePort32(controller, portBase(port.hardware_port), PORT_CLB, 0);
                writePort32(controller, portBase(port.hardware_port), PORT_CLBU, 0);
                writePort32(controller, portBase(port.hardware_port), PORT_FB, 0);
                writePort32(controller, portBase(port.hardware_port), PORT_FBU, 0);
            }
        }
    }
    const irq_safe = unregisterInterrupts(controller, ctx);
    const bus_master_safe = disablePciBusMaster(controller, ctx);
    const safe = stopped and work_safe and irq_safe and bus_master_safe;
    if (safe) {
        for (controller.port_indices[0..controller.port_count]) |port_index| {
            const port = &ports[port_index];
            if (port.region.phys_addr != 0) ctx.freeDmaRegion(&port.region);
            port.configured = false;
        }
        controller.present = false;
        controller.phase = .stopped;
    } else {
        controller.phase = .failed;
    }
    controller.shutdown_safe = safe;
    controller.shutdown_done = safe;
    return safe;
}

fn releaseDriverWork(controller: *ControllerState, ctx: *const r4os.r4dev.DriverContext) bool {
    @atomicStore(bool, &controller.work_pending, false, .release);
    var safe = true;
    for (&controller.work_handles) |*stored| {
        const handle = @atomicLoad(u32, stored, .acquire);
        if (handle == 0) continue;
        var status: r4os.abi.DriverCompletionStatus = .{};
        if (ctx.completionStatus(handle, &status) == 0 and status.state == r4os.abi.driver_work_state_queued) {
            _ = ctx.workCancel(handle);
        }
        var result: i32 = 0;
        const waited = ctx.completionWait(handle, ahci_state.ticksFromMilliseconds(controller.timer_hz, INIT_TIMEOUT_MS), &result);
        if (waited != 0 and waited != r4os.abi.driver_work_result_cancelled) {
            safe = false;
            continue;
        }
        if (ctx.completionRelease(handle) == 0) {
            @atomicStore(u32, stored, 0, .release);
        } else {
            safe = false;
        }
    }
    return safe;
}

fn unregisterInterrupts(controller: *ControllerState, ctx: *const r4os.r4dev.DriverContext) bool {
    const used_msi = controller.irq_mode == 2;
    for (controller.irq_routes[0..controller.irq_route_count]) |route| {
        if (route < 32) _ = ctx.irqUnregister(route, irqHandler, @intFromPtr(controller));
    }
    controller.irq_registered = false;
    controller.interrupts_armed = false;
    controller.irq_route_count = 0;
    controller.irq_mode = 0;
    if (used_msi and ctx.pciDisableMsi(controller.info) != 0) return false;
    return true;
}

fn disablePciBusMaster(controller: *ControllerState, ctx: *const r4os.r4dev.DriverContext) bool {
    if (!controller.present) return true;
    const raw = ctx.pciReadConfig32(controller.info, 0x04);
    if (raw == 0xFFFF_FFFF) return false;
    if ((raw & 0x0004) == 0) return true;
    const command = (raw & 0x0000_FFFF) & ~@as(u32, 0x0004);
    if (ctx.pciWriteConfig32(controller.info, 0x04, command) != 0) return false;
    const verified = ctx.pciReadConfig32(controller.info, 0x04);
    return verified != 0xFFFF_FFFF and (verified & 0x0004) == 0;
}

fn validCancelReason(reason: u32) bool {
    return reason == r4os.abi.storage_cancel_reason_timeout or
        reason == r4os.abi.storage_cancel_reason_caller or
        reason == r4os.abi.storage_cancel_reason_reset or
        reason == r4os.abi.storage_cancel_reason_shutdown;
}

fn cancelResult(reason: u32) i32 {
    return switch (reason) {
        r4os.abi.storage_cancel_reason_timeout => r4os.abi.storage_request_result_timeout,
        r4os.abi.storage_cancel_reason_reset => r4os.abi.storage_request_result_reset,
        r4os.abi.storage_cancel_reason_shutdown => r4os.abi.storage_request_result_shutdown,
        else => r4os.abi.storage_request_result_cancelled,
    };
}

fn portFromContext(raw: ?*anyopaque) ?*PortState {
    const ptr = raw orelse return null;
    const port: *PortState = @ptrCast(@alignCast(ptr));
    if (port.index >= port_count or &ports[port.index] != port or !port.used) return null;
    return port;
}

fn controllerForPort(port: *const PortState) ?*ControllerState {
    if (port.controller_index >= controller_count) return null;
    const controller = &controllers[port.controller_index];
    if (!controller.used) return null;
    return controller;
}

fn controllerContext(controller: *const ControllerState) r4os.r4dev.DriverContext {
    return r4os.r4dev.DriverContext.init(controller.api.?);
}

fn acquireController(controller: *ControllerState) bool {
    var attempts: u32 = 0;
    while (attempts < 64) : (attempts += 1) {
        if (@cmpxchgWeak(u8, &controller.lock, 0, 1, .acquire, .monotonic) == null) return true;
        controllerContext(controller).waitTicks(1);
    }
    return false;
}

fn releaseController(controller: *ControllerState) void {
    @atomicStore(u8, &controller.lock, 0, .release);
}

fn nextGeneration(previous: u32) u32 {
    const next = previous +% 1;
    return if (next == 0) 1 else next;
}

fn ioTimeoutTicks(controller: *const ControllerState) u64 {
    return @max(@as(u64, 1), ahci_state.ticksFromMilliseconds(controller.timer_hz, IO_TIMEOUT_MS));
}

fn waitControllerClear(controller: *ControllerState, offset: u64, mask: u32, milliseconds: u64) bool {
    const ctx = controllerContext(controller);
    const start = ctx.tickCount();
    const timeout = ahci_state.ticksFromMilliseconds(controller.timer_hz, milliseconds);
    while ((read32(controller, offset) & mask) != 0) {
        if (ahci_state.deadlineExpired(start, timeout, ctx.tickCount())) return false;
        ctx.waitTicks(1);
    }
    return true;
}

fn waitPortClear(controller: *ControllerState, base: u64, offset: u64, mask: u32, milliseconds: u64) bool {
    const ctx = controllerContext(controller);
    const start = ctx.tickCount();
    const timeout = ahci_state.ticksFromMilliseconds(controller.timer_hz, milliseconds);
    while ((readPort32(controller, base, offset) & mask) != 0) {
        if (ahci_state.deadlineExpired(start, timeout, ctx.tickCount())) return false;
        ctx.waitTicks(1);
    }
    return true;
}

fn waitPortReady(controller: *ControllerState, base: u64, milliseconds: u64) bool {
    const ctx = controllerContext(controller);
    const start = ctx.tickCount();
    const timeout = ahci_state.ticksFromMilliseconds(controller.timer_hz, milliseconds);
    while (true) {
        const tfd = readPort32(controller, base, PORT_TFD);
        if ((tfd & (ahci_state.tfd_bsy | ahci_state.tfd_drq)) == 0) return (tfd & ahci_state.tfd_err) == 0;
        if (ahci_state.deadlineExpired(start, timeout, ctx.tickCount())) return false;
        ctx.waitTicks(1);
    }
}

fn portBase(hardware_port: u8) u64 {
    return PORT_BASE + @as(u64, hardware_port) * PORT_STRIDE;
}

fn commandHeader(port: *const PortState, slot_index: usize) *volatile CommandHeader {
    return @ptrFromInt(port.region.virt_addr + COMMAND_LIST_OFFSET + slot_index * @sizeOf(CommandHeader));
}

fn commandTablePhys(port: *const PortState, slot_index: usize) u64 {
    return port.region.phys_addr + COMMAND_TABLE_OFFSET + slot_index * PAGE_SIZE;
}

fn commandTableVirt(port: *const PortState, slot_index: usize) u64 {
    return port.region.virt_addr + COMMAND_TABLE_OFFSET + slot_index * PAGE_SIZE;
}

fn identifyPhys(port: *const PortState) u64 {
    return port.region.phys_addr + IDENTIFY_OFFSET;
}

fn identifyVirt(port: *const PortState) u64 {
    return port.region.virt_addr + IDENTIFY_OFFSET;
}

fn zeroBytes(virt_addr: u64, bytes: u32) void {
    if (virt_addr == 0 or bytes == 0) return;
    const target: [*]u8 = @ptrFromInt(virt_addr);
    @memset(target[0..bytes], 0);
}

fn dmaFence() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}

fn read32(controller: *const ControllerState, offset: u64) u32 {
    const ptr: *volatile u32 = @ptrFromInt(controller.mmio.virt_addr + offset);
    return ptr.*;
}

fn write32(controller: *const ControllerState, offset: u64, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(controller.mmio.virt_addr + offset);
    ptr.* = value;
}

fn readPort32(controller: *const ControllerState, base: u64, offset: u64) u32 {
    return read32(controller, base + offset);
}

fn writePort32(controller: *const ControllerState, base: u64, offset: u64, value: u32) void {
    write32(controller, base + offset, value);
}
