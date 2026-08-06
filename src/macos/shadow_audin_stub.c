#include <freerdp/server/shadow.h>

/*
 * FreeRDP's shadow channel dispatcher currently initializes AUDIN for every
 * client, even when the channel is disabled. macrdp does not expose a
 * microphone, so report the optional channel as unavailable without failing
 * the desktop session.
 */
BOOL shadow_client_audin_init(rdpShadowClient* client)
{
	(void)client;
	return TRUE;
}

void shadow_client_audin_uninit(rdpShadowClient* client)
{
	(void)client;
}
