// =============================================================================
// Top-Level Testbench for cJTAG Bridge
// =============================================================================
// Connects cJTAG bridge to JTAG TAP and provides VPI interface
// Uses 100MHz system clock for cJTAG protocol detection
// =============================================================================

module top (
    input  logic clk_i,       // System clock (100MHz)
    input  logic ntrst_i,
    input  logic tckc_i,
    input  logic tmsc_i,
    output logic tmsc_o,
    output logic tmsc_oen,
    // Exposed internal signals for testing
    output logic tck_o,
    output logic tms_o,
    output logic tdi_o,
    output logic tdo_o,       // negedge-registered (valid when TCK low)
    output logic tdo_comb_o,  // combinatorial (what bridge actually samples)
    output logic online_o,
    output logic nsp_o
);

    // ==========================================================================
    // cJTAG Bridge Instance
    // ==========================================================================
    logic tdo_comb_w;  // Combinatorial TDO from TAP – used by bridge for OScan1 timing

    cjtag_bridge u_cjtag_bridge (
        .clk_i   (clk_i),
        .ntrst_i (ntrst_i),
        .tckc_i  (tckc_i),
        .tmsc_i  (tmsc_i),
        .tmsc_o  (tmsc_o),
        .tmsc_oen(tmsc_oen),
        .tck_o   (tck_o),
        .tms_o   (tms_o),
        .tdi_o   (tdi_o),
        .tdo_i   (tdo_comb_w),
        .online_o(online_o),
        .nsp_o   (nsp_o)
    );

    // ==========================================================================
    // JTAG TAP Instance
    // ==========================================================================
    jtag_tap #(
        .IDCODE(32'h1DEAD3FF),
        .IR_LEN(5)
    ) u_jtag_tap (
        .tck_i     (tck_o),
        .tms_i     (tms_o),
        .tdi_i     (tdi_o),
        .tdo_o     (tdo_o),       // negedge-registered external output
        .tdo_comb_o(tdo_comb_w),  // combinatorial path for bridge
        .ntrst_i   (ntrst_i)
    );

    // Expose combinatorial TDO for debug (this is what bridge actually uses)
    assign tdo_comb_o = tdo_comb_w;

    // ==========================================================================
    // Waveform Dumping
    // ==========================================================================
`ifndef SYNTHESIS
    initial begin
        if ($test$plusargs("trace")) begin
            $display("Enabling FST waveform dump...");
            $dumpfile("cjtag.fst");
            $dumpvars(0, top);
        end
    end

    // ==========================================================================
    // Debug Display
    // ==========================================================================
`ifdef VERBOSE
    /* verilator lint_off SYNCASYNCNET */
    always @(posedge tckc_i) begin
        if (online_o) begin
            $display("[%0t] cJTAG ONLINE: TCKC=%b TMSC_I=%b TMSC_O=%b TCK=%b TMS=%b TDI=%b TDO=%b", $time, tckc_i,
                     tmsc_i, tmsc_o, tck_o, tms_o, tdi_o, tdo_o);
        end
    end
    /* verilator lint_on SYNCASYNCNET */
`endif  // VERBOSE
`endif  // SYNTHESIS

endmodule
