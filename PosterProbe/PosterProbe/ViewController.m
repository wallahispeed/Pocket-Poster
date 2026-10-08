#import <UIKit/UIKit.h>
#import <dlfcn.h>

// ── Forward-declared ObjC selectors we call via NSInvocation ──────────────────
// (avoids linking against private frameworks at build time)

@interface ViewController : UIViewController
@property (strong, nonatomic) UITextView  *textView;
@property (strong, nonatomic) UIActivityIndicatorView *spinner;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    // Title
    UILabel *title = [[UILabel alloc] init];
    title.text = @"PosterProbe";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:18];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:title];

    // TextView for results
    self.textView = [[UITextView alloc] init];
    self.textView.backgroundColor = UIColor.blackColor;
    self.textView.textColor = UIColor.greenColor;
    self.textView.font = [UIFont fontWithName:@"Menlo" size:11];
    self.textView.editable = NO;
    self.textView.text = @"Running tests…";
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.textView];

    // Copy button
    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [copyBtn setTitle:@"Copy" forState:UIControlStateNormal];
    copyBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [copyBtn addTarget:self action:@selector(copyOutput) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:copyBtn];

    // Spinner
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.color = UIColor.whiteColor;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.spinner];
    [self.spinner startAnimating];

    // Layout
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [self.spinner.leadingAnchor constraintEqualToAnchor:title.trailingAnchor constant:8],
        [self.textView.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [self.textView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [self.textView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
        [self.textView.bottomAnchor constraintEqualToAnchor:copyBtn.topAnchor constant:-8],
        [copyBtn.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [copyBtn.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
    ]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *result = [self runAllTests];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.textView.text = result;
            [self.spinner stopAnimating];
        });
    });
}

- (void)copyOutput {
    UIPasteboard.generalPasteboard.string = self.textView.text;
}

// ── Core test runner ──────────────────────────────────────────────────────────

- (NSString *)runAllTests {
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"=== PosterProbe ===\n\n"];

    // 1. Load private frameworks
    [out appendString:@"[1] Loading frameworks\n"];
    void *pfHandle  = dlopen("/System/Library/PrivateFrameworks/PosterFoundation.framework/PosterFoundation", RTLD_NOW);
    void *pbsHandle = dlopen("/System/Library/PrivateFrameworks/PosterBoardServices.framework/PosterBoardServices", RTLD_NOW);
    [out appendFormat:@"  PosterFoundation:   %@\n", pfHandle  ? @"✓ loaded" : [NSString stringWithUTF8String:dlerror()]];
    [out appendFormat:@"  PosterBoardServices:%@\n\n", pbsHandle ? @"✓ loaded" : [NSString stringWithUTF8String:dlerror()]];

    // 2. Check classes
    [out appendString:@"[2] Classes\n"];
    NSArray *classNames = @[
        @"PRSPosterConfiguration", @"PFPosterPath",
        @"PFServerPosterPath",     @"PFServerPosterIdentity",
        @"PRSService",             @"PRSConnection",
        @"PRSServer",
    ];
    BOOL allFound = YES;
    for (NSString *cn in classNames) {
        Class cls = NSClassFromString(cn);
        [out appendFormat:@"  %-30s %@\n", cn.UTF8String, cls ? @"✓" : @"✗ MISSING"];
        if (!cls) allFound = NO;
    }
    [out appendString:@"\n"];

    if (!allFound) {
        [out appendString:@"ABORT: required classes missing.\n"];
        [out appendString:@"iOS version may not support these classes (need iOS 16+).\n"];
        return out;
    }

    // 3. Load payload files from app bundle
    [out appendString:@"[3] Payload files\n"];
    NSData *basePayload   = [self loadPayload:@"payload_pfposterpath"   ext:@"keyed" out:out];
    NSData *serverPayload = [self loadPayload:@"payload_pfserverposterpath" ext:@"keyed" out:out];
    [out appendString:@"\n"];

    // 4. NSKeyedUnarchiver direct decode (no entitlement needed)
    [out appendString:@"[4] Direct NSKeyedUnarchiver decode\n"];
    if (basePayload)   [self decodePayload:basePayload   label:@"base"   out:out];
    if (serverPayload) [self decodePayload:serverPayload label:@"server" out:out];
    [out appendString:@"\n"];

    // 5. decodeFromPersistableRepresentation:error: (PF public API, no entitlement needed)
    [out appendString:@"[5] decodeFromPersistableRepresentation: (PF API)\n"];
    if (basePayload)   [self decodeViaPF:basePayload   out:out];
    [out appendString:@"\n"];

    // 6. Try importPosterConfigurationFromArchiveData: via PRSConnection
    //    (will fail with entitlement error — tells us which entitlement is needed)
    [out appendString:@"[6] XPC import attempt (expect entitlement error)\n"];
    if (basePayload) [self tryXPCImport:basePayload out:out];
    [out appendString:@"\n"];

    [out appendString:@"=== DONE ===\n"];
    return out;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

- (NSData *)loadPayload:(NSString *)name ext:(NSString *)ext out:(NSMutableString *)out {
    NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:ext];
    if (!path) {
        [out appendFormat:@"  %@.%@: ✗ NOT IN BUNDLE\n", name, ext];
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfFile:path];
    [out appendFormat:@"  %@.%@: %zu bytes\n", name, ext, data.length];
    return data;
}

- (void)decodePayload:(NSData *)data label:(NSString *)label out:(NSMutableString *)out {
    NSSet *allowedClasses = [NSSet setWithObjects:
        NSClassFromString(@"PRSPosterConfiguration"),
        NSClassFromString(@"PFPosterPath"),
        NSClassFromString(@"PFServerPosterPath"),
        NSClassFromString(@"PFServerPosterIdentity"),
        [NSURL class], [NSString class], [NSUUID class],
        [NSData class], [NSNumber class], [NSDictionary class],
        nil
    ];

    NSError *err = nil;
    NSKeyedUnarchiver *u = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&err];
    if (!u) {
        [out appendFormat:@"  [%@] init error: %@\n", label, err.localizedDescription];
        return;
    }
    u.requiresSecureCoding = YES;
    u.decodingFailurePolicy = NSDecodingFailurePolicySetErrorAndReturn;

    NSError *decodeErr = nil;
    id result = [u decodeTopLevelObjectOfClasses:allowedClasses forKey:@"root" error:&decodeErr];

    if (result) {
        [out appendFormat:@"  [%@] ✓ decoded → %@\n", label, NSStringFromClass([result class])];
        // Try to read contentsURL to confirm payload structure
        SEL contSel = NSSelectorFromString(@"contentsURL");
        if ([result respondsToSelector:contSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id path = [result performSelector:NSSelectorFromString(@"path")];
            if (path) {
                SEL pathSel = NSSelectorFromString(@"contentsURL");
                id pObj = [path performSelector:pathSel];
                [out appendFormat:@"         contentsURL → %@\n", pObj];
            }
#pragma clang diagnostic pop
        }
    } else {
        [out appendFormat:@"  [%@] ✗ decode failed: %@\n", label,
             decodeErr.localizedDescription ?: @"nil result, no error"];
    }
}

- (void)decodeViaPF:(NSData *)data out:(NSMutableString *)out {
    Class PRSPosterConfig = NSClassFromString(@"PRSPosterConfiguration");
    SEL sel = NSSelectorFromString(@"decodeFromPersistableRepresentation:error:");
    if (![PRSPosterConfig respondsToSelector:sel]) {
        [out appendString:@"  decodeFromPersistableRepresentation: not found on PRSPosterConfiguration\n"];
        return;
    }

    NSMethodSignature *sig = [PRSPosterConfig methodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:PRSPosterConfig];
    [inv setSelector:sel];
    [inv setArgument:&data atIndex:2];
    NSError *err = nil;
    NSError * __autoreleasing *ep = &err;
    [inv setArgument:&ep atIndex:3];

    @try {
        [inv invoke];
    } @catch (NSException *e) {
        [out appendFormat:@"  PF decode exception: %@\n", e.reason];
        return;
    }

    id __unsafe_unretained result = nil;
    [inv getReturnValue:&result];

    if (result) {
        [out appendFormat:@"  ✓ PF decoded → %@\n", NSStringFromClass([result class])];
    } else {
        [out appendFormat:@"  ✗ PF decode nil, err: %@\n", err.localizedDescription ?: @"(no error)"];
    }
}

- (void)tryXPCImport:(NSData *)data out:(NSMutableString *)out {
    Class connClass = NSClassFromString(@"PRSConnection");
    if (!connClass) {
        [out appendString:@"  PRSConnection not found\n"];
        return;
    }

    id conn = [[connClass alloc] init];
    SEL importSel = NSSelectorFromString(@"importPosterConfigurationFromArchiveData:completion:");
    if (![conn respondsToSelector:importSel]) {
        importSel = NSSelectorFromString(@"importPosterConfigurationFromArchivedData:completion:");
    }
    if (![conn respondsToSelector:importSel]) {
        [out appendString:@"  import selector not found on PRSConnection\n"];
        return;
    }

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block NSString *resultStr = @"(timeout)";

    void (^completion)(id, NSError *) = ^(id path, NSError *error) {
        if (error) {
            resultStr = [NSString stringWithFormat:@"✗ error: %@ (domain=%@ code=%ld)",
                         error.localizedDescription, error.domain, (long)error.code];
        } else if (path) {
            resultStr = [NSString stringWithFormat:@"✓ SUCCESS: %@",
                         NSStringFromClass([path class])];
        } else {
            resultStr = @"✗ nil path + nil error";
        }
        dispatch_semaphore_signal(sema);
    };

    NSMethodSignature *sig = [conn methodSignatureForSelector:importSel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:conn];
    [inv setSelector:importSel];
    [inv setArgument:&data atIndex:2];
    [inv setArgument:&completion atIndex:3];

    @try {
        [inv invoke];
    } @catch (NSException *e) {
        [out appendFormat:@"  XPC call exception: %@\n", e.reason];
        return;
    }

    // Wait up to 5 seconds for callback
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    [out appendFormat:@"  %@\n", resultStr];
}

@end
