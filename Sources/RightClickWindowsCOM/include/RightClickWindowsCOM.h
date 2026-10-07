#ifndef RIGHTCLICK_WINDOWS_COM_H
#define RIGHTCLICK_WINDOWS_COM_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct rc_com_client rc_com_client;
typedef struct rc_com_call rc_com_call;
/* Native transport only. No activation, shell, authority, task model or observer.
   All native interfaces stay in one MTA; returned tokens contain no pointers.
   Status: 0 success, 1 absent/stale, 2 unsupported/limit, 3 quarantined/timeout. */
rc_com_client *rc_com_open(void);
void rc_com_close(rc_com_client *client);
int rc_com_catalog(rc_com_client *client, unsigned char **bytes, size_t *length);
int rc_com_validate(rc_com_client *client, const char *acquisition);
/* Ordered binary values: u32 count, then (u16 VARTYPE, payload).
   BSTR = u32 UTF8 length + exact bytes; BOOL = u8 0/1; I8/R8 = u64 LE bits.
   Result is one (u16 VARTYPE, payload); VOID result is represented by VT_EMPTY. */
int rc_com_prepare(rc_com_client *client, const char *acquisition, int32_t member,
                   const unsigned char *arguments, size_t length, rc_com_call **call);
/* Immediate one-use queue insertion, suitable for the common admitted start.
   No COM RPC or result wait occurs in this function. */
int rc_com_enqueue(rc_com_call *call);
int rc_com_wait(rc_com_call *call, unsigned char **bytes, size_t *length);
void rc_com_release_call(rc_com_call *call);
void rc_com_free(void *bytes);
#ifdef __cplusplus
}
#endif
#endif
