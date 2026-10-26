/*
 * Minimal Total Commander / Double Commander Lister (WLX) plugin API.
 * Only what this plugin needs. On macOS, window handles are NSView*.
 */
#ifndef LISTPLUG_H
#define LISTPLUG_H

#include <stdint.h>

/* No __stdcall on macOS */
#define __stdcall

typedef void *HWND;

/* ListLoad / ListLoadNext / ListSendCommand return codes */
#define LISTPLUGIN_OK    0
#define LISTPLUGIN_ERROR 1

/* ShowFlags bits (subset), as in Double Commander's sdk/wlxplugin.h. DC
 * derives the fit bits from its own Image menu (fviewer.pas, PluginShowFlags):
 * Stretch -> lcp_fittowindow, Stretch only large -> lcp_fittowindow |
 * lcp_fitlargeronly. */
#define lcp_fittowindow    2
#define lcp_forceshow     16
#define lcp_fitlargeronly 32
#define lcp_center        64

/* ListSendCommand commands. Double Commander's viewer routes its own Cmd+C
 * hotkey here when a plugin owns the window (cm_CopyToClipboard -> lc_copy),
 * and sends lc_newparams when one of its Image menu options changes. */
#define lc_copy          1
#define lc_newparams     2
#define lc_selectall     3

typedef struct {
    int   size;
    uint32_t PluginInterfaceVersionLow;
    uint32_t PluginInterfaceVersionHi;
    char  DefaultIniName[260];
} ListDefaultParamStruct;

#endif /* LISTPLUG_H */
