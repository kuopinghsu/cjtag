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
    int jtag_vpi_get_free_run_cycles();  // Get remaining free-run cycles
    void jtag_vpi_dec_free_run_cycles(); // Decrement free-run counter
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

    // Disable stdout buffering for immediate verbose output
    setvbuf(stdout, NULL, _IONBF, 0);

    // Create DUT instance
    Vtop* top = new Vtop;

    // Initialize waveform trace (if enabled)
    VerilatedFstC* tfp = nullptr;
    bool trace_enabled = false;

    // Check for WAVE environment variable or +trace argument
    const char* wave_env = getenv("WAVE");
    // Don't use commandArgsPlusMatch - it's unreliable with --trace-fst compile flag
    // Just rely on WAVE environment variable

    #ifdef VERBOSE
    printf("DEBUG: WAVE env = %s\n", wave_env ? wave_env : "NULL");
    #endif

    if (wave_env && atoi(wave_env) == 1) {
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

    // Main loop with OpenOCD-controlled TCKC
    // TCKC is driven directly by OpenOCD via CMD_OSCAN1_RAW commands
    // No automatic TCKC toggling - OpenOCD has full control for precise timing
    //
    // CLOCK SYSTEM:
    // - System clock: 100MHz (10ns period)
    // - TCKC: Controlled by OpenOCD, not free-running
    // - VPI commands checked every 100 system clocks (1us)
    //
    enum EventType { SYS_CLK_LOW, SYS_CLK_HIGH, VPI_CHECK };
    EventType next_event = SYS_CLK_LOW;
    int sys_clocks_since_vpi = 0;
    const int sys_clocks_per_vpi = 100;  // Check VPI every 100 sys clocks (1us)
    vluint64_t tick_count = 0;

    while (!g_shutdown && !Verilated::gotFinish()) {
        switch (next_event) {
            case SYS_CLK_LOW:
                // System clock low phase
                top->clk_i = 0;
                top->eval();
                if (trace_enabled && tfp) tfp->dump(main_time);
                main_time++;
                next_event = SYS_CLK_HIGH;
                break;

            case SYS_CLK_HIGH:
                // System clock high phase
                top->clk_i = 1;
                top->eval();
                if (trace_enabled && tfp) tfp->dump(main_time);
                main_time++;
                sys_clocks_since_vpi++;

                // Time to check VPI?
                if (sys_clocks_since_vpi >= sys_clocks_per_vpi) {
                    next_event = VPI_CHECK;
                } else {
                    next_event = SYS_CLK_LOW;
                }
                break;

            case VPI_CHECK:
                // Process VPI commands from OpenOCD
                // OpenOCD directly controls TCKC via CMD_OSCAN1_RAW
                if (!jtag_vpi_tick(top)) {
                    printf("VPI requested simulation stop\n");
                    g_shutdown = true;
                }
                sys_clocks_since_vpi = 0;
                next_event = SYS_CLK_LOW;
                break;
        }

        // Print status periodically
        tick_count++;
        if (tick_count % 10000000 == 0) {
            printf("Simulation running... time=%llu cycles\n",
                   (unsigned long long)main_time / 2);
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
