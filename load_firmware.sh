#!/usr/bin/env bash
# Load a firmware ELF into the running Sapphire SoC over JTAG (no Eclipse).
#
# Uses Efinity's bundled riscv OpenOCD and the BSP's ready-made cfg for the
# Ti180J484 dev board (FT2232H channel B, bscan-tunneled riscv debug).
#
# Usage: load_firmware.sh [path/to/app.elf]
# Default: the tinyml_mlperf ELF in the scratch tree.
set -euo pipefail

EFINITY=/d/efinix/efinity/2026.1
GCCBIN=/d/efinix/tools/xpack-riscv-none-elf-gcc-15.2.0-1/bin
APP_DIR=/d/efinix/ethernet/embedded_sw/efx_solution/software/standalone/tsemac/lwipIperfServer
ELF="${1:-$APP_DIR/build/lwipIperfServer.elf}"
OPENOCD_CFG_DIR=/d/efinix/ethernet/embedded_sw/efx_solution/bsp/efinix/EfxSapphireSoc/openocd

ENTRY=$("$GCCBIN/riscv-none-elf-readelf" -h "$ELF" | awk '/Entry point/ {print $4}')
# openocd.exe is a native Windows binary - give it a Windows-style path
ELF_WIN=$(cygpath -m "$ELF")
echo "ELF   : $ELF_WIN"
echo "Entry : $ENTRY"

# cwd matters: debug_ti.cfg probes ../../.. for cpu0.yaml (harmless for the
# standard riscv target, but keeps the cfg quiet).
cd "$APP_DIR"

"$EFINITY/debugger/openocd/bin/openocd.exe"     -f "$OPENOCD_CFG_DIR/ftdi_ti.cfg"     -f "$OPENOCD_CFG_DIR/debug_ti.cfg"     -c "init"     -c "targets fpga_spinal.cpu1"     -c "halt"     -c "targets fpga_spinal.cpu0"     -c "halt"     -c "load_image $ELF_WIN"     -c "targets fpga_spinal.cpu1"     -c "resume $ENTRY"     -c "targets fpga_spinal.cpu0"     -c "resume $ENTRY"     -c "shutdown"
echo "firmware loaded and running"
