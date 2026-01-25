// =============================================================================
// Top-Level Testbench for cJTAG Bridge
// =============================================================================
// Connects cJTAG bridge to JTAG TAP and provides VPI interface
// Uses 100MHz system clock for cJTAG protocol detection
// =============================================================================

module top (
    input  logic        clk_i,          // System clock (100MHz)
    input  logic        ntrst_i,
    input  logic        tckc_i,
    input  logic        tmsc_i,
    output logic        tmsc_o,
    output logic        tmsc_oen,
    // Exposed internal signals for testing
    output logic        tck_o,
    output logic        tms_o,
    output logic        tdi_o,
    output logic        tdo_o,
    output logic        online_o,
    output logic        nsp_o
);

    // ==========================================================================
    // cJTAG Bridge Instance
    // ==========================================================================
    cjtag_bridge u_cjtag_bridge (
        .clk_i      (clk_i),
        .ntrst_i    (ntrst_i),
        .tckc_i     (tckc_i),
        .tmsc_i     (tmsc_i),
        .tmsc_o     (tmsc_o),
        .tmsc_oen   (tmsc_oen),
        .tck_o      (tck_o),
        .tms_o      (tms_o),
        .tdi_o      (tdi_o),
        .tdo_i      (tdo_o),
        .online_o   (online_o),
        .nsp_o      (nsp_o)
    );

    // ==========================================================================
    // JTAG TAP Instance
    // ==========================================================================
    jtag_tap #(
        .IDCODE(32'h1DEAD3FF),
        .IR_LEN(5)
    ) u_jtag_tap (
        .tck_i      (tck_o),
        .tms_i      (tms_o),
        .tdi_i      (tdi_o),
        .tdo_o      (tdo_o),
        .ntrst_i    (ntrst_i)
    );

    // ==========================================================================
    // Waveform Dumping
    // ==========================================================================
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
    always @(posedge tckc_i) begin
        if (online_o) begin
            $display("[%0t] cJTAG ONLINE: TCKC=%b TMSC_I=%b TMSC_O=%b TCK=%b TMS=%b TDI=%b TDO=%b",
                     $time, tckc_i, tmsc_i, tmsc_o, tck_o, tms_o, tdi_o, tdo_o);
        end
    end
    `endif

endmodule
