#import <UIKit/UIKit.h>

static NSHashTable *gModels;
static void TSAAdd(id m);
static NSInteger kBtnTag = 0x5A5A;

#pragma mark - Helpers

static id SafeKVC(id obj, NSString *path) {
    if (!obj) return nil;
    @try { return [obj valueForKeyPath:path]; } @catch (__unused id e) { return nil; }
}

static NSString *FirstString(id obj, NSArray<NSString *> *paths) {
    for (NSString *p in paths) {
        id v = SafeKVC(obj, p);
        if ([v isKindOfClass:NSString.class] && [(NSString *)v length]) return v;
        if ([v isKindOfClass:NSNumber.class]) return [(NSNumber *)v stringValue];
    }
    return nil;
}

static NSURL *VideoURL(id aweme) {
    NSArray *keys = @[@"video.playAddr.originURLList",
                      @"video.playAddr.urlList",
                      @"video.downloadAddr.originURLList",
                      @"video.downloadAddr.urlList",
                      @"video.h264URL.originURLList"];
    for (NSString *k in keys) {
        id list = SafeKVC(aweme, k);
        if ([list isKindOfClass:NSArray.class] && [list count]) {
            NSString *s = [list firstObject];
            if ([s isKindOfClass:NSString.class]) return [NSURL URLWithString:s];
        }
    }
    return nil;
}

static NSString *AuthorID(id aweme) {
    return FirstString(aweme, @[@"author.userID", @"author.uid", @"authorUserID"]);
}

static NSString *AwemeID(id aweme) {
    return FirstString(aweme, @[@"awemeID", @"itemID", @"aweme_id"]);
}

static UIViewController *TopVC(void) {
    UIWindow *w = nil;
    for (UIWindow *win in UIApplication.sharedApplication.windows)
        if (win.isKeyWindow) { w = win; break; }
    UIViewController *vc = w.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

#pragma mark - Saver (no Photos framework needed)

@interface TSASaver : NSObject
+ (instancetype)shared;
- (void)saveVideoAtPath:(NSString *)path completion:(void (^)(BOOL ok))completion;
@end

@implementation TSASaver
+ (instancetype)shared {
    static TSASaver *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [TSASaver new]; });
    return s;
}
- (void)saveVideoAtPath:(NSString *)path completion:(void (^)(BOOL))completion {
    void *ctx = (void *)CFBridgingRetain([completion copy]);
    dispatch_async(dispatch_get_main_queue(), ^{
        UISaveVideoAtPathToSavedPhotosAlbum(path, self,
            @selector(video:didFinishSavingWithError:contextInfo:), ctx);
    });
}
- (void)video:(NSString *)path didFinishSavingWithError:(NSError *)error contextInfo:(void *)ctx {
    void (^cb)(BOOL) = (void (^)(BOOL))CFBridgingRelease(ctx);
    if (cb) cb(error == nil);
}
@end

#pragma mark - Downloader

@interface TSADownloader : NSObject
+ (void)downloadAll:(NSArray *)awemes;
@end

static volatile BOOL gCancel = NO;
static NSURLSessionDownloadTask *gTask = nil;

@implementation TSADownloader

+ (void)downloadAll:(NSArray *)awemes {
    gCancel = NO;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"TikSaveAll"
                         message:[NSString stringWithFormat:@"0 / %lu", (unsigned long)awemes.count]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a) {
            gCancel = YES;
            [gTask cancel];
        }]];
    [TopVC() presentViewController:alert animated:YES completion:nil];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSURLSession *session = NSURLSession.sharedSession;
        __block NSInteger ok = 0, fail = 0;

        for (NSUInteger i = 0; i < awemes.count; i++) {
            if (gCancel) break;
            NSURL *url = VideoURL(awemes[i]);
            if (!url) { fail++; continue; }

            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
            [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 14_3 like Mac OS X)" forHTTPHeaderField:@"User-Agent"];

            gTask = [session downloadTaskWithRequest:req completionHandler:^(NSURL *loc, NSURLResponse *r, NSError *e) {
                if (loc && !e && !gCancel) {
                    NSString *name = [NSString stringWithFormat:@"tsa_%@.mp4", AwemeID(awemes[i]) ?: NSUUID.UUID.UUIDString];
                    NSString *dest = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
                    [NSFileManager.defaultManager removeItemAtPath:dest error:nil];
                    [NSFileManager.defaultManager moveItemAtURL:loc toURL:[NSURL fileURLWithPath:dest] error:nil];

                    [[TSASaver shared] saveVideoAtPath:dest completion:^(BOOL success) {
                        if (success) ok++; else fail++;
                        [NSFileManager.defaultManager removeItemAtPath:dest error:nil];
                        dispatch_semaphore_signal(sem);
                    }];
                } else {
                    if (!gCancel) fail++;
                    dispatch_semaphore_signal(sem);
                }
            }];
            [gTask resume];

            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            if (gCancel) break;
            dispatch_async(dispatch_get_main_queue(), ^{
                alert.message = [NSString stringWithFormat:@"%lu / %lu  (failed: %ld)",
                                 (unsigned long)(i + 1), (unsigned long)awemes.count, (long)fail];
            });
        }

        BOOL cancelled = gCancel;
        dispatch_async(dispatch_get_main_queue(), ^{
            void (^showDone)(void) = ^{
                UIAlertController *d = [UIAlertController
                    alertControllerWithTitle:cancelled ? @"Cancelled" : @"Done"
                    message:[NSString stringWithFormat:@"Saved %ld, failed %ld", (long)ok, (long)fail]
                    preferredStyle:UIAlertControllerStyleAlert];
                [d addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [TopVC() presentViewController:d animated:YES completion:nil];
            };
            if (alert.presentingViewController) {
                [alert dismissViewControllerAnimated:YES completion:showDone];
            } else {
                showDone();
            }
        });
    });
}
@end

#pragma mark - Model tracking

static void TSAAdd(id m) {
    if (!m) return;
    if (!gModels) gModels = [NSHashTable weakObjectsHashTable];
    @synchronized (gModels) { [gModels addObject:m]; }
}

%hook AWEAwemeModel
- (id)init { id me = %orig; TSAAdd(me); return me; }
- (id)initWithDictionary:(id)d error:(id *)e { id me = %orig; TSAAdd(me); return me; }
%end

#pragma mark - Floating button

@interface TSAHandler : NSObject
+ (instancetype)shared;
- (void)tapped;
- (void)ensureButton;
@end

@implementation TSAHandler
+ (instancetype)shared {
    static TSAHandler *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [TSAHandler new]; });
    return s;
}

- (void)ensureButton {
    UIWindow *w = nil;
    for (UIWindow *win in UIApplication.sharedApplication.windows)
        if (win.isKeyWindow) { w = win; break; }
    if (!w || [w viewWithTag:kBtnTag]) return;

    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.tag = kBtnTag;
    b.frame = CGRectMake(10, 120, 80, 36);
    b.backgroundColor = [UIColor colorWithRed:0.9 green:0.1 blue:0.3 alpha:0.9];
    b.layer.cornerRadius = 18;
    b.layer.zPosition = 9999;
    [b setTitle:@"\u2B07 Save" forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [b addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    [w addSubview:b];
}

- (void)tapped {
    // group loaded videos by author, pick the author with most videos
    NSMutableDictionary<NSString *, NSMutableArray *> *byAuthor = [NSMutableDictionary dictionary];
    NSMutableSet *seen = [NSMutableSet set];
    NSInteger total = 0;
    if (gModels) {
        @synchronized (gModels) {
            for (id m in gModels.allObjects) {
                total++;
                if (!VideoURL(m)) continue;
                NSString *aid = AwemeID(m) ?: [NSString stringWithFormat:@"%p", m];
                if ([seen containsObject:aid]) continue;
                [seen addObject:aid];
                NSString *au = AuthorID(m) ?: @"unknown";
                if (!byAuthor[au]) byAuthor[au] = [NSMutableArray array];
                [byAuthor[au] addObject:m];
            }
        }
    }

    NSArray *best = nil;
    for (NSArray *l in byAuthor.allValues) if (l.count > best.count) best = l;

    if (!best.count) {
        NSString *msg = [NSString stringWithFormat:
            @"No videos found (models seen: %ld).\nCurrent screen class:\n%@\n\nOpen a profile, scroll down, then tap again.",
            (long)total, NSStringFromClass([TopVC() class])];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"TikSaveAll"
            message:msg preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [TopVC() presentViewController:a animated:YES completion:nil];
        return;
    }

    UIAlertController *c = [UIAlertController alertControllerWithTitle:@"TikSaveAll"
        message:[NSString stringWithFormat:@"Save %lu videos?", (unsigned long)best.count]
        preferredStyle:UIAlertControllerStyleAlert];
    [c addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [c addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [TSADownloader downloadAll:best];
    }]];
    [TopVC() presentViewController:c animated:YES completion:nil];
}
@end

%ctor {
    gModels = [NSHashTable weakObjectsHashTable];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [[TSAHandler shared] ensureButton];
            });
    }];
    // keep the button alive when windows change
    [NSTimer scheduledTimerWithTimeInterval:3 repeats:YES block:^(NSTimer *t) {
        [[TSAHandler shared] ensureButton];
    }];
}
