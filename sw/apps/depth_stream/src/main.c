/*
 * depth_stream: bring up Ethernet (same static-IP config already proven in
 * sw/apps/eth_test, see docs/BOARD_CONFIG.md) and stream the stereo
 * disparity frames out over UDP. Structure mirrors eth_test/src/main.c,
 * trimmed of the SFP/SI5324/ZCU102 IIC-PHY-reset paths that don't apply to
 * this board's onboard IP101GA PHY, and of the TCP timers (UDP doesn't
 * need them).
 */
#include <stdio.h>

#include "xparameters.h"
#include "netif/xadapter.h"

#include "platform.h"
#include "platform_config.h"
#if defined (__arm__) || defined(__aarch64__)
#include "xil_printf.h"
#endif

#include "lwip/udp.h"
#include "xil_cache.h"

#include "depth_stream.h"

/* missing declaration in lwIP */
void lwip_init(void);

static struct netif server_netif;
struct netif *echo_netif;

static void print_ip(char *msg, ip_addr_t *ip)
{
	print(msg);
	xil_printf("%d.%d.%d.%d\n\r", ip4_addr1(ip), ip4_addr2(ip),
	           ip4_addr3(ip), ip4_addr4(ip));
}

static void print_ip_settings(ip_addr_t *ip, ip_addr_t *mask, ip_addr_t *gw)
{
	print_ip("Board IP: ", ip);
	print_ip("Netmask : ", mask);
	print_ip("Gateway : ", gw);
}

int main(void)
{
	ip_addr_t ipaddr, netmask, gw;

	/* the mac address of the board. this should be unique per board */
	unsigned char mac_ethernet_address[] =
	{ 0x00, 0x0a, 0x35, 0x00, 0x01, 0x02 };

	echo_netif = &server_netif;

	init_platform();

	/* Board static IP on the laptop's dedicated point-to-point wired link
	 * (eno1 = 192.168.2.1/24, no DHCP server on this link) -- same
	 * config already verified working in sw/apps/eth_test. */
	IP4_ADDR(&ipaddr,  192, 168,   2, 10);
	IP4_ADDR(&netmask, 255, 255, 255,  0);
	IP4_ADDR(&gw,      192, 168,   2,  1);

	xil_printf("\r\n\r\n----- depth_stream -----\r\n");

	lwip_init();

	if (!xemac_add(echo_netif, &ipaddr, &netmask, &gw, mac_ethernet_address,
	               PLATFORM_EMAC_BASEADDR)) {
		xil_printf("Error adding N/W interface\n\r");
		return -1;
	}
	netif_set_default(echo_netif);

#ifndef SDT
	platform_enable_interrupts();
#endif

	netif_set_up(echo_netif);

	print_ip_settings(&ipaddr, &netmask, &gw);

	/* The destination the disparity stream is sent to defaults to the
	 * gateway address above (the laptop end of the point-to-point link) --
	 * override here if the receiver is elsewhere, before start_application()
	 * opens the UDP PCBs. */
	depth_stream_set_dest(192, 168, 2, 1);

	if (start_application() != 0) {
		xil_printf("Error starting depth_stream application\r\n");
		return -1;
	}

	while (1) {
		xemacif_input(echo_netif);
		transfer_data();
	}

	/* never reached */
	cleanup_platform();
	return 0;
}
