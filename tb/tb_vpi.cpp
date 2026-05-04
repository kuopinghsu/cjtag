// =============================================================================
// VPI Testbench for cJTAG Bridge
// =============================================================================
// Dedicated VPI server for OpenOCD testing with synchronous clock control
// Based on jv32.dev's proven VPI architecture
//
// This testbench uses blocking socket I/O where the VPI controls all clocking.
// Each CMD_OSCAN1_RAW command:
//   1. Sets TCKC/TMSC inputs
//   2. Runs N system clock cycles (default 10)
//   3. Reads TMSC output
//   4. Sends response
//
// This differs from tb_cjtag.cpp which uses free-running clocks.
// =============================================================================

#include <verilated.h>
#include <verilated_fst_c.h>
#include "Vtop.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <csignal>
#include <cerrno>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <sys/select.h>

// ─── VPI protocol constants ──────────────────────────────────────────────────
#define CMD_RESET               0u
#define CMD_TMS_SEQ             1u
#define CMD_SCAN_CHAIN          2u
#define CMD_SCAN_CHAIN_FLIP_TMS 3u
#define CMD_STOP_SIMU           4u
#define CMD_OSCAN1_RAW          5u
#define XFERT_MAX_SIZE          512

struct vpi_cmd {
    uint32_t cmd;
    uint8_t  buffer_out[XFERT_MAX_SIZE];
    uint8_t  buffer_in[XFERT_MAX_SIZE];
    uint32_t length;
    uint32_t nb_bits;
};
static_assert(sizeof(vpi_cmd) == 1036, "vpi_cmd size mismatch");

// ─── Simulation globals ──────────────────────────────────────────────────────
static Vtop*          g_dut      = nullptr;
static VerilatedFstC* g_tfp      = nullptr;
static uint64_t       g_sim_time = 0;
static uint64_t       g_cycle    = 0;
static volatile bool  g_abort    = false;

static const uint64_t CLK_HALF_PS = 5000ULL; // 10 ns period = 5 ns half

// ─── Run-time parameters ─────────────────────────────────────────────────────
static int      g_vpi_port       = 5555;
static uint64_t g_max_cycles     = 50000000ULL;
static int      g_clks_per_vpi   = 30;  // Match test_idcode.cpp timing (20 low + 10 high)
static int      g_idle_clks      = 1000;
static int      g_boot_clks      = 100;
static bool     g_trace_enabled  = false;

static void sig_handler(int) { g_abort = true; }

// ─── Clock helpers ───────────────────────────────────────────────────────────
static inline void tick_half() {
    g_dut->eval();
    if (g_tfp) g_tfp->dump(g_sim_time);
    g_sim_time += CLK_HALF_PS;
}

static inline void tick() {
    g_dut->clk_i = 1; tick_half();
    g_dut->clk_i = 0; tick_half();
    ++g_cycle;
}

static void run_clocks(int n) {
    for (int i = 0; i < n; ++i) tick();
}

// ─── TCP helpers ─────────────────────────────────────────────────────────────
static bool recv_exact(int fd, void *buf, size_t n) {
    size_t got = 0;
    while (got < n) {
        ssize_t r = recv(fd, static_cast<char*>(buf) + got, n - got, 0);
        if (r <= 0) return false;
        got += static_cast<size_t>(r);
    }
    return true;
}

static bool send_exact(int fd, const void *buf, size_t n) {
    size_t sent = 0;
    while (sent < n) {
        ssize_t r = send(fd, static_cast<const char*>(buf) + sent, n - sent, 0);
        if (r <= 0) return false;
        sent += static_cast<size_t>(r);
    }
    return true;
}

// ─── VPI command processor ───────────────────────────────────────────────────
static bool process_vpi_cmd(int fd, struct vpi_cmd *c) {
    const uint32_t cmd = c->cmd;

    switch (cmd) {

    case CMD_RESET: {
        uint8_t trst = c->buffer_out[0] & 0x01u;
        g_dut->ntrst_i = trst ? 0 : 1;  // active-low
        run_clocks(g_clks_per_vpi * 4);
        return true;
    }

    case CMD_TMS_SEQ:
        // Not used in cJTAG mode
        return true;

    case CMD_SCAN_CHAIN:
    case CMD_SCAN_CHAIN_FLIP_TMS:
        // Not used in cJTAG mode
        fprintf(stderr, "[VPI] SCAN_CHAIN not supported in cJTAG mode\n");
        return true;

    case CMD_OSCAN1_RAW: {
        // cJTAG: drive TCKC/TMSC, return TMSC output
        uint8_t tckc = c->buffer_out[0] & 0x01u;
        uint8_t tmsc = (c->buffer_out[0] >> 1) & 0x01u;
        
        // 1-bit delay buffer to fix TDO sampling offset
        // The TAP shifts by the time we sample (after 30 clocks), so we see bit N+1
        // instead of bit N. Solution: Buffer each bit and return the previous one.
        static uint8_t tdo_delay_buffer = 0;
        static bool first_command = true;
        
        g_dut->tckc_i = tckc;
        g_dut->tmsc_i = tmsc;
        
        // Run clocks to let bridge process
        run_clocks(g_clks_per_vpi);

        // Read TMSC output when bridge is driving (tmsc_oen active-low = 0)
        uint8_t oe  = g_dut->tmsc_oen & 1u;
        uint8_t out = g_dut->tmsc_o & 1u;
        uint8_t tmsc_current = (oe == 0u) ? out : 0u;
        
        // Return the PREVIOUS bit (from buffer), except on first command
        // BUG FIX: Only apply delay to TDO reads (when oe=0), not to TDI/TMS bits
        uint8_t tmsc_response;
        if (oe == 0) {  // TDO window is open
            tmsc_response = first_command ? tmsc_current : tdo_delay_buffer;
            tdo_delay_buffer = tmsc_current;
            first_command = false;
        } else {
            // Not a TDO read, just pass through
            tmsc_response = tmsc_current;
        }
        
        // Read internal JTAG signals for debugging
        uint8_t tck  = g_dut->tck_o & 1u;
        uint8_t tms  = g_dut->tms_o & 1u;
        uint8_t tdi  = g_dut->tdi_o & 1u;
        uint8_t tdo_comb = g_dut->tdo_comb_o & 1u;  // Combinatorial TDO (what bridge uses)
        uint8_t tdo_reg  = g_dut->tdo_o & 1u;       // Negedge-registered (valid when TCK=0)
        uint8_t online = g_dut->online_o & 1u;

#ifdef VERBOSE
        static int cmd_count = 0;
        ++cmd_count;
        if (cmd_count <= 150 || (cmd_count > 4400 && cmd_count <= 4700)) {
            fprintf(stderr, "[VPI] #%04d: TCKC=%u TMSC_in=%u | oe=%u out=%u → TMSC=%u (resp=%u) | TCK=%u TMS=%u TDI=%u TDO_comb=%u TDO_reg=%u online=%u\n",
                    cmd_count, tckc, tmsc, oe, out, tmsc_current, tmsc_response, tck, tms, tdi, tdo_comb, tdo_reg, online);
        }
#endif

        memset(c->buffer_in, 0, sizeof(c->buffer_in));
        c->buffer_in[0] = tmsc_response;  // Send buffered value on TCKC rising edge
        return send_exact(fd, c, sizeof(*c));
    }

    case CMD_STOP_SIMU:
        fprintf(stderr, "[VPI] CMD_STOP_SIMU received\n");
        return false;

    default:
        fprintf(stderr, "[VPI] Unknown VPI command 0x%08x\n", cmd);
        return true;
    }
}

// ─── Main ────────────────────────────────────────────────────────────────────
int main(int argc, char **argv) {
    // Parse arguments
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            g_vpi_port = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--trace") == 0) {
            g_trace_enabled = true;
        } else if (strcmp(argv[i], "--max-cycles") == 0 && i + 1 < argc) {
            g_max_cycles = strtoull(argv[++i], nullptr, 10);
        } else if (strcmp(argv[i], "--clks-per-vpi") == 0 && i + 1 < argc) {
            g_clks_per_vpi = atoi(argv[++i]);
        }
    }

    // Create Verilator context
    const std::unique_ptr<VerilatedContext> contextp{new VerilatedContext};
    contextp->commandArgs(argc, argv);
    contextp->traceEverOn(g_trace_enabled);

    // Create DUT
    g_dut = new Vtop{contextp.get(), "top"};

    // Optional tracing
    if (g_trace_enabled) {
        g_tfp = new VerilatedFstC;
        g_dut->trace(g_tfp, 99);
        g_tfp->open("cjtag_vpi.fst");
        fprintf(stderr, "[VPI] FST tracing enabled → cjtag_vpi.fst\n");
    }

    // Signal handling
    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);

    // Reset
    g_dut->ntrst_i = 0;
    g_dut->tckc_i = 0;
    g_dut->tmsc_i = 0;
    run_clocks(20);
    g_dut->ntrst_i = 1;
    run_clocks(g_boot_clks);

    fprintf(stderr, "[VPI] Reset complete, starting VPI server on port %d\n", g_vpi_port);

    // Create TCP server
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        fprintf(stderr, "[VPI] socket() failed: %s\n", strerror(errno));
        return 1;
    }

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(g_vpi_port);

    if (bind(server_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "[VPI] bind() failed: %s\n", strerror(errno));
        close(server_fd);
        return 1;
    }

    if (listen(server_fd, 1) < 0) {
        fprintf(stderr, "[VPI] listen() failed: %s\n", strerror(errno));
        close(server_fd);
        return 1;
    }

    fprintf(stderr, "[VPI] Listening on port %d, waiting for OpenOCD...\n", g_vpi_port);

    // Accept connection (blocking)
    int client_fd = accept(server_fd, nullptr, nullptr);
    if (client_fd < 0) {
        fprintf(stderr, "[VPI] accept() failed: %s\n", strerror(errno));
        close(server_fd);
        return 1;
    }

    fprintf(stderr, "[VPI] Client connected\n");

    // Main VPI command loop
    uint64_t cmd_count = 0;
    bool running = true;

    while (running && !g_abort && (g_max_cycles == 0 || g_cycle < g_max_cycles)) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(client_fd, &rfds);
        struct timeval tv = { 0, 1000 }; // 1 ms

        int ready = select(client_fd + 1, &rfds, nullptr, nullptr, &tv);
        if (ready > 0) {
            struct vpi_cmd cmd;
            if (!recv_exact(client_fd, &cmd, sizeof(cmd))) {
                fprintf(stderr, "[VPI] Connection closed by OpenOCD\n");
                break;
            }
            running = process_vpi_cmd(client_fd, &cmd);
            ++cmd_count;
        } else if (ready == 0) {
            // Timeout: advance idle clocks
            run_clocks(g_idle_clks);
        }
    }

    fprintf(stderr, "[VPI] Done: %llu commands, %llu cycles\n",
            (unsigned long long)cmd_count, (unsigned long long)g_cycle);

    // Cleanup
    close(client_fd);
    close(server_fd);
    if (g_tfp) {
        g_tfp->flush();
        g_tfp->close();
        delete g_tfp;
    }
    g_dut->final();
    delete g_dut;

    return 0;
}
