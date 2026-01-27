// =============================================================================
// Simple JTAG TAP Controller (IEEE 1149.1)
// =============================================================================
// Basic TAP state machine for testing cJTAG bridge
// Supports standard JTAG operations with a simple 32-bit instruction register
// and 32-bit data register
// =============================================================================

module jtag_tap #(
    parameter IDCODE = 32'h1DEAD3FF,  // JTAG ID code
    parameter IR_LEN = 5              // Instruction register length
)(
    input  logic        tck_i,         // JTAG clock
    input  logic        tms_i,         // JTAG mode select
    input  logic        tdi_i,         // JTAG data in
    output logic        tdo_o,         // JTAG data out
    input  logic        ntrst_i        // JTAG reset (active low)
);

    // =========================================================================
    // TAP Controller States (IEEE 1149.1)
    // =========================================================================
    typedef enum logic [3:0] {
        TEST_LOGIC_RESET = 4'h0,
        RUN_TEST_IDLE    = 4'h1,
        SELECT_DR_SCAN   = 4'h2,
        CAPTURE_DR       = 4'h3,
        SHIFT_DR         = 4'h4,
        EXIT1_DR         = 4'h5,
        PAUSE_DR         = 4'h6,
        EXIT2_DR         = 4'h7,
        UPDATE_DR        = 4'h8,
        SELECT_IR_SCAN   = 4'h9,
        CAPTURE_IR       = 4'hA,
        SHIFT_IR         = 4'hB,
        EXIT1_IR         = 4'hC,
        PAUSE_IR         = 4'hD,
        EXIT2_IR         = 4'hE,
        UPDATE_IR        = 4'hF
    } tap_state_t;

    tap_state_t state, state_next;

    // =========================================================================
    // Instruction Register
    // =========================================================================
    typedef enum logic [4:0] {
        IDCODE_INSTR   = 5'b00001,
        BYPASS_INSTR   = 5'b11111,
        DTMCS_INSTR    = 5'b10000,  // RISC-V Debug DTM Control/Status
        DMI_INSTR      = 5'b10001   // RISC-V Debug Module Interface
    } instruction_t;

    logic [IR_LEN-1:0] ir_reg;         // Instruction register
    logic [IR_LEN-1:0] ir_shift;       // IR shift register

    // =========================================================================
    // Data Registers
    // =========================================================================
    logic        bypass_reg;           // Bypass register (1-bit)

    // =========================================================================
    // TAP State Machine
    // =========================================================================
    always_ff @(posedge tck_i or negedge ntrst_i) begin
        if (!ntrst_i) begin
            state <= TEST_LOGIC_RESET;
        end else begin
            state <= state_next;
            `ifdef VERBOSE
            $display("[%0t] TAP: tck_i posedge, tms_i=%b, state=%0d->%0d",
                     $time, tms_i, state, state_next);
            `endif
        end
    end

    // Next state logic
    always_comb begin
        case (state)
            TEST_LOGIC_RESET: state_next = tms_i ? TEST_LOGIC_RESET : RUN_TEST_IDLE;
            RUN_TEST_IDLE:    state_next = tms_i ? SELECT_DR_SCAN : RUN_TEST_IDLE;

            // DR path
            SELECT_DR_SCAN:   state_next = tms_i ? SELECT_IR_SCAN : CAPTURE_DR;
            CAPTURE_DR:       state_next = tms_i ? EXIT1_DR : SHIFT_DR;
            SHIFT_DR:         state_next = tms_i ? EXIT1_DR : SHIFT_DR;
            EXIT1_DR:         state_next = tms_i ? UPDATE_DR : PAUSE_DR;
            PAUSE_DR:         state_next = tms_i ? EXIT2_DR : PAUSE_DR;
            EXIT2_DR:         state_next = tms_i ? UPDATE_DR : SHIFT_DR;
            UPDATE_DR:        state_next = tms_i ? SELECT_DR_SCAN : RUN_TEST_IDLE;

            // IR path
            SELECT_IR_SCAN:   state_next = tms_i ? TEST_LOGIC_RESET : CAPTURE_IR;
            CAPTURE_IR:       state_next = tms_i ? EXIT1_IR : SHIFT_IR;
            SHIFT_IR:         state_next = tms_i ? EXIT1_IR : SHIFT_IR;
            EXIT1_IR:         state_next = tms_i ? UPDATE_IR : PAUSE_IR;
            PAUSE_IR:         state_next = tms_i ? EXIT2_IR : PAUSE_IR;
            EXIT2_IR:         state_next = tms_i ? UPDATE_IR : SHIFT_IR;
            UPDATE_IR:        state_next = tms_i ? SELECT_DR_SCAN : RUN_TEST_IDLE;

            default:          state_next = TEST_LOGIC_RESET;
        endcase
    end

    // =========================================================================
    // Instruction Register Operations
    // =========================================================================
    always_ff @(posedge tck_i or negedge ntrst_i) begin
        if (!ntrst_i) begin
            ir_reg <= IDCODE_INSTR;
            ir_shift <= '0;
        end else begin
            case (state)
                TEST_LOGIC_RESET: begin
                    ir_reg <= IDCODE_INSTR;
                end

                CAPTURE_IR: begin
                    // Load current instruction for readback
                    // Note: IEEE 1149.1 requires bits [1:0] = 01, but we implement full readback
                    ir_shift <= ir_reg;
                    `ifdef VERBOSE
                    $display("[%0t] TAP: CAPTURE_IR, loading ir_reg=%b (%h) into ir_shift",
                             $time, ir_reg, ir_reg);
                    `endif
                end

                SHIFT_IR: begin
                    ir_shift <= {tdi_i, ir_shift[IR_LEN-1:1]};
                    `ifdef VERBOSE
                    $display("[%0t] TAP: SHIFT_IR, tdi_i=%b, ir_shift=%b -> %b",
                             $time, tdi_i, ir_shift, {tdi_i, ir_shift[IR_LEN-1:1]});
                    `endif
                end

                UPDATE_IR: begin
                    ir_reg <= ir_shift;
                    `ifdef VERBOSE
                    $display("[%0t] TAP: UPDATE_IR, ir_reg=%b -> %b (%h)",
                             $time, ir_reg, ir_shift, ir_shift);
                    `endif
                end

                default: begin
                    // Do nothing for other states
                end
            endcase
        end
    end

    // =========================================================================
    // Data Register Operations - Use DTM module for RISC-V debug support
    // =========================================================================

    // DTM control signals
    logic dtm_tdo;
    logic capture_dr_pulse;
    logic shift_dr_pulse;
    logic update_dr_pulse;

    // Generate control pulses for DTM
    assign capture_dr_pulse = (state == CAPTURE_DR);
    assign shift_dr_pulse = (state == SHIFT_DR);
    assign update_dr_pulse = (state == UPDATE_DR);

    // Instantiate RISC-V Debug Transport Module
    riscv_dtm #(
        .IDCODE(IDCODE)
    ) u_dtm (
        .tck_i(tck_i),
        .tdi_i(tdi_i),
        .tdo_o(dtm_tdo),
        .capture_dr_i(capture_dr_pulse),
        .shift_dr_i(shift_dr_pulse),
        .update_dr_i(update_dr_pulse),
        .ir_i(ir_reg),
        .ntrst_i(ntrst_i)
    );

    // Bypass register for non-DTM operations
    always_ff @(posedge tck_i or negedge ntrst_i) begin
        if (!ntrst_i) begin
            bypass_reg <= 1'b0;
        end else begin
            case (state)
                CAPTURE_DR: begin
                    if (ir_reg == BYPASS_INSTR) bypass_reg <= 1'b0;
                end
                SHIFT_DR: begin
                    if (ir_reg == BYPASS_INSTR) bypass_reg <= tdi_i;
                end
                default: begin
                    // Hold value
                end
            endcase
        end
    end

    // =========================================================================
    // TDO Output Multiplexer
    // =========================================================================
    always_comb begin
        case (state)
            CAPTURE_IR, SHIFT_IR, EXIT1_IR: begin
                tdo_o = ir_shift[0];
            end

            CAPTURE_DR, SHIFT_DR, EXIT1_DR: begin
                case (ir_reg)
                    BYPASS_INSTR: tdo_o = bypass_reg;
                    default: tdo_o = dtm_tdo;  // All other instructions handled by DTM
                endcase
            end

            default: tdo_o = 1'b0;
        endcase
    end

    // =========================================================================
    // Debug Info (for simulation)
    // =========================================================================
    `ifdef VERBOSE
    /* verilator lint_off UNUSED */
    string state_name;
    /* verilator lint_on UNUSED */
    always_comb begin
        case (state)
            TEST_LOGIC_RESET: state_name = "RESET";
            RUN_TEST_IDLE:    state_name = "IDLE";
            SELECT_DR_SCAN:   state_name = "SEL_DR";
            CAPTURE_DR:       state_name = "CAP_DR";
            SHIFT_DR:         state_name = "SHFT_DR";
            EXIT1_DR:         state_name = "EX1_DR";
            PAUSE_DR:         state_name = "PAUSE_DR";
            EXIT2_DR:         state_name = "EX2_DR";
            UPDATE_DR:        state_name = "UPD_DR";
            SELECT_IR_SCAN:   state_name = "SEL_IR";
            CAPTURE_IR:       state_name = "CAP_IR";
            SHIFT_IR:         state_name = "SHFT_IR";
            EXIT1_IR:         state_name = "EX1_IR";
            PAUSE_IR:         state_name = "PAUSE_IR";
            EXIT2_IR:         state_name = "EX2_IR";
            UPDATE_IR:        state_name = "UPD_IR";
        endcase
    end
    `endif

endmodule
