// =============================================================================
// Top-Level FPGA Module for cJTAG Bridge
// =============================================================================
// FPGA synthesis version with differential clock input
// Uses IBUFDS to convert differential clock to single-ended
// 3-port interface: ntrst_i, tckc_i, tmsc (bidirectional)
// =============================================================================

module top (
    input  logic        clk_i_p,        // Differential clock positive (100MHz)
    input  logic        clk_i_n,        // Differential clock negative (100MHz)
    input  logic        ntrst_i,        // JTAG reset (active low)
    input  logic        tckc_i,         // cJTAG clock
    inout  wire         tmsc            // cJTAG bidirectional data
);

    // ==========================================================================
    // Internal Signals
    // ==========================================================================
    logic tmsc_i, tmsc_o, tmsc_oen;
    logic tck_o, tms_o, tdi_o, tdo_o;
    logic online_o, nsp_o;

    // ==========================================================================
    // Xilinx I/O Buffer for Bidirectional TMSC
    // ==========================================================================
    // IOBUF: Single-ended Bi-directional Buffer
    // tmsc_oen: 1=input (high-z), 0=output (drive)
    IOBUF #(
        .DRIVE(12),           // Drive strength (mA)
        .IBUF_LOW_PWR("TRUE"), // Low power mode
        .IOSTANDARD("LVCMOS18"),
        .SLEW("SLOW")         // Slew rate
    ) u_tmsc_iobuf (
        .O  (tmsc_i),         // Buffer output (to internal logic)
        .IO (tmsc),           // Buffer inout (to external pin)
        .I  (tmsc_o),         // Buffer input (from internal logic)
        .T  (tmsc_oen)        // 3-state enable (1=input, 0=output)
    );

    // ==========================================================================
    // Clock Buffer - Convert differential to single-ended
    // ==========================================================================
    logic clk_i;  // Internal single-ended clock

    IBUFDS #(
        .DIFF_TERM("FALSE"),
        .IBUF_LOW_PWR("TRUE"),
        .IOSTANDARD("LVDS")
    ) u_clk_ibufds (
        .I  (clk_i_p),
        .IB (clk_i_n),
        .O  (clk_i)
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
    always @(posedge tckc_i) begin
        if (online_o) begin
            $display("[%0t] cJTAG ONLINE: TCKC=%b TMSC_I=%b TMSC_O=%b TCK=%b TMS=%b TDI=%b TDO=%b",
                     $time, tckc_i, tmsc_i, tmsc_o, tck_o, tms_o, tdi_o, tdo_o);
        end
    end
    `endif
    `endif  // SYNTHESIS

endmodule
