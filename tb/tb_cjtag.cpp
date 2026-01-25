// =============================================================================
// C++ Testbench for Verilator Simulation
// =============================================================================
// Main simulation driver with VPI interface support
// =============================================================================

#include "Vtop.h"
#include "verilated.h"
#include "verilated_fst_c.h"
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>

// VPI interface functions (from jtag_vpi.cpp)
extern "C" {
    void jtag_vpi_init(int port);
    bool jtag_vpi_tick(Vtop* top);
    void jtag_vpi_close();
}

// Global flag for graceful shutdown
static bool g_shutdown = false;

void signal_handler(int signum) {
    printf("\nReceived signal %d, shutting down...\n", signum);
    g_shutdown = true;
}

int main(int argc, char** argv) {
    // Initialize Verilator
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    // Create DUT instance
    Vtop* top = new Vtop;

    // Initialize waveform trace (if enabled)
    VerilatedFstC* tfp = nullptr;
    bool trace_enabled = false;

    // Check for WAVE environment variable or +trace argument
    const char* wave_env = getenv("WAVE");
    if ((wave_env && atoi(wave_env) == 1) || Verilated::commandArgsPlusMatch("trace")) {
        trace_enabled = true;
        tfp = new VerilatedFstC;
        top->trace(tfp, 99);  // Trace 99 levels of hierarchy
        tfp->open("cjtag.fst");
        printf("FST waveform tracing enabled: cjtag.fst\n");
    }

    // Setup signal handlers
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    // Initialize VPI server
    int vpi_port = 3333;
    if (const char* port_env = getenv("VPI_PORT")) {
        vpi_port = atoi(port_env);
    }
    jtag_vpi_init(vpi_port);

    // Initial reset
    top->clk_i = 0;
    top->ntrst_i = 0;
    top->tckc_i = 0;
    top->tmsc_i = 1;

    printf("=================================================\n");
    printf("cJTAG Bridge Simulation with Verilator\n");
    printf("=================================================\n");
    printf("System Clock:    100 MHz\n");
    printf("VPI Port:        %d\n", vpi_port);
    printf("Waveform:        %s\n", trace_enabled ? "Enabled (cjtag.fst)" : "Disabled");
    printf("=================================================\n");
    printf("Waiting for OpenOCD connection...\n");
    printf("Run: openocd -f openocd/cjtag.cfg\n");
    printf("Press Ctrl+C to exit\n");
    printf("=================================================\n\n");

    // Simulation time
    vluint64_t main_time = 0;
    const vluint64_t reset_cycles = 100;

    // Release reset after some cycles
    while (main_time < reset_cycles && !g_shutdown) {
        top->ntrst_i = (main_time > 10) ? 1 : 0;

        // Generate system clock (100 MHz = 10ns period, 5ns half-period)
        // In simulation, we use arbitrary time units, so just toggle each cycle
        top->clk_i = (main_time % 2) == 0 ? 0 : 1;

        // TCKC not driven during reset (will come from VPI)
        top->tckc_i = 0;

        // Evaluate model
        top->eval();

        // Dump waveform
        if (trace_enabled && tfp) {
            tfp->dump(main_time);
        }

        main_time++;
    }

    printf("Reset complete, entering main loop...\n\n");

    // Main simulation loop
    vluint64_t tick_count = 0;
    const vluint64_t idle_interval = 1000;  // Cycles between VPI checks when idle

    while (!g_shutdown && !Verilated::gotFinish()) {
        // Generate system clock (continues running throughout simulation)
        top->clk_i = (main_time % 2) == 0 ? 0 : 1;

        // Process VPI commands (VPI controls tckc_i and tmsc_i)
        if (!jtag_vpi_tick(top)) {
            printf("VPI requested simulation stop\n");
            break;
        }

        // Evaluate model
        top->eval();

        // Dump waveform
        if (trace_enabled && tfp) {
            tfp->dump(main_time);
        }

        // Advance time (very small step for VPI responsiveness)
        main_time++;
        tick_count++;

        // Print status periodically
        if (tick_count % 1000000 == 0) {
            printf("Simulation running... time=%llu cycles\n",
                   (unsigned long long)main_time);
        }

        // Small delay to avoid busy-waiting (when no VPI activity)
        if (tick_count % idle_interval == 0) {
            usleep(100);  // 100 microseconds
        }
    }

    printf("\nSimulation ending at time %llu\n", (unsigned long long)main_time);

    // Cleanup
    if (trace_enabled && tfp) {
        tfp->flush();
        tfp->close();
        delete tfp;
    }

    jtag_vpi_close();

    top->final();
    delete top;

    printf("Simulation complete.\n");
    return 0;
}
