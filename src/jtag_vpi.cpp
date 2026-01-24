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

// cJTAG specific commands
#define CMD_CJTAG_TCKC  0x10
#define CMD_CJTAG_WRITE 0x11
#define CMD_CJTAG_READ  0x12

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

    JtagVpi(int port_num = 3333) : port(port_num), connected(false),
                                    cjtag_mode(true), tckc_state(0), tmsc_out(0) {
        server_fd = -1;
        client_fd = -1;
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

        // Check if data available
        fd_set read_fds;
        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 0;

        FD_ZERO(&read_fds);
        FD_SET(client_fd, &read_fds);

        if (select(client_fd + 1, &read_fds, NULL, NULL, &tv) <= 0) {
            return true;  // No data available
        }

        // Read command
        uint8_t cmd;
        ssize_t n = recv(client_fd, &cmd, 1, 0);
        if (n <= 0) {
            printf("VPI: Client disconnected\n");
            close(client_fd);
            client_fd = -1;
            connected = false;
            return true;
        }

        // Process cJTAG commands
        switch (cmd) {
            case CMD_CJTAG_TCKC: {
                // Set TCKC state
                uint8_t state;
                recv(client_fd, &state, 1, 0);
                tckc_state = state & 0x01;
                top->tckc_i = tckc_state;
                break;
            }

            case CMD_CJTAG_WRITE: {
                // Write TMSC
                uint8_t data;
                recv(client_fd, &data, 1, 0);
                tmsc_out = data & 0x01;
                top->tmsc_i = tmsc_out;
                break;
            }

            case CMD_CJTAG_READ: {
                // Read TMSC (when driven by device)
                uint8_t data = top->tmsc_o;
                send(client_fd, &data, 1, 0);
                break;
            }

            case CMD_RESET: {
                // Reset the JTAG TAP
                top->ntrst_i = 0;
                for (int i = 0; i < 10; i++) {
                    top->tckc_i = 0;
                    top->eval();
                    top->tckc_i = 1;
                    top->eval();
                }
                top->ntrst_i = 1;
                top->eval();

                // Send response
                uint8_t resp = 0;
                send(client_fd, &resp, 1, 0);
                break;
            }

            case CMD_STOP_SIMU: {
                printf("VPI: Received stop simulation command\n");
                return false;  // Stop simulation
            }

            default: {
                printf("VPI: Unknown command: 0x%02x\n", cmd);
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
}
