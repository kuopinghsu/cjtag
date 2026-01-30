// Simple IDCODE test - direct copy of working test_cjtag logic
#include "Vtop.h"
#include "verilated.h"
#include "verilated_fst_c.h"
#include <stdio.h>

class TestHarness {
public:
    Vtop* dut;
    VerilatedFstC* tfp;
    vluint64_t time;
    bool clk_state;
    bool trace_enabled;

    TestHarness() : time(0), clk_state(false) {
        dut = new Vtop;

        // Enable tracing only if WAVE environment variable is set
        const char* wave_env = getenv("WAVE");
        trace_enabled = (wave_env && atoi(wave_env) == 1);

        if (trace_enabled) {
            Verilated::traceEverOn(true);
            tfp = new VerilatedFstC;
            dut->trace(tfp, 99);
            tfp->open("cjtag.fst");
        } else {
            tfp = nullptr;
        }

        dut->ntrst_i = 0;
        dut->tckc_i = 0;
        dut->tmsc_i = 1;

        // Run system clock during reset
        for (int i = 0; i < 100; i++) {
            tick();
        }

        dut->ntrst_i = 1;

        // Let system clock run for a bit after reset
        for (int i = 0; i < 20; i++) {
            tick();
        }
    }

    ~TestHarness() {
        if (tfp) {
            tfp->close();
            delete tfp;
        }
        delete dut;
    }

    void tick() {
        clk_state = !clk_state;
        dut->clk_i = clk_state;
        dut->eval();
        if (tfp) {
            tfp->dump(time);
        }
        time++;
    }

    void tckc_cycle(int tmsc_val) {
        dut->tckc_i = 1;
        dut->tmsc_i = tmsc_val;
        for (int i = 0; i < 10; i++) {
            tick();
        }
        dut->tckc_i = 0;
        for (int i = 0; i < 10; i++) {
            tick();
        }
    }

    void send_escape_sequence(int edge_count) {
        dut->tckc_i = 1;
        for (int i = 0; i < 5; i++) {
            tick();
        }
        for (int i = 0; i < edge_count; i++) {
            dut->tmsc_i = !dut->tmsc_i;
            for (int j = 0; j < 10; j++) {
                tick();
            }
        }
        dut->tckc_i = 0;
        for (int i = 0; i < 10; i++) {
            tick();
        }
    }

    void send_oac_sequence() {
        // Full 12-bit activation packet per IEEE 1149.7:
        // OAC (4 bits) + EC (4 bits) + CP (4 bits) - all LSB first
        int oac[4] = {0, 0, 1, 1};  // OAC: 1100 LSB first
        int ec[4]  = {0, 0, 0, 1};  // EC: 1000 LSB first
        int cp[4];                  // CP: calculated

        // Calculate CP: CP[i] = OAC[i] XOR EC[i]
        for (int i = 0; i < 4; i++) {
            cp[i] = oac[i] ^ ec[i];
        }

        // Send all 12 bits
        for (int i = 0; i < 4; i++) tckc_cycle(oac[i]);
        for (int i = 0; i < 4; i++) tckc_cycle(ec[i]);
        for (int i = 0; i < 4; i++) tckc_cycle(cp[i]);
    }

    void send_oscan1_packet(int tdi, int tms, int* tdo_out) {
        tckc_cycle(!tdi);
        tckc_cycle(tms);

        dut->tckc_i = 0;
        dut->tmsc_i = 0;
        for (int i = 0; i < 10; i++) {
            tick();
        }
        dut->tckc_i = 1;
        for (int i = 0; i < 10; i++) {
            tick();
        }
        if (tdo_out) {
            *tdo_out = dut->tmsc_o;
        }
        dut->tckc_i = 0;
        for (int i = 0; i < 10; i++) {
            tick();
        }
    }
};

uint32_t read_idcode(TestHarness& tb) {
    // Navigate TAP to SHIFT-DR state
    tb.send_oscan1_packet(0, 1, nullptr); // TMS=1: RUN_TEST_IDLE -> SELECT_DR
    tb.send_oscan1_packet(0, 0, nullptr); // TMS=0: SELECT_DR -> CAPTURE_DR

    // Enter SHIFT-DR and read first bit
    int first_bit = 0;
    tb.send_oscan1_packet(0, 0, &first_bit); // TMS=0: CAPTURE_DR -> SHIFT-DR, reads bit 0

    // Read remaining 31 bits (total 32 bits)
    uint32_t idcode = first_bit;
    for (int i = 1; i < 32; i++) {
        int tdo = 0;
        int tms = (i == 31) ? 1 : 0; // Last bit exits SHIFT-DR to EXIT1-DR
        tb.send_oscan1_packet(0, tms, &tdo);
        idcode |= (tdo << i);
    }

    // Return to RUN_TEST_IDLE from EXIT1-DR
    tb.send_oscan1_packet(0, 1, nullptr); // TMS=1: EXIT1-DR -> UPDATE-DR
    tb.send_oscan1_packet(0, 0, nullptr); // TMS=0: UPDATE-DR -> RUN_TEST_IDLE

    return idcode;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    // Check for iteration count from environment or argument
    const char* iter_env = getenv("IDCODE_ITERATIONS");
    int iterations = iter_env ? atoi(iter_env) : 100;  // Default: 100 iterations

    if (argc > 1) {
        iterations = atoi(argv[1]);
    }

    printf("========================================\n");
    printf("JTAG IDCODE Stress Test via cJTAG Bridge\n");
    printf("Testing %d iterations\n", iterations);
    printf("========================================\n\n");

    TestHarness tb;

    // Go online first
    printf("Sending escape sequence...\n");
    tb.send_escape_sequence(6);
    printf("Sending OAC sequence...\n");
    tb.send_oac_sequence();

    // Ensure TCKC is stable low and run system clock
    tb.dut->tckc_i = 0;
    tb.dut->tmsc_i = 0;
    for (int i = 0; i < 20; i++) {
        tb.tick();
    }

    // Check if we went online
    printf("online_o: %d\n", tb.dut->online_o);
    if (!tb.dut->online_o) {
        printf("❌ ERROR: Bridge did not go online after OAC!\n");
        return 1;
    }

    // Navigate to RUN_TEST_IDLE initially
    printf("Navigating to RUN_TEST_IDLE...\n");
    tb.send_oscan1_packet(0, 0, nullptr); // TMS=0: RESET -> RUN_TEST_IDLE

    // Stress test: Read IDCODE multiple times
    printf("\nStarting stress test...\n");
    int failures = 0;
    for (int iter = 0; iter < iterations; iter++) {
        uint32_t idcode = read_idcode(tb);

        if (idcode != 0x1DEAD3FF) {
            printf("❌ Iteration %d FAILED: Got 0x%08X, Expected 0x1DEAD3FF\n", iter + 1, idcode);
            failures++;
        } else if (iter % 10 == 0 || iter == iterations - 1) {
            printf("✓ Iteration %d: 0x%08X\n", iter + 1, idcode);
        }
    }

    printf("\n========================================\n");
    printf("Stress Test Complete: %d iterations\n", iterations);
    printf("Passed: %d\n", iterations - failures);
    printf("Failed: %d\n", failures);
    printf("========================================\n");

    if (failures == 0) {
        printf("✅ SUCCESS: All iterations passed!\n");
        return 0;
    } else {
        printf("❌ FAILURE: %d iterations failed\n", failures);
        return 1;
    }
}
