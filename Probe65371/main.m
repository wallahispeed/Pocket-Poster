/*
 * main.m — Probe65371 embedded XPC service.
 *
 * Implements the service side of the CVE-2026-65371 cross-task pad1 test.
 * Uses NSXPCListener (iOS-compatible) rather than xpc_main / dlsym.
 *
 * Protocol flow:
 *   HOST → probeWithReply:  — service allocates recv port, starts receive
 *                              thread, returns the send right as NSMachPort.
 *   HOST  sends raw Mach message (MAKE_SEND PORT descriptors) to that port.
 *   SVC recv thread reads descriptors, extracts pad1 / portname.
 *   SVC → reportDescCount:pad1s:portNames:error:  — reports back to host.
 */

#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <pthread.h>
#include <string.h>
#include <dlfcn.h>

/* ── Protocols (must match ProbeXPC.m exactly) ─────────────────────── */

@protocol Probe65371Protocol <NSObject>
- (void)probeWithReply:(void(^)(NSMachPort *servicePort))reply;
@end

@protocol ProbeResultProtocol <NSObject>
- (void)reportDescCount:(uint32_t)count
                  pad1s:(NSArray<NSNumber *> *)pad1Values
              portNames:(NSArray<NSNumber *> *)portNames
                  error:(NSString *)error;
@end

/* ── Receive-thread context ─────────────────────────────────────────── */

typedef struct {
    void        *conn_ref;   /* __bridge_retained NSXPCConnection*; released in thread */
    mach_port_t  recv;
} recv_ctx_t;

static void *recv_thread(void *arg)
{
    recv_ctx_t *ctx = (recv_ctx_t *)arg;
    mach_port_t recv = ctx->recv;
    /* Transfer ownership back to ARC; conn is released at end of scope. */
    NSXPCConnection *conn = (__bridge_transfer NSXPCConnection *)ctx->conn_ref;
    free(ctx);

    uint8_t buf[4096] __attribute__((aligned(8)));
    memset(buf, 0, sizeof(buf));
    mach_msg_header_t *hdr = (mach_msg_header_t *)buf;

    kern_return_t kr = mach_msg(hdr,
                                MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                                0, (mach_msg_size_t)sizeof(buf),
                                recv, 12000, MACH_PORT_NULL);

    id<ProbeResultProtocol> proxy = [conn remoteObjectProxy];

    if (kr != MACH_MSG_SUCCESS) {
        NSString *err = [NSString stringWithFormat:@"mach_msg_recv kr=0x%x", (unsigned)kr];
        [proxy reportDescCount:0 pad1s:@[] portNames:@[] error:err];
        mach_port_deallocate(mach_task_self(), recv);
        return NULL;
    }

    /* Read desc_count from the mach_msg_body at offset 24. */
    uint32_t desc_count = 0;
    if (sizeof(buf) >= 28)
        memcpy(&desc_count, buf + 24, 4);
    if (desc_count > 8) desc_count = 8;

    NSMutableArray<NSNumber *> *pad1s  = [NSMutableArray arrayWithCapacity:desc_count];
    NSMutableArray<NSNumber *> *names  = [NSMutableArray arrayWithCapacity:desc_count];

    for (uint32_t i = 0; i < desc_count; i++) {
        size_t base = 28 + (size_t)i * 12;
        uint32_t portname = 0, pad1 = 0;
        if (base + 8 <= sizeof(buf)) {
            memcpy(&portname, buf + base,     4);
            memcpy(&pad1,     buf + base + 4, 4);
        }
        [pad1s addObject:@(pad1)];
        [names addObject:@(portname)];
    }

    [proxy reportDescCount:desc_count pad1s:pad1s portNames:names error:@""];
    mach_port_deallocate(mach_task_self(), recv);
    return NULL;
}

/* ── Service implementation ─────────────────────────────────────────── */

@interface ProbeServiceImpl : NSObject <Probe65371Protocol>
@property (weak) NSXPCConnection *connection;
@end

@implementation ProbeServiceImpl

- (void)probeWithReply:(void(^)(NSMachPort *))reply
{
    mach_port_t recv = MACH_PORT_NULL;

    if (mach_port_allocate(mach_task_self(),
                           MACH_PORT_RIGHT_RECEIVE, &recv) != KERN_SUCCESS) {
        reply(nil);
        return;
    }
    if (mach_port_insert_right(mach_task_self(), recv, recv,
                               MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), recv);
        reply(nil);
        return;
    }

    /*
     * Build receive-thread context.  We retain the connection manually so
     * the thread can call back after probeWithReply: has already returned.
     * __bridge_retained bumps the retain count without ARC involvement;
     * recv_thread undoes it with __bridge_transfer.
     */
    recv_ctx_t *ctx = malloc(sizeof(recv_ctx_t));
    ctx->recv     = recv;
    ctx->conn_ref = (__bridge_retained void *)self.connection;

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    pthread_create(&thread, &attr, recv_thread, ctx);
    pthread_attr_destroy(&attr);

    /*
     * NSMachPortDeallocateNone: NSMachPort does NOT deallocate the port on
     * release.  We keep the recv right alive for recv_thread; NSXPCConnection
     * sends the send right to the host as part of the reply message.
     */
    NSMachPort *port = [[NSMachPort alloc]
                            initWithMachPort:recv
                                     options:NSMachPortDeallocateNone];
    reply(port);
}

@end

/* ── NSXPCListener delegate ─────────────────────────────────────────── */

@interface ServiceDelegate : NSObject <NSXPCListenerDelegate>
@end

@implementation ServiceDelegate

- (BOOL)listener:(NSXPCListener *)listener
shouldAcceptNewConnection:(NSXPCConnection *)conn
{
    /*
     * Service exports Probe65371Protocol.
     * The reply block of probeWithReply: carries an NSMachPort — we must
     * whitelist the class so NSXPCConnection allows it through.
     */
    NSXPCInterface *svcIface =
        [NSXPCInterface interfaceWithProtocol:@protocol(Probe65371Protocol)];
    [svcIface setClasses:[NSSet setWithObject:[NSMachPort class]]
             forSelector:@selector(probeWithReply:)
           argumentIndex:0
                 ofReply:YES];
    conn.exportedInterface = svcIface;

    /*
     * Host exports ProbeResultProtocol.
     * pad1s and portNames are NSArray<NSNumber*> — whitelist both.
     */
    NSXPCInterface *resultIface =
        [NSXPCInterface interfaceWithProtocol:@protocol(ProbeResultProtocol)];
    [resultIface setClasses:[NSSet setWithObjects:[NSArray class],
                                                  [NSNumber class], nil]
               forSelector:@selector(reportDescCount:pad1s:portNames:error:)
             argumentIndex:1 ofReply:NO];
    [resultIface setClasses:[NSSet setWithObjects:[NSArray class],
                                                  [NSNumber class], nil]
               forSelector:@selector(reportDescCount:pad1s:portNames:error:)
             argumentIndex:2 ofReply:NO];
    conn.remoteObjectInterface = resultIface;

    ProbeServiceImpl *impl = [ProbeServiceImpl new];
    impl.connection = conn;
    conn.exportedObject = impl;

    [conn resume];
    return YES;
}

@end

/* ── Entry point ────────────────────────────────────────────────────── */

int main(void)
{
    @autoreleasepool {
        NSLog(@"[Probe65371] service main() starting — iOS %@",
              [NSProcessInfo processInfo].operatingSystemVersionString);

        /*
         * NSXPCListener +serviceListener is marked API_UNAVAILABLE(ios) in the
         * SDK header.  Use performSelector: so Clang never sees a static
         * reference to the unavailable API.  The method IS present in
         * Foundation at runtime for embedded XPC services on iOS.
         */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSXPCListener *listener = (NSXPCListener *)
            [NSXPCListener performSelector:NSSelectorFromString(@"serviceListener")];
#pragma clang diagnostic pop

        if (!listener) {
            NSLog(@"[Probe65371] FATAL: NSXPCListener serviceListener returned nil — "
                  @"XPC service launch not supported by this iOS version/configuration. "
                  @"xpc_main present: %s",
                  dlsym(RTLD_DEFAULT, "xpc_main") ? "YES" : "NO");
            return 1;
        }

        NSLog(@"[Probe65371] serviceListener OK — setting delegate and resuming");
        listener.delegate = [ServiceDelegate new];
        [listener resume];
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
