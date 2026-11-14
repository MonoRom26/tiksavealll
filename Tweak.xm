#import <UIKit/UIKit.h>

static NSHashTable *gModels;
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

@implementation TSADownloader

+ (void)downloadAll:(NSArray *)awemes {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"TikSaveAll"
                         message:[NSString stringWithFormat:@"0 / %lu", (unsigned long)awemes.count]
                  preferredStyle:UIAlertControllerStyleAlert];
    [TopVC() presentViewController:alert animated:YES completion:nil];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSURLSession *session = NSURLSession.sharedSession;
        __block NSInteger ok = 0, fail = 0;

        for (NSUInteger i = 0; i < awemes.count; i++) {
            NSURL *url = VideoURL(awemes[i]);
            if (!url) { fail++; continue; }

            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
            [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 14_3 like Mac OS X)" forHTTPHeaderField:@"User-Agent"];

            [[session downloadTaskWithRequest:req completionHandler:^(NSURL *loc, NSURLResponse *r, NSError *e) {
                if (loc && !e) {
                    NSString *name = [NSString stringWithFormat:@"tsa_%@.mp4", AwemeID(awemes[i]) ?: NSUUID.UUID.UUIDString];
                    NSString *dest = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
                    [NSFileManager.defaultManager removeItemAtPath:dest error:nil];
                    [NSFileManager.defaultManager moveItemAtURL:loc toURL:[NSURL fileURLWithPath:dest] error:nil];

                    [[TSASaver shared] saveVideoAtPath:dest completion:^(BOOL success) {
                        if (success) ok++; else fail++;
                        [NSFileManager.defaultManager removeItemAtPath:dest error:nil];
                        dispatch_semaphore_signal(sem);
                    }];
                } else { fail++; dispatch_semaphore_signal(sem); }
            }] resume];

            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            dispatch_async(dispatch_get_main_queue(), ^{
                alert.message = [NSString stringWithFormat:@"%lu / %lu  (failed: %ld)",
                                 (unsigned long)(i + 1), (unsigned long)awemes.count, (long)fail];
            });
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            alert.title = @"Done";
            alert.message = [NSString stringWithFormat:@"Saved %ld, failed %ld", (long)ok, (long)fail];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        });
    });
}
@end

#pragma mark - Hooks

%hook AWEAwemeModel
- (id)init {
    id me = %orig;
    if (me) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ gModels = [NSHashTable weakObjectsHashTable]; });
        @synchronized (gModels) { [gModels addObject:me]; }
    }
    return me;
}
%end

%hook AWEUserProfileViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UIView *v = [(UIViewController *)self view];
    if ([v viewWithTag:kBtnTag]) return;

    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.tag = kBtnTag;
    b.frame = CGRectMake(v.bounds.size.width - 110, 100, 100, 36);
    b.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    b.layer.cornerRadius = 18;
    [b setTitle:@"Save All" forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [b addTarget:self action:@selector(tsa_saveAll) forControlEvents:UIControlEventTouchUpInside];
    [v addSubview:b];
}

%new
- (void)tsa_saveAll {
    NSString *uid = FirstString(self, @[@"user.userID", @"user.uid", @"userModel.userID", @"userID"]);

    NSMutableArray *list = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    if (gModels) {
        @synchronized (gModels) {
            for (id m in gModels.allObjects) {
                if (!VideoURL(m)) continue;
                NSString *aid = AwemeID(m);
                if (!aid || [seen containsObject:aid]) continue;
                if (uid && ![AuthorID(m) isEqualToString:uid]) continue;
                [seen addObject:aid];
                [list addObject:m];
            }
        }
    }

    if (!list.count) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"TikSaveAll"
            message:@"No videos found. Scroll the profile to load them first."
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [(UIViewController *)self presentViewController:a animated:YES completion:nil];
        return;
    }
    [TSADownloader downloadAll:list];
}
%end
