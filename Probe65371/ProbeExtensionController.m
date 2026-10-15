/*
 * ProbeExtensionController.m — Probe65371 extension (v3.2.65).
 *
 * Architecture (corrected per v3.2.65 analysis):
 *
 *   Info.plist sets NSExtensionContextClass = ProbeVendorContext.
 *   The framework creates a ProbeVendorContext as this request's context,
 *   calls +_extensionAuxiliaryVendorProtocol / +_extensionAuxiliaryHostProtocol
 *   on it to configure both sides of the auxiliary connection, and exports
 *   the context itself as the connection's exportedObject.
 *
 *   ProbeExtensionController (principal class) receives
 *   beginRequestWithExtensionContext: as a lifecycle callback only — it must
 *   NOT set interfaces, export objects, or call resume; the framework has
 *   already done all of that by the time this method is called.
 *
 * Protocol (unchanged):
 *   HOST → [auxConn.remoteProxy probeWithReply:]
 *     ProbeVendorContext allocates a recv port, starts recv thread,
 *     and returns a send right (NSMachPort) to the host.
 *   HOST sends cross-task Mach message (PORT descriptors) to that port.
 *   recv_thread reads descriptors, calls back via
 *   [auxConn.remoteProxy reportDescCount:pad1s:portNames:error:].
 */

#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <pthread.h>
#include <string.h>

/* ── Shared protocols (must match ProbeXPC.m exactly) ───────────────── */

@protocol Probe65371Protocol <NSObject>
- (void)probeWithReply:(void(^)(NSMachPort *))reply;
@end

@protocol ProbeResultProtocol <NSObject>
- (void)reportDescCount:(uint32_t)count
                  pad1s:(NSArray<NSNumber *> *)pad1Values
              portNames:(NSArray<NSNumber *> *)portNames
                  error:(NSString *)error;
@end

/* ── Receive-thread context ─────────────────────────────────────────── */

typedef struct {
    void        *conn_ref;  /* __bridge_retained NSXPCConnection*; released in thread */
    mach_port_t  recv;
} recv_ctx_t;

static void *recv_thread(void *arg)
{
    recv_ctx_t *ctx = (recv_ctx_t *)arg;
    mach_port_t recv = ctx->recv;
    NSXPCConnection *conn = (__bridge_transfer NSXPCConnection *)ctx->conn_ref;
    free(ctx);

    uint8_t buf[4096] __attribute__((aligned(8)));
    memset(buf, 0, sizeof(buf));
    mach_msg_header_t *hdr = (mach_msg_header_t *)buf;

    kern_return_t kr = mach_msg(hdr,
                                MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                                0, (mach_msg_size_t)sizeof(buf),
                                recv, 12000, MACH_PORT_NULL);

    NSLog(@"[Probe65371] recv_thread: mach_msg returned kr=0x%x", (unsigned)kr);

    id<ProbeResultProtocol> proxy = [conn remoteObjectProxy];

    if (kr != MACH_MSG_SUCCESS) {
        NSString *err = [NSString stringWithFormat:@"mach_msg_recv kr=0x%x", (unsigned)kr];
        [proxy reportDescCount:0 pad1s:@[] portNames:@[] error:err];
        mach_port_deallocate(mach_task_self(), recv);
        return NULL;
    }

    uint32_t desc_count = 0;
    if (sizeof(buf) >= 28)
        memcpy(&desc_count, buf + 24, 4);
    if (desc_count > 8) desc_count = 8;

    NSMutableArray<NSNumber *> *pad1s = [NSMutableArray arrayWithCapacity:desc_count];
    NSMutableArray<NSNumber *> *names = [NSMutableArray arrayWithCapacity:desc_count];

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

/* ── ProbeVendorContext — NSExtensionContext subclass ───────────────── */
/*
 * Named in Info.plist via NSExtensionContextClass.  The framework:
 *   1. Instantiates this class as the request's NSExtensionContext.
 *   2. Calls +_extensionAuxiliaryVendorProtocol / +_extensionAuxiliaryHostProtocol
 *      on it to configure both sides of the auxiliary XPC connection.
 *   3. Exports this instance as auxConn.exportedObject on the extension side.
 *   4. Resumes the connection.
 *
 * We implement Probe65371Protocol here so calls from the host dispatch to us.
 */
@interface ProbeVendorContext : NSExtensionContext <Probe65371Protocol>
@end

@implementation ProbeVendorContext

+ (NSXPCInterface *)_extensionAuxiliaryVendorProtocol
{
    NSXPCInterface *iface = [NSXPCInterface interfaceWithProtocol:@protocol(Probe65371Protocol)];
    [iface setClasses:[NSSet setWithObject:[NSMachPort class]]
          forSelector:@selector(probeWithReply:)
        argumentIndex:0 ofReply:YES];
    return iface;
}

+ (NSXPCInterface *)_extensionAuxiliaryHostProtocol
{
    NSXPCInterface *iface = [NSXPCInterface interfaceWithProtocol:@protocol(ProbeResultProtocol)];
    [iface setClasses:[NSSet setWithObjects:[NSArray class], [NSNumber class], nil]
          forSelector:@selector(reportDescCount:pad1s:portNames:error:)
        argumentIndex:1 ofReply:NO];
    [iface setClasses:[NSSet setWithObjects:[NSArray class], [NSNumber class], nil]
          forSelector:@selector(reportDescCount:pad1s:portNames:error:)
        argumentIndex:2 ofReply:NO];
    return iface;
}

- (void)probeWithReply:(void(^)(NSMachPort *))reply
{
    NSLog(@"[Probe65371] probeWithReply: called on ProbeVendorContext");

    mach_port_t recv = MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(),
                           MACH_PORT_RIGHT_RECEIVE, &recv) != KERN_SUCCESS) {
        NSLog(@"[Probe65371] mach_port_allocate failed");
        reply(nil); return;
    }
    if (mach_port_insert_right(mach_task_self(), recv, recv,
                               MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), recv);
        NSLog(@"[Probe65371] mach_port_insert_right failed");
        reply(nil); return;
    }

    /* Get the auxiliary connection from self (we ARE the NSExtensionContext). */
    NSXPCConnection *auxConn = nil;
    @try { auxConn = [self valueForKey:@"_auxiliaryConnection"]; }
    @catch (NSException *e) {
        NSLog(@"[Probe65371] _auxiliaryConnection on self threw: %@", e);
    }
    NSLog(@"[Probe65371] auxConn from self: %@", auxConn ?: @"<nil>");

    recv_ctx_t *ctx = malloc(sizeof(recv_ctx_t));
    ctx->recv     = recv;
    ctx->conn_ref = (__bridge_retained void *)auxConn;

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    pthread_create(&thread, &attr, recv_thread, ctx);
    pthread_attr_destroy(&attr);

    NSLog(@"[Probe65371] recv thread started for port %u", recv);

    /* NSMachPortDeallocateNone: recv_thread owns the recv right. */
    NSMachPort *port = [[NSMachPort alloc]
                            initWithMachPort:recv
                                     options:NSMachPortDeallocateNone];
    reply(port);
}

@end

/* ── Principal class ────────────────────────────────────────────────── */
/*
 * NSExtensionRequestHandling entry point.  By the time this is called,
 * the framework has already set up, configured, and resumed the auxiliary
 * connection on 'context' (a ProbeVendorContext instance).  We must NOT
 * touch interfaces, exportedObject, or call resume — only log state for
 * debugging, and do NOT call completeRequest.
 */
@interface ProbeExtensionController : NSObject <NSExtensionRequestHandling>
@end

@implementation ProbeExtensionController

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context
{
    NSLog(@"[Probe65371] beginRequestWithExtensionContext: iOS %@, context class: %@",
          [NSProcessInfo processInfo].operatingSystemVersionString,
          NSStringFromClass([context class]));

    /* Diagnostic: log what the framework set up on the connection. */
    NSXPCConnection *auxConn = nil;
    @try { auxConn = [context valueForKey:@"_auxiliaryConnection"]; }
    @catch (NSException *e) {
        NSLog(@"[Probe65371] diag: _auxiliaryConnection threw: %@", e);
    }
    NSLog(@"[Probe65371] diag: auxConn=%@ exportedObject=%@ exportedInterface=%@",
          auxConn ?: @"<nil>",
          auxConn.exportedObject ?: @"<nil>",
          auxConn.exportedInterface ?: @"<nil>");

    /*
     * Framework owns the connection — do not modify or resume.
     * Do NOT call [context completeRequest:...]; leaving it open
     * keeps the extension alive.
     */
}

@end
