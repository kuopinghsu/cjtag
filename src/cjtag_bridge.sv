// =============================================================================
// cJTAG Bridge (IEEE 1149.7 Subset)
// =============================================================================
// Converts 2-pin cJTAG (TCKC/TMSC) to 4-pin JTAG (TCK/TMS/TDI/TDO)
// Implements OScan1 format with TAP.7 star-2 scan topology
//
// DESIGN LIMITATIONS:
// - OSCAN1 -> OFFLINE transition NOT supported via escape sequences
// - Use hardware reset (ntrst_i) to return from OSCAN1 to OFFLINE
// - Reason: Bidirectional TMSC conflicts with escape sequence detection
//           during packet bit 2 (TDO readback phase)
// =============================================================================

module cjtag_bridge (
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
    // Registers
    // =========================================================================
    logic [4:0]  edge_count;            // TMSC edge counter for escape detection
    logic [10:0] oac_shift;             // Online Activation Code shift register (11 bits)
    logic [3:0]  oac_count;             // Bit counter for OAC reception
    logic [1:0]  bit_pos;               // Position in 3-bit OScan1 packet
    logic        tmsc_prev;             // Previous TMSC for edge detection
    logic        tckc_high_hold;        // TCKC held high indicator
    logic        tmsc_changed;          // TMSC changed on last posedge (escape continues)
    logic        reset_escape;          // Signal from negedge to posedge to reset escape tracking

    // JTAG outputs (registered)
    logic        tck_int;
    logic        tms_int;
    logic        tdi_int;
    logic        tmsc_oen_int;          // TMSC output enable (registered)

    // OScan1 3-bit packet buffer (signals removed - not used in current implementation)

    // =========================================================================
    // Edge Detection for Escape Sequence
    // =========================================================================
    // During escape sequence: TCKC is held high, TMSC toggles
    // We sample TMSC on negedge to count edges that occurred while TCKC was high

    // =========================================================================
    // Sampled input (captured on negedge)
    // =========================================================================
    logic tmsc_sampled;

    // =========================================================================
    // Main State Machine - runs on FALLING edge of TCKC (samples inputs)
    // =========================================================================
    always_ff @(negedge tckc_i or negedge ntrst_i) begin
        if (!ntrst_i) begin
            state           <= ST_OFFLINE;
            oac_shift       <= 11'd0;
            oac_count       <= 4'd0;
            bit_pos         <= 2'd0;
            tmsc_sampled    <= 1'b0;
            reset_escape    <= 1'b0;
        end else begin
            // Sample the input
            tmsc_sampled    <= tmsc_i;

            `ifdef VERBOSE
            $display("[%0t] NEGEDGE: state=%0d, tmsc_i=%b", $time, state, tmsc_i);
            `endif

            case (state)
                // =============================================================
                // OFFLINE: Wait for escape sequence
                // =============================================================
                ST_OFFLINE: begin
                    `ifdef VERBOSE
                    $display("[%0t] OFFLINE: tckc_high_hold=%b, edge_count=%d, tmsc_i=%b, tmsc_prev=%b",
                             $time, tckc_high_hold, edge_count, tmsc_i, tmsc_prev);
                    `endif

                    // Check if we just ended an escape sequence (TMSC stopped toggling)
                    if (tckc_high_hold && !tmsc_changed) begin
                        `ifdef VERBOSE
                        $display("[%0t] OFFLINE: Escape ended, edge_count=%d", $time, edge_count);
                        `endif

                        // Evaluate escape sequence
                        if (edge_count >= 5'd3 && edge_count <= 5'd9) begin
                            // Valid escape: 3-5 edges or 7-9 edges both go to ONLINE_ACT
                            state <= ST_ONLINE_ACT;
                            oac_shift <= 11'd0;
                            oac_count <= 4'd0;

                            `ifdef VERBOSE
                            $display("[%0t] OFFLINE -> ONLINE_ACT (%d edges)", $time, edge_count);
                            `endif
                        end
                        // Note: tckc_high_hold and edge_count are reset in posedge block
                    end
                end

                // =============================================================
                // ONLINE_ACT: Receive OAC + EC + CP (12 bits)
                // =============================================================
                ST_ONLINE_ACT: begin
                    oac_shift <= {tmsc_i, oac_shift[10:1]};

                    `ifdef VERBOSE
                    $display("[%0t] ONLINE_ACT: bit %0d, tmsc_i=%b, oac_shift=%b",
                             $time, oac_count, tmsc_i, oac_shift);
                    `endif

                    // After 12 bits, check the activation code
                    if (oac_count == 4'd11) begin
                        `ifdef VERBOSE
                        $display("[%0t] Checking OAC: received=%b, expected=%b",
                                 $time, {tmsc_i, oac_shift[10:0]}, 12'b0000_1000_1100);
                        `endif

                        // Expected: OAC=1100 (LSB first), EC=1000, CP=0000
                        // Combined: 0000_1000_1100 (MSB to LSB order in shift reg)
                        if ({tmsc_i, oac_shift[10:0]} == 12'b0000_1000_1100) begin
                            state <= ST_OSCAN1;
                            bit_pos <= 2'd0;

                            `ifdef VERBOSE
                            $display("[%0t] ONLINE_ACT -> OSCAN1, bit_pos=0", $time);
                            `endif
                        end else begin
                            // Invalid code, return offline
                            state <= ST_OFFLINE;
                        end
                        oac_count <= 4'd0;
                    end else begin
                        oac_count <= oac_count + 4'd1;
                    end
                end

                // =============================================================
                // OSCAN1: Active mode with 3-bit scan packets
                // =============================================================
                // LIMITATION: OSCAN1 -> OFFLINE transition requires hardware reset (ntrst_i)
                // Escape sequences from OSCAN1 are not supported due to protocol complexity
                // with bidirectional TMSC during packet bit 2 (TDO readback)
                ST_OSCAN1: begin
                    // No escape detection in OSCAN1 state
                    // Only way out is hardware reset
                    reset_escape <= 1'b0;

                    // Always increment bit_pos for normal packet operation
                    // (unless we just transitioned to OFFLINE above)
                    if (state == ST_OSCAN1) begin
                        case (bit_pos)
                            2'd0: begin
                                // First bit: nTDI (inverted TDI)
                                bit_pos <= 2'd1;
                            end

                            2'd1: begin
                                // Second bit: TMS
                                bit_pos <= 2'd2;
                            end

                            2'd2: begin
                                // Third bit: TDO (from device)
                                bit_pos <= 2'd0;
                            end

                            default: bit_pos <= 2'd0;
                        endcase
                    end
                end

                default: begin
                    state <= ST_OFFLINE;
                end
            endcase
        end
    end

    // =========================================================================
    // Escape sequence tracking and output updates - runs on RISING edge of TCKC
    // =========================================================================
    always_ff @(posedge tckc_i or negedge ntrst_i) begin
        if (!ntrst_i) begin
            tck_int             <= 1'b0;
            tms_int             <= 1'b1;
            tdi_int             <= 1'b0;
            tmsc_oen_int        <= 1'b1;           // Default to input mode
            tckc_high_hold      <= 1'b0;
            edge_count          <= 5'd0;
            tmsc_prev           <= 1'b0;
            tmsc_changed        <= 1'b0;
        end else begin
            // Handle escape tracking and resets
            if (reset_escape) begin
                // Negedge requested reset after evaluating escape or normal cycle
                `ifdef VERBOSE
                $display("[%0t] POSEDGE: Reset escape tracking (reset_escape=1)", $time);
                `endif

                tckc_high_hold  <= 1'b0;
                edge_count      <= 5'd0;
                tmsc_changed    <= 1'b0;
                // After reset, will restart tracking below if in OFFLINE/OSCAN1
            end

            if (tckc_high_hold && state == ST_ONLINE_ACT) begin
                // Transitioned to ONLINE_ACT, reset tracking
                `ifdef VERBOSE
                $display("[%0t] POSEDGE: Reset escape tracking (entered ONLINE_ACT)", $time);
                `endif

                tckc_high_hold  <= 1'b0;
                edge_count      <= 5'd0;
                tmsc_changed    <= 1'b0;
            end

            // Escape tracking for OFFLINE/OSCAN1 states
            // This runs after any resets above, so tckc_high_hold reflects the reset state
            if ((state == ST_OFFLINE || state == ST_OSCAN1) && !tckc_high_hold) begin
                // Start fresh tracking (first posedge after reset or initial)
                `ifdef VERBOSE
                $display("[%0t] POSEDGE: Start escape tracking, tmsc_i=%b", $time, tmsc_i);
                `endif

                tckc_high_hold  <= 1'b1;
                edge_count      <= 5'd0;
                tmsc_prev       <= tmsc_i;
                tmsc_changed    <= 1'b0;
            end else if ((state == ST_OFFLINE || state == ST_OSCAN1) && tckc_high_hold) begin
                // Continue tracking (subsequent posedge, tckc_high_hold still set)
                `ifdef VERBOSE
                $display("[%0t] POSEDGE: Continue tracking, tmsc_i=%b, tmsc_prev=%b",
                         $time, tmsc_i, tmsc_prev);
                `endif

                tckc_high_hold <= 1'b1;  // Keep it set
                if (tmsc_i != tmsc_prev) begin
                    // TMSC changed - count edge
                    edge_count <= edge_count + 5'd1;
                    tmsc_changed <= 1'b1;

                    `ifdef VERBOSE
                    $display("[%0t] POSEDGE: TMSC edge! count=%d->%d, tmsc=%b->%b",
                             $time, edge_count, edge_count + 5'd1, tmsc_prev, tmsc_i);
                    `endif
                end else begin
                    // TMSC didn't change this cycle
                    tmsc_changed <= 1'b0;
                end
                tmsc_prev <= tmsc_i;
            end

            // Update outputs based on state (outputs change on rising edge)
            case (state)
                ST_OFFLINE: begin
                    tck_int <= 1'b0;
                    tms_int <= 1'b1;
                    tdi_int <= 1'b0;
                    tmsc_oen_int <= 1'b1;       // Input mode
                end

                ST_ONLINE_ACT: begin
                    tck_int <= 1'b0;
                    tms_int <= 1'b1;
                    tdi_int <= 1'b0;
                    tmsc_oen_int <= 1'b1;       // Input mode
                end

                ST_OSCAN1: begin
                    `ifdef VERBOSE
                    $display("[%0t] POSEDGE: OSCAN1 case, bit_pos=%d", $time, bit_pos);
                    `endif

                    // Update outputs based on bit position
                    // Note: bit_pos was incremented on the previous negedge
                    case (bit_pos)
                        2'd0: begin
                            // After TDO sampled on negedge, lower TCK on this posedge
                            tck_int <= 1'b0;
                            tmsc_oen_int <= 1'b1;   // Back to input mode for nTDI
                        end

                        2'd1: begin
                            // After nTDI sampled on negedge, update TDI on this posedge
                            tdi_int <= ~tmsc_sampled;
                            tmsc_oen_int <= 1'b1;   // Input mode for TMS

                            `ifdef VERBOSE
                            $display("[%0t] OSCAN1 posedge: bit_pos=1, tmsc_sampled=%b, tdi_int=%b",
                                     $time, tmsc_sampled, ~tmsc_sampled);
                            `endif
                        end

                        2'd2: begin
                            // After TMS sampled on negedge, update on this posedge
                            tms_int <= tmsc_sampled;
                            tck_int <= 1'b1;  // Generate TCK pulse
                            tmsc_oen_int <= 1'b0;   // Output mode for TDO

                            `ifdef VERBOSE
                            $display("[%0t] OSCAN1 posedge: bit_pos=2, TCK pulse, tdo_i=%b",
                                     $time, tdo_i);
                            `endif
                        end

                        default: begin
                            // Keep current values for any other bit_pos
                            tck_int <= tck_int;
                            tms_int <= tms_int;
                            tdi_int <= tdi_int;
                            tmsc_oen_int <= 1'b1;   // Default to input mode
                        end
                    endcase
                end

                default: begin
                    tck_int <= 1'b0;
                    tms_int <= 1'b1;
                    tdi_int <= 1'b0;
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
