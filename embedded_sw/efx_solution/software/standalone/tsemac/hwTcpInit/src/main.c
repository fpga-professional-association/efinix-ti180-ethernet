////////////////////////////////////////////////////////////////////////////////
// hwTcpInit - one-time MAC/PHY bring-up for the hardware TCP sink.
//
// The TSEMAC streams are owned by hw_tcp_sink in fabric; this firmware only
// performs the register init the vendor demo did (PHY autoneg + MAC speed/IPG)
// and then idles. No DMA, no lwIP, no interrupts - the CPU never touches a
// packet.
////////////////////////////////////////////////////////////////////////////////
#include <stdint.h>
#include "bsp.h"
#include "riscv.h"
#include "efx_tse_mac.h"
#include "efx_tse_phy.h"

void trap() {
    while (1);
}

void main() {
    int drv_sel, speed, link_speed;

    bsp_init();
    MacRst(1, 1);

    bsp_printf("***HW TCP sink: MAC/PHY init***\n\r");
    drv_sel = Phy_identification();

    bsp_printf("Info: Phy Init ..\n\r");
    bsp_printf("Info: Waiting Link Up ..\n\r");
    if (drv_sel) {
        rtl8211_drv_init();
        speed = rtl8211_drv_linkup();
    } else {
        speed = PhyNormalInit();
    }

    if (speed == TSE_Speed_1000Mhz)
        link_speed = 1000;
    else if (speed == TSE_Speed_100Mhz)
        link_speed = 100;
    else if (speed == TSE_Speed_10Mhz)
        link_speed = 10;
    else
        link_speed = 0;

    MacNormalInit(speed);

    bsp_printf("Info: link %d Mbps\n\r", link_speed);
    bsp_printf("HW_TCP_READY IP=192.168.1.55 PORT=5001\n\r");

    while (1);
}
