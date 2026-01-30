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
//
// CLOCK RATIO REQUIREMENTS:
// 1. Synchronizer requirement: f_sys >= 6 × f_tckc
//    - 2-stage synchronizer needs 2 clocks to capture signal
//    - Edge detection needs 1 additional clock
//    - Each TCKC phase (high/low) must be stable for >= 3 system clocks
//    - Therefore: TCKC period >= 6 system clock cycles
//
// 2. Escape detection requirement: TCKC high period >= MIN_ESC_CYCLES (20)
//    - During escape sequence, TCKC must be held high for >= 20 system clocks
//    - This ensures intentional escape vs. spurious glitches
//    - Each TCKC edge during escape must allow sufficient time for toggle detection
//
// EXAMPLE: 100MHz system clock, 10MHz TCKC max
//    - TCKC period = 100ns, system period = 10ns
//    - Ratio: 100ns / 10ns = 10 system clocks per TCKC period (MEETS requirement >= 6)
//    - TCKC toggle every 5 system clocks = 50ns high, 50ns low (MEETS requirement >= 30ns)
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

    logic [10:0] activation_shift;      // Activation packet shift register (11 bits, 12th bit in tmsc_s)
    logic [3:0]  activation_count;      // Bit counter for activation packet (0-11)
    logic [1:0]  bit_pos;               // Position in 3-bit OScan1 packet
    logic        tmsc_sampled;          // TMSC sampled on TCKC negedge

    // JTAG outputs (registered)
    logic        tck_int;
    logic        tms_int;
    logic        tdi_int;
    logic        tmsc_oen_int;          // TMSC output enable (registered)
    logic        tdo_sampled;           // TDO sampled when TCK is high

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
    //
    // MIN_ESC_CYCLES: Optional glitch filter - not required by IEEE 1149.7
    // Set to 0 to disable (accepts escape on any TCKC negedge with valid toggle count)
    // Set to >0 to require TCKC held high for minimum cycles (filters noise)
    // =========================================================================
    // verilator lint_off UNUSEDPARAM
    localparam MIN_ESC_CYCLES = 0;  // Minimum system clock cycles TCKC must be high (0=disabled)
    // verilator lint_on UNUSEDPARAM

    always_ff @(posedge clk_i or negedge ntrst_i) begin
        if (!ntrst_i) begin
            tckc_is_high <= 1'b0;
            tckc_high_cycles <= 5'd0;
            tmsc_toggle_count <= 5'd0;
        end else begin
            // Escape detection: Monitor TMSC toggles while TCKC is high
            // Active in ALL states to allow reset (8+ toggles) from any state
            // Track when TCKC goes high
            if (tckc_posedge) begin
                tckc_is_high <= 1'b1;
                tckc_high_cycles <= 5'd1;
                tmsc_toggle_count <= 5'd0;  // Reset counter on TCKC rising edge

                `ifdef VERBOSE
                $display("[%0t] TCKC POSEDGE detected! Resetting toggle count", $time);
                `endif
            end
            // Track TCKC going low (escape sequence ends)
            else if (tckc_negedge) begin
                tckc_is_high <= 1'b0;
                tckc_high_cycles <= 5'd0;

                `ifdef VERBOSE
                $display("[%0t] TCKC NEGEDGE detected! Toggle count was %0d", $time, tmsc_toggle_count);
                `endif
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
            activation_shift <= 11'd0;
            activation_count <= 4'd0;
            bit_pos         <= 2'd0;
            tmsc_sampled    <= 1'b0;
        end else begin
            case (state)
                // =============================================================
                // OFFLINE: Wait for escape sequence
                // =============================================================
                ST_OFFLINE: begin
                    // Check for escape sequence completion on TCKC falling edge
                    if (tckc_negedge) begin
                        `ifdef VERBOSE
                        $display("[%0t] OFFLINE (state=%0d): Escape sequence ended, toggles=%0d, cycles=%0d",
                                 $time, state, tmsc_toggle_count, tckc_high_cycles);
                        `endif

                        // Evaluate escape sequence based on toggle count
                        if (tmsc_toggle_count >= 5'd6 && tmsc_toggle_count <= 5'd7) begin
                            // Selection escape (6-7 toggles) - enter activation
                            state <= ST_ONLINE_ACT;
                            activation_shift <= 11'd0;
                            activation_count <= 4'd0;

                            `ifdef VERBOSE
                            $display("[%0t] OFFLINE -> ONLINE_ACT (%0d toggles)",
                                     $time, tmsc_toggle_count);
                            `endif
                        end else if (tmsc_toggle_count >= 5'd8) begin
                            // Reset escape (8+ toggles) - stay in OFFLINE
                            `ifdef VERBOSE
                            $display("[%0t] OFFLINE: Reset escape detected (%0d toggles), staying OFFLINE",
                                     $time, tmsc_toggle_count);
                            `endif
                        end
                        // 4-5 toggles (deselection) stays in OFFLINE
                    end

                    `ifdef VERBOSE
                    else if (tckc_negedge) begin
                        $display("[%0t] OFFLINE: TCKC negedge but not enough cycles (%0d < %0d) or toggles=%0d",
                                 $time, tckc_high_cycles, MIN_ESC_CYCLES, tmsc_toggle_count);
                    end
                    `endif
                end

                // =============================================================
                // ONLINE_ACT: Receive OAC (4 bits on TCKC edges)
                // OAC = 0xB (1011 binary, LSB first: 1,1,0,1)
                // =============================================================
                ST_ONLINE_ACT: begin
                    `ifdef VERBOSE
                    // Debug every clock cycle in ONLINE_ACT
                    if (tckc_negedge || tckc_posedge) begin
                        $display("[%0t] ONLINE_ACT: tckc_negedge=%b tckc_posedge=%b activation_count=%0d tckc_s=%b tmsc_s=%b",
                                 $time, tckc_negedge, tckc_posedge, activation_count, tckc_s, tmsc_s);
                    end
                    `endif

                    // Check for reset escape (8+ toggles) at any time - takes priority
                    if (tckc_negedge && tmsc_toggle_count >= 5'd8) begin
                        state <= ST_OFFLINE;
                        activation_shift <= 11'd0;
                        activation_count <= 4'd0;

                        `ifdef VERBOSE
                        $display("[%0t] ONLINE_ACT -> OFFLINE (reset escape: %0d toggles)",
                                 $time, tmsc_toggle_count);
                        `endif
                    end
                    // Sample TMSC on TCKC falling edge (normal activation packet reception)
                    else if (tckc_negedge) begin
                        activation_shift <= {tmsc_s, activation_shift[10:1]};

                        `ifdef VERBOSE
                        $display("[%0t] ONLINE_ACT: bit %0d, tmsc_s=%b",
                                 $time, activation_count, tmsc_s);
                        `endif

                        // After 12 bits (count 0-11), check the full activation packet
                        // Format: OAC (4 bits) + EC (4 bits) + CP (4 bits) - all LSB first
                        // Expected: OAC=1100, EC=1000, CP=calculated parity
                        if (activation_count == 4'd11) begin
                            // Combine current bit with previous 11 bits: {tmsc_s, activation_shift[10:0]}
                            logic [11:0] received_packet;
                            logic [3:0] received_oac, received_ec, received_cp;
                            logic [3:0] calculated_cp;
                            logic cp_valid;

                            received_packet = {tmsc_s, activation_shift[10:0]};

                            // Extract fields (bits received LSB first)
                            received_oac = received_packet[3:0];   // OAC: bits 0-3
                            received_ec  = received_packet[7:4];   // EC: bits 4-7
                            received_cp  = received_packet[11:8];  // CP: bits 8-11

                            // Calculate CP: XOR of each bit position across OAC and EC
                            // CP[0] = OAC[0] XOR EC[0], CP[1] = OAC[1] XOR EC[1], etc.
                            calculated_cp = received_oac ^ received_ec;

                            // Validate CP (always enabled for IEEE 1149.7 compliance)
                            cp_valid = (received_cp == calculated_cp);

                            `ifdef VERBOSE
                            $display("[%0t] Checking activation packet:", $time);
                            $display("    Full packet: %b", received_packet);
                            $display("    OAC=%b (expected=1100), EC=%b (expected=1000), CP=%b",
                                     received_oac, received_ec, received_cp);
                            $display("    Calculated CP=%b, CP valid=%b", calculated_cp, cp_valid);
                            `endif

                            // Validate: OAC=1100, EC=1000, CP matches calculated value
                            if (received_oac == 4'b1100 && received_ec == 4'b1000 && cp_valid) begin
                                state <= ST_OSCAN1;
                                bit_pos <= 2'd0;

                                `ifdef VERBOSE
                                $display("[%0t] ONLINE_ACT -> OSCAN1 (activation packet valid!)", $time);
                                `endif
                            end else begin
                                state <= ST_OFFLINE;

                                `ifdef VERBOSE
                                if (!cp_valid) begin
                                    $display("[%0t] ONLINE_ACT -> OFFLINE (CP parity error: rx=%b calc=%b)",
                                             $time, received_cp, calculated_cp);
                                end else if (received_oac != 4'b1100) begin
                                    $display("[%0t] ONLINE_ACT -> OFFLINE (invalid OAC: %b)", $time, received_oac);
                                end else begin
                                    $display("[%0t] ONLINE_ACT -> OFFLINE (invalid EC: %b)", $time, received_ec);
                                end
                                `endif
                            end
                            activation_count <= 4'd0;
                        end else begin
                            // Not yet 12 bits, increment counter
                            activation_count <= activation_count + 4'd1;
                        end
                    end
                end

                // =============================================================
                // OSCAN1: Active mode with 3-bit scan packets
                // =============================================================
                ST_OSCAN1: begin
                    `ifdef VERBOSE
                    if (tckc_negedge)
                        $display("[%0t] OSCAN1 negedge: toggles=%0d, bit_pos=%0d",
                                 $time, tmsc_toggle_count, bit_pos);
                    if (tckc_posedge)
                        $display("[%0t] OSCAN1 posedge: toggles=%0d, bit_pos=%0d",
                                 $time, tmsc_toggle_count, bit_pos);
                    `endif

                    // Sample on TCKC falling edge
                    if (tckc_negedge) begin
                        // Check for deselection escape (4-5 toggles while TCKC was high)
                        if (tmsc_toggle_count >= 5'd4 && tmsc_toggle_count <= 5'd5) begin
                            `ifdef VERBOSE
                            $display("[%0t] *** OSCAN1 -> OFFLINE *** (deselection escape detected, toggles=%0d)",
                                     $time, tmsc_toggle_count);
                            `endif

                            state <= ST_OFFLINE;
                            activation_shift <= 11'd0;
                            activation_count <= 4'd0;
                            bit_pos <= 2'd0;
                        end
                        // Check for reset escape (8+ toggles while TCKC was high)
                        else if (tmsc_toggle_count >= 5'd8) begin
                            `ifdef VERBOSE
                            $display("[%0t] *** OSCAN1 -> OFFLINE *** (reset escape detected, toggles=%0d >= 8)",
                                     $time, tmsc_toggle_count);
                            `endif

                            state <= ST_OFFLINE;
                            activation_shift <= 11'd0;
                            activation_count <= 4'd0;
                            bit_pos <= 2'd0;
                        end
                        // Normal operation: sample TMSC for current bit position
                        else begin
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
            tdo_sampled     <= 1'b0;
        end else begin
            // Sample TDO when TCK is high (after TAP has updated it)
            if (tck_int && state == ST_OSCAN1 && bit_pos == 2'd2) begin
                tdo_sampled <= tdo_i;
            end

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
                                // TDO will be sampled on next clock cycle after TCK rises

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

    // TMSC output: Drive sampled TDO during third bit of OScan1 packet
    assign tmsc_o = (state == ST_OSCAN1 && bit_pos == 2'd2) ? tdo_sampled : 1'b0;

    // TMSC output enable: Registered, changes on rising edge
    assign tmsc_oen = tmsc_oen_int;

    // Status outputs
    assign online_o = (state == ST_OSCAN1);
    assign nsp_o = (state != ST_OSCAN1);  // Standard Protocol active when not in OScan1

    `ifdef VERBOSE
    // Monitor state changes
    logic [2:0] prev_state;
    always_ff @(posedge clk_i or negedge ntrst_i) begin
        if (!ntrst_i) begin
            prev_state <= 3'd0;  // ST_OFFLINE
        end else begin
            if (state != prev_state) begin
                $display("[%0t] STATE CHANGE: %0d -> %0d", $time, prev_state, state);
                prev_state <= state;
            end
        end
    end
    `endif

endmodule
