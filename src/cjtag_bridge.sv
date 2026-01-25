// =============================================================================
// cJTAG Bridge (IEEE 1149.7 Subset)
// =============================================================================
// Converts 2-pin cJTAG (TCKC/TMSC) to 4-pin JTAG (TCK/TMS/TDI/TDO)
// Implements OScan1 format with TAP.7 star-2 scan topology
//
// ARCHITECTURE:
// - Uses system clock (100MHz) to sample async cJTAG inputs
// - Detects TCKC edges and TMSC transitions
// - Implements escape sequence detection per IEEE 1149.7:
//   * 4-5 TMSC toggles (TCKC high): Deselection
//   * 6-7 TMSC toggles (TCKC high): Selection (activation)
//   * 8+ TMSC toggles (TCKC high): Reset to OFFLINE
// =============================================================================

module cjtag_bridge (
    input  logic        clk_i,          // System clock (e.g., 100MHz)
    input  logic        ntrst_i,        // Optional reset (active low)

    // cJTAG Interface (2-wire)
    input  logic        tckc_i,         // cJTAG clock from probe
    input  logic        tmsc_i,         // cJTAG data/control in
    output logic        tmsc_o,         // cJTAG data out
    output logic        tmsc_oen,       // cJTAG output enable (0=output, 1=input)

    // JTAG Interface (4-wire)
    output logic        tck_o,          // JTAG clock to TAP
    output logic        tms_o,          // JTAG TMS to TAP
    output logic        tdi_o,          // JTAG TDI to TAP
    input  logic        tdo_i,          // JTAG TDO from TAP

    // Status
    output logic        online_o,       // 1=online, 0=offline
    output logic        nsp_o           // Standard Protocol indicator
);

    // =========================================================================
    // State Machine States
    // =========================================================================
    typedef enum logic [2:0] {
        ST_OFFLINE          = 3'b000,
        ST_ESCAPE           = 3'b001,
        ST_ONLINE_ACT       = 3'b010,
        ST_OSCAN1           = 3'b011
    } state_t;

    state_t state;

    // =========================================================================
    // Input Synchronizers (2-stage for metastability)
    // =========================================================================
    logic [1:0]  tckc_sync;
    logic [1:0]  tmsc_sync;

    // Synchronized and edge-detected signals
    logic        tckc_s;                // Synchronized TCKC
    logic        tmsc_s;                // Synchronized TMSC
    logic        tckc_prev;             // Previous TCKC for edge detection
    logic        tmsc_prev;             // Previous TMSC for edge detection
    logic        tckc_posedge;          // TCKC positive edge detected
    logic        tckc_negedge;          // TCKC negative edge detected
    logic        tmsc_edge;             // TMSC edge detected

    // =========================================================================
    // State Machine and Control Registers
    // =========================================================================
    logic [4:0]  tmsc_toggle_count;     // TMSC toggle counter for escape sequences
    logic        tckc_is_high;          // TCKC currently held high
    logic [4:0]  tckc_high_cycles;      // Counter for TCKC high duration

    logic [10:0] oac_shift;             // Online Activation Code shift register (11 bits)
    logic [3:0]  oac_count;             // Bit counter for OAC reception
    logic [1:0]  bit_pos;               // Position in 3-bit OScan1 packet
    logic        tmsc_sampled;          // TMSC sampled on TCKC negedge

    // JTAG outputs (registered)
    logic        tck_int;
    logic        tms_int;
    logic        tdi_int;
    logic        tmsc_oen_int;          // TMSC output enable (registered)

    // =========================================================================
    // Input Synchronizers - 2-stage for metastability protection
    // =========================================================================
    /* verilator lint_off SYNCASYNCNET */
    always_ff @(posedge clk_i or negedge ntrst_i) begin
        if (!ntrst_i) begin
            tckc_sync <= 2'b00;
            tmsc_sync <= 2'b00;
        end else begin
            tckc_sync <= {tckc_sync[0], tckc_i};
            tmsc_sync <= {tmsc_sync[0], tmsc_i};
        end
    end
    /* verilator lint_on SYNCASYNCNET */

    assign tckc_s = tckc_sync[1];
    assign tmsc_s = tmsc_sync[1];

    // =========================================================================
    // Edge Detection Logic
    // =========================================================================
    always_ff @(posedge clk_i or negedge ntrst_i) begin
        if (!ntrst_i) begin
            tckc_prev <= 1'b0;
            tmsc_prev <= 1'b0;
            tckc_posedge <= 1'b0;
            tckc_negedge <= 1'b0;
            tmsc_edge <= 1'b0;
        end else begin
            tckc_prev <= tckc_s;
            tmsc_prev <= tmsc_s;

            // Detect TCKC edges
            tckc_posedge <= (!tckc_prev && tckc_s);
            tckc_negedge <= (tckc_prev && !tckc_s);

            // Detect TMSC edge (any transition)
            tmsc_edge <= (tmsc_prev != tmsc_s);
        end
    end

    // =========================================================================
    // Escape Sequence Detection
    // =========================================================================
    // Monitors: TCKC held high + TMSC toggling
    // Counts TMSC edges while TCKC remains high
    // Requires TCKC to be held high for at least MIN_ESC_CYCLES to be valid
    // =========================================================================
    localparam MIN_ESC_CYCLES = 20;  // Minimum system clock cycles TCKC must be high

    always_ff @(posedge clk_i or negedge ntrst_i) begin
        if (!ntrst_i) begin
            tckc_is_high <= 1'b0;
            tckc_high_cycles <= 5'd0;
            tmsc_toggle_count <= 5'd0;
        end else begin
            // Track when TCKC goes high
            if (tckc_posedge) begin
                tckc_is_high <= 1'b1;
                tckc_high_cycles <= 5'd1;
                tmsc_toggle_count <= 5'd0;  // Reset counter on TCKC rising edge
            end
            // Track TCKC going low (escape sequence ends)
            else if (tckc_negedge) begin
                tckc_is_high <= 1'b0;
                tckc_high_cycles <= 5'd0;
            end
            // TCKC is held high - monitor TMSC and count cycles
            else if (tckc_is_high && tckc_s) begin
                // Increment high duration counter (with saturation at 31)
                if (tckc_high_cycles < 5'd31) begin
                    tckc_high_cycles <= tckc_high_cycles + 5'd1;
                end

                // Count TMSC toggles while TCKC is high
                if (tmsc_edge) begin
                    tmsc_toggle_count <= tmsc_toggle_count + 5'd1;

                    `ifdef VERBOSE
                    $display("[%0t] Escape: TMSC toggle #%0d detected (TCKC high for %0d cycles)",
                             $time, tmsc_toggle_count + 5'd1, tckc_high_cycles);
                    `endif
                end
            end
        end
    end

    // =========================================================================
    // Main State Machine - runs on system clock
    // =========================================================================
    always_ff @(posedge clk_i or negedge ntrst_i) begin
        if (!ntrst_i) begin
            state           <= ST_OFFLINE;
            oac_shift       <= 11'd0;
            oac_count       <= 4'd0;
            bit_pos         <= 2'd0;
            tmsc_sampled    <= 1'b0;
        end else begin
            case (state)
                // =============================================================
                // OFFLINE: Wait for escape sequence
                // =============================================================
                ST_OFFLINE: begin
                    // Check for escape sequence completion on TCKC falling edge
                    // Require TCKC was held high long enough to be intentional
                    if (tckc_negedge && tckc_high_cycles >= MIN_ESC_CYCLES) begin
                        `ifdef VERBOSE
                        $display("[%0t] OFFLINE: Escape sequence ended, toggles=%0d, cycles=%0d",
                                 $time, tmsc_toggle_count, tckc_high_cycles);
                        `endif

                        // Evaluate escape sequence based on toggle count
                        if (tmsc_toggle_count >= 5'd6 && tmsc_toggle_count <= 5'd7) begin
                            // Selection escape (6-7 toggles) - enter activation
                            state <= ST_ONLINE_ACT;
                            oac_shift <= 11'd0;
                            oac_count <= 4'd0;

                            `ifdef VERBOSE
                            $display("[%0t] OFFLINE -> ONLINE_ACT (%0d toggles)",
                                     $time, tmsc_toggle_count);
                            `endif
                        end
                        // 4-5 toggles (deselection) stays in OFFLINE
                        // 8+ toggles (reset) stays in OFFLINE
                    end
                end

                // =============================================================
                // ONLINE_ACT: Receive OAC + EC + CP (12 bits on TCKC edges)
                // =============================================================
                ST_ONLINE_ACT: begin
                    // Sample TMSC on TCKC falling edge
                    if (tckc_negedge) begin
                        oac_shift <= {tmsc_s, oac_shift[10:1]};

                        `ifdef VERBOSE
                        $display("[%0t] ONLINE_ACT: bit %0d, tmsc_s=%b, oac_shift=%b",
                                 $time, oac_count, tmsc_s, oac_shift);
                        `endif

                        // After 12 bits, check the activation code
                        if (oac_count == 4'd11) begin
                            `ifdef VERBOSE
                            $display("[%0t] Checking OAC: received=%b, expected=%b",
                                     $time, {tmsc_s, oac_shift[10:0]}, 12'b0000_1000_1100);
                            `endif

                            // Expected: OAC=1100 (LSB first), EC=1000, CP=0000
                            // Combined: 0000_1000_1100 (MSB to LSB order in shift reg)
                            if ({tmsc_s, oac_shift[10:0]} == 12'b0000_1000_1100) begin
                                state <= ST_OSCAN1;
                                bit_pos <= 2'd0;

                                `ifdef VERBOSE
                                $display("[%0t] ONLINE_ACT -> OSCAN1, bit_pos=0", $time);
                                `endif
                            end else begin
                                // Invalid code, return offline
                                state <= ST_OFFLINE;

                                `ifdef VERBOSE
                                $display("[%0t] ONLINE_ACT -> OFFLINE (invalid OAC)", $time);
                                `endif
                            end
                            oac_count <= 4'd0;
                        end else begin
                            oac_count <= oac_count + 4'd1;
                        end
                    end
                end

                // =============================================================
                // OSCAN1: Active mode with 3-bit scan packets
                // =============================================================
                ST_OSCAN1: begin
                    // Check for escape sequence while in OSCAN1
                    // Require TCKC was held high long enough to be intentional (not just normal clock pulse)
                    if (tckc_negedge && tckc_high_cycles >= MIN_ESC_CYCLES) begin
                        `ifdef VERBOSE
                        $display("[%0t] OSCAN1: Escape sequence detected, toggles=%0d, cycles=%0d",
                                 $time, tmsc_toggle_count, tckc_high_cycles);
                        `endif

                        // Check for reset escape (8+ toggles)
                        if (tmsc_toggle_count >= 5'd8) begin
                            state <= ST_OFFLINE;
                            bit_pos <= 2'd0;

                            `ifdef VERBOSE
                            $display("[%0t] OSCAN1 -> OFFLINE (reset escape, %0d toggles)",
                                     $time, tmsc_toggle_count);
                            `endif
                        end
                        // Otherwise stay in OSCAN1 (ignore other escape types)
                    end
                    // Normal OSCAN1 operation - sample on TCKC falling edge
                    else if (tckc_negedge) begin
                        // Sample TMSC for current bit position
                        tmsc_sampled <= tmsc_s;

                        // Advance to next bit position
                        case (bit_pos)
                            2'd0: bit_pos <= 2'd1;  // nTDI sampled
                            2'd1: bit_pos <= 2'd2;  // TMS sampled
                            2'd2: bit_pos <= 2'd0;  // TDO sampled (from device)
                            default: bit_pos <= 2'd0;
                        endcase

                        `ifdef VERBOSE
                        $display("[%0t] OSCAN1 negedge: bit_pos=%0d, tmsc_s=%b",
                                 $time, bit_pos, tmsc_s);
                        `endif
                    end
                end

                default: begin
                    state <= ST_OFFLINE;
                end
            endcase
        end
    end

    // =========================================================================
    // Output Generation - runs on system clock, updates on TCKC edges
    // =========================================================================
    always_ff @(posedge clk_i or negedge ntrst_i) begin
        if (!ntrst_i) begin
            tck_int         <= 1'b0;
            tms_int         <= 1'b1;
            tdi_int         <= 1'b0;
            tmsc_oen_int    <= 1'b1;  // Default to input mode
        end else begin
            case (state)
                ST_OFFLINE, ST_ONLINE_ACT: begin
                    // Keep JTAG interface idle
                    tck_int <= 1'b0;
                    tms_int <= 1'b1;
                    tdi_int <= 1'b0;
                    tmsc_oen_int <= 1'b1;  // Input mode
                end

                ST_OSCAN1: begin
                    // Update outputs based on TCKC edges and bit position

                    // On TCKC rising edge - generate TCK pulse and drive TDO
                    if (tckc_posedge) begin
                        case (bit_pos)
                            2'd0: begin
                                // Start of new packet - TCK low, prepare for nTDI
                                tck_int <= 1'b0;
                                tmsc_oen_int <= 1'b1;  // Input mode for nTDI
                            end

                            2'd1: begin
                                // After nTDI sampled - update TDI, prepare for TMS
                                tdi_int <= ~tmsc_sampled;
                                tmsc_oen_int <= 1'b1;  // Input mode for TMS

                                `ifdef VERBOSE
                                $display("[%0t] OSCAN1 posedge: bit_pos=1, tdi_int=%b (inverted from %b)",
                                         $time, ~tmsc_sampled, tmsc_sampled);
                                `endif
                            end

                            2'd2: begin
                                // After TMS sampled - generate TCK pulse, drive TDO
                                tms_int <= tmsc_sampled;
                                tck_int <= 1'b1;       // Generate TCK pulse
                                tmsc_oen_int <= 1'b0;  // Output mode for TDO

                                `ifdef VERBOSE
                                $display("[%0t] OSCAN1 posedge: bit_pos=2, TCK high, tms_int=%b, driving TDO=%b",
                                         $time, tmsc_sampled, tdo_i);
                                `endif
                            end

                            default: begin
                                tmsc_oen_int <= 1'b1;  // Default to input
                            end
                        endcase
                    end

                    // On TCKC falling edge - lower TCK
                    if (tckc_negedge && bit_pos == 2'd2) begin
                        tck_int <= 1'b0;  // End TCK pulse

                        `ifdef VERBOSE
                        $display("[%0t] OSCAN1 negedge: bit_pos=2, TCK low", $time);
                        `endif
                    end
                end

                default: begin
                    tck_int <= 1'b0;
                    tms_int <= 1'b1;
                    tdi_int <= 1'b0;
                    tmsc_oen_int <= 1'b1;
                end
            endcase
        end
    end

    // =========================================================================
    // Output Logic
    // =========================================================================
    assign tck_o = tck_int;
    assign tms_o = tms_int;
    assign tdi_o = tdi_int;

    // TMSC output: Drive TDO during third bit of OScan1 packet
    assign tmsc_o = (state == ST_OSCAN1 && bit_pos == 2'd2) ? tdo_i : 1'b0;

    // TMSC output enable: Registered, changes on rising edge
    assign tmsc_oen = tmsc_oen_int;

    // Status outputs
    assign online_o = (state == ST_OSCAN1);
    assign nsp_o = (state != ST_OSCAN1);  // Standard Protocol active when not in OScan1

endmodule
