const r4os = @import("r4os");

const CLASS_MASS_STORAGE: u8 = 0x01;
const SUBCLASS_AHCI: u8 = 0x06;
const PROGIF_AHCI: u8 = 0x01;

const AhciState = extern struct {
    present: u32 = 0,
    mapped: u32 = 0,
    dma_ready: u32 = 0,
    ports: u32 = 0,
    bar5_phys: u64 = 0,
    bar5_size: u32 = 0,
};

var state: AhciState = .{};
var mmio: r4os.abi.MmioRegion = .{};
var dma: r4os.abi.DmaBuffer = .{};

comptime {
    asm (r4os.r4dev.driverEntriesAsm("ahci_init", "ahci_shutdown"));
}

export fn ahci_init(api: *const r4os.r4dev.DriverApi) callconv(.c) i32 {
    var ctx = r4os.r4dev.DriverContext.init(api);
    if (!ctx.apiCompatible()) {
        ctx.logError("AHCI.R4D driver api mismatch");
        return -3;
    }

    const info = findAhci(&ctx) orelse {
        ctx.logWarn("AHCI.R4D no AHCI controller found; preload boundary only");
        return 0;
    };

    state.present = 1;
    if (ctx.pciEnableBusMaster(info, r4os.abi.pci_enable_memory_space) != 0) {
        ctx.logWarn("AHCI.R4D bus master enable failed; legacy rescue required");
        return 0;
    }

    if (ctx.pciMapBar(info, 5, 8192, 0, &mmio) != 0 or mmio.virt_addr == 0) {
        ctx.logWarn("AHCI.R4D BAR5 map failed; legacy rescue required");
        return 0;
    }
    state.mapped = 1;
    state.bar5_phys = mmio.phys_addr;
    state.bar5_size = mmio.mapped_bytes;
    state.ports = readPortsImplemented(mmio.virt_addr);

    if (ctx.allocDmaRegion(4096, 4096, &dma) == 0 and dma.phys_addr != 0 and dma.virt_addr != 0) {
        state.dma_ready = 1;
    } else {
        ctx.logWarn("AHCI.R4D DMA smoke allocation failed");
    }

    ctx.logInfo("AHCI.R4D preload storage boundary ready; built-in legacy rescue remains data path");
    return 0;
}

export fn ahci_shutdown() callconv(.c) i32 {
    return 0;
}

fn findAhci(ctx: *const r4os.r4dev.DriverContext) ?r4os.abi.PciDeviceInfo {
    var index: u32 = 0;
    while (true) {
        var info: r4os.abi.PciDeviceInfo = .{};
        const found = ctx.pciFindByClass(CLASS_MASS_STORAGE, SUBCLASS_AHCI, index, &info);
        if (found < 0) return null;
        index = @as(u32, @intCast(found)) + 1;
        if (info.prog_if == PROGIF_AHCI or info.prog_if == 0) return info;
    }
}

fn readPortsImplemented(base: u64) u32 {
    const ptr: *volatile u32 = @ptrFromInt(base + 0x0C);
    return ptr.*;
}
