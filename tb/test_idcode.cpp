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

    TestHarness() : time(0), clk_state(false) {
        dut = new Vtop;
        Verilated::traceEverOn(true);
        tfp = new VerilatedFstC;
        dut->trace(tfp, 99);
        tfp->open("idcode_test.fst");

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
        tfp->close();
        delete dut;
    }

    void tick() {
        clk_state = !clk_state;
        dut->clk_i = clk_state;
        dut->eval();
        tfp->dump(time++);
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
        // OAC = 0xB = {1,1,0,1} (4 bits, LSB first)
        int bits[4] = {1, 1, 0, 1};
        for (int i = 0; i < 4; i++) {
            tckc_cycle(bits[i]);
        }
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

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    printf("========================================\n");
    printf("JTAG IDCODE Test via cJTAG Bridge\n");
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

    // Navigate TAP to SHIFT-DR state
    printf("Navigating to SHIFT-DR...\n");
    tb.send_oscan1_packet(0, 0, nullptr); // TMS=0: RESET -> RUN_TEST_IDLE
    printf("After RUN_TEST_IDLE: tck_o=%d, tms_o=%d, tdo_o=%d\n", tb.dut->tck_o, tb.dut->tms_o, tb.dut->tdo_o);

    tb.send_oscan1_packet(0, 1, nullptr); // TMS=1: RUN_TEST_IDLE -> SELECT_DR
    printf("After SELECT_DR: tck_o=%d, tms_o=%d, tdo_o=%d\n", tb.dut->tck_o, tb.dut->tms_o, tb.dut->tdo_o);

    tb.send_oscan1_packet(0, 0, nullptr); // TMS=0: SELECT_DR -> CAPTURE_DR
    printf("After CAPTURE_DR: tck_o=%d, tms_o=%d, tdo_o=%d\n", tb.dut->tck_o, tb.dut->tms_o, tb.dut->tdo_o);

    // Enter SHIFT-DR and read first bit
    int first_bit = 0;
    tb.send_oscan1_packet(0, 0, &first_bit); // TMS=0: CAPTURE_DR -> SHIFT-DR, reads bit 0

    // Read remaining 31 bits (total 32 bits)
    uint32_t idcode = first_bit;
    printf("Bit 0: %d\n", first_bit);
    for (int i = 1; i < 32; i++) {
        int tdo = 0;
        int tms = (i == 31) ? 1 : 0; // Last bit exits SHIFT-DR
        tb.send_oscan1_packet(0, tms, &tdo);
        idcode |= (tdo << i);
        if (i < 8 || i % 8 == 7) {
            printf("Bit %d: %d\n", i, tdo);
        }
    }

    printf("\n========================================\n");
    printf("IDCODE Result: 0x%08X\n", idcode);
    printf("========================================\n");

    if (idcode == 0x1DEAD3FF) {
        printf("✅ SUCCESS: IDCODE matches expected value!\n");
        return 0;
    } else {
        printf("❌ FAILURE: Expected 0x1DEAD3FF\n");
        return 1;
    }
}
