// ============================================================================
// RISC-V Debug Transport Module (DTM) - Minimal Implementation
// ============================================================================
// Implements the JTAG Debug Transport Module interface per RISC-V Debug Spec
// Provides just enough functionality for OpenOCD to initialize
//
// Supported Instructions:
//   - IDCODE (0x01): Returns device ID
//   - DTMCS  (0x10): DTM Control and Status register
//   - DMI    (0x11): Debug Module Interface access
//   - BYPASS (0x1F): Bypass register
//
// NOTE: This is a MINIMAL implementation for simulation/testing
//       Does not implement full debug module functionality
// ============================================================================

module riscv_dtm #(
    parameter IDCODE = 32'h1DEAD3FF
) (
    // JTAG Interface (from TAP controller)
    input  logic       tck_i,        // JTAG clock
    input  logic       tdi_i,        // JTAG data in
    output logic       tdo_o,        // JTAG data out
    input  logic       capture_dr_i, // Capture-DR state
    input  logic       shift_dr_i,   // Shift-DR state
    input  logic       update_dr_i,  // Update-DR state
    input  logic [4:0] ir_i,         // Current instruction register

    // System
    input  logic       ntrst_i       // JTAG reset (active low)
);

    // ========================================================================
    // Instruction Opcodes
    // ========================================================================
    localparam IR_IDCODE  = 5'h01;  // IDCODE instruction
    localparam IR_DTMCS   = 5'h10;  // DTM Control and Status
    localparam IR_DMI     = 5'h11;  // Debug Module Interface
    localparam IR_BYPASS  = 5'h1F;  // Bypass

    // ========================================================================
    // DTMCS Register (32 bits) - Read Only
    // ========================================================================
    // Bits [31:18]: Reserved (0)
    // Bits [17]:    dmihardreset (0 - not supported)
    // Bits [16]:    dmireset (0 - not supported)
    // Bits [15]:    Reserved (0)
    // Bits [14:12]: idle (0 - no idle cycles required)
    // Bits [11:10]: dmistat (0 - no error)
    // Bits [9:4]:   abits (6 - DMI address width is 6 bits)
    // Bits [3:0]:   version (1 - DTM version 0.13)
    localparam [31:0] DTMCS_VALUE = {
        14'b0,           // [31:18] Reserved
        1'b0,            // [17] dmihardreset
        1'b0,            // [16] dmireset
        1'b0,            // [15] Reserved
        3'd0,            // [14:12] idle (no idle cycles needed)
        2'b00,           // [11:10] dmistat (no error)
        6'd6,            // [9:4] abits (DMI address = 6 bits)
        4'd1             // [3:0] version (0.13)
    };

    // ========================================================================
    // DMI Register (41 bits for abits=6)
    // ========================================================================
    // Bits [40:34]: address (7 bits, but only 6 used)
    // Bits [33:2]:  data (32 bits)
    // Bits [1:0]:   op (2 bits: 0=NOP, 1=Read, 2=Write, 3=Reserved)

    // Debug Module Registers (simplified)
    // Address 0x10: dmcontrol
    // Address 0x11: dmstatus
    // Address 0x16: hartinfo

    localparam [31:0] DMCONTROL_RESET = 32'h00000000;
    /* verilator lint_off WIDTHEXPAND */
    localparam [31:0] DMSTATUS_VALUE  = {
        9'b000000000,   // [31:23] Reserved (9 bits)
        1'b0,           // [22] impebreak
        1'b0,           // [21] Reserved
        1'b1,           // [20] allhavereset
        1'b1,           // [19] anyhavereset
        1'b0,           // [18] allresumeack
        1'b0,           // [17] anyresumeack
        1'b0,           // [16] allnonexistent
        1'b0,           // [15] anynonexistent
        1'b0,           // [14] allunavail
        1'b0,           // [13] anyunavail
        1'b0,           // [12] allrunning
        1'b0,           // [11] anyrunning
        1'b1,           // [10] allhalted
        1'b1,           // [9] anyhalted
        1'b1,           // [8] authenticated
        1'b0,           // [7] authbusy
        1'b0,           // [6] hasresethaltreq
        1'b0,           // [5] confstrptrvalid
        1'b0,           // [4] Reserved
        4'b0011         // [3:0] version (bits 3:0 = 0011 = 3)
    };
    /* verilator lint_on WIDTHEXPAND */

    localparam [31:0] HARTINFO_VALUE = {
        8'b0,           // [31:24] Reserved
        4'd1,           // [23:20] nscratch (1 scratch register)
        3'b0,           // [19:17] Reserved
        1'b0,           // [16] dataaccess
        4'd1,           // [15:12] datasize (1 = 32-bit)
        12'd0           // [11:0] dataaddr
    };

    // ========================================================================
    // Shift Registers
    // ========================================================================
    logic [31:0] idcode_shift;
    logic [31:0] dtmcs_shift;
    logic [40:0] dmi_shift;
    logic        bypass_shift;

    // DMI state
    logic [6:0]  dmi_address;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] dmi_data;    // Used for debugging
    logic [1:0]  dmi_op;      // Used for debugging
    /* verilator lint_on UNUSEDSIGNAL */
    logic [31:0] dmcontrol;

    // ========================================================================
    // Capture-DR: Load shift registers
    // ========================================================================
    always_ff @(posedge tck_i or negedge ntrst_i) begin
        if (!ntrst_i) begin
            idcode_shift  <= IDCODE;
            dtmcs_shift   <= DTMCS_VALUE;
            dmi_shift     <= 41'b0;
            bypass_shift  <= 1'b0;
            dmcontrol     <= DMCONTROL_RESET;
        end else if (capture_dr_i) begin
            case (ir_i)
                IR_IDCODE:  idcode_shift <= IDCODE;
                IR_DTMCS:   dtmcs_shift  <= DTMCS_VALUE;
                IR_DMI: begin
                    // Capture: Return data from previous operation
                    // For reads, put the read data in data field
                    // op field is 0 (success)
                    case (dmi_address)
                        7'h10: dmi_shift <= {dmi_address, dmcontrol, 2'b00};     // dmcontrol
                        7'h11: dmi_shift <= {dmi_address, DMSTATUS_VALUE, 2'b00}; // dmstatus
                        7'h16: dmi_shift <= {dmi_address, HARTINFO_VALUE, 2'b00}; // hartinfo
                        default: dmi_shift <= {dmi_address, 32'h0, 2'b00};
                    endcase
                end
                IR_BYPASS:  bypass_shift <= 1'b0;
                default:    bypass_shift <= 1'b0;
            endcase
        end
    end

    // ========================================================================
    // Shift-DR: Shift data through register
    // ========================================================================
    always_ff @(posedge tck_i or negedge ntrst_i) begin
        if (!ntrst_i) begin
            // Reset handled in capture_dr block
        end else if (shift_dr_i) begin
            case (ir_i)
                IR_IDCODE:  idcode_shift  <= {tdi_i, idcode_shift[31:1]};
                IR_DTMCS:   dtmcs_shift   <= {tdi_i, dtmcs_shift[31:1]};
                IR_DMI:     dmi_shift     <= {tdi_i, dmi_shift[40:1]};
                IR_BYPASS:  bypass_shift  <= tdi_i;
                default:    bypass_shift  <= tdi_i;
            endcase
        end
    end

    // ========================================================================
    // Update-DR: Process DMI operations
    // ========================================================================
    always_ff @(posedge tck_i or negedge ntrst_i) begin
        if (!ntrst_i) begin
            dmi_address <= 7'b0;
            dmi_data    <= 32'b0;
            dmi_op      <= 2'b0;
        end else if (update_dr_i && ir_i == IR_DMI) begin
            // Extract fields from shifted data
            dmi_address <= dmi_shift[40:34];
            dmi_data    <= dmi_shift[33:2];
            dmi_op      <= dmi_shift[1:0];

            // Process write operations
            if (dmi_shift[1:0] == 2'b10) begin  // Write operation
                case (dmi_shift[40:34])
                    7'h10: dmcontrol <= dmi_shift[33:2];  // Write to dmcontrol
                    default: begin
                        // Other registers are read-only in this minimal implementation
                    end
                endcase
            end
        end
    end

    // ========================================================================
    // TDO Output Multiplexer
    // ========================================================================
    always_comb begin
        case (ir_i)
            IR_IDCODE:  tdo_o = idcode_shift[0];
            IR_DTMCS:   tdo_o = dtmcs_shift[0];
            IR_DMI:     tdo_o = dmi_shift[0];
            IR_BYPASS:  tdo_o = bypass_shift;
            default:    tdo_o = bypass_shift;
        endcase
    end

endmodule
