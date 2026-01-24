# Manual OpenOCD cJTAG Patch Application Guide

## Important Note

⚠️ **If the manual patch application fails or the unified patch doesn't apply cleanly**, you can use the pre-patched OpenOCD repository that already includes all cJTAG/OScan1 support:

**Pre-patched OpenOCD**: https://github.com/kuopinghsu/openocd

Simply clone and build that repository instead:
```bash
git clone https://github.com/kuopinghsu/openocd.git
cd openocd
./bootstrap
./configure --enable-jtag_vpi
make clean && make -j4
sudo make install
```

This repository has all patches already applied and tested.

---

## Problem
The unified patch file `001-jtag_vpi-cjtag-support.patch` may not apply cleanly to your OpenOCD version because the file structure has changed between versions.

## Solution: Manual Application

Since OpenOCD's `jtag_vpi.c` file structure varies between versions, follow these manual steps to apply the changes directly:

### Step 1: Add oscan1.h Include

Edit `{OPENOCD_DIR}/src/jtag/drivers/jtag_vpi.c`:

Find this line (around line 25):
```c
#include "helper/replacements.h"
```

Add immediately after it:
```c
#include "oscan1.h"
```

### Step 2: Add CMD_OSCAN1 Definition

Find the command definitions (around line 37-40):
```c
#define CMD_RESET               0
#define CMD_TMS_SEQ             1
#define CMD_SCAN_CHAIN          2
#define CMD_SCAN_CHAIN_FLIP_TMS 3
#define CMD_STOP_SIMU           4
```

Add immediately after CMD_STOP_SIMU:
```c
#define CMD_OSCAN1              5
```

### Step 3: Add cJTAG Mode Flag

Find the static variables section (around line 47-50):
```c
/* Send CMD_STOP_SIMU to server when OpenOCD exits? */
static bool stop_sim_on_exit;

static int sockfd;
```

Add these lines between `stop_sim_on_exit` and `static int sockfd`:
```c
/* cJTAG mode flag */
static bool jtag_vpi_cjtag_mode = false;
```

The result should look like:
```c
/* Send CMD_STOP_SIMU to server when OpenOCD exits? */
static bool stop_sim_on_exit;

/* cJTAG mode flag */
static bool jtag_vpi_cjtag_mode = false;

static int sockfd;
static struct sockaddr_in serv_addr;
```

### Step 4: Update cmd_to_str Function

Find the `jtag_vpi_cmd_to_str` function (around line 80-90):
```c
	case CMD_STOP_SIMU:
		return "CMD_STOP_SIMU";
	default:
		return "<unknown>";
	}
}
```

Add the CMD_OSCAN1 case after CMD_STOP_SIMU:
```c
	case CMD_STOP_SIMU:
		return "CMD_STOP_SIMU";
	case CMD_OSCAN1:
		return "CMD_OSCAN1";
	default:
		return "<unknown>";
	}
}
```

### Step 5: Add cJTAG TMS Sequence Handler

Find the `jtag_vpi_tms_seq` function (around line 226):
```c
static int jtag_vpi_tms_seq(const uint8_t *bits, int nb_bits)
{
	struct vpi_cmd vpi;
	int nb_bytes;

	memset(&vpi, 0, sizeof(struct vpi_cmd));
```

Add the cJTAG check at the beginning of the function (after variable declarations):
```c
static int jtag_vpi_tms_seq(const uint8_t *bits, int nb_bits)
{
	struct vpi_cmd vpi;
	int nb_bytes;

	/* In cJTAG mode, encode TMS transitions using OScan1 SF0 (TMS on rising edge).
	 * Use TDI=1 as a don't-care to avoid unintended data shifts. */
	if (jtag_vpi_cjtag_mode) {
		for (int i = 0; i < nb_bits; i++) {
			uint8_t tms = (bits[i / 8] >> (i % 8)) & 0x1;
			uint8_t dummy_tdo = 0;
			int ret = oscan1_sf0_encode(tms, 1, &dummy_tdo);
			if (ret != ERROR_OK)
				return ret;
		}
		return ERROR_OK;
	}

	/* Standard JTAG mode continues below... */
	memset(&vpi, 0, sizeof(struct vpi_cmd));
	nb_bytes = DIV_ROUND_UP(nb_bits, 8);
```

### Step 6: Add cJTAG Data Transfer Handler

Find the `jtag_vpi_queue_tdi_xfer` function (around line 291):
```c
static int jtag_vpi_queue_tdi_xfer(uint8_t *bits, int nb_bits, int tap_shift)
{
	struct vpi_cmd vpi;
	int nb_bytes = DIV_ROUND_UP(nb_bits, 8);
```

Add the cJTAG handler at the beginning of the function:
```c
static int jtag_vpi_queue_tdi_xfer(uint8_t *bits, int nb_bits, int tap_shift)
{
	/* In cJTAG mode, translate shifts into OScan1 SF0 cycles (TMS on rising, TDI on falling).
	 * Maintain the existing bit ordering: LSB-first per OpenOCD buffer layout. */
	if (jtag_vpi_cjtag_mode) {
		for (int bit = 0; bit < nb_bits; bit++) {
			uint8_t tms = (tap_shift && (bit == nb_bits - 1)) ? 1 : 0;
			uint8_t tdi = bits ? ((bits[bit / 8] >> (bit % 8)) & 0x1) : 1;
			uint8_t tdo = 0;
			int ret = oscan1_sf0_encode(tms, tdi, &tdo);
			if (ret != ERROR_OK)
				return ret;
			if (bits) {
				if (tdo)
					bits[bit / 8] |= (1 << (bit % 8));
				else
					bits[bit / 8] &= ~(1 << (bit % 8));
			}
		}
		return ERROR_OK;
	}

	/* Standard JTAG mode continues below... */
	struct vpi_cmd vpi;
	int nb_bytes = DIV_ROUND_UP(nb_bits, 8);
```

### Step 7: Initialize OScan1 in jtag_vpi_init

Find the end of `jtag_vpi_init` function (around line 562, after the LOG_INFO line):
```c
	LOG_INFO("jtag_vpi: Connection to %s : %u successful", server_address, server_port);

	return ERROR_OK;
}
```

Add OScan1 initialization before the return:
```c
	LOG_INFO("jtag_vpi: Connection to %s : %u successful", server_address, server_port);

	/* Initialize OScan1 protocol if cJTAG mode is enabled */
	if (jtag_vpi_cjtag_mode) {
		LOG_INFO("jtag_vpi: cJTAG mode enabled, initializing OScan1 protocol");
		if (oscan1_init() != ERROR_OK) {
			LOG_ERROR("jtag_vpi: Failed to initialize OScan1 protocol");
			close(sockfd);
			return ERROR_FAIL;
		}
	}

	return ERROR_OK;
}
```

### Step 8: Add Command Handler Forward Declarations

Find the `jtag_vpi_quit` function (around line 589-641):
```c
static int jtag_vpi_quit(void)
{
	close(sockfd);
	return ERROR_OK;
}

COMMAND_HANDLER(jtag_vpi_set_port)
```

Add forward declarations after `jtag_vpi_quit`:
```c
static int jtag_vpi_quit(void)
{
	close(sockfd);
	return ERROR_OK;
}

/* Forward declaration */
COMMAND_HANDLER(jtag_vpi_enable_cjtag_handler);
COMMAND_HANDLER(jtag_vpi_handle_scanning_format_command);
COMMAND_HANDLER(jtag_vpi_handle_enable_crc_command);
COMMAND_HANDLER(jtag_vpi_handle_enable_parity_command);

COMMAND_HANDLER(jtag_vpi_set_port)
```

### Step 9: Register TCL Commands

Find the `jtag_vpi_subcommand_handlers` array (around line 645):
```c
static const struct command_registration jtag_vpi_subcommand_handlers[] = {
	{
		.name = "set_port",
		.handler = jtag_vpi_set_port,
		.mode = COMMAND_CONFIG,
		.help = "set the TCP port of the VPI server to connect to",
		.usage = "port",
	},
	{
		.name = "set_address",
		.handler = jtag_vpi_set_address,
		.mode = COMMAND_CONFIG,
		.help = "set the address of the VPI server to connect to",
		.usage = "address",
	},
	{
		.name = "stop_sim_on_exit",
		.handler = jtag_vpi_stop_sim_on_exit,
		.mode = COMMAND_CONFIG,
		.help = "configure if jtag_vpi driver should send CMD_STOP_SIMU "
			"before OpenOCD exits (default: off)",
		.usage = "<on|off>",
	},
	COMMAND_REGISTRATION_DONE
};
```

Add the new cJTAG commands before `COMMAND_REGISTRATION_DONE`:
```c
static const struct command_registration jtag_vpi_subcommand_handlers[] = {
	{
		.name = "set_port",
		.handler = jtag_vpi_set_port,
		.mode = COMMAND_CONFIG,
		.help = "set the TCP port of the VPI server to connect to",
		.usage = "port",
	},
	{
		.name = "set_address",
		.handler = jtag_vpi_set_address,
		.mode = COMMAND_CONFIG,
		.help = "set the address of the VPI server to connect to",
		.usage = "address",
	},
	{
		.name = "stop_sim_on_exit",
		.handler = jtag_vpi_stop_sim_on_exit,
		.mode = COMMAND_CONFIG,
		.help = "configure if jtag_vpi driver should send CMD_STOP_SIMU "
			"before OpenOCD exits (default: off)",
		.usage = "<on|off>",
	},
	{
		.name = "enable_cjtag",
		.handler = &jtag_vpi_enable_cjtag_handler,
		.mode = COMMAND_CONFIG,
		.help = "enable cJTAG/OScan1 two-wire protocol mode",
		.usage = "<on|off>",
	},
	{
		.name = "scanning_format",
		.handler = &jtag_vpi_handle_scanning_format_command,
		.mode = COMMAND_CONFIG,
		.help = "Set cJTAG scanning format",
		.usage = "0|1|2|3",
	},
	{
		.name = "enable_crc",
		.handler = &jtag_vpi_handle_enable_crc_command,
		.mode = COMMAND_CONFIG,
		.help = "Enable CRC-8 error detection",
		.usage = "on|off",
	},
	{
		.name = "enable_parity",
		.handler = &jtag_vpi_handle_enable_parity_command,
		.mode = COMMAND_CONFIG,
		.help = "Enable parity checking",
		.usage = "on|off",
	},
	COMMAND_REGISTRATION_DONE
};
```

### Step 10: Implement Command Handlers and OScan1 Communication Functions

Find the `jtag_vpi_interface` structure (around line 664):
```c
static struct jtag_interface jtag_vpi_interface = {
	.execute_queue = jtag_vpi_execute_queue,
};

struct adapter_driver jtag_vpi_adapter_driver = {
```

Add all the implementation functions between these two structures:
```c
static struct jtag_interface jtag_vpi_interface = {
	.execute_queue = jtag_vpi_execute_queue,
};

/* Last CMD_OSCAN1 response (TDO bit on TMSC line) */
static uint8_t last_oscan1_response = 0;

/* cJTAG / OScan1 protocol support */
int jtag_vpi_send_tckc_tmsc(uint8_t tckc, uint8_t tmsc)
{
	struct vpi_cmd vpi;
	int retval;

	memset(&vpi, 0, sizeof(struct vpi_cmd));

	vpi.cmd = CMD_OSCAN1;
	vpi.length = 1;
	vpi.nb_bits = 2;
	vpi.buffer_out[0] = (tckc & 0x01) | ((tmsc & 0x01) << 1);

	retval = jtag_vpi_send_cmd(&vpi);

	if (retval == ERROR_OK) {
		/* Store TDO bit from response */
		last_oscan1_response = vpi.buffer_in[0] & 0x01;
	}

	return retval;
}

uint8_t jtag_vpi_receive_tmsc(void)
{
	return last_oscan1_response;
}

COMMAND_HANDLER(jtag_vpi_enable_cjtag_handler)
{
	if (CMD_ARGC != 1)
		return ERROR_COMMAND_SYNTAX_ERROR;

	COMMAND_PARSE_ON_OFF(CMD_ARGV[0], jtag_vpi_cjtag_mode);
	LOG_INFO("cJTAG mode %s", jtag_vpi_cjtag_mode ? "enabled" : "disabled");

	return ERROR_OK;
}

COMMAND_HANDLER(jtag_vpi_handle_scanning_format_command)
{
	if (CMD_ARGC != 1)
		return ERROR_COMMAND_SYNTAX_ERROR;

	unsigned int format;
	COMMAND_PARSE_NUMBER(uint, CMD_ARGV[0], format);

	if (format > 3) {
		LOG_ERROR("Invalid scanning format %d (must be 0-3)", format);
		return ERROR_COMMAND_SYNTAX_ERROR;
	}

	oscan1_set_scanning_format(format);
	LOG_INFO("Scanning format set to SF%d", format);

	return ERROR_OK;
}

COMMAND_HANDLER(jtag_vpi_handle_enable_crc_command)
{
	if (CMD_ARGC != 1)
		return ERROR_COMMAND_SYNTAX_ERROR;

	bool enable = (strcmp(CMD_ARGV[0], "on") == 0 || strcmp(CMD_ARGV[0], "1") == 0);
	oscan1_enable_crc(enable);
	LOG_INFO("CRC-8 %s", enable ? "enabled" : "disabled");

	return ERROR_OK;
}

COMMAND_HANDLER(jtag_vpi_handle_enable_parity_command)
{
	if (CMD_ARGC != 1)
		return ERROR_COMMAND_SYNTAX_ERROR;

	bool enable = (strcmp(CMD_ARGV[0], "on") == 0 || strcmp(CMD_ARGV[0], "1") == 0);
	oscan1_enable_parity(enable);
	LOG_INFO("Parity checking %s", enable ? "enabled" : "disabled");

	return ERROR_OK;
}

struct adapter_driver jtag_vpi_adapter_driver = { 
```

### Step 11: Add OScan1 Source Files

```bash
# Copy oscan1.c
cp {PROJECT_DIR}/openocd/patched/002-oscan1-new-file.txt \
   {OPENOCD_DIR}/src/jtag/drivers/oscan1.c

# Copy oscan1.h
cp {PROJECT_DIR}/openocd/patched/003-oscan1-header-new-file.txt \
   {OPENOCD_DIR}/src/jtag/drivers/oscan1.h
```

### Step 12: Update Makefile.am

Edit `{OPENOCD_DIR}/src/jtag/drivers/Makefile.am`:

Find the section with:
```makefile
if JTAG_VPI
DRIVERFILES += %D%/jtag_vpi.c
endif
```

Change to:
```makefile
if JTAG_VPI
DRIVERFILES += %D%/jtag_vpi.c
DRIVERFILES += %D%/oscan1.c
endif
```

### Step 13: Build

```bash
cd {OPENOCD_DIR}
./bootstrap  # If needed
./configure --enable-jtag_vpi
make clean
make -j4
sudo make install
```

## Quick Verification

After building, verify the changes:

```bash
# Check oscan1.h is included
grep "oscan1.h" {OPENOCD_DIR}/src/jtag/drivers/jtag_vpi.c

# Check CMD_OSCAN1 is defined
grep "CMD_OSCAN1" {OPENOCD_DIR}/src/jtag/drivers/jtag_vpi.c

# Check cJTAG flag exists
grep "jtag_vpi_cjtag_mode" {OPENOCD_DIR}/src/jtag/drivers/jtag_vpi.c

# Check oscan1.c was compiled
nm {OPENOCD_DIR}/src/jtag/drivers/.libs/jtag_vpi.o | grep oscan1
```

## Troubleshooting

**Problem**: Function not found errors during compilation

**Solution**: Make sure you've added ALL the oscan1 function calls in the correct places and that oscan1.c/oscan1.h are properly created.

**Problem**: Command registration errors

**Solution**: Check that you've properly registered the command handlers in the `jtag_interface` structure.

**Problem**: Makefile doesn't pick up oscan1.c

**Solution**: Run `./bootstrap` then `./configure --enable-jtag_vpi` again to regenerate the build system.
