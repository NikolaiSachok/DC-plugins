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

/* ListLoad / ListLoadNext return codes */
#define LISTPLUGIN_OK    0
#define LISTPLUGIN_ERROR 1

/* ShowFlags bits (subset) */
#define lcp_wraptext     1
#define lcp_fittowindow  4
#define lcp_ansi         8
#define lcp_ascii       16
#define lcp_variable    32
#define lcp_forceshow   64

/* ListSendCommand commands. Double Commander's viewer routes its own Cmd+C /
 * Cmd+A hotkeys here when a plugin owns the window (fviewer.pas: cm_CopyToClipboard
 * -> lc_copy, cm_SelectAll -> lc_selectall) — a plugin that does not export
 * ListSendCommand makes those keys silently dead. */
#define lc_copy          1
#define lc_newparams     2
#define lc_selectall     3
#define lc_setpercent    4

typedef struct {
    int   size;
    uint32_t PluginInterfaceVersionLow;
    uint32_t PluginInterfaceVersionHi;
    char  DefaultIniName[260];
} ListDefaultParamStruct;

#endif /* LISTPLUG_H */
