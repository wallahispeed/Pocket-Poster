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

    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = @"PosterProbe";
    lbl.textColor = UIColor.whiteColor;
    lbl.font = [UIFont boldSystemFontOfSize:18];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:lbl];

    self.textView = [[UITextView alloc] init];
    self.textView.backgroundColor = UIColor.blackColor;
    self.textView.textColor = UIColor.greenColor;
    self.textView.font = [UIFont fontWithName:@"Menlo" size:11];
    self.textView.editable = NO;
    self.textView.text = @"Scanning…";
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
        [lbl.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [lbl.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:lbl.centerYAnchor],
        [self.spinner.leadingAnchor constraintEqualToAnchor:lbl.trailingAnchor constant:8],
        [self.textView.topAnchor constraintEqualToAnchor:lbl.bottomAnchor constant:8],
        [self.textView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [self.textView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
        [self.textView.bottomAnchor constraintEqualToAnchor:copyBtn.topAnchor constant:-8],
        [copyBtn.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [copyBtn.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
    ]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *result = [self runScan];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.textView.text = result;
            [self.spinner stopAnimating];
        });
    });
}

- (void)copyOutput {
    UIPasteboard.generalPasteboard.string = self.textView.text;
}

- (NSString *)runScan {
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"=== PosterProbe ===\n\n"];

    // 1. Load frameworks (dlopen only — no alloc, no init)
    [out appendString:@"[1] dlopen\n"];
    void *pfH  = dlopen("/System/Library/PrivateFrameworks/PosterFoundation.framework/PosterFoundation", RTLD_NOW);
    void *pbsH = dlopen("/System/Library/PrivateFrameworks/PosterBoardServices.framework/PosterBoardServices", RTLD_NOW);
    [out appendFormat:@"  PF:  %@\n", pfH  ? @"ok" : [NSString stringWithUTF8String:dlerror()]];
    [out appendFormat:@"  PBS: %@\n\n", pbsH ? @"ok" : [NSString stringWithUTF8String:dlerror()]];

    // 2. Named class lookup (NSClassFromString only — zero side effects)
    [out appendString:@"[2] Named classes\n"];
    for (NSString *cn in @[
        @"PRSPosterConfiguration", @"PFPosterPath",
        @"PFServerPosterPath",     @"PFServerPosterIdentity",
        @"PRSService",             @"PRSConnection",
        @"PRSServer",              @"PRSClient",
        @"PRSXPCConnection",       @"PRSServiceConnection",
        @"PRSPosterService",       @"PRSPosterConnection",
        @"PRSPosterImporter",      @"PRSArchiveImporter",
    ]) {
        [out appendFormat:@"  %-28s %@\n", cn.UTF8String, NSClassFromString(cn) ? @"✓" : @"—"];
    }
    [out appendString:@"\n"];

    // 3. Runtime scan — read-only: class_getName + respondsToSelector only
    //    No alloc, no init, no method calls on instances
    [out appendString:@"[3] Class scan (PRS*/PBS*/PF* prefix)\n"];
    SEL selA = NSSelectorFromString(@"importPosterConfigurationFromArchiveData:completion:");
    SEL selB = NSSelectorFromString(@"importPosterConfigurationFromArchivedData:completion:");
    SEL selC = NSSelectorFromString(@"importPosterConfiguration:completion:");
    SEL selD = NSSelectorFromString(@"mutateSwitcherConfiguration:completion:");

    int total = objc_getClassList(NULL, 0);
    [out appendFormat:@"  total classes: %d\n", total];

    if (total > 0 && total < 500000) {
        __unsafe_unretained Class *buf = (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)total);
        if (buf) {
            objc_getClassList(buf, total);
            for (int i = 0; i < total; i++) {
                const char *cn = class_getName(buf[i]);
                if (!cn) continue;
                if (strncmp(cn, "PRS", 3) != 0 &&
                    strncmp(cn, "PBS", 3) != 0 &&
                    strncmp(cn, "PF",  2) != 0) continue;

                // Build tag showing which selectors this class instance responds to
                NSMutableString *tags = [NSMutableString string];
                if ([buf[i] instancesRespondToSelector:selA]) [tags appendString:@" [importArchive]"];
                if ([buf[i] instancesRespondToSelector:selB]) [tags appendString:@" [importArchivedOld]"];
                if ([buf[i] instancesRespondToSelector:selC]) [tags appendString:@" [importConfig]"];
                if ([buf[i] instancesRespondToSelector:selD]) [tags appendString:@" [mutateSwitcher]"];

                if (tags.length > 0) {
                    [out appendFormat:@"  %s%@\n", cn, tags];
                } else {
                    [out appendFormat:@"  %s\n", cn];
                }
            }
            free(buf);
        } else {
            [out appendString:@"  malloc failed\n"];
        }
    }

    [out appendString:@"\n=== DONE ===\n"];
    return out;
}

@end
