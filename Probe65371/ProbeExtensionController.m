/*
 * ProbeExtensionController.m — Probe65371 extension principal class.
 *
 * The extension is launched by the host app via the private NSExtension API
 * (NSExtension +extensionWithIdentifier:error: / -beginExtensionRequestWithInputItems:completion:).
 * The framework sets up a bidirectional NSXPCConnection ("auxiliary connection")
 * between host and extension, configured via the _extensionAuxiliaryVendorProtocol /
 * _extensionAuxiliaryHostProtocol class methods on NSExtensionContext.
 *
 * Protocol:
 *   HOST → [auxConn.remoteProxy probeWithReply:]
 *     Extension allocates recv port, starts recv thread, returns send right.
 *   HOST sends cross-task Mach message (MAKE_SEND PORT descriptors) to that port.
 *   recv_thread reads descriptors, reports pad1/portname values back via
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

/* ── NSExtensionContext category: auxiliary connection protocol config ─ */
/*
 * The framework calls +_extensionAuxiliaryVendorProtocol to determine what
 * the extension exports (Probe65371Protocol), and +_extensionAuxiliaryHostProtocol
 * to determine what the host exports back (ProbeResultProtocol).  Both methods
 * are private and undocumented; we add them via category so the framework finds
 * them when it looks on NSExtensionContext.
 *
 * Some iOS versions may look for these on the principal class instead — we
 * also declare them there as a fallback.
 */
@interface NSExtensionContext (Probe65371Aux)
+ (NSXPCInterface *)_extensionAuxiliaryVendorProtocol;
+ (NSXPCInterface *)_extensionAuxiliaryHostProtocol;
@end

@implementation NSExtensionContext (Probe65371Aux)

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

/* ── Service implementation (exported on the auxiliary connection) ───── */

@interface ProbeServiceImpl : NSObject <Probe65371Protocol>
@property (weak) NSXPCConnection *connection;
@end

@implementation ProbeServiceImpl

- (void)probeWithReply:(void(^)(NSMachPort *))reply
{
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

    recv_ctx_t *ctx = malloc(sizeof(recv_ctx_t));
    ctx->recv     = recv;
    ctx->conn_ref = (__bridge_retained void *)self.connection;

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    pthread_create(&thread, &attr, recv_thread, ctx);
    pthread_attr_destroy(&attr);

    NSLog(@"[Probe65371] recv thread started for port %u", recv);

    /* NSMachPortDeallocateNone: do not deallocate on release — recv_thread owns it. */
    NSMachPort *port = [[NSMachPort alloc]
                            initWithMachPort:recv
                                     options:NSMachPortDeallocateNone];
    reply(port);
}

@end

/* ── Principal class ────────────────────────────────────────────────── */

@interface ProbeExtensionController : NSObject <NSExtensionRequestHandling>
@end

@implementation ProbeExtensionController

/*
 * Fallback in case the framework calls these on the principal class
 * rather than on NSExtensionContext.
 */
+ (NSXPCInterface *)_extensionAuxiliaryVendorProtocol
{
    return [NSExtensionContext _extensionAuxiliaryVendorProtocol];
}
+ (NSXPCInterface *)_extensionAuxiliaryHostProtocol
{
    return [NSExtensionContext _extensionAuxiliaryHostProtocol];
}

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context
{
    NSLog(@"[Probe65371] beginRequestWithExtensionContext — iOS %@",
          [NSProcessInfo processInfo].operatingSystemVersionString);

    /*
     * The framework should have already set up the auxiliary connection.
     * Try two KVC paths; both are private — log which one succeeds.
     */
    NSXPCConnection *auxConn = nil;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    @try {
        auxConn = [context performSelector:NSSelectorFromString(@"_auxiliaryConnection")];
    } @catch (NSException *e) {
        NSLog(@"[Probe65371] performSelector _auxiliaryConnection threw: %@", e);
    }
#pragma clang diagnostic pop

    if (!auxConn) {
        @try {
            auxConn = [context valueForKey:@"_auxiliaryConnection"];
        } @catch (NSException *e) {
            NSLog(@"[Probe65371] valueForKey _auxiliaryConnection threw: %@", e);
        }
    }

    NSLog(@"[Probe65371] auxiliary connection: %@", auxConn ?: @"<nil — fatal>");

    if (!auxConn) {
        NSLog(@"[Probe65371] FATAL: no auxiliary connection. "
              @"The framework did not set up _auxiliaryConnection. "
              @"Private API may have changed on this iOS version.");
        return;
    }

    /*
     * Explicitly configure interfaces as a safety net in case the framework
     * did not apply _extensionAuxiliaryVendorProtocol / _extensionAuxiliaryHostProtocol.
     * If the framework already set them, setting again is harmless (same object).
     */
    @try {
        NSXPCInterface *svcIface =
            [NSXPCInterface interfaceWithProtocol:@protocol(Probe65371Protocol)];
        [svcIface setClasses:[NSSet setWithObject:[NSMachPort class]]
                 forSelector:@selector(probeWithReply:)
               argumentIndex:0 ofReply:YES];
        auxConn.exportedInterface = svcIface;

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
        auxConn.remoteObjectInterface = resultIface;
    } @catch (NSException *e) {
        NSLog(@"[Probe65371] interface config exception (may be pre-set by framework): %@", e);
    }

    ProbeServiceImpl *impl = [ProbeServiceImpl new];
    impl.connection = auxConn;
    auxConn.exportedObject = impl;

    /* Resume in case the framework has not done so yet. */
    @try { [auxConn resume]; } @catch (NSException *e) {
        NSLog(@"[Probe65371] resume exception (may already be active): %@", e);
    }

    NSLog(@"[Probe65371] probe service live on auxiliary connection");

    /*
     * Do NOT call [context completeRequest...].
     * Leaving the request open keeps the extension process alive until the host
     * cancels it or the system kills it.
     */
}

@end
