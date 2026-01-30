// =============================================================================
// JTAG VPI Interface Module
// =============================================================================
// Provides VPI (Verilog Procedural Interface) connection to OpenOCD
// Implements two-wire cJTAG (TCKC/TMSC) protocol for OScan1
// =============================================================================

#include "Vtop.h"
#include "verilated.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <errno.h>

// VPI Protocol Commands (matching OpenOCD jtag_vpi)
#define CMD_RESET       0
#define CMD_TMS_SEQ     1
#define CMD_SCAN_CHAIN  2
#define CMD_SCAN_CHAIN_FLIP_TMS 3
#define CMD_STOP_SIMU   4
// OScan1 raw command (sends TCKC/TMSC pair, returns TMSC state)
// MUST match OpenOCD patch: CMD_OSCAN1_RAW = 5
#define CMD_OSCAN1_RAW  5

// Buffer size MUST match OpenOCD's XFERT_MAX_SIZE
#define XFERT_MAX_SIZE  512

// VPI packet structure
#pragma pack(push, 1)
struct vpi_cmd {
    int cmd;
    unsigned char buffer_out[XFERT_MAX_SIZE];
    unsigned char buffer_in[XFERT_MAX_SIZE];
    int length;
    int nb_bits;
};
#pragma pack(pop)

class JtagVpi {
public:
    int server_fd;
    int client_fd;
    bool connected;
    int port;

    // cJTAG state
    bool cjtag_mode;
    uint8_t tckc_state;
    uint8_t tmsc_out;
    int free_run_cycles;  // Number of TCKC cycles to free-run (0 = OpenOCD controlled)

    // State machine for waiting on tck_o edge
    bool waiting_for_tck_edge;
    uint8_t tck_initial_state;
    struct vpi_cmd pending_response;
    int wait_counter;  // Counter for how many ticks we've waited
    static const int MAX_WAIT_TICKS = 100;  // Maximum ticks to wait for tck_o edge

    JtagVpi(int port_num = 3333) : port(port_num), connected(false),
                                    cjtag_mode(true), tckc_state(0), tmsc_out(0), free_run_cycles(0),
                                    waiting_for_tck_edge(false), tck_initial_state(0), wait_counter(0) {
        server_fd = -1;
        client_fd = -1;
        memset(&pending_response, 0, sizeof(pending_response));
    }

    ~JtagVpi() {
        close_connection();
    }

    bool init_server() {
        struct sockaddr_in server_addr;

        server_fd = socket(AF_INET, SOCK_STREAM, 0);
        if (server_fd < 0) {
            printf("VPI: Failed to create socket\n");
            return false;
        }

        // Set socket options
        int opt = 1;
        setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

        memset(&server_addr, 0, sizeof(server_addr));
        server_addr.sin_family = AF_INET;
        server_addr.sin_addr.s_addr = INADDR_ANY;
        server_addr.sin_port = htons(port);

        if (bind(server_fd, (struct sockaddr*)&server_addr, sizeof(server_addr)) < 0) {
            printf("VPI: Failed to bind to port %d: %s\n", port, strerror(errno));
            close(server_fd);
            server_fd = -1;
            return false;
        }

        if (listen(server_fd, 1) < 0) {
            printf("VPI: Failed to listen on port %d\n", port);
            close(server_fd);
            server_fd = -1;
            return false;
        }

        printf("VPI: Server listening on port %d (cJTAG mode)\n", port);
        return true;
    }

    bool check_connection() {
        if (connected) return true;
        if (server_fd < 0) return false;

        // Non-blocking accept
        fd_set read_fds;
        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 0;

        FD_ZERO(&read_fds);
        FD_SET(server_fd, &read_fds);

        if (select(server_fd + 1, &read_fds, NULL, NULL, &tv) > 0) {
            client_fd = accept(server_fd, NULL, NULL);
            if (client_fd >= 0) {
                connected = true;
                printf("VPI: Client connected\n");
                return true;
            }
        }

        return false;
    }

    void close_connection() {
        if (client_fd >= 0) {
            close(client_fd);
            client_fd = -1;
        }
        if (server_fd >= 0) {
            close(server_fd);
            server_fd = -1;
        }
        connected = false;
    }

    bool process_commands(Vtop* top) {
        if (!connected) return true;

        // First, check if we're waiting for a tck_o edge from a previous command
        if (waiting_for_tck_edge) {
            wait_counter++;

            if (top->tck_o != tck_initial_state) {
                // tck_o edge detected! Now read TMSC_O and send response
                #ifdef VERBOSE
                printf("[VPI] tck_o edge detected after %d ticks (was %d, now %d), sending response\n",
                       wait_counter, tck_initial_state, top->tck_o);
                #endif

                // Read TMSC_O after JTAG clock edge (real hardware timing)
                pending_response.buffer_in[0] = top->tmsc_o & 0x01;

                // Send response
                send(client_fd, &pending_response, sizeof(pending_response), 0);

                // Clear waiting state
                waiting_for_tck_edge = false;
                wait_counter = 0;
            } else if (wait_counter >= MAX_WAIT_TICKS) {
                // Timeout - send response anyway to avoid hanging OpenOCD
                #ifdef VERBOSE
                printf("[VPI] Timeout after %d ticks, tck_o didn't change, sending response anyway\n", wait_counter);
                #endif

                // Read current TMSC_O state
                pending_response.buffer_in[0] = top->tmsc_o & 0x01;

                // Send response
                send(client_fd, &pending_response, sizeof(pending_response), 0);

                // Clear waiting state
                waiting_for_tck_edge = false;
                wait_counter = 0;
            }
            // Still waiting, return and let testbench continue running clocks
            return true;
        }

        // Check if data available (non-blocking - immediate return)
        fd_set read_fds;
        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 0;  // Non-blocking: return immediately

        FD_ZERO(&read_fds);
        FD_SET(client_fd, &read_fds);

        int select_result = select(client_fd + 1, &read_fds, NULL, NULL, &tv);

        if (select_result <= 0) {
            return true;  // No data available or timeout
        }

        // Read VPI command structure (OpenOCD format)
        struct vpi_cmd vpi;
        memset(&vpi, 0, sizeof(vpi));

        // Read full structure (blocking read since select confirmed data is available)
        ssize_t n = recv(client_fd, &vpi, sizeof(vpi), 0);
        if (n <= 0) {
            if (n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK)) {
                printf("VPI: Client disconnected (recv returned %zd, errno=%d)\n", n, errno);
                close(client_fd);
                client_fd = -1;
                connected = false;
            }
            return true;
        }

        // Extract command (little-endian)
        uint32_t cmd = vpi.cmd;

        #ifdef VERBOSE
        static int total_commands = 0;
        printf("VPI: Received command 0x%02x (total: %d) [n=%zd bytes]\n",
               cmd, total_commands++, n);
        #endif

        // Process commands
        switch (cmd) {
            case CMD_RESET: {
                #ifdef VERBOSE
                printf("VPI: CMD_RESET (cJTAG mode - keeping bridge in OSCAN1)\n");
                #endif

                // In cJTAG mode, do NOT reset the cJTAG bridge
                // The bridge must stay in OSCAN1 mode once activated
                // OpenOCD's "TAP reset" is for the internal JTAG state machine only
                // The cJTAG spec doesn't have a way to reset just the JTAG TAP
                // without resetting the entire cJTAG bridge

                // Just acknowledge the command without doing anything
                memset(&vpi.buffer_in, 0, sizeof(vpi.buffer_in));
                send(client_fd, &vpi, sizeof(vpi), 0);

                break;
            }

            case CMD_TMS_SEQ: {
                // TMS sequence command - send TMS bits
                // Format: buffer_out[] contains TMS bits packed, nb_bits = number of bits
                // Note: This command is not well-supported in cJTAG mode
                //       OpenOCD should use CMD_OSCAN1_RAW instead

                #ifdef VERBOSE
                printf("VPI: CMD_TMS_SEQ: %d TMS bits (WARNING: Use CMD_OSCAN1_RAW for cJTAG)\n", vpi.nb_bits);
                #endif

                // Send each TMS bit via TMSC
                // VPI is just a pass-through - signal changes only, no clock generation
                for (int bit = 0; bit < vpi.nb_bits; bit++) {
                    int byte_idx = bit / 8;
                    int bit_idx = bit % 8;
                    uint8_t tms_bit = (vpi.buffer_out[byte_idx] >> bit_idx) & 0x01;

                    // Set TMSC to TMS value and TCKC high
                    top->tmsc_i = tms_bit;
                    top->tckc_i = 1;
                    top->eval();

                    // Then TCKC low
                    top->tckc_i = 0;
                    top->eval();
                }

                // Return TDO state (read from TMSC output)
                memset(&vpi.buffer_in, 0, sizeof(vpi.buffer_in));
                vpi.buffer_in[0] = top->tmsc_o & 0x01;

                // Send full struct
                send(client_fd, &vpi, sizeof(vpi), 0);

                break;
            }

            case CMD_SCAN_CHAIN:
            case CMD_SCAN_CHAIN_FLIP_TMS: {
                // Scan chain commands - NOT SUPPORTED with free-running TCKC
                // These are legacy JTAG commands that require manual clock control
                // OScan1 mode uses CMD_OSCAN1_RAW instead
                printf("VPI: WARNING: CMD_SCAN_CHAIN not supported with free-running TCKC (use CMD_OSCAN1_RAW)\n");

                // Error response - send full struct
                memset(&vpi.buffer_in, 0xFF, sizeof(vpi.buffer_in));
                send(client_fd, &vpi, sizeof(vpi), 0);

                break;
            }

            case CMD_STOP_SIMU: {
                printf("VPI: Received stop simulation command\n");
                return false;  // Stop simulation
            }

            case CMD_OSCAN1_RAW: {
                // OScan1 raw command: Direct control of TCKC and TMSC
                // Format: 1 byte in buffer_out with bit0=TCKC, bit1=TMSC
                // OpenOCD directly controls TCKC for escape sequences and OAC
                uint8_t cmd_byte = vpi.buffer_out[0];

                uint8_t tckc = cmd_byte & 0x01;
                uint8_t tmsc = (cmd_byte >> 1) & 0x01;

                #ifdef VERBOSE
                static int raw_cmd_count = 0;
                raw_cmd_count++;
                printf("[VPI] CMD_OSCAN1_RAW #%d: tckc=%d tmsc=%d\n",
                       raw_cmd_count, tckc, tmsc);
                #endif

                // Set TCKC and TMSC signals
                top->tckc_i = tckc;
                top->tmsc_i = tmsc;

                // Capture initial tck_o state and set waiting flag
                tck_initial_state = top->tck_o;
                top->eval();

                // Set waiting flag - response will be sent when tck_o changes
                waiting_for_tck_edge = true;
                wait_counter = 0;  // Reset wait counter
                pending_response = vpi;  // Save command structure for response

                #ifdef VERBOSE
                printf("[VPI] Waiting for tck_o edge (initial state: %d)\n", tck_initial_state);
                #endif

                // Return without sending response - will be sent when tck_o edge detected
                return true;
            }

            default: {
                printf("VPI: Unknown command: 0x%02x\n", cmd);

                // Error response - send full struct
                memset(&vpi.buffer_in, 0xFF, sizeof(vpi.buffer_in));
                send(client_fd, &vpi, sizeof(vpi), 0);

                break;
            }
        }

        return true;
    }
};

// Global VPI instance
static JtagVpi* g_vpi = nullptr;

extern "C" {
    void jtag_vpi_init(int port) {
        if (g_vpi == nullptr) {
            g_vpi = new JtagVpi(port);
            g_vpi->init_server();
        }
    }

    bool jtag_vpi_tick(Vtop* top) {
        if (g_vpi != nullptr) {
            g_vpi->check_connection();
            return g_vpi->process_commands(top);
        }
        return true;
    }

    void jtag_vpi_close() {
        if (g_vpi != nullptr) {
            delete g_vpi;
            g_vpi = nullptr;
        }
    }

    int jtag_vpi_get_free_run_cycles() {
        return g_vpi ? g_vpi->free_run_cycles : 0;
    }

    void jtag_vpi_dec_free_run_cycles() {
        if (g_vpi && g_vpi->free_run_cycles > 0) {
            g_vpi->free_run_cycles--;
        }
    }
}
