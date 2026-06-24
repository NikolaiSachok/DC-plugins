/*
 * Minimal Total Commander / Double Commander Content (WDX) plugin API.
 * Only what this plugin needs. Strings are UTF-8 (Double Commander on macOS
 * passes/consumes UTF-8 for the non-wide entry points).
 */
#ifndef CONTPLUG_H
#define CONTPLUG_H

#include <stdint.h>

/* No __stdcall on macOS; exported ABI symbols must stay visible under
   -fvisibility=hidden. */
#define __stdcall
#define DLLEXPORT __attribute__((visibility("default")))

/* Field types returned by ContentGetSupportedField / ContentGetValue. */
#define ft_nomorefields      0
#define ft_numeric_32        1
#define ft_numeric_64        2
#define ft_numeric_floating  3
#define ft_date              4
#define ft_time              5
#define ft_boolean           6
#define ft_multiplechoice    7
#define ft_string            8
#define ft_fulltext          9
#define ft_datetime         10
#define ft_stringw          11

/* Special ContentGetValue return codes. */
#define ft_nosuchfield      -1
#define ft_fileerror        -2
#define ft_fieldempty       -3
#define ft_ondemand         -4
#define ft_notsupported     -5
#define ft_setcancel        -6
/* ft_delayed shares the 0 slot with ft_nomorefields, but the two never collide:
   ft_nomorefields is only meaningful from ContentGetSupportedField, ft_delayed
   only from ContentGetValue (and only when CONTENT_DELAYIFSLOW was requested). */
#define ft_delayed           0

/* ContentGetValue flags. */
#define CONTENT_DELAYIFSLOW  1   /* foreground call: return ft_delayed if slow */

typedef struct {
    int      size;
    uint32_t PluginInterfaceVersionLow;
    uint32_t PluginInterfaceVersionHi;
    char     DefaultIniName[260];
} ContentDefaultParamStruct;

#endif /* CONTPLUG_H */
