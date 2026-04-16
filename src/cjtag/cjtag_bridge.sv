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
// 2. Escape detection: TCKC held high during escape sequence
//    - During escape sequence, TCKC is held high while TMSC toggles
//    - Toggle count is evaluated on TCKC falling edge
//    - No minimum hold time required
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
    state_t      return_state;          // State to evaluate after escape sequence

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
    // =========================================================================
    always_ff @(posedge clk_i or negedge ntrst_i) begin
        if (!ntrst_i) begin
            tckc_is_high <= 1'b0;
            tmsc_toggle_count <= 5'd0;
        end else begin
            // Escape detection: Monitor TMSC toggles while TCKC is high
            // Active in ALL states to allow reset (8+ toggles) from any state
            // Track when TCKC goes high
            if (tckc_posedge) begin
                tckc_is_high <= 1'b1;
                tmsc_toggle_count <= 5'd0;  // Reset counter on TCKC rising edge

                `ifdef VERBOSE
                $display("[%0t] TCKC POSEDGE detected! Resetting toggle count", $time);
                `endif
            end
            // Track TCKC going low (escape sequence ends)
            else if (tckc_negedge) begin
                tckc_is_high <= 1'b0;

                `ifdef VERBOSE
                $display("[%0t] TCKC NEGEDGE detected! Toggle count was %0d", $time, tmsc_toggle_count);
                `endif
            end
            // TCKC is held high - monitor TMSC toggles
            else if (tckc_is_high && tckc_s && tmsc_edge) begin
                // Count TMSC toggles while TCKC is high
                tmsc_toggle_count <= tmsc_toggle_count + 5'd1;

                `ifdef VERBOSE
                $display("[%0t] Escape: TMSC toggle #%0d detected",
                         $time, tmsc_toggle_count + 5'd1);
                `endif
            end
        end
    end

    // =========================================================================
    // Main State Machine - runs on system clock
    // =========================================================================
    always_ff @(posedge clk_i or negedge ntrst_i) begin
        if (!ntrst_i) begin
            state           <= ST_OFFLINE;
            return_state    <= ST_OFFLINE;
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
                    // Check for escape sequence on TCKC falling edge
                    if (tckc_negedge && tmsc_toggle_count >= 5'd4) begin
                        return_state <= ST_OFFLINE;
                        state <= ST_ESCAPE;

                        `ifdef VERBOSE
                        $display("[%0t] OFFLINE -> ESCAPE (toggles=%0d)",
                                 $time, tmsc_toggle_count);
                        `endif
                    end
                end

                // =============================================================
                // ESCAPE: Evaluate escape sequence and transition
                // =============================================================
                ST_ESCAPE: begin
                    `ifdef VERBOSE
                    $display("[%0t] ESCAPE: Evaluating toggles=%0d from return_state=%0d",
                             $time, tmsc_toggle_count, return_state);
                    `endif

                    // Reset escape (8+ toggles) - always goes to OFFLINE
                    if (tmsc_toggle_count >= 5'd8) begin
                        state <= ST_OFFLINE;
                        activation_shift <= 11'd0;
                        activation_count <= 4'd0;
                        bit_pos <= 2'd0;

                        `ifdef VERBOSE
                        $display("[%0t] ESCAPE -> OFFLINE (reset: %0d toggles)",
                                 $time, tmsc_toggle_count);
                        `endif
                    end
                    // Selection escape (6-7 toggles) - OFFLINE -> ONLINE_ACT
                    else if (tmsc_toggle_count >= 5'd6 && tmsc_toggle_count <= 5'd7 &&
                             return_state == ST_OFFLINE) begin
                        state <= ST_ONLINE_ACT;
                        activation_shift <= 11'd0;
                        activation_count <= 4'd0;

                        `ifdef VERBOSE
                        $display("[%0t] ESCAPE -> ONLINE_ACT (selection: %0d toggles)",
                                 $time, tmsc_toggle_count);
                        `endif
                    end
                    // Deselection escape (4-5 toggles) - OSCAN1 -> OFFLINE
                    else if (tmsc_toggle_count >= 5'd4 && tmsc_toggle_count <= 5'd5 &&
                             return_state == ST_OSCAN1) begin
                        state <= ST_OFFLINE;
                        activation_shift <= 11'd0;
                        activation_count <= 4'd0;
                        bit_pos <= 2'd0;

                        `ifdef VERBOSE
                        $display("[%0t] ESCAPE -> OFFLINE (deselection: %0d toggles)",
                                 $time, tmsc_toggle_count);
                        `endif
                    end
                    // Invalid escape sequence - force offline
                    else begin
                        state <= ST_OFFLINE;
                        activation_shift <= 11'd0;
                        activation_count <= 4'd0;
                        bit_pos <= 2'd0;

                        `ifdef VERBOSE
                        $display("[%0t] ESCAPE -> OFFLINE (invalid sequence: %0d toggles)",
                                 $time, tmsc_toggle_count);
                        `endif
                    end
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

                    // Check for escape sequence (takes priority)
                    if (tckc_negedge && tmsc_toggle_count >= 5'd4) begin
                        return_state <= ST_ONLINE_ACT;
                        state <= ST_ESCAPE;
                        activation_shift <= 11'd0;
                        activation_count <= 4'd0;

                        `ifdef VERBOSE
                        $display("[%0t] ONLINE_ACT -> ESCAPE (toggles=%0d)",
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
                            // Combine current bit with previous 11 bits and validate inline
                            // Packet: {tmsc_s, activation_shift[10:0]}
                            // OAC: bits [3:0], EC: bits [7:4], CP: bits [11:8]

                            `ifdef VERBOSE
                            $display("[%0t] Checking activation packet:", $time);
                            $display("    Full packet: %b", {tmsc_s, activation_shift[10:0]});
                            $display("    OAC=%b (expected=1100), EC=%b (expected=1000), CP=%b",
                                     {tmsc_s, activation_shift[10:0]}[3:0],
                                     {tmsc_s, activation_shift[10:0]}[7:4],
                                     {tmsc_s, activation_shift[10:0]}[11:8]);
                            $display("    Calculated CP=%b, CP valid=%b",
                                     {tmsc_s, activation_shift[10:0]}[3:0] ^ {tmsc_s, activation_shift[10:0]}[7:4],
                                     {tmsc_s, activation_shift[10:0]}[11:8] == ({tmsc_s, activation_shift[10:0]}[3:0] ^ {tmsc_s, activation_shift[10:0]}[7:4]));
                            `endif

                            // Validate: OAC=1100, EC=1000, CP matches calculated value
                            // OAC check: bits [3:0] == 4'b1100
                            // EC check: bits [7:4] == 4'b1000
                            // CP check: bits [11:8] == (bits[3:0] XOR bits[7:4])
                            if (activation_shift[3:0] == 4'b1100 &&
                                activation_shift[7:4] == 4'b1000 &&
                                {tmsc_s, activation_shift[10:8]} == (activation_shift[3:0] ^ activation_shift[7:4])) begin
                                state <= ST_OSCAN1;
                                bit_pos <= 2'd0;

                                `ifdef VERBOSE
                                $display("[%0t] ONLINE_ACT -> OSCAN1 (activation packet valid!)", $time);
                                `endif
                            end else begin
                                state <= ST_OFFLINE;

                                `ifdef VERBOSE
                                if ({tmsc_s, activation_shift[10:0]}[11:8] != ({tmsc_s, activation_shift[10:0]}[3:0] ^ {tmsc_s, activation_shift[10:0]}[7:4])) begin
                                    $display("[%0t] ONLINE_ACT -> OFFLINE (CP parity error: rx=%b calc=%b)",
                                             $time,
                                             {tmsc_s, activation_shift[10:0]}[11:8],
                                             {tmsc_s, activation_shift[10:0]}[3:0] ^ {tmsc_s, activation_shift[10:0]}[7:4]);
                                end else if ({tmsc_s, activation_shift[10:0]}[3:0] != 4'b1100) begin
                                    $display("[%0t] ONLINE_ACT -> OFFLINE (invalid OAC: %b)", $time, {tmsc_s, activation_shift[10:0]}[3:0]);
                                end else begin
                                    $display("[%0t] ONLINE_ACT -> OFFLINE (invalid EC: %b)", $time, {tmsc_s, activation_shift[10:0]}[7:4]);
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

                    // Check for escape sequence on TCKC falling edge (takes priority)
                    if (tckc_negedge && tmsc_toggle_count >= 5'd4) begin
                        return_state <= ST_OSCAN1;
                        state <= ST_ESCAPE;

                        `ifdef VERBOSE
                        $display("[%0t] OSCAN1 -> ESCAPE (toggles=%0d)",
                                 $time, tmsc_toggle_count);
                        `endif
                    end
                    // Sample on TCKC falling edge (normal operation)
                    else if (tckc_negedge) begin
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
            tdo_sampled     <= 1'b0;
        end else begin
            case (state)
                ST_OFFLINE, ST_ONLINE_ACT, ST_ESCAPE: begin
                    // Keep JTAG interface idle
                    tck_int <= 1'b0;
                    tms_int <= 1'b1;
                    tdi_int <= 1'b0;
                    tmsc_oen_int <= 1'b1;  // Input mode
                end

                ST_OSCAN1: begin
                    // Update outputs based on TCKC edges and bit position

                    // Sample TDO while TCK is high: the TAP registers TDO on negedge TCK,
                    // so tdo_i is stable and correct throughout the TCK-high period.
                    // Continuously latching here ensures tdo_sampled is captured and held
                    // for the probe to read on TMSC during the TDO bit slot.
                    if (tck_int) begin
                        tdo_sampled <= tdo_i;
                    end

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
                                // After TMS sampled - generate TCK pulse, enable TDO output.
                                // tdo_sampled will be updated once tck_int is high (above).
                                tms_int <= tmsc_sampled;
                                tck_int <= 1'b1;       // Generate TCK pulse
                                tmsc_oen_int <= 1'b0;  // Output mode for TDO

                                `ifdef VERBOSE
                                $display("[%0t] OSCAN1 posedge: bit_pos=2, TCK high, tms_int=%b",
                                         $time, tmsc_sampled);
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

    // TMSC output: Drive TDO only during the third (TDO) bit slot of an OScan1 packet.
    // Output enable (tmsc_oen_int=0) gates it at other times, but driving 0 outside
    // the slot avoids any glitch that could be misinterpreted by other TAPs in a scan chain.
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

    // =========================================================================
    // SystemVerilog Assertions (SVA) - Verification Only
    // =========================================================================
    `ifndef SYNTHESIS

    // -------------------------------------------------------------------------
    // State Machine Assertions
    // -------------------------------------------------------------------------

    // Assert: State must always be one of the defined states
    property valid_state;
        @(posedge clk_i) disable iff (!ntrst_i)
        (state == ST_OFFLINE) || (state == ST_ESCAPE) ||
        (state == ST_ONLINE_ACT) || (state == ST_OSCAN1);
    endproperty
    assert property (valid_state)
        else $error("[ASSERT] Invalid state detected: %0d", state);

    // Assert: Reset brings system to OFFLINE state
    property reset_to_offline;
        @(posedge clk_i)
        !ntrst_i |=> (state == ST_OFFLINE);
    endproperty
    assert property (reset_to_offline)
        else $error("[ASSERT] Reset did not transition to OFFLINE");

    // Assert: State transitions are legal (split by source state)
    property legal_transition_from_offline;
        @(posedge clk_i) disable iff (!ntrst_i)
        (state == ST_OFFLINE) |=>
            (state == ST_OFFLINE) || (state == ST_ESCAPE);
    endproperty
    assert property (legal_transition_from_offline)
        else $error("[ASSERT] Illegal transition from OFFLINE to %0d", state);

    property legal_transition_from_escape;
        @(posedge clk_i) disable iff (!ntrst_i)
        (state == ST_ESCAPE) |=>
            (state == ST_OFFLINE) || (state == ST_ONLINE_ACT);
    endproperty
    assert property (legal_transition_from_escape)
        else $error("[ASSERT] Illegal transition from ESCAPE to %0d", state);

    property legal_transition_from_online_act;
        @(posedge clk_i) disable iff (!ntrst_i)
        (state == ST_ONLINE_ACT) |=>
            (state == ST_ONLINE_ACT) || (state == ST_ESCAPE) ||
            (state == ST_OSCAN1) || (state == ST_OFFLINE);
    endproperty
    assert property (legal_transition_from_online_act)
        else $error("[ASSERT] Illegal transition from ONLINE_ACT to %0d", state);

    property legal_transition_from_oscan1;
        @(posedge clk_i) disable iff (!ntrst_i)
        (state == ST_OSCAN1) |=>
            (state == ST_OSCAN1) || (state == ST_ESCAPE) || (state == ST_OFFLINE);
    endproperty
    assert property (legal_transition_from_oscan1)
        else $error("[ASSERT] Illegal transition from OSCAN1 to %0d", state);

    // -------------------------------------------------------------------------
    // Counter Bounds Assertions
    // -------------------------------------------------------------------------

    // Assert: Toggle counter must not exceed 31 (5-bit saturating counter)
    // Note: This is tautological for a 5-bit counter but useful for formal verification
    /* verilator lint_off CMPCONST */
    property toggle_count_bounds;
        @(posedge clk_i) disable iff (!ntrst_i)
        tmsc_toggle_count <= 5'd31;
    endproperty
    assert property (toggle_count_bounds)
        else $error("[ASSERT] Toggle counter overflow: %0d", tmsc_toggle_count);
    /* verilator lint_on CMPCONST */

    // Assert: Activation bit counter must be in range 0-11 when in ONLINE_ACT
    property activation_count_bounds;
        @(posedge clk_i) disable iff (!ntrst_i)
        (state == ST_ONLINE_ACT) |-> (activation_count <= 4'd11);
    endproperty
    assert property (activation_count_bounds)
        else $error("[ASSERT] Activation counter out of bounds: %0d", activation_count);

    // Assert: Bit position must be 0, 1, or 2 in OSCAN1 state
    property bit_pos_bounds;
        @(posedge clk_i) disable iff (!ntrst_i)
        (state == ST_OSCAN1) |-> (bit_pos <= 2'd2);
    endproperty
    assert property (bit_pos_bounds)
        else $error("[ASSERT] Bit position out of bounds: %0d", bit_pos);

    // Assert: Bit position advances on TCKC negedge when stable in OSCAN1
    // (Simplified check - just ensures progression happens)
    property bit_pos_advances;
        @(posedge clk_i) disable iff (!ntrst_i)
        (state == ST_OSCAN1 && $past(state) == ST_OSCAN1 &&
         $past(state, 2) == ST_OSCAN1 && $past(tckc_negedge)) |->
            (bit_pos != $past(bit_pos, 2));
    endproperty
    assert property (bit_pos_advances)
        else $error("[ASSERT] Bit position did not advance after TCKC negedge");

    // -------------------------------------------------------------------------
    // Status Signal Assertions
    // -------------------------------------------------------------------------

    // Assert: online_o is high only in OSCAN1 state
    property online_only_in_oscan1;
        @(posedge clk_i) disable iff (!ntrst_i)
        online_o == (state == ST_OSCAN1);
    endproperty
    assert property (online_only_in_oscan1)
        else $error("[ASSERT] online_o mismatch: online_o=%b, state=%0d",
                    online_o, state);

    // Assert: nsp_o is inverse of online state
    property nsp_inverse_of_online;
        @(posedge clk_i) disable iff (!ntrst_i)
        nsp_o == !online_o;
    endproperty
    assert property (nsp_inverse_of_online)
        else $error("[ASSERT] nsp_o should be inverse of online_o");

    // -------------------------------------------------------------------------
    // TCK Generation Assertions
    // -------------------------------------------------------------------------

    // Assert: TCK should only go high in OSCAN1 state at bit position 2
    property tck_only_in_oscan1;
        @(posedge clk_i) disable iff (!ntrst_i)
        tck_o |-> (state == ST_OSCAN1);
    endproperty
    assert property (tck_only_in_oscan1)
        else $error("[ASSERT] TCK high outside OSCAN1 state");

    // Assert: TCK high only at bit position 2 in OSCAN1
    property tck_only_at_bit2;
        @(posedge clk_i) disable iff (!ntrst_i)
        (state == ST_OSCAN1 && tck_o) |-> (bit_pos == 2'd2 || $past(bit_pos) == 2'd2);
    endproperty
    assert property (tck_only_at_bit2)
        else $error("[ASSERT] TCK high at wrong bit position: %0d", bit_pos);

    // Assert: TMS stays high when not in OSCAN1 (JTAG idle)
    // Check with 1-cycle delay to account for pipeline
    property tms_high_when_offline;
        @(posedge clk_i) disable iff (!ntrst_i)
        ($past(state) != ST_OSCAN1) |-> tms_o;
    endproperty
    assert property (tms_high_when_offline)
        else $error("[ASSERT] TMS should be high when not in OSCAN1");

    // -------------------------------------------------------------------------
    // TMSC Bidirectional Control Assertions
    // -------------------------------------------------------------------------

    // Assert: TMSC output enable low only in OSCAN1 (or 1 cycle after leaving)
    // Allow 1-cycle delay for pipeline
    property tmsc_oen_output_mode;
        @(posedge clk_i) disable iff (!ntrst_i)
        !tmsc_oen |-> (state == ST_OSCAN1 || $past(state) == ST_OSCAN1);
    endproperty
    assert property (tmsc_oen_output_mode)
        else $error("[ASSERT] TMSC output enabled outside OSCAN1");

    // Assert: TMSC in input mode (oen=1) when not in OSCAN1
    // Check with 1-cycle delay for pipeline
    property tmsc_oen_input_when_offline;
        @(posedge clk_i) disable iff (!ntrst_i)
        ($past(state) != ST_OSCAN1 && $past(state, 2) != ST_OSCAN1) |-> tmsc_oen;
    endproperty
    assert property (tmsc_oen_input_when_offline)
        else $error("[ASSERT] TMSC should be in input mode when not in OSCAN1");

    // -------------------------------------------------------------------------
    // Escape Sequence Assertions
    // -------------------------------------------------------------------------

    // Assert: Toggle counter resets on TCKC rising edge
    property toggle_counter_reset_on_posedge;
        @(posedge clk_i) disable iff (!ntrst_i)
        tckc_posedge |=> (tmsc_toggle_count == 5'd0);
    endproperty
    assert property (toggle_counter_reset_on_posedge)
        else $error("[ASSERT] Toggle counter not reset on TCKC posedge: %0d",
                    tmsc_toggle_count);

    // Assert: Transition to ESCAPE requires toggle count >= 4
    property escape_requires_min_toggles;
        @(posedge clk_i) disable iff (!ntrst_i)
        (state != $past(state) && state == ST_ESCAPE) |->
            ($past(tmsc_toggle_count) >= 5'd4);
    endproperty
    assert property (escape_requires_min_toggles)
        else $error("[ASSERT] Entered ESCAPE with insufficient toggles: %0d",
                    $past(tmsc_toggle_count));

    // Assert: Return state is saved before entering ESCAPE
    property return_state_valid;
        @(posedge clk_i) disable iff (!ntrst_i)
        (state == ST_ESCAPE) |->
            (return_state == ST_OFFLINE || return_state == ST_ONLINE_ACT ||
             return_state == ST_OSCAN1);
    endproperty
    assert property (return_state_valid)
        else $error("[ASSERT] Invalid return_state in ESCAPE: %0d", return_state);

    // -------------------------------------------------------------------------
    // Synchronizer Assertions
    // -------------------------------------------------------------------------

    // Assert: Synchronizer stages are not X or Z in simulation
    property no_x_in_sync;
        @(posedge clk_i) disable iff (!ntrst_i)
        !$isunknown(tckc_sync) && !$isunknown(tmsc_sync);
    endproperty
    assert property (no_x_in_sync)
        else $error("[ASSERT] Unknown value in synchronizers");

    // -------------------------------------------------------------------------
    // Activation Packet Assertions
    // -------------------------------------------------------------------------

    // Assert: Activation counter resets when leaving ONLINE_ACT
    property activation_count_reset;
        @(posedge clk_i) disable iff (!ntrst_i)
        ($past(state) == ST_ONLINE_ACT && state != ST_ONLINE_ACT) |->
            (activation_count == 4'd0);
    endproperty
    assert property (activation_count_reset)
        else $error("[ASSERT] Activation counter not reset when leaving ONLINE_ACT: %0d",
                    activation_count);

    // Assert: When entering OSCAN1 from ONLINE_ACT, bit_pos must be 0
    property oscan1_starts_at_bit0;
        @(posedge clk_i) disable iff (!ntrst_i)
        ($past(state) == ST_ONLINE_ACT && state == ST_OSCAN1) |->
            (bit_pos == 2'd0);
    endproperty
    assert property (oscan1_starts_at_bit0)
        else $error("[ASSERT] OSCAN1 did not start at bit_pos 0: %0d", bit_pos);

    // -------------------------------------------------------------------------
    // Edge Detection Assertions
    // -------------------------------------------------------------------------

    // Assert: Posedge and negedge are mutually exclusive
    property edges_mutually_exclusive;
        @(posedge clk_i) disable iff (!ntrst_i)
        !(tckc_posedge && tckc_negedge);
    endproperty
    assert property (edges_mutually_exclusive)
        else $error("[ASSERT] Both TCKC posedge and negedge detected simultaneously");

    // Assert: TCKC edge detection corresponds to actual signal change
    // Note: Edge detection has 1 cycle delay, so check previous values
    property posedge_detection_valid;
        @(posedge clk_i) disable iff (!ntrst_i)
        tckc_posedge |-> ($past(tckc_prev) == 1'b0 && $past(tckc_s) == 1'b1);
    endproperty
    assert property (posedge_detection_valid)
        else $error("[ASSERT] Invalid TCKC posedge detection");

    property negedge_detection_valid;
        @(posedge clk_i) disable iff (!ntrst_i)
        tckc_negedge |-> ($past(tckc_prev) == 1'b1 && $past(tckc_s) == 1'b0);
    endproperty
    assert property (negedge_detection_valid)
        else $error("[ASSERT] Invalid TCKC negedge detection");

    // -------------------------------------------------------------------------
    // Coverage Properties
    // -------------------------------------------------------------------------

    // Cover: All states are reached
    cover property (@(posedge clk_i) state == ST_OFFLINE);
    cover property (@(posedge clk_i) state == ST_ESCAPE);
    cover property (@(posedge clk_i) state == ST_ONLINE_ACT);
    cover property (@(posedge clk_i) state == ST_OSCAN1);

    // Cover: All state transitions
    cover property (@(posedge clk_i) disable iff (!ntrst_i)
        $past(state) == ST_OFFLINE && state == ST_ESCAPE);
    cover property (@(posedge clk_i) disable iff (!ntrst_i)
        $past(state) == ST_ESCAPE && state == ST_ONLINE_ACT);
    cover property (@(posedge clk_i) disable iff (!ntrst_i)
        $past(state) == ST_ONLINE_ACT && state == ST_OSCAN1);
    cover property (@(posedge clk_i) disable iff (!ntrst_i)
        $past(state) == ST_OSCAN1 && state == ST_ESCAPE);

    // Cover: Escape sequences with different toggle counts
    cover property (@(posedge clk_i) disable iff (!ntrst_i)
        tmsc_toggle_count == 5'd4);
    cover property (@(posedge clk_i) disable iff (!ntrst_i)
        tmsc_toggle_count == 5'd6);
    cover property (@(posedge clk_i) disable iff (!ntrst_i)
        tmsc_toggle_count == 5'd8);
    cover property (@(posedge clk_i) disable iff (!ntrst_i)
        tmsc_toggle_count == 5'd31);  // Saturation

    // Cover: Full OScan1 packet processing (all bit positions)
    cover property (@(posedge clk_i) disable iff (!ntrst_i)
        state == ST_OSCAN1 && bit_pos == 2'd0);
    cover property (@(posedge clk_i) disable iff (!ntrst_i)
        state == ST_OSCAN1 && bit_pos == 2'd1);
    cover property (@(posedge clk_i) disable iff (!ntrst_i)
        state == ST_OSCAN1 && bit_pos == 2'd2);

    `endif // SYNTHESIS

endmodule
