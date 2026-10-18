#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString * const KBook = @"currentBook";
static NSString * const KRecent = @"recentBooks";
static NSString * const KPositions = @"positions";
static NSString * const KHidden = @"hidden";
static NSString * const KLength = @"displayLength";
static NSString * const KFont = @"fontSize";
static NSString * const KColor = @"textColor";
static NSString * const KPrevKey = @"previousShortcut";
static NSString * const KNextKey = @"nextShortcut";
static NSString * const KToggleKey = @"toggleShortcut";
static NSString * const KLibrary = @"libraryBooks";
static NSString * const KUnderlines = @"savedUnderlines";
static NSString * const KShortcutsPaused = @"shortcutsPaused";
static NSString * const KClickToTurn = @"clickToTurnPage";
static NSString * const KSmartBreak = @"breakAtPunctuation";
static NSString * const KAutoInterval = @"autoTurnInterval";
static NSString * const KMeetingHide = @"hideDuringMeetings";
static NSString * const KReaderFont = @"readerFontSize";
static NSString * const KReaderSpacing = @"readerLineSpacing";
static NSString * const KReaderTheme = @"readerTheme";
// 解析规则变化时加一，旧缓存会自动失效并重新解析。
static NSInteger const KParserVersion = 2;

@interface EPUBDelegate : NSObject <NSXMLParserDelegate>
@property NSMutableDictionary<NSString *, NSString *> *manifest;
@property NSMutableArray<NSString *> *spine;
@end

@implementation EPUBDelegate
- (instancetype)init { if ((self = [super init])) { _manifest = [NSMutableDictionary dictionary]; _spine = [NSMutableArray array]; } return self; }
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)name namespaceURI:(NSString *)uri qualifiedName:(NSString *)qName attributes:(NSDictionary<NSString *,NSString *> *)attrs {
    if ([name hasSuffix:@"item"] && attrs[@"id"] && attrs[@"href"]) self.manifest[attrs[@"id"]] = attrs[@"href"];
    else if ([name hasSuffix:@"itemref"] && attrs[@"idref"]) [self.spine addObject:attrs[@"idref"]];
}
@end

static NSString *CleanText(NSString *text) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    NSString *out = [re stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@" "];
    return [out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *DecodeText(NSData *data) {
    const unsigned char *bytes = data.bytes;
    if (data.length >= 2) {
        if ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF)) {
            NSString *utf16 = [[NSString alloc] initWithData:data encoding:NSUTF16StringEncoding];
            if (utf16) return utf16;
        }
    }
    // 无 BOM 的中文 TXT 很容易被 UTF-16“成功”误解码，因此优先检测
    // UTF-8、GB18030/GBK 和 Big5，最后才尝试 UTF-16。
    NSArray<NSNumber *> *encodings = @[@(NSUTF8StringEncoding), @(CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000)), @(CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingBig5)), @(NSUTF16StringEncoding)];
    for (NSNumber *value in encodings) {
        NSString *text = [[NSString alloc] initWithData:data encoding:value.unsignedIntegerValue];
        if (text) return text;
    }
    return nil;
}

static NSString *DecodeTextFile(NSURL *url, NSError **outError) {
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:outError];
    if (!data) return nil;
    // BOM 与 UTF-8 先走原生解码；其他常见中文 TXT 使用系统 iconv 的
    // GB18030 容错模式，跳过下载站文本中偶尔混入的坏字节。
    const unsigned char *bytes = data.bytes;
    BOOL hasUTF16BOM = data.length >= 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF));
    if (hasUTF16BOM) return [[NSString alloc] initWithData:data encoding:NSUTF16StringEncoding];
    NSString *utf8 = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (utf8) return utf8;

    NSPipe *output = [NSPipe pipe];
    NSPipe *errors = [NSPipe pipe];
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/iconv"];
    task.arguments = @[@"-c", @"-f", @"GB18030", @"-t", @"UTF-8", url.path];
    task.standardOutput = output;
    task.standardError = errors;
    if ([task launchAndReturnError:outError]) {
        NSData *converted = [output.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];
        NSString *text = [[NSString alloc] initWithData:converted encoding:NSUTF8StringEncoding];
        if (task.terminationStatus == 0 && text.length) return text;
    }
    return DecodeText(data);
}

static NSArray<NSDictionary *> *ParseTXT(NSString *text) {
    text = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    // 章节名前经常带有书名或下载站前缀，不能要求整行只有“第X章”。
    // 排除“节”，避免把“第一节课”等正文误识别成章节。
    // 但正文里也常出现“读完了第三章的结尾。”这类句子，因此要求：整行较短、
    // 前缀（书名、站名）不含句读标点且以空格或》】等收尾、
    // 行尾不是句末标点。不满足时整行保留在正文里。
    NSRegularExpression *chapterRE = [NSRegularExpression regularExpressionWithPattern:@"^(?:[^。，！？；：…“”\"]{0,20}?[\\s》】」』\\]）)])?(第[0-9０-９零〇一二三四五六七八九十百千万两]+[章回卷部篇].*)$" options:0 error:nil];
    NSCharacterSet *sentenceEnd = [NSCharacterSet characterSetWithCharactersInString:@"。，！？；…”\"、"];
    NSMutableArray *chapters = [NSMutableArray array];
    __block NSMutableArray *body = [NSMutableArray array];
    __block NSString *title = @"正文";
    void (^appendChapter)(void) = ^{
        NSString *joined = CleanText([body componentsJoinedByString:@" "]);
        if (joined.length) [chapters addObject:@{@"title": title, @"text": joined}];
    };
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSTextCheckingResult *heading = nil;
        if (trimmed.length && trimmed.length <= 40 && ![sentenceEnd characterIsMember:[trimmed characterAtIndex:trimmed.length - 1]])
            heading = [chapterRE firstMatchInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)];
        if (heading) {
            appendChapter();
            title = [trimmed substringWithRange:[heading rangeAtIndex:1]];
            body = [NSMutableArray array];
        } else if (trimmed.length) {
            [body addObject:line];
        }
    }
    appendChapter();
    if (!chapters.count) [chapters addObject:@{@"title": @"正文", @"text": CleanText(text)}];
    return chapters;
}

static NSString *HTMLTitle(NSString *html, NSUInteger index) {
    for (NSString *pattern in @[@"(?is)<h[1-3][^>]*>(.*?)</h[1-3]>", @"(?is)<title[^>]*>(.*?)</title>"]) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
        NSTextCheckingResult *match = [re firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
        if (match) {
            NSString *raw = [html substringWithRange:match.range];
            raw = [[NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:0 error:nil] stringByReplacingMatchesInString:raw options:0 range:NSMakeRange(0, raw.length) withTemplate:@""];
            raw = CleanText(raw);
            if (raw.length) return raw;
        }
    }
    return [NSString stringWithFormat:@"第 %lu 节", (unsigned long)index + 1];
}

static NSArray<NSDictionary *> *ParseEPUB(NSURL *url, NSError **outError) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *temp = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[@"Xidu-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [fm createDirectoryAtURL:temp withIntermediateDirectories:YES attributes:nil error:nil];
    NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/ditto"]; task.arguments = @[@"-x", @"-k", url.path, temp.path];
    [task launchAndReturnError:outError]; [task waitUntilExit];
    if (task.terminationStatus != 0) { [fm removeItemAtURL:temp error:nil]; return nil; }
    NSURL *containerURL = [temp URLByAppendingPathComponent:@"META-INF/container.xml"];
    NSString *container = [NSString stringWithContentsOfURL:containerURL encoding:NSUTF8StringEncoding error:outError];
    NSRegularExpression *pathRE = [NSRegularExpression regularExpressionWithPattern:@"full-path\\s*=\\s*[\\\"']([^\\\"']+)[\\\"']" options:0 error:nil];
    NSTextCheckingResult *match = [pathRE firstMatchInString:container ?: @"" options:0 range:NSMakeRange(0, container.length)];
    if (!match || match.numberOfRanges < 2) { [fm removeItemAtURL:temp error:nil]; return nil; }
    NSString *opfPath = [container substringWithRange:[match rangeAtIndex:1]];
    NSURL *opfURL = [temp URLByAppendingPathComponent:opfPath];
    EPUBDelegate *delegate = [EPUBDelegate new];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithContentsOfURL:opfURL]; parser.delegate = delegate; [parser parse];
    NSURL *base = opfURL.URLByDeletingLastPathComponent;
    NSMutableArray *chapters = [NSMutableArray array];
    for (NSString *identifier in delegate.spine) {
        NSString *href = delegate.manifest[identifier]; if (!href) continue;
        NSRange fragment = [href rangeOfString:@"#"]; if (fragment.location != NSNotFound) href = [href substringToIndex:fragment.location];
        NSURL *fileURL = [base URLByAppendingPathComponent:href.stringByRemovingPercentEncoding ?: href];
        NSData *data = [NSData dataWithContentsOfURL:fileURL]; if (!data) continue;
        NSDictionary *options = @{NSDocumentTypeDocumentAttribute: NSHTMLTextDocumentType, NSCharacterEncodingDocumentAttribute: @(NSUTF8StringEncoding)};
        NSAttributedString *attributed = [[NSAttributedString alloc] initWithData:data options:options documentAttributes:nil error:nil];
        NSString *cleaned = CleanText(attributed.string ?: @""); if (!cleaned.length) continue;
        NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        [chapters addObject:@{@"title": HTMLTitle(html, chapters.count), @"text": cleaned}];
    }
    [fm removeItemAtURL:temp error:nil];
    return chapters.count ? chapters : nil;
}

// 搜索时忽略大小写、空白和标点，同时保留每个规范化字符在原文中的位置。
static NSString *SearchNormalizedText(NSString *text, NSMutableArray<NSNumber *> *mapping) {
    NSMutableString *normalized=[NSMutableString string];NSCharacterSet *ignored=[NSCharacterSet whitespaceAndNewlineCharacterSet];NSCharacterSet *punctuation=[NSCharacterSet punctuationCharacterSet];
    [text enumerateSubstringsInRange:NSMakeRange(0,text.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *substring,NSRange range,NSRange enclosingRange,BOOL *stop){
        unichar first=substring.length?[substring characterAtIndex:0]:0;
        if([ignored characterIsMember:first]||[punctuation characterIsMember:first])return;
        NSString *folded=[substring lowercaseString];[normalized appendString:folded];
        if(mapping)for(NSUInteger i=0;i<folded.length;i++)[mapping addObject:@(range.location)];
    }];return normalized;
}

typedef struct { __unsafe_unretained NSString *label; UInt32 keyCode; UInt32 modifiers; } Shortcut;
@class AppDelegate;
static OSStatus HotKeyHandler(EventHandlerCallRef next, EventRef event, void *data);

@protocol ReaderTextViewOwner <NSObject>
- (void)continueReadingHere:(id)sender;
- (NSString *)underlineMenuTitle;
- (BOOL)canToggleUnderline;
- (void)toggleUnderline:(id)sender;
@end

@interface ReaderTextView : NSTextView
@property (weak) id<ReaderTextViewOwner> readerOwner;
@property NSInteger contextCharacterIndex;
@end

@implementation ReaderTextView
- (void)commitContextPosition:(id)sender {[self.readerOwner continueReadingHere:self];}
- (void)rightMouseDown:(NSEvent *)event {
    NSPoint point=[self convertPoint:event.locationInWindow fromView:nil];
    point.x-=self.textContainerOrigin.x;point.y-=self.textContainerOrigin.y;
    NSUInteger glyph=[self.layoutManager glyphIndexForPoint:point inTextContainer:self.textContainer fractionOfDistanceThroughGlyph:nil];
    self.contextCharacterIndex=(glyph<self.layoutManager.numberOfGlyphs)?[self.layoutManager characterIndexForGlyphAtIndex:glyph]:self.string.length;
    [super rightMouseDown:event];
}
- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSMenu *menu=[NSMenu new];
    NSMenuItem *continueItem=[[NSMenuItem alloc]initWithTitle:@"从此处继续阅读" action:@selector(commitContextPosition:) keyEquivalent:@""];continueItem.target=self;[menu addItem:continueItem];
    NSMenuItem *underlineItem=[[NSMenuItem alloc]initWithTitle:[self.readerOwner underlineMenuTitle] action:@selector(toggleUnderline:) keyEquivalent:@""];underlineItem.target=self.readerOwner;underlineItem.enabled=[self.readerOwner canToggleUnderline];[menu addItem:underlineItem];
    [menu addItem:NSMenuItem.separatorItem];NSMenuItem *copy=[[NSMenuItem alloc]initWithTitle:@"拷贝" action:@selector(copy:) keyEquivalent:@""];copy.target=nil;copy.enabled=(self.selectedRange.length>0);[menu addItem:copy];return menu;
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, ReaderTextViewOwner>
@property NSStatusItem *statusItem;
@property NSDictionary *book;
@property NSInteger chapter;
@property NSInteger offset;
@property NSMutableDictionary *positions;
@property NSMutableArray<NSValue *> *hotKeyRefs;
@property NSMenu *popupMenu;
@property id globalMouseMonitor;
@property id localMouseMonitor;
@property NSWindow *readerWindow;
@property ReaderTextView *readerTextView;
@property NSPopUpButton *readerChapterPopup;
@property NSScrollView *readerScrollView;
@property BOOL updatingReader;
@property NSInteger readerBrowseChapter;
@property NSView *readerSearchBar;
@property NSSearchField *readerSearchField;
@property NSPopUpButton *readerSearchScope;
@property NSTextField *readerSearchCount;
@property NSArray<NSDictionary *> *readerSearchMatches;
@property NSInteger readerSearchIndex;
@property id readerKeyMonitor;
@property NSMutableArray<NSMutableDictionary *> *library;
@property NSMutableDictionary<NSString *,NSMutableArray<NSMutableDictionary *> *> *underlines;
@property NSWindow *shelfWindow;
@property NSTableView *shelfTable;
@property NSWindow *excerptsWindow;
@property NSTableView *excerptsTable;
@property NSPopUpButton *excerptsBookFilter;
@property NSArray<NSDictionary *> *visibleExcerpts;
@property BOOL didFinishLaunching;
@property NSMutableIndexSet *failedHotKeyActions;
@property id statusScrollMonitor;
@property CGFloat statusScrollAccumulator;
@property NSTimer *autoTurnTimer;
@property BOOL autoHidden;
@property BOOL screenLocked;
@property NSArray<NSNumber *> *chapterStarts;
@property NSInteger bookLength;
@property NSPopUpButton *readerStyleButton;
@property NSString *readerLoadedBookPath;
@property NSInteger readerLoadedChapter;
@property NSMutableArray<NSURL *> *pendingOpenURLs;
- (void)handleHotKey:(UInt32)identifier;
- (NSDictionary *)importBookURL:(NSURL *)source error:(NSError **)outError;
- (void)saveLibrary;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d registerDefaults:@{KHidden:@NO, KLength:@0, KFont:@13, KColor:@"label", KPrevKey:@0, KNextKey:@0, KToggleKey:@0, KShortcutsPaused:@NO, KClickToTurn:@YES, KSmartBreak:@YES, KAutoInterval:@0, KMeetingHide:@YES, KReaderFont:@18, KReaderSpacing:@1.3, KReaderTheme:@"system"}];
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(statusItemClicked:);
    [self.statusItem.button sendActionOn:NSEventMaskLeftMouseUp|NSEventMaskRightMouseUp];
    // 鼠标停在状态栏正文上滚动滚轮也能翻页。本地监听只收到发给本程序窗口的事件。
    __weak typeof(self) weakStatusSelf=self;
    self.statusScrollMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel handler:^NSEvent *(NSEvent *event){
        if(event.window&&event.window==weakStatusSelf.statusItem.button.window){[weakStatusSelf handleStatusScroll:event];return nil;}
        return event;
    }];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(frontApplicationChanged:) name:NSWorkspaceDidActivateApplicationNotification object:nil];
    // 锁屏或屏幕休眠时暂停自动翻页。
    [NSDistributedNotificationCenter.defaultCenter addObserverForName:@"com.apple.screenIsLocked" object:nil queue:nil usingBlock:^(NSNotification *n){self.screenLocked=YES;}];
    [NSDistributedNotificationCenter.defaultCenter addObserverForName:@"com.apple.screenIsUnlocked" object:nil queue:nil usingBlock:^(NSNotification *n){self.screenLocked=NO;}];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceScreensDidSleepNotification object:nil queue:nil usingBlock:^(NSNotification *n){self.screenLocked=YES;}];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceScreensDidWakeNotification object:nil queue:nil usingBlock:^(NSNotification *n){self.screenLocked=NO;}];
    NSDictionary *diskPositions=[NSDictionary dictionaryWithContentsOfURL:[self progressFileURL]];
    self.positions = [diskPositions mutableCopy] ?: [[d dictionaryForKey:KPositions] mutableCopy] ?: [NSMutableDictionary dictionary];
    // 书库和划线保存在 Application Support/隙读 下的 JSON 文件；首次启动新版本时
    // 从旧版的 NSUserDefaults 迁移过来。
    id storedLibrary=[self readStoreNamed:@"library.json"];
    self.library = [NSMutableArray array];
    for (NSDictionary *entry in [storedLibrary isKindOfClass:NSArray.class] ? storedLibrary : ([d arrayForKey:KLibrary] ?: @[])) [self.library addObject:[entry mutableCopy]];
    self.underlines=[NSMutableDictionary dictionary];
    id storedUnderlines=[self readStoreNamed:@"underlines.json"];
    NSDictionary *savedUnderlines=[storedUnderlines isKindOfClass:NSDictionary.class]?storedUnderlines:([d dictionaryForKey:KUnderlines]?:@{});for(NSString *path in savedUnderlines){NSMutableArray *items=[NSMutableArray array];for(NSDictionary *item in savedUnderlines[path])[items addObject:[item mutableCopy]];self.underlines[path]=items;}
    // 将旧版本保存的外部文件自动复制进托管书库，并迁移阅读进度。
    NSMutableArray *legacyPaths=[NSMutableArray arrayWithArray:[d stringArrayForKey:KRecent]?:@[]];
    NSString *legacyCurrent=[d stringForKey:KBook];if(legacyCurrent.length&&![legacyPaths containsObject:legacyCurrent])[legacyPaths insertObject:legacyCurrent atIndex:0];
    for(NSString *legacyPath in legacyPaths){
        if(![NSFileManager.defaultManager fileExistsAtPath:legacyPath])continue;
        BOOL managed=NO;NSDictionary *alreadyImported=nil;
        for(NSDictionary *entry in self.library){if([entry[@"path"]isEqual:legacyPath]){managed=YES;break;}if([entry[@"sourcePath"]isEqual:legacyPath])alreadyImported=entry;}
        if(managed)continue;
        if(alreadyImported){if([legacyCurrent isEqual:legacyPath])[d setObject:alreadyImported[@"path"] forKey:KBook];continue;}
        NSDictionary *entry=[self importBookURL:[NSURL fileURLWithPath:legacyPath] error:nil];
        if(entry){NSDictionary *oldPosition=self.positions[legacyPath];if(oldPosition&&!self.positions[entry[@"path"]])self.positions[entry[@"path"]]=oldPosition;if([legacyCurrent isEqual:legacyPath])[d setObject:entry[@"path"] forKey:KBook];}
    }
    [self flushPositions];[self saveLibrary];[self saveUnderlines];
    self.hotKeyRefs = [NSMutableArray array];
    EventTypeSpec type = {kEventClassKeyboard, kEventHotKeyPressed};
    InstallApplicationEventHandler(&HotKeyHandler, 1, &type, (__bridge void *)self, NULL);
    NSString *path = [d stringForKey:KBook];
    if (path.length && [NSFileManager.defaultManager fileExistsAtPath:path]) [self openURL:[NSURL fileURLWithPath:path] showError:NO];
    [self updateMeetingHide];[self registerHotKeys]; [self restartAutoTurn]; [self updateUI];
    self.didFinishLaunching = YES;
    if (self.pendingOpenURLs.count) { [self importURLs:self.pendingOpenURLs openFirst:YES]; self.pendingOpenURLs = nil; }
}

// 在 Finder 中双击、“打开方式”或拖到程序图标上时调用。冷启动时系统可能在
// applicationDidFinishLaunching 之前就送来文件，此时书库尚未加载，先暂存。
- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    if (!self.didFinishLaunching) {
        if (!self.pendingOpenURLs) self.pendingOpenURLs = [NSMutableArray array];
        [self.pendingOpenURLs addObjectsFromArray:urls];
        return;
    }
    [self importURLs:urls openFirst:YES];
}

- (NSURL *)supportDirectory {
    NSURL *support=[NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    NSURL *directory=[support URLByAppendingPathComponent:@"隙读" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];return directory;
}

- (NSURL *)libraryDirectory {
    NSURL *directory=[[self supportDirectory] URLByAppendingPathComponent:@"Books" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];return directory;
}

- (NSURL *)progressFileURL {return [[self supportDirectory] URLByAppendingPathComponent:@"progress.plist"];}

// 翻页很频繁，进度合并到 1 秒后写一次盘；退出时立即写入。
- (void)savePositions {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(flushPositions) object:nil];
    [self performSelector:@selector(flushPositions) withObject:nil afterDelay:1.0];
}

- (void)flushPositions {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(flushPositions) object:nil];
    [self.positions writeToURL:[self progressFileURL] atomically:YES];
}

- (id)readStoreNamed:(NSString *)name {
    NSData *data=[NSData dataWithContentsOfURL:[[self supportDirectory] URLByAppendingPathComponent:name]];
    return data?[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil]:nil;
}

- (void)writeStore:(id)object named:(NSString *)name {
    NSData *data=[NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
    [data writeToURL:[[self supportDirectory] URLByAppendingPathComponent:name] atomically:YES];
}

- (void)saveLibrary {[self writeStore:self.library named:@"library.json"];}

- (NSDictionary *)libraryEntryForPath:(NSString *)path {for(NSDictionary *entry in self.library)if([entry[@"path"]isEqual:path])return entry;return nil;}

- (NSDictionary *)importBookURL:(NSURL *)source error:(NSError **)outError {
    NSString *ext=source.pathExtension.lowercaseString;if(![@[@"txt",@"epub"]containsObject:ext])return nil;
    NSDictionary *attrs=[NSFileManager.defaultManager attributesOfItemAtPath:source.path error:outError];if(!attrs)return nil;
    NSString *title=source.URLByDeletingPathExtension.lastPathComponent;NSNumber *size=attrs[NSFileSize]?:@0;
    for(NSDictionary *entry in self.library){if(([entry[@"sourcePath"]isEqual:source.path])||([entry[@"title"]isEqual:title]&&[entry[@"size"]isEqual:size]))return entry;}
    NSString *filename=[NSString stringWithFormat:@"%@.%@",NSUUID.UUID.UUIDString,ext];NSURL *destination=[[self libraryDirectory]URLByAppendingPathComponent:filename];
    if(![NSFileManager.defaultManager copyItemAtURL:source toURL:destination error:outError])return nil;
    NSMutableDictionary *entry=[@{@"id":NSUUID.UUID.UUIDString,@"title":title,@"path":destination.path,@"sourcePath":source.path,@"size":size}mutableCopy];[self.library addObject:entry];[self saveLibrary];return entry;
}

- (NSInteger)segmentLength {
    NSInteger value = [NSUserDefaults.standardUserDefaults integerForKey:KLength];
    NSInteger requested = value;
    CGFloat width = NSScreen.mainScreen.frame.size.width ?: 1440;
    if (requested <= 0) {
        requested = MAX(24, MIN(46, (NSInteger)(width / 42.0)));
        // 带刘海的屏幕上，刘海右侧的状态栏空间有限；正文太长时系统会直接把状态项藏起来。
        // 自动长度最多占刘海右侧空间的一半（按当前字号估算每个汉字的宽度）。
        if (@available(macOS 12.0, *)) {
            NSScreen *screen = self.statusItem.button.window.screen ?: NSScreen.mainScreen;
            if (screen.safeAreaInsets.top > 0) {
                CGFloat available = NSWidth(screen.auxiliaryTopRightArea) * 0.5 - 48.0;
                CGFloat glyph = MAX(10.0, [NSUserDefaults.standardUserDefaults doubleForKey:KFont]);
                requested = MIN(requested, MAX(10, (NSInteger)(available / glyph)));
            }
        }
    }
    // 阅读段长只由用户设置（或自动值）决定，不随前台程序改变。
    // 这样切换 Chrome、Finder 等应用时，正文范围和翻页步长始终一致。
    return requested;
}

// 会议和办公通讯软件在前台时自动隐藏正文，切走后自动恢复。
- (void)updateMeetingHide {
    static NSSet *meetingApps; static dispatch_once_t once;
    dispatch_once(&once, ^{ meetingApps = [NSSet setWithArray:@[@"us.zoom.xos", @"com.tencent.meeting", @"com.microsoft.teams", @"com.microsoft.teams2", @"com.cisco.webexmeetingsapp", @"Cisco-Systems.Spark", @"com.apple.FaceTime", @"com.electron.lark", @"com.bytedance.lark", @"com.larksuite.larkApp", @"com.alibaba.DingTalkMac", @"com.tencent.WeWorkMac"]]; });
    NSString *front = NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier;
    self.autoHidden = [NSUserDefaults.standardUserDefaults boolForKey:KMeetingHide] && front && [meetingApps containsObject:front];
}

- (void)frontApplicationChanged:(NSNotification *)notification {
    [self updateMeetingHide];
    self.statusItem.visible = YES;
    [self updateUI];
    // 等系统完成新应用菜单布局后再刷新一次，避免状态项沿用上一帧的
    // 可用宽度判断而保持隐藏。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.statusItem.visible = YES;
        [self updateUI];
    });
}

- (NSString *)currentText {
    NSArray *chapters = self.book[@"chapters"];
    if (!chapters.count) return @"隙读 · 选择一本书";
    self.chapter = MAX(0, MIN(self.chapter, (NSInteger)chapters.count - 1));
    NSString *text = chapters[self.chapter][@"text"];
    if (!text.length) return chapters[self.chapter][@"title"];
    self.offset = MAX(0, MIN(self.offset, (NSInteger)text.length - 1));
    NSInteger end = [self segmentEndInText:text from:self.offset];
    return [text substringWithRange:NSMakeRange(self.offset, end - self.offset)];
}

static BOOL IsBreakCharacter(unichar c) {
    static NSCharacterSet *set; static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSCharacterSet characterSetWithCharactersInString:@"，。！？；：、…—,.!?;:）)」』”’》 "]; });
    return [set characterIsMember:c];
}

// 这一段的结束位置。开启“在标点处断开”时，在设定字数的 60%–130% 范围内
// 找离设定字数最近的标点，断在标点之后；找不到就按字数断开。
- (NSInteger)segmentEndInText:(NSString *)text from:(NSInteger)start {
    NSInteger length = text.length, target = self.segmentLength;
    if (start + target >= length) return length;
    NSInteger ideal = start + target;
    if ([NSUserDefaults.standardUserDefaults boolForKey:KSmartBreak]) {
        NSInteger low = start + MAX(1, (NSInteger)(target * 0.6)), high = MIN(length, start + (NSInteger)ceil(target * 1.3));
        NSInteger best = NSNotFound;
        for (NSInteger p = low; p <= high; p++) {
            if (!IsBreakCharacter([text characterAtIndex:p - 1])) continue;
            // 连续标点（如“。”）”）断在最后一个之后。
            while (p < high && IsBreakCharacter([text characterAtIndex:p])) p++;
            if (best == NSNotFound || labs(p - ideal) < labs(best - ideal)) best = p;
        }
        if (best != NSNotFound) ideal = best;
    }
    if (ideal < length) ideal = [text rangeOfComposedCharacterSequenceAtIndex:ideal].location;  // 不拆开 emoji 等组合字符
    return MAX(start + 1, MIN(ideal, length));
}

// 上一段的起点：从本章开头按同样规则往后切，取最后一个早于 offset 的段首。
// 这样“下一段”再“上一段”一定回到原处。
- (NSInteger)segmentStartBefore:(NSInteger)offset inText:(NSString *)text {
    NSInteger start = 0, previous = 0;
    while (start < offset) { previous = start; start = [self segmentEndInText:text from:start]; }
    return previous;
}

- (NSColor *)currentColor {
    NSString *key = [NSUserDefaults.standardUserDefaults stringForKey:KColor];
    if ([key isEqual:@"gray"]) return NSColor.secondaryLabelColor;
    if ([key isEqual:@"faint"]) return NSColor.tertiaryLabelColor;
    return NSColor.labelColor;
}

- (void)updateUI {
    self.statusItem.visible = YES;
    NSButton *button = self.statusItem.button;
    BOOL hidden = [NSUserDefaults.standardUserDefaults boolForKey:KHidden] || self.autoHidden;
    if (!self.book && !self.library.count) {
        // 第一次使用：直接告诉用户点这里添加书籍。
        button.image = nil; button.font = [NSFont systemFontOfSize:13]; button.title = @"隙读 · 点此添加书籍";
        self.statusItem.length = NSVariableStatusItemLength; button.toolTip = @"点击添加 TXT 或 EPUB";
    } else if (hidden || !self.book) {
        self.statusItem.length=NSSquareStatusItemLength;button.alignment=NSTextAlignmentCenter;
        button.title = @""; button.image = [NSImage imageWithSystemSymbolName:@"book.closed" accessibilityDescription:@"隙读"]; button.toolTip = self.book ? @"隙读：正文已隐藏" : @"隙读：点击选择书籍";
    } else {
        button.image = nil;
        NSFont *font = [NSFont systemFontOfSize:[NSUserDefaults.standardUserDefaults doubleForKey:KFont]];
        // “系统默认”不写死前景色，让菜单栏根据当前前台应用的深浅外观
        // 自动选择黑色或白色；Chrome 等应用会动态改变菜单栏材质。
        NSString *colorKey = [NSUserDefaults.standardUserDefaults stringForKey:KColor] ?: @"label";
        if (![colorKey isEqual:@"gray"] && ![colorKey isEqual:@"faint"]) {  // 旧版的红绿蓝也按系统默认处理
            button.font = font;
            button.contentTintColor = nil;
            button.title = self.currentText;
        } else {
            NSDictionary *attrs = @{NSFontAttributeName:font, NSForegroundColorAttributeName:self.currentColor};
            button.attributedTitle = [[NSAttributedString alloc] initWithString:self.currentText attributes:attrs];
        }
        // 状态项右侧保留 48pt 安静空间。状态项仍锚定在右侧状态区，
        // 因此这段留白会把正文整体向左移动，但不会贴住应用菜单。
        CGFloat textWidth=ceil(button.attributedTitle.size.width);
        self.statusItem.length=textWidth+48.0;button.alignment=NSTextAlignmentLeft;
        button.toolTip = self.book[@"title"] ?: @"点击选择一本书";
    }
}

- (NSMenuItem *)item:(NSString *)title action:(SEL)action {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""]; item.target = self; return item;
}

- (void)rebuildMenu {
    NSMenu *menu = [NSMenu new];
    [menu addItem:[self item:@"添加书籍…" action:@selector(addBooks:)]];
    [menu addItem:[self item:@"打开书架…" action:@selector(openShelf:)]];
    [menu addItem:[self item:@"摘录…" action:@selector(openExcerpts:)]];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self item:@"上一段" action:@selector(previous:)]];
    [menu addItem:[self item:@"下一段" action:@selector(next:)]];
    NSMenuItem *expand=[self item:@"展开阅读…" action:@selector(openExpandedReader:)];expand.enabled=(self.book!=nil);[menu addItem:expand];
    [menu addItem:[self item:[NSUserDefaults.standardUserDefaults boolForKey:KHidden] ? @"显示正文" : @"隐藏正文" action:@selector(toggleText:)]];
    if(self.autoHidden){NSMenuItem *note=[[NSMenuItem alloc]initWithTitle:@"会议软件在前台，正文已自动隐藏" action:nil keyEquivalent:@""];note.enabled=NO;[menu addItem:note];}
    NSMenuItem *chapterRoot = [[NSMenuItem alloc] initWithTitle:@"章节目录" action:nil keyEquivalent:@""];
    NSMenu *chapterMenu = [NSMenu new]; NSArray *chapters = self.book[@"chapters"];
    // 网文常有上千章，菜单里只列当前章前后几章；完整目录在展开阅读窗口里。
    NSInteger first=0,last=(NSInteger)chapters.count-1;
    if(chapters.count>30){first=MAX(0,self.chapter-5);last=MIN((NSInteger)chapters.count-1,first+15);}
    for (NSInteger i=first; i<=last && chapters.count; i++) { NSMenuItem *entry = [self item:chapters[i][@"title"] action:@selector(selectChapter:)]; entry.tag=i; entry.state=(i==self.chapter?NSControlStateValueOn:NSControlStateValueOff); [chapterMenu addItem:entry]; }
    if (!chapterMenu.numberOfItems) [chapterMenu addItemWithTitle:@"请先打开书籍" action:nil keyEquivalent:@""];
    else if (chapters.count>30) {[chapterMenu addItem:NSMenuItem.separatorItem];[chapterMenu addItem:[self item:[NSString stringWithFormat:@"全部目录（共 %lu 章）…",(unsigned long)chapters.count] action:@selector(openExpandedReader:)]];}
    chapterRoot.submenu=chapterMenu; [menu addItem:chapterRoot];
    NSMenuItem *autoRoot=[[NSMenuItem alloc]initWithTitle:@"自动翻页" action:nil keyEquivalent:@""];NSMenu *autoMenu=[NSMenu new];NSInteger interval=[NSUserDefaults.standardUserDefaults integerForKey:KAutoInterval];
    for(NSNumber *seconds in @[@0,@3,@5,@8,@12,@20]){NSMenuItem *e=[self item:seconds.integerValue?[NSString stringWithFormat:@"每 %@ 秒",seconds]:@"关闭" action:@selector(setAutoTurn:)];e.tag=seconds.integerValue;e.state=(interval==e.tag);e.enabled=(self.book!=nil||!e.tag);[autoMenu addItem:e];}
    autoRoot.submenu=autoMenu;if(interval>0)autoRoot.title=[NSString stringWithFormat:@"自动翻页（每 %ld 秒）",(long)interval];[menu addItem:autoRoot];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self settingsItem]];
    if (self.book) {
        NSMenuItem *info=[[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%@ · %@ · 全书 %.0f%%",self.book[@"title"],chapters[self.chapter][@"title"],[self bookPercent]] action:nil keyEquivalent:@""]; info.enabled=NO; [menu addItem:info];
    }
    [menu addItem:NSMenuItem.separatorItem]; [menu addItem:[self item:@"退出隙读" action:@selector(quit:)]];
    // 不把 NSMenu 直接绑定给宽状态项，否则 macOS 会强制菜单至少与正文等宽。
    // 独立弹出后，菜单只按自身内容计算宽度。
    self.popupMenu = menu;
    self.statusItem.menu = nil;
}

// 单击正文翻到下一段；右键、按住 ⌥/⌃ 单击、或正文隐藏时弹出菜单。
- (void)statusItemClicked:(id)sender {
    NSEvent *event=NSApp.currentEvent;
    BOOL wantsMenu=(event.type==NSEventTypeRightMouseUp)||(event.modifierFlags&(NSEventModifierFlagOption|NSEventModifierFlagControl));
    if(!self.book&&!self.library.count&&!wantsMenu){[self addBooks:nil];return;}
    BOOL textVisible=self.book&&![NSUserDefaults.standardUserDefaults boolForKey:KHidden]&&!self.autoHidden;
    if(!wantsMenu&&textVisible&&[NSUserDefaults.standardUserDefaults boolForKey:KClickToTurn]){[self next:nil];return;}
    [self showMenu:sender];
}

- (void)handleStatusScroll:(NSEvent *)event {
    if(!self.book||[NSUserDefaults.standardUserDefaults boolForKey:KHidden]||self.autoHidden)return;
    if(event.momentumPhase!=NSEventPhaseNone)return;  // 触控板惯性滚动不翻页
    if(event.phase==NSEventPhaseBegan)self.statusScrollAccumulator=0;
    // 按用户自己的“自然滚动”设置理解方向：像往下读网页那样滚动就是下一段。
    CGFloat delta=event.scrollingDeltaY;
    self.statusScrollAccumulator+=delta;
    // 滚轮一格翻一段；触控板需滑动一小段距离才翻，避免轻碰连翻。
    CGFloat threshold=event.hasPreciseScrollingDeltas?24.0:0.5;
    if(self.statusScrollAccumulator<=-threshold){self.statusScrollAccumulator=0;[self next:nil];}
    else if(self.statusScrollAccumulator>=threshold){self.statusScrollAccumulator=0;[self previous:nil];}
}

- (void)showMenu:(id)sender {
    // 菜单（含完整章节目录）只在点开时构建，翻页时不再重建。
    [self rebuildMenu];
    NSButton *button = self.statusItem.button;
    // 保持正文原样。inView 为 nil 时，定位点使用屏幕坐标并代表菜单
    // 左上角；横向右对齐状态项，纵向直接使用菜单栏底边。
    NSRect windowRect = [button convertRect:button.bounds toView:nil];
    NSRect screenRect = [button.window convertRectToScreen:windowRect];
    NSSize menuSize = self.popupMenu.size;
    NSPoint origin = NSMakePoint(NSMaxX(screenRect) - menuSize.width,
                                 NSMinY(screenRect) - 2);
    [self.popupMenu popUpMenuPositioningItem:nil atLocation:origin inView:nil];
}

- (NSMenuItem *)settingsItem {
    NSUserDefaults *d=NSUserDefaults.standardUserDefaults; NSMenuItem *root=[[NSMenuItem alloc]initWithTitle:@"设置" action:nil keyEquivalent:@""]; NSMenu *menu=[NSMenu new];
    NSMenuItem *lengthRoot=[[NSMenuItem alloc]initWithTitle:@"显示长度" action:nil keyEquivalent:@""]; NSMenu *lengthMenu=[NSMenu new];
    NSArray *lengths=@[@0,@20,@30,@40]; NSArray *lengthNames=@[@"自动（推荐）",@"20 字",@"30 字",@"40 字"];
    NSInteger savedLength=[d integerForKey:KLength];
    for(NSUInteger i=0;i<lengths.count;i++){NSMenuItem *e=[self item:lengthNames[i] action:@selector(setLength:)];e.tag=[lengths[i]integerValue];e.state=(savedLength==e.tag);[lengthMenu addItem:e];}
    [lengthMenu addItem:NSMenuItem.separatorItem];
    BOOL isCustom=(savedLength>0 && ![lengths containsObject:@(savedLength)]);
    NSString *customTitle=isCustom?[NSString stringWithFormat:@"自定义…（%ld 字）",(long)savedLength]:@"自定义…";
    NSMenuItem *custom=[self item:customTitle action:@selector(setCustomLength:)];custom.state=isCustom;[lengthMenu addItem:custom];
    [lengthMenu addItem:NSMenuItem.separatorItem];NSMenuItem *smart=[self item:@"在标点处断开" action:@selector(toggleSmartBreak:)];smart.state=[d boolForKey:KSmartBreak];[lengthMenu addItem:smart];
    lengthRoot.submenu=lengthMenu;[menu addItem:lengthRoot];
    NSMenuItem *sizeRoot=[[NSMenuItem alloc]initWithTitle:@"字号" action:nil keyEquivalent:@""];NSMenu *sizeMenu=[NSMenu new];
    for(NSNumber *n in @[@11,@12,@13,@14,@15]){NSMenuItem *e=[self item:[NSString stringWithFormat:@"%@ pt",n] action:@selector(setFont:)];e.tag=n.integerValue;e.state=((NSInteger)[d doubleForKey:KFont]==e.tag);[sizeMenu addItem:e];}sizeRoot.submenu=sizeMenu;[menu addItem:sizeRoot];
    // 菜单栏正文越不显眼越好，所以只提供深浅，不再提供红绿蓝。
    NSMenuItem *colorRoot=[[NSMenuItem alloc]initWithTitle:@"文字深浅" action:nil keyEquivalent:@""];NSMenu *colorMenu=[NSMenu new];
    NSArray *names=@[@"系统默认",@"淡一些",@"更淡"],*keys=@[@"label",@"gray",@"faint"];NSString *savedColor=[keys containsObject:[d stringForKey:KColor]]?[d stringForKey:KColor]:@"label";
    for(NSUInteger i=0;i<keys.count;i++){NSMenuItem *e=[self item:names[i] action:@selector(setColor:)];e.representedObject=keys[i];e.state=[savedColor isEqual:keys[i]];[colorMenu addItem:e];}colorRoot.submenu=colorMenu;[menu addItem:colorRoot];[menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *click=[self item:@"单击正文翻到下一段" action:@selector(toggleClickToTurn:)];click.state=[d boolForKey:KClickToTurn];[menu addItem:click];
    NSMenuItem *meeting=[self item:@"会议软件在前台时自动隐藏" action:@selector(toggleMeetingHide:)];meeting.state=[d boolForKey:KMeetingHide];meeting.toolTip=@"Zoom、腾讯会议、Teams、FaceTime、Webex、飞书、钉钉、企业微信";[menu addItem:meeting];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *pause=[self item:@"暂停全部快捷键" action:@selector(toggleShortcutsPaused:)];pause.state=[d boolForKey:KShortcutsPaused];[menu addItem:pause];
    [menu addItem:[self shortcutRoot:@"上一段快捷键" action:0 key:KPrevKey]];[menu addItem:[self shortcutRoot:@"下一段快捷键" action:1 key:KNextKey]];[menu addItem:[self shortcutRoot:@"显示/隐藏快捷键" action:2 key:KToggleKey]];[menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *launch=[self item:@"开机自动启动" action:@selector(toggleLaunch:)];if(@available(macOS 13.0,*))launch.state=(SMAppService.mainAppService.status==SMAppServiceStatusEnabled);[menu addItem:launch];root.submenu=menu;return root;
}

// 预设避开系统和编辑器的常用键：⌥←/→ 是按词移动光标，⌃←/→ 是切换桌面，
// ⌘←/→ 是行首行尾。全局快捷键会让这些键在所有 App 里失效。
- (NSArray<NSDictionary *> *)shortcutOptions:(NSInteger)action {
    if(action==0)return @[@{@"name":@"⌃⌥←",@"code":@(kVK_LeftArrow),@"mods":@(controlKey|optionKey)},@{@"name":@"⌃⌥↑",@"code":@(kVK_UpArrow),@"mods":@(controlKey|optionKey)},@{@"name":@"F13",@"code":@(kVK_F13),@"mods":@0}];
    if(action==1)return @[@{@"name":@"⌃⌥→",@"code":@(kVK_RightArrow),@"mods":@(controlKey|optionKey)},@{@"name":@"⌃⌥↓",@"code":@(kVK_DownArrow),@"mods":@(controlKey|optionKey)},@{@"name":@"F14",@"code":@(kVK_F14),@"mods":@0}];
    return @[@{@"name":@"⌃⌥Space",@"code":@(kVK_Space),@"mods":@(controlKey|optionKey)},@{@"name":@"⌃⌥H",@"code":@(kVK_ANSI_H),@"mods":@(controlKey|optionKey)},@{@"name":@"F15",@"code":@(kVK_F15),@"mods":@0}];
}
- (NSDictionary *)shortcutConfiguration:(NSInteger)action {
    NSArray *keys=@[KPrevKey,KNextKey,KToggleKey];
    id saved=[NSUserDefaults.standardUserDefaults objectForKey:keys[action]];
    if([saved isKindOfClass:NSDictionary.class] && ((saved[@"code"] && saved[@"mods"]) || ([saved[@"type"] isEqual:@"mouse"] && saved[@"button"]))) return saved;
    NSInteger index=[saved respondsToSelector:@selector(integerValue)]?[saved integerValue]:0;
    NSArray *options=[self shortcutOptions:action];
    return options[MAX(0,MIN(index,(NSInteger)options.count-1))];
}
- (NSMenuItem *)shortcutRoot:(NSString *)title action:(NSInteger)action key:(NSString *)key {
    NSMenuItem *root=[[NSMenuItem alloc]initWithTitle:title action:nil keyEquivalent:@""];
    NSMenu *m=[NSMenu new]; NSDictionary *current=[self shortcutConfiguration:action];
    NSString *currentTitle=[@"当前：" stringByAppendingString:current[@"name"]?:@"未设置"];
    if([self.failedHotKeyActions containsIndex:action])currentTitle=[currentTitle stringByAppendingString:@"（未生效，可能被其他程序占用）"];
    NSMenuItem *currentItem=[[NSMenuItem alloc]initWithTitle:currentTitle action:nil keyEquivalent:@""];
    currentItem.enabled=NO; [m addItem:currentItem]; [m addItem:NSMenuItem.separatorItem];
    // 预设直接列在这一层，不再嵌套“常用组合”子菜单。
    NSArray *opts=[self shortcutOptions:action];
    for(NSInteger i=0;i<(NSInteger)opts.count;i++){NSMenuItem *e=[self item:opts[i][@"name"] action:@selector(setShortcut:)];e.tag=action*10+i;e.state=(![current[@"type"]isEqual:@"mouse"]&&[current[@"code"]unsignedIntValue]==[opts[i][@"code"]unsignedIntValue]&&[current[@"mods"]unsignedIntValue]==[opts[i][@"mods"]unsignedIntValue]);[m addItem:e];}
    [m addItem:NSMenuItem.separatorItem];
    NSMenuItem *custom=[self item:@"自定义…（键盘或鼠标侧键）" action:@selector(recordShortcut:)]; custom.tag=action; [m addItem:custom];
    root.submenu=m;return root;
}

- (NSString *)shortcutLabelForEvent:(NSEvent *)event carbonModifiers:(UInt32 *)carbonOut {
    NSEventModifierFlags flags=event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    NSMutableString *label=[NSMutableString string]; UInt32 carbon=0;
    if(flags&NSEventModifierFlagControl){[label appendString:@"⌃"];carbon|=controlKey;}
    if(flags&NSEventModifierFlagOption){[label appendString:@"⌥"];carbon|=optionKey;}
    if(flags&NSEventModifierFlagShift){[label appendString:@"⇧"];carbon|=shiftKey;}
    if(flags&NSEventModifierFlagCommand){[label appendString:@"⌘"];carbon|=cmdKey;}
    NSString *key=nil;
    switch(event.keyCode){case kVK_LeftArrow:key=@"←";break;case kVK_RightArrow:key=@"→";break;case kVK_UpArrow:key=@"↑";break;case kVK_DownArrow:key=@"↓";break;case kVK_PageUp:key=@"Page Up";break;case kVK_PageDown:key=@"Page Down";break;case kVK_Home:key=@"Home";break;case kVK_End:key=@"End";break;case kVK_F13:key=@"F13";break;case kVK_F14:key=@"F14";break;case kVK_F15:key=@"F15";break;case kVK_Space:key=@"Space";break;case kVK_Return:key=@"Return";break;case kVK_Tab:key=@"Tab";break;case kVK_Delete:key=@"Delete";break;default:key=event.charactersIgnoringModifiers.uppercaseString;break;}
    if(carbonOut)*carbonOut=carbon;[label appendString:key?:@"?"];return label;
}

- (void)recordShortcut:(NSMenuItem *)sender {
    NSInteger action=sender.tag;
    // 等菜单追踪循环完全结束后再录制，否则鼠标侧键可能被 NSMenu 吞掉。
    dispatch_async(dispatch_get_main_queue(), ^{ [self beginRecordingShortcutForAction:action]; });
}

- (void)beginRecordingShortcutForAction:(NSInteger)action {
    NSArray *names=@[@"上一段",@"下一段",@"显示/隐藏"];
    NSAlert *alert=[NSAlert new];alert.messageText=[NSString stringWithFormat:@"设置“%@”快捷键",names[action]];alert.informativeText=@"请直接按下新的组合键。快捷键必须包含 ⌘、⌥、⌃ 或 ⇧；按 Esc 取消。";[alert addButtonWithTitle:@"取消"];
    NSTextField *display=[NSTextField labelWithString:@"等待按键…"];display.alignment=NSTextAlignmentCenter;display.font=[NSFont systemFontOfSize:20 weight:NSFontWeightMedium];display.frame=NSMakeRect(0,0,280,38);alert.accessoryView=display;
    __block id monitor=nil; __block id globalMonitor=nil; __block BOOL captured=NO; __weak typeof(self) weakSelf=self;
    [self clearRegisteredShortcuts];
    void (^captureMouse)(NSEvent *)=^(NSEvent *event){
        if(captured || event.buttonNumber<3)return;
        captured=YES; NSArray *keys=@[KPrevKey,KNextKey,KToggleKey];
        NSString *label=[NSString stringWithFormat:@"鼠标侧键 %ld",(long)event.buttonNumber];
        NSDictionary *saved=@{@"name":label,@"type":@"mouse",@"button":@(event.buttonNumber)};
        [NSUserDefaults.standardUserDefaults setObject:saved forKey:keys[action]];
        dispatch_async(dispatch_get_main_queue(), ^{display.stringValue=label;[NSApp abortModal];});
    };
    globalMonitor=[NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskOtherMouseDown handler:^(NSEvent *event){captureMouse(event);}];
    monitor=[NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskKeyDown|NSEventMaskOtherMouseDown) handler:^NSEvent *(NSEvent *event){
        NSArray *keys=@[KPrevKey,KNextKey,KToggleKey]; NSDictionary *saved=nil;
        if(event.type==NSEventTypeOtherMouseDown){
            if(event.buttonNumber<3){display.stringValue=@"请按鼠标侧键";NSBeep();return nil;}
            captureMouse(event);return nil;
        }else{
            if(event.keyCode==kVK_Escape){[NSApp abortModal];return nil;}
            UInt32 carbon=0;NSString *label=[weakSelf shortcutLabelForEvent:event carbonModifiers:&carbon];
            BOOL safeSingleKey=(event.keyCode==kVK_PageUp||event.keyCode==kVK_PageDown||event.keyCode==kVK_Home||event.keyCode==kVK_End||event.keyCode==kVK_F13||event.keyCode==kVK_F14||event.keyCode==kVK_F15);
            if(carbon==0&&!safeSingleKey){display.stringValue=@"普通按键请同时按住修饰键";NSBeep();return nil;}
            saved=@{@"name":label,@"type":@"keyboard",@"code":@(event.keyCode),@"mods":@(carbon)};
        }
        captured=YES;[NSUserDefaults.standardUserDefaults setObject:saved forKey:keys[action]];
        display.stringValue=saved[@"name"];[NSApp abortModal];return nil;
    }];
    [alert runModal]; if(monitor)[NSEvent removeMonitor:monitor];if(globalMonitor)[NSEvent removeMonitor:globalMonitor]; [self registerHotKeys]; [self updateUI];
    if(captured)[self warnIfShortcutFailed:action];
}

- (void)warnIfShortcutFailed:(NSInteger)action {
    if(![self.failedHotKeyActions containsIndex:action])return;
    NSAlert *alert=[NSAlert new];alert.messageText=[NSString stringWithFormat:@"快捷键 %@ 没有生效",[self shortcutConfiguration:action][@"name"]?:@""];
    alert.informativeText=@"这个组合键可能已被系统或其他程序占用，请换一个。";[NSApp activateIgnoringOtherApps:YES];[alert runModal];
}

- (void)addBooks:(id)sender {
    NSOpenPanel *panel=[NSOpenPanel openPanel];panel.title=@"添加电子书到隙读书架";panel.allowedContentTypes=@[[UTType typeWithFilenameExtension:@"txt"],[UTType typeWithFilenameExtension:@"epub"]];panel.allowsMultipleSelection=YES;panel.canChooseDirectories=NO;
    if([panel runModal]!=NSModalResponseOK)return;
    [self importURLs:panel.URLs openFirst:NO];
}

// 导入到托管书库；openFirst 为 NO 时只在当前没有打开书籍时打开第一本。
- (void)importURLs:(NSArray<NSURL *> *)urls openFirst:(BOOL)openFirst {
    NSMutableArray *failures=[NSMutableArray array];NSDictionary *first=nil;
    for(NSURL *url in urls){NSError *error=nil;NSDictionary *entry=[self importBookURL:url error:&error];if(!entry)[failures addObject:error.localizedDescription?:url.lastPathComponent];else if(!first)first=entry;}
    [self.shelfTable reloadData];[self updateUI];
    if(first&&(openFirst||!self.book))[self openURL:[NSURL fileURLWithPath:first[@"path"]] showError:YES];
    if(failures.count){NSAlert *alert=[NSAlert new];alert.messageText=@"部分书籍添加失败";alert.informativeText=[failures componentsJoinedByString:@"\n"];[NSApp activateIgnoringOtherApps:YES];[alert runModal];}
}

- (void)openShelf:(id)sender {
    if(!self.shelfWindow){
        self.shelfWindow=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,620,420) styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable) backing:NSBackingStoreBuffered defer:NO];
        self.shelfWindow.title=@"隙读书架";self.shelfWindow.minSize=NSMakeSize(480,300);self.shelfWindow.releasedWhenClosed=NO;
        NSView *content=self.shelfWindow.contentView;
        NSScrollView *scroll=[[NSScrollView alloc]initWithFrame:NSMakeRect(20,66,content.bounds.size.width-40,content.bounds.size.height-86)];scroll.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;scroll.hasVerticalScroller=YES;scroll.borderType=NSBezelBorder;
        self.shelfTable=[[NSTableView alloc]initWithFrame:scroll.contentView.bounds];self.shelfTable.delegate=self;self.shelfTable.dataSource=self;self.shelfTable.doubleAction=@selector(openSelectedShelfBook:);self.shelfTable.target=self;self.shelfTable.rowHeight=30;self.shelfTable.usesAlternatingRowBackgroundColors=YES;
        NSTableColumn *title=[[NSTableColumn alloc]initWithIdentifier:@"title"];title.title=@"书名";title.width=280;[self.shelfTable addTableColumn:title];
        NSTableColumn *progress=[[NSTableColumn alloc]initWithIdentifier:@"progress"];progress.title=@"阅读进度";progress.width=150;[self.shelfTable addTableColumn:progress];
        NSTableColumn *lastRead=[[NSTableColumn alloc]initWithIdentifier:@"lastRead"];lastRead.title=@"上次阅读";lastRead.width=120;[self.shelfTable addTableColumn:lastRead];
        scroll.documentView=self.shelfTable;[content addSubview:scroll];
        NSButton *add=[NSButton buttonWithTitle:@"添加书籍…" target:self action:@selector(addBooks:)];add.frame=NSMakeRect(20,20,110,30);add.autoresizingMask=NSViewMaxXMargin|NSViewMaxYMargin;[content addSubview:add];
        NSButton *open=[NSButton buttonWithTitle:@"继续阅读" target:self action:@selector(openSelectedShelfBook:)];open.frame=NSMakeRect(content.bounds.size.width-240,20,100,30);open.autoresizingMask=NSViewMinXMargin|NSViewMaxYMargin;[content addSubview:open];
        NSButton *remove=[NSButton buttonWithTitle:@"从书架移除" target:self action:@selector(removeSelectedShelfBook:)];remove.frame=NSMakeRect(content.bounds.size.width-130,20,110,30);remove.autoresizingMask=NSViewMinXMargin|NSViewMaxYMargin;[content addSubview:remove];
        [self.shelfWindow center];
    }
    [self.shelfTable reloadData];[self.shelfWindow makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {return tableView==self.excerptsTable?self.visibleExcerpts.count:self.library.count;}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    if(tableView==self.excerptsTable){if(row<0||row>=(NSInteger)self.visibleExcerpts.count)return @"";NSDictionary *item=self.visibleExcerpts[row];if([column.identifier isEqual:@"excerpt"])return item[@"text"]?:@"";if([column.identifier isEqual:@"book"])return item[@"bookTitle"]?:@"";return item[@"chapterTitle"]?:@"";}
    if(row<0||row>=(NSInteger)self.library.count)return @"";NSDictionary *entry=self.library[row];
    if([column.identifier isEqual:@"title"]){BOOL current=[self.book[@"path"]isEqual:entry[@"path"]];return [NSString stringWithFormat:@"%@%@",current?@"✓ ":@"",entry[@"title"]?:@"未命名"];
    }
    NSDictionary *position=self.positions[entry[@"path"]];
    if([column.identifier isEqual:@"lastRead"]){
        if(!position[@"updatedAt"])return position?@"—":@"";
        static NSDateFormatter *formatter;if(!formatter){formatter=[NSDateFormatter new];formatter.locale=[NSLocale localeWithLocaleIdentifier:@"zh_CN"];formatter.dateStyle=NSDateFormatterShortStyle;formatter.timeStyle=NSDateFormatterShortStyle;formatter.doesRelativeDateFormatting=YES;}
        return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:[position[@"updatedAt"]doubleValue]]];
    }
    if(!position)return @"未开始";
    if([self.book[@"path"]isEqual:entry[@"path"]])return [NSString stringWithFormat:@"全书 %.0f%%",[self bookPercent]];
    if(position[@"percent"])return [NSString stringWithFormat:@"全书 %.0f%%",[position[@"percent"]doubleValue]];
    return [NSString stringWithFormat:@"第 %ld 章",(long)[position[@"chapter"]integerValue]+1];
}

- (void)openSelectedShelfBook:(id)sender {NSInteger row=self.shelfTable.selectedRow;if(row<0||row>=(NSInteger)self.library.count)return;NSDictionary *entry=self.library[row];if([self openURL:[NSURL fileURLWithPath:entry[@"path"]]showError:YES]){[self.shelfTable reloadData];}}

- (void)removeSelectedShelfBook:(id)sender {
    NSInteger row=self.shelfTable.selectedRow;if(row<0||row>=(NSInteger)self.library.count)return;NSDictionary *entry=self.library[row];
    NSAlert *alert=[NSAlert new];alert.messageText=[NSString stringWithFormat:@"从书架移除《%@》？",entry[@"title"]];alert.informativeText=@"会删除隙读保存的书库副本、阅读进度和全部划线，但不会删除你原来导入的文件。";[alert addButtonWithTitle:@"移除"];[alert addButtonWithTitle:@"取消"];if([alert runModal]!=NSAlertFirstButtonReturn)return;
    NSString *path=entry[@"path"];NSURL *cacheURL=[self cacheURLForBookURL:[NSURL fileURLWithPath:path]];if(cacheURL)[NSFileManager.defaultManager removeItemAtURL:cacheURL error:nil];[NSFileManager.defaultManager removeItemAtPath:path error:nil];[self.library removeObjectAtIndex:row];[self.positions removeObjectForKey:path];[self.underlines removeObjectForKey:path];[self saveLibrary];[self savePositions];[self saveUnderlines];
    if([self.book[@"path"]isEqual:path]){[self.readerWindow close];self.book=nil;self.chapter=0;self.offset=0;[NSUserDefaults.standardUserDefaults removeObjectForKey:KBook];}
    [self.shelfTable reloadData];[self updateUI];
}

- (void)saveUnderlines {[self writeStore:self.underlines named:@"underlines.json"];}

- (void)reloadVisibleExcerpts {
    NSString *filter=self.excerptsBookFilter.selectedItem.representedObject;NSMutableArray *rows=[NSMutableArray array];
    for(NSDictionary *bookEntry in self.library){NSString *path=bookEntry[@"path"];if(filter.length&&![filter isEqual:path])continue;NSArray *items=self.underlines[path]?:@[];for(NSDictionary *underline in items){NSMutableDictionary *row=[underline mutableCopy];row[@"path"]=path;row[@"bookTitle"]=bookEntry[@"title"]?:@"未命名";NSInteger chapter=[underline[@"chapter"]integerValue];NSString *chapterTitle=[NSString stringWithFormat:@"第 %ld 章",(long)chapter+1];if([self.book[@"path"]isEqual:path]){NSArray *chapters=self.book[@"chapters"];if(chapter>=0&&chapter<(NSInteger)chapters.count)chapterTitle=chapters[chapter][@"title"]?:chapterTitle;}row[@"chapterTitle"]=chapterTitle;[rows addObject:row];}}
    self.visibleExcerpts=rows;[self.excerptsTable reloadData];
}

- (void)openExcerpts:(id)sender {
    if(!self.excerptsWindow){
        self.excerptsWindow=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,760,460) styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable) backing:NSBackingStoreBuffered defer:NO];self.excerptsWindow.title=@"摘录";self.excerptsWindow.minSize=NSMakeSize(560,320);self.excerptsWindow.releasedWhenClosed=NO;NSView *content=self.excerptsWindow.contentView;
        self.excerptsBookFilter=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(20,content.bounds.size.height-48,260,28)];self.excerptsBookFilter.autoresizingMask=NSViewMinYMargin;self.excerptsBookFilter.target=self;self.excerptsBookFilter.action=@selector(excerptsFilterChanged:);[content addSubview:self.excerptsBookFilter];
        NSScrollView *scroll=[[NSScrollView alloc]initWithFrame:NSMakeRect(20,66,content.bounds.size.width-40,content.bounds.size.height-124)];scroll.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;scroll.hasVerticalScroller=YES;scroll.borderType=NSBezelBorder;
        self.excerptsTable=[[NSTableView alloc]initWithFrame:scroll.contentView.bounds];self.excerptsTable.delegate=self;self.excerptsTable.dataSource=self;self.excerptsTable.target=self;self.excerptsTable.doubleAction=@selector(openSelectedExcerpt:);self.excerptsTable.rowHeight=34;self.excerptsTable.usesAlternatingRowBackgroundColors=YES;
        NSTableColumn *excerpt=[[NSTableColumn alloc]initWithIdentifier:@"excerpt"];excerpt.title=@"摘录内容";excerpt.width=390;[self.excerptsTable addTableColumn:excerpt];NSTableColumn *book=[[NSTableColumn alloc]initWithIdentifier:@"book"];book.title=@"书籍";book.width=170;[self.excerptsTable addTableColumn:book];NSTableColumn *chapter=[[NSTableColumn alloc]initWithIdentifier:@"chapter"];chapter.title=@"章节";chapter.width=150;[self.excerptsTable addTableColumn:chapter];scroll.documentView=self.excerptsTable;[content addSubview:scroll];
        NSButton *open=[NSButton buttonWithTitle:@"打开摘录" target:self action:@selector(openSelectedExcerpt:)];open.frame=NSMakeRect(content.bounds.size.width-240,20,100,30);open.autoresizingMask=NSViewMinXMargin|NSViewMaxYMargin;[content addSubview:open];NSButton *remove=[NSButton buttonWithTitle:@"删除划线" target:self action:@selector(deleteSelectedExcerpt:)];remove.frame=NSMakeRect(content.bounds.size.width-130,20,110,30);remove.autoresizingMask=NSViewMinXMargin|NSViewMaxYMargin;[content addSubview:remove];
        NSButton *copyAll=[NSButton buttonWithTitle:@"全部拷贝" target:self action:@selector(copyAllExcerpts:)];copyAll.frame=NSMakeRect(20,20,100,30);copyAll.autoresizingMask=NSViewMaxXMargin|NSViewMaxYMargin;[content addSubview:copyAll];
        NSButton *export=[NSButton buttonWithTitle:@"导出 Markdown…" target:self action:@selector(exportExcerpts:)];export.frame=NSMakeRect(126,20,140,30);export.autoresizingMask=NSViewMaxXMargin|NSViewMaxYMargin;[content addSubview:export];
        [self.excerptsWindow center];
    }
    [self.excerptsBookFilter removeAllItems];[self.excerptsBookFilter addItemWithTitle:@"全部书籍"];self.excerptsBookFilter.lastItem.representedObject=@"";for(NSDictionary *entry in self.library){[self.excerptsBookFilter addItemWithTitle:entry[@"title"]?:@"未命名"];self.excerptsBookFilter.lastItem.representedObject=entry[@"path"]?:@"";}[self reloadVisibleExcerpts];[self.excerptsWindow makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
}

- (void)excerptsFilterChanged:(id)sender {[self reloadVisibleExcerpts];}

// 按书名、章节分组的 Markdown；只包含当前筛选出的摘录。
- (NSString *)excerptsMarkdown {
    NSMutableString *md=[NSMutableString stringWithString:@"# 隙读摘录\n"];NSString *lastBook=nil,*lastChapter=nil;
    for(NSDictionary *item in self.visibleExcerpts){
        if(![item[@"bookTitle"]isEqual:lastBook]){[md appendFormat:@"\n## %@\n",item[@"bookTitle"]];lastBook=item[@"bookTitle"];lastChapter=nil;}
        if(![item[@"chapterTitle"]isEqual:lastChapter]){[md appendFormat:@"\n### %@\n",item[@"chapterTitle"]];lastChapter=item[@"chapterTitle"];}
        [md appendFormat:@"\n> %@\n",item[@"text"]?:@""];
    }
    return md;
}
- (void)copyAllExcerpts:(id)sender {
    if(!self.visibleExcerpts.count){NSBeep();return;}
    [NSPasteboard.generalPasteboard clearContents];[NSPasteboard.generalPasteboard setString:[self excerptsMarkdown] forType:NSPasteboardTypeString];
}
- (void)exportExcerpts:(id)sender {
    if(!self.visibleExcerpts.count){NSBeep();return;}
    NSSavePanel *panel=[NSSavePanel savePanel];panel.nameFieldStringValue=@"隙读摘录.md";panel.allowedContentTypes=@[[UTType typeWithFilenameExtension:@"md"]?:UTTypePlainText];
    [panel beginSheetModalForWindow:self.excerptsWindow completionHandler:^(NSModalResponse result){
        if(result!=NSModalResponseOK)return;NSError *error=nil;
        if(![[self excerptsMarkdown] writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&error]){NSAlert *a=[NSAlert alertWithError:error];[a runModal];}
    }];
}
- (void)openSelectedExcerpt:(id)sender {NSInteger row=self.excerptsTable.selectedRow;if(row<0||row>=(NSInteger)self.visibleExcerpts.count)return;NSDictionary *item=self.visibleExcerpts[row];NSString *path=item[@"path"];if(![self.book[@"path"]isEqual:path]&&![self openURL:[NSURL fileURLWithPath:path]showError:YES])return;[self openExpandedReader:nil];self.readerBrowseChapter=[item[@"chapter"]integerValue];[self refreshReaderWindow];NSRange range=NSMakeRange([item[@"location"]unsignedIntegerValue],[item[@"length"]unsignedIntegerValue]);dispatch_async(dispatch_get_main_queue(),^{[self.readerTextView scrollRangeToVisible:range];});}
- (void)deleteSelectedExcerpt:(id)sender {NSInteger row=self.excerptsTable.selectedRow;if(row<0||row>=(NSInteger)self.visibleExcerpts.count)return;NSDictionary *item=self.visibleExcerpts[row];NSMutableArray *items=self.underlines[item[@"path"]];NSIndexSet *indexes=[items indexesOfObjectsPassingTest:^BOOL(NSDictionary *candidate,NSUInteger idx,BOOL *stop){return [candidate[@"chapter"]isEqual:item[@"chapter"]]&&[candidate[@"location"]isEqual:item[@"location"]]&&[candidate[@"length"]isEqual:item[@"length"]];}];[items removeObjectsAtIndexes:indexes];[self saveUnderlines];[self reloadVisibleExcerpts];[self applyReaderHighlights];}

- (void)openExpandedReader:(id)sender {
    if(!self.book)return;
    if(!self.readerWindow){
        NSRect frame=NSMakeRect(0,0,760,680);
        self.readerWindow=[[NSWindow alloc]initWithContentRect:frame styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable) backing:NSBackingStoreBuffered defer:NO];
        self.readerWindow.delegate=self;self.readerWindow.title=@"隙读";self.readerWindow.minSize=NSMakeSize(480,360);self.readerWindow.releasedWhenClosed=NO;
        NSView *content=self.readerWindow.contentView;
        self.readerChapterPopup=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(18,content.bounds.size.height-48,content.bounds.size.width-36-66,30) pullsDown:NO];
        self.readerStyleButton=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(content.bounds.size.width-18-58,content.bounds.size.height-48,58,30) pullsDown:YES];
        self.readerStyleButton.autoresizingMask=NSViewMinXMargin|NSViewMinYMargin;self.readerStyleButton.toolTip=@"字号、行距与背景";[content addSubview:self.readerStyleButton];
        self.readerChapterPopup.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;self.readerChapterPopup.target=self;self.readerChapterPopup.action=@selector(readerChapterChanged:);[content addSubview:self.readerChapterPopup];
        self.readerSearchBar=[[NSView alloc]initWithFrame:NSMakeRect(18,content.bounds.size.height-88,content.bounds.size.width-36,34)];self.readerSearchBar.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;self.readerSearchBar.hidden=YES;
        self.readerSearchScope=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(0,2,112,28)];[self.readerSearchScope addItemsWithTitles:@[@"当前章节",@"整本书"]];self.readerSearchScope.target=self;self.readerSearchScope.action=@selector(readerSearchScopeChanged:);[self.readerSearchBar addSubview:self.readerSearchScope];
        self.readerSearchField=[[NSSearchField alloc]initWithFrame:NSMakeRect(120,2,250,28)];self.readerSearchField.placeholderString=@"查找";self.readerSearchField.delegate=self;self.readerSearchField.target=self;self.readerSearchField.action=@selector(readerSearchSubmit:);self.readerSearchField.autoresizingMask=NSViewWidthSizable;[self.readerSearchBar addSubview:self.readerSearchField];
        self.readerSearchCount=[NSTextField labelWithString:@"0 / 0"];self.readerSearchCount.frame=NSMakeRect(content.bounds.size.width-305,7,80,20);self.readerSearchCount.alignment=NSTextAlignmentCenter;self.readerSearchCount.autoresizingMask=NSViewMinXMargin;[self.readerSearchBar addSubview:self.readerSearchCount];
        NSButton *previous=[NSButton buttonWithTitle:@"‹" target:self action:@selector(readerSearchPrevious:)];previous.frame=NSMakeRect(content.bounds.size.width-220,2,38,28);previous.autoresizingMask=NSViewMinXMargin;[self.readerSearchBar addSubview:previous];
        NSButton *next=[NSButton buttonWithTitle:@"›" target:self action:@selector(readerSearchNext:)];next.frame=NSMakeRect(content.bounds.size.width-178,2,38,28);next.autoresizingMask=NSViewMinXMargin;[self.readerSearchBar addSubview:next];
        NSButton *close=[NSButton buttonWithTitle:@"完成" target:self action:@selector(closeReaderSearch:)];close.frame=NSMakeRect(content.bounds.size.width-134,2,98,28);close.autoresizingMask=NSViewMinXMargin;[self.readerSearchBar addSubview:close];[content addSubview:self.readerSearchBar];
        self.readerScrollView=[[NSScrollView alloc]initWithFrame:NSMakeRect(18,18,content.bounds.size.width-36,content.bounds.size.height-78)];
        self.readerScrollView.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;self.readerScrollView.hasVerticalScroller=YES;self.readerScrollView.borderType=NSBezelBorder;self.readerScrollView.drawsBackground=YES;
        self.readerTextView=[[ReaderTextView alloc]initWithFrame:self.readerScrollView.contentView.bounds];self.readerTextView.readerOwner=self;self.readerTextView.editable=NO;self.readerTextView.selectable=YES;self.readerTextView.richText=YES;self.readerTextView.importsGraphics=NO;self.readerTextView.verticallyResizable=YES;self.readerTextView.horizontallyResizable=NO;self.readerTextView.autoresizingMask=NSViewWidthSizable;self.readerTextView.minSize=NSMakeSize(0,self.readerScrollView.contentView.bounds.size.height);self.readerTextView.maxSize=NSMakeSize(CGFLOAT_MAX,CGFLOAT_MAX);self.readerTextView.textContainer.widthTracksTextView=YES;self.readerTextView.textContainer.heightTracksTextView=NO;self.readerTextView.textContainer.containerSize=NSMakeSize(self.readerScrollView.contentView.bounds.size.width,CGFLOAT_MAX);self.readerTextView.textContainerInset=NSMakeSize(22,24);self.readerTextView.font=[NSFont systemFontOfSize:18];self.readerTextView.textColor=NSColor.labelColor;self.readerTextView.backgroundColor=NSColor.textBackgroundColor;
        self.readerScrollView.documentView=self.readerTextView;[content addSubview:self.readerScrollView];[self.readerWindow center];
        [self rebuildReaderStyleMenu];[self applyReaderTheme];
        __weak typeof(self) weakSelf=self;self.readerKeyMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event){
            if(!weakSelf.readerWindow.isKeyWindow)return event;
            NSEventModifierFlags flags=event.modifierFlags&NSEventModifierFlagDeviceIndependentFlagsMask;
            if((flags&NSEventModifierFlagCommand)&&[[event.charactersIgnoringModifiers lowercaseString]isEqual:@"f"]){[weakSelf toggleReaderSearch:nil];return nil;}
            if(flags&NSEventModifierFlagCommand){
                NSString *key=event.charactersIgnoringModifiers;
                if([key isEqual:@"="]||[key isEqual:@"+"]){[weakSelf adjustReaderFont:2];return nil;}
                if([key isEqual:@"-"]){[weakSelf adjustReaderFont:-2];return nil;}
            }
            if(event.keyCode==kVK_Escape&&!weakSelf.readerSearchBar.hidden){[weakSelf closeReaderSearch:nil];return nil;}return event;
        }];
    }
    self.readerBrowseChapter=self.chapter;
    [self refreshReaderWindow];[self.readerWindow makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
}

- (void)refreshReaderWindow {
    if(!self.readerWindow||!self.book)return;
    NSArray *chapters=self.book[@"chapters"];if(!chapters.count)return;
    self.updatingReader=YES;
    // 只有换书或换章时才重建目录和正文；同一章内翻页只移动高亮，避免整章重新排版。
    BOOL bookChanged=![self.readerLoadedBookPath isEqual:self.book[@"path"]];
    if(bookChanged){
        // 直接往 menu 里加项：addItemWithTitle: 会合并同名章节，导致序号错位。
        [self.readerChapterPopup removeAllItems];
        for(NSDictionary *chapter in chapters)[self.readerChapterPopup.menu addItemWithTitle:chapter[@"title"]?:@"" action:nil keyEquivalent:@""];
        self.readerLoadedBookPath=self.book[@"path"];self.readerLoadedChapter=-1;
    }
    self.readerBrowseChapter=MAX(0,MIN(self.readerBrowseChapter,(NSInteger)chapters.count-1));[self.readerChapterPopup selectItemAtIndex:self.readerBrowseChapter];
    self.readerWindow.title=[NSString stringWithFormat:@"%@ — %@",self.book[@"title"],chapters[self.readerBrowseChapter][@"title"]];
    if(self.readerLoadedChapter!=self.readerBrowseChapter){
        self.readerTextView.string=chapters[self.readerBrowseChapter][@"text"]?:@"";self.readerLoadedChapter=self.readerBrowseChapter;
        [self applyReaderHighlights];
        [self.readerTextView.layoutManager ensureLayoutForTextContainer:self.readerTextView.textContainer];
    } else [self applyTemporaryHighlights];
    NSInteger target=(self.readerBrowseChapter==self.chapter)?MAX(0,MIN(self.offset,(NSInteger)self.readerTextView.string.length)):0;
    dispatch_async(dispatch_get_main_queue(), ^{[self scrollReaderToCharacter:target];self.updatingReader=NO;});
}

// 状态栏位置变化后，让展开阅读窗口跟到当前段落；窗口没打开时不做任何排版。
- (void)readerFollowPosition {
    self.readerBrowseChapter=self.chapter;
    if(self.readerWindow.isVisible)[self refreshReaderWindow];
}

- (void)scrollReaderToCharacter:(NSInteger)character {
    NSUInteger length=self.readerTextView.string.length;if(!length){[self.readerScrollView.contentView scrollToPoint:NSZeroPoint];return;}
    NSUInteger target=MIN((NSUInteger)MAX(0,character),length-1);
    [self.readerTextView.layoutManager ensureLayoutForTextContainer:self.readerTextView.textContainer];
    NSRange glyphRange=[self.readerTextView.layoutManager glyphRangeForCharacterRange:NSMakeRange(target,1) actualCharacterRange:NULL];
    NSRect glyphRect=[self.readerTextView.layoutManager boundingRectForGlyphRange:glyphRange inTextContainer:self.readerTextView.textContainer];
    CGFloat y=MAX(0.0,NSMinY(glyphRect)+self.readerTextView.textContainerOrigin.y-8.0);
    NSClipView *clip=self.readerScrollView.contentView;[clip scrollToPoint:NSMakePoint(clip.bounds.origin.x,y)];[self.readerScrollView reflectScrolledClipView:clip];
    self.readerTextView.selectedRange=NSMakeRange(target,0);
}

- (void)readerChapterChanged:(NSPopUpButton *)sender {
    NSInteger selectedChapter=sender.indexOfSelectedItem;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.readerBrowseChapter=selectedChapter;
        if(self.readerSearchBar.hidden){self.chapter=selectedChapter;self.offset=0;[self savePosition];[self updateUI];}
        [self refreshReaderWindow];
        if(!self.readerSearchBar.hidden&&self.readerSearchField.stringValue.length&&self.readerSearchScope.indexOfSelectedItem==0)[self performReaderSearch];
    });
}

- (void)windowWillClose:(NSNotification *)notification {if(notification.object==self.readerWindow){[self closeReaderSearch:nil];[self updateUI];}}

- (void)applicationWillTerminate:(NSNotification *)notification {[self flushPositions];[NSUserDefaults.standardUserDefaults synchronize];}

// 字体和划线写进 textStorage（会触发重新排版，只在换章或改划线时调用）；
// 当前段落和搜索结果用临时属性，翻页时只重绘，不重新排版。
- (void)applyReaderHighlights {
    if(!self.readerTextView)return;NSTextStorage *storage=self.readerTextView.textStorage;NSRange all=NSMakeRange(0,storage.length);
    NSMutableParagraphStyle *paragraph=[NSMutableParagraphStyle new];paragraph.lineHeightMultiple=[NSUserDefaults.standardUserDefaults doubleForKey:KReaderSpacing]?:1.3;
    [storage beginEditing];[storage setAttributes:@{NSFontAttributeName:[self readerFont],NSForegroundColorAttributeName:[self readerTextColor],NSParagraphStyleAttributeName:paragraph} range:all];
    for(NSDictionary *underline in self.underlines[self.book[@"path"]]?:@[]){if([underline[@"chapter"]integerValue]!=self.readerBrowseChapter)continue;NSRange range=NSMakeRange([underline[@"location"]unsignedIntegerValue],[underline[@"length"]unsignedIntegerValue]);if(NSMaxRange(range)>storage.length)continue;[storage addAttribute:NSUnderlineStyleAttributeName value:@(NSUnderlineStyleSingle|NSUnderlinePatternSolid) range:range];[storage addAttribute:NSUnderlineColorAttributeName value:NSColor.systemBlueColor range:range];}
    [storage endEditing];
    [self applyTemporaryHighlights];
}

- (NSFont *)readerFont {return [NSFont systemFontOfSize:MAX(12,MIN(36,[NSUserDefaults.standardUserDefaults doubleForKey:KReaderFont]))];}
- (BOOL)readerSepia {return [[NSUserDefaults.standardUserDefaults stringForKey:KReaderTheme]isEqual:@"sepia"];}
- (NSColor *)readerTextColor {return self.readerSepia?[NSColor colorWithSRGBRed:0.36 green:0.27 blue:0.20 alpha:1]:NSColor.labelColor;}

- (void)applyReaderTheme {
    NSColor *background=self.readerSepia?[NSColor colorWithSRGBRed:0.96 green:0.93 blue:0.85 alpha:1]:NSColor.textBackgroundColor;
    self.readerTextView.backgroundColor=background;self.readerScrollView.backgroundColor=background;
}

- (void)rebuildReaderStyleMenu {
    NSMenu *menu=self.readerStyleButton.menu;[menu removeAllItems];NSUserDefaults *d=NSUserDefaults.standardUserDefaults;
    [menu addItemWithTitle:@"Aa" action:nil keyEquivalent:@""];  // 下拉按钮的第一项是按钮标题
    NSMenuItem *bigger=[self item:@"放大字号（⌘+）" action:@selector(readerFontMenu:)];bigger.tag=2;[menu addItem:bigger];
    NSMenuItem *smaller=[self item:@"缩小字号（⌘-）" action:@selector(readerFontMenu:)];smaller.tag=-2;[menu addItem:smaller];
    [menu addItem:NSMenuItem.separatorItem];
    NSArray *spacings=@[@1.0,@1.3,@1.6],*spacingNames=@[@"行距：紧凑",@"行距：适中",@"行距：宽松"];
    for(NSUInteger i=0;i<spacings.count;i++){NSMenuItem *e=[self item:spacingNames[i] action:@selector(setReaderSpacing:)];e.representedObject=spacings[i];e.state=fabs([d doubleForKey:KReaderSpacing]-[spacings[i]doubleValue])<0.01;[menu addItem:e];}
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *system=[self item:@"背景：跟随系统" action:@selector(setReaderTheme:)];system.representedObject=@"system";system.state=!self.readerSepia;[menu addItem:system];
    NSMenuItem *sepia=[self item:@"背景：米黄护眼" action:@selector(setReaderTheme:)];sepia.representedObject=@"sepia";sepia.state=self.readerSepia;[menu addItem:sepia];
}

// 改样式会重新排版；记下窗口顶部正在看的字，排版后滚回原处。
- (void)readerStyleChanged {
    NSLayoutManager *layout=self.readerTextView.layoutManager;NSRect visible=self.readerScrollView.contentView.bounds;visible.origin.y-=self.readerTextView.textContainerOrigin.y;
    NSRange glyphs=[layout glyphRangeForBoundingRect:visible inTextContainer:self.readerTextView.textContainer];
    NSUInteger topCharacter=glyphs.length?[layout characterIndexForGlyphAtIndex:glyphs.location]:0;NSRange selection=self.readerTextView.selectedRange;
    [self rebuildReaderStyleMenu];[self applyReaderTheme];[self applyReaderHighlights];
    [self scrollReaderToCharacter:topCharacter];self.readerTextView.selectedRange=selection;
}
- (void)adjustReaderFont:(CGFloat)delta {
    NSUserDefaults *d=NSUserDefaults.standardUserDefaults;CGFloat size=MAX(12,MIN(36,[d doubleForKey:KReaderFont]+delta));
    if(size==[d doubleForKey:KReaderFont]){NSBeep();return;}
    [d setDouble:size forKey:KReaderFont];[self readerStyleChanged];
}
- (void)readerFontMenu:(NSMenuItem *)sender {[self adjustReaderFont:sender.tag];}
- (void)setReaderSpacing:(NSMenuItem *)sender {[NSUserDefaults.standardUserDefaults setDouble:[sender.representedObject doubleValue] forKey:KReaderSpacing];[self readerStyleChanged];}
- (void)setReaderTheme:(NSMenuItem *)sender {[NSUserDefaults.standardUserDefaults setObject:sender.representedObject forKey:KReaderTheme];[self readerStyleChanged];}

- (void)applyTemporaryHighlights {
    if(!self.readerTextView)return;NSLayoutManager *layout=self.readerTextView.layoutManager;NSUInteger length=self.readerTextView.textStorage.length;
    [layout removeTemporaryAttribute:NSBackgroundColorAttributeName forCharacterRange:NSMakeRange(0,length)];
    if(self.readerBrowseChapter==self.chapter&&length){NSInteger start=MAX(0,MIN(self.offset,(NSInteger)length));NSInteger count=[self segmentEndInText:self.readerTextView.string from:start]-start;if(start<(NSInteger)length&&count>0)[layout addTemporaryAttribute:NSBackgroundColorAttributeName value:[NSColor colorWithRed:0.72 green:0.91 blue:0.76 alpha:0.72] forCharacterRange:NSMakeRange(start,count)];}
    for(NSInteger i=0;i<(NSInteger)self.readerSearchMatches.count;i++){NSDictionary *match=self.readerSearchMatches[i];if([match[@"chapter"]integerValue]!=self.readerBrowseChapter)continue;NSRange range=NSMakeRange([match[@"location"]unsignedIntegerValue],[match[@"length"]unsignedIntegerValue]);if(NSMaxRange(range)>length)continue;NSColor *color=(i==self.readerSearchIndex)?[NSColor colorWithRed:1.0 green:0.64 blue:0.20 alpha:0.82]:[NSColor colorWithRed:1.0 green:0.91 blue:0.42 alpha:0.65];[layout addTemporaryAttribute:NSBackgroundColorAttributeName value:color forCharacterRange:range];}
}

- (NSDictionary *)underlineAtContext {
    NSInteger index=self.readerTextView.contextCharacterIndex;for(NSDictionary *item in self.underlines[self.book[@"path"]]?:@[]){if([item[@"chapter"]integerValue]!=self.readerBrowseChapter)continue;NSRange range=NSMakeRange([item[@"location"]unsignedIntegerValue],[item[@"length"]unsignedIntegerValue]);if(NSLocationInRange(index,range))return item;}return nil;
}
- (NSString *)underlineMenuTitle {return [self underlineAtContext]?@"取消划线":@"添加划线";}
- (BOOL)canToggleUnderline {if([self underlineAtContext])return YES;NSRange selection=self.readerTextView.selectedRange;if(!selection.length)return NO;for(NSDictionary *item in self.underlines[self.book[@"path"]]?:@[]){if([item[@"chapter"]integerValue]!=self.readerBrowseChapter)continue;NSRange existing=NSMakeRange([item[@"location"]unsignedIntegerValue],[item[@"length"]unsignedIntegerValue]);if(NSIntersectionRange(selection,existing).length)return NO;}return YES;}
- (void)toggleUnderline:(id)sender {
    NSString *path=self.book[@"path"];if(!path)return;NSMutableArray *items=self.underlines[path];if(!items){items=[NSMutableArray array];self.underlines[path]=items;}NSDictionary *existing=[self underlineAtContext];
    if(existing)[items removeObject:existing];else{NSRange selection=self.readerTextView.selectedRange;if(!selection.length||![self canToggleUnderline])return;NSString *text=[self.readerTextView.string substringWithRange:selection];[items addObject:[@{@"chapter":@(self.readerBrowseChapter),@"location":@(selection.location),@"length":@(selection.length),@"text":text,@"createdAt":@([NSDate.date timeIntervalSince1970])}mutableCopy]];[items sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){NSInteger ac=[a[@"chapter"]integerValue],bc=[b[@"chapter"]integerValue];if(ac!=bc)return ac<bc?NSOrderedAscending:NSOrderedDescending;return [a[@"location"]compare:b[@"location"]];}];}
    [self saveUnderlines];[self applyReaderHighlights];[self reloadVisibleExcerpts];
}

- (NSArray<NSDictionary *> *)searchMatchesForText:(NSString *)text chapter:(NSInteger)chapter query:(NSString *)query {
    NSMutableArray<NSNumber *> *map=[NSMutableArray array];NSString *normalized=SearchNormalizedText(text,map);if(!query.length||!normalized.length)return @[];
    NSMutableArray *matches=[NSMutableArray array];NSRange remaining=NSMakeRange(0,normalized.length);
    while(remaining.length){NSRange found=[normalized rangeOfString:query options:0 range:remaining];if(found.location==NSNotFound)break;NSUInteger start=[map[found.location]unsignedIntegerValue];NSUInteger after=NSMaxRange(found);NSUInteger end=(after<map.count)?[map[after]unsignedIntegerValue]:text.length;if(end<=start)end=MIN(text.length,start+1);[matches addObject:@{@"chapter":@(chapter),@"location":@(start),@"length":@(end-start)}];NSUInteger next=NSMaxRange(found);if(next>=normalized.length)break;remaining=NSMakeRange(next,normalized.length-next);}
    return matches;
}

- (void)performReaderSearch {
    NSString *query=SearchNormalizedText(self.readerSearchField.stringValue?:@"",nil);NSMutableArray *all=[NSMutableArray array];NSArray *chapters=self.book[@"chapters"];
    if(query.length){if(self.readerSearchScope.indexOfSelectedItem==0){NSString *text=chapters[self.readerBrowseChapter][@"text"]?:@"";[all addObjectsFromArray:[self searchMatchesForText:text chapter:self.readerBrowseChapter query:query]];}else{for(NSInteger chapter=0;chapter<(NSInteger)chapters.count;chapter++){NSString *text=chapters[chapter][@"text"]?:@"";[all addObjectsFromArray:[self searchMatchesForText:text chapter:chapter query:query]];}}}
    self.readerSearchMatches=all;self.readerSearchIndex=all.count?0:-1;self.readerSearchCount.stringValue=all.count?[NSString stringWithFormat:@"1 / %ld",(long)all.count]:@"0 / 0";if(all.count)[self showCurrentReaderSearchMatch];else[self applyTemporaryHighlights];
}

- (void)showCurrentReaderSearchMatch {
    if(self.readerSearchIndex<0||self.readerSearchIndex>=(NSInteger)self.readerSearchMatches.count)return;NSDictionary *match=self.readerSearchMatches[self.readerSearchIndex];NSInteger chapter=[match[@"chapter"]integerValue];BOOL chapterChanged=(chapter!=self.readerBrowseChapter);self.readerBrowseChapter=chapter;
    if(chapterChanged)[self refreshReaderWindow];else [self applyTemporaryHighlights];
    NSRange range=NSMakeRange([match[@"location"]unsignedIntegerValue],[match[@"length"]unsignedIntegerValue]);dispatch_async(dispatch_get_main_queue(),^{[self.readerTextView scrollRangeToVisible:range];});self.readerSearchCount.stringValue=[NSString stringWithFormat:@"%ld / %ld",(long)self.readerSearchIndex+1,(long)self.readerSearchMatches.count];
}

- (void)toggleReaderSearch:(id)sender {if(self.readerSearchBar.hidden)[self openReaderSearch:sender];else[self closeReaderSearch:sender];}
- (void)openReaderSearch:(id)sender {self.readerSearchBar.hidden=NO;NSView *content=self.readerWindow.contentView;self.readerScrollView.frame=NSMakeRect(18,18,content.bounds.size.width-36,content.bounds.size.height-118);[self.readerWindow makeFirstResponder:self.readerSearchField];[self.readerSearchField selectText:nil];}
- (void)closeReaderSearch:(id)sender {if(!self.readerSearchBar)return;self.readerSearchBar.hidden=YES;self.readerSearchField.stringValue=@"";self.readerSearchMatches=@[];self.readerSearchIndex=-1;self.readerSearchCount.stringValue=@"0 / 0";NSView *content=self.readerWindow.contentView;self.readerScrollView.frame=NSMakeRect(18,18,content.bounds.size.width-36,content.bounds.size.height-78);[self applyTemporaryHighlights];}
- (void)controlTextDidChange:(NSNotification *)notification {if(notification.object==self.readerSearchField)[self performReaderSearch];}
- (void)readerSearchScopeChanged:(id)sender {[self performReaderSearch];}
- (void)readerSearchSubmit:(id)sender {if(NSApp.currentEvent.modifierFlags&NSEventModifierFlagShift)[self readerSearchPrevious:sender];else[self readerSearchNext:sender];}
- (void)readerSearchNext:(id)sender {if(!self.readerSearchMatches.count)return;self.readerSearchIndex=(self.readerSearchIndex+1)%self.readerSearchMatches.count;[self showCurrentReaderSearchMatch];}
- (void)readerSearchPrevious:(id)sender {if(!self.readerSearchMatches.count)return;self.readerSearchIndex=(self.readerSearchIndex-1+(NSInteger)self.readerSearchMatches.count)%self.readerSearchMatches.count;[self showCurrentReaderSearchMatch];}

- (void)continueReadingHere:(id)sender {
    NSInteger target=self.readerTextView.contextCharacterIndex;NSInteger maximum=MAX(0,(NSInteger)self.readerTextView.string.length-1);target=MAX(0,MIN(target,maximum));self.chapter=self.readerBrowseChapter;self.offset=target;self.readerTextView.selectedRange=NSMakeRange(target,0);
    [self savePosition];
    [self applyTemporaryHighlights];[self updateUI];
}

- (BOOL)openURL:(NSURL *)url showError:(BOOL)showError {
    NSError *error=nil;NSArray *chapters=nil;
    chapters=[self chaptersForURL:url error:&error];
    if(!chapters.count){if(showError){NSAlert *a=[NSAlert new];a.messageText=@"无法打开这本书";a.informativeText=error.localizedDescription?:@"没有找到可读取的正文";[a runModal];}return NO;}
    [self savePosition];NSDictionary *libraryEntry=[self libraryEntryForPath:url.path];NSString *displayTitle=libraryEntry[@"title"]?:url.URLByDeletingPathExtension.lastPathComponent;self.book=@{@"path":url.path,@"title":displayTitle,@"chapters":chapters};NSMutableArray *starts=[NSMutableArray array];NSInteger total=0;for(NSDictionary *c in chapters){[starts addObject:@(total)];total+=[c[@"text"]length];}self.chapterStarts=starts;self.bookLength=total;NSDictionary *pos=self.positions[url.path];self.chapter=[pos[@"chapter"]integerValue];self.offset=[pos[@"offset"]integerValue];
    [NSUserDefaults.standardUserDefaults setObject:url.path forKey:KBook];[self readerFollowPosition];[self updateUI];return YES;
}
// 解析结果缓存在 Application Support/隙读/Cache，按解析版本、文件大小和修改时间校验。
// EPUB 解析要解压并经过 HTML 排版引擎，缓存后再次打开和启动都不必重复。
- (NSURL *)cacheURLForBookURL:(NSURL *)url {
    if(![url.URLByDeletingLastPathComponent.path isEqual:[self libraryDirectory].path])return nil;
    NSURL *directory=[[self supportDirectory]URLByAppendingPathComponent:@"Cache" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    return [directory URLByAppendingPathComponent:[url.lastPathComponent stringByAppendingString:@".plist"]];
}

- (NSArray<NSDictionary *> *)chaptersForURL:(NSURL *)url error:(NSError **)outError {
    NSDictionary *attrs=[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    NSNumber *size=attrs[NSFileSize]?:@0;NSNumber *modified=@([attrs[NSFileModificationDate] timeIntervalSince1970]);
    NSURL *cacheURL=[self cacheURLForBookURL:url];
    NSDictionary *cached=cacheURL?[NSDictionary dictionaryWithContentsOfURL:cacheURL]:nil;
    if([cached[@"version"] integerValue]==KParserVersion&&[cached[@"size"] isEqual:size]&&[cached[@"modified"] isEqual:modified]&&[cached[@"chapters"] count])return cached[@"chapters"];
    NSArray *chapters=nil;
    if([url.pathExtension.lowercaseString isEqual:@"epub"])chapters=ParseEPUB(url,outError);else{NSString *text=DecodeTextFile(url,outError);if(text)chapters=ParseTXT(text);}
    if(chapters.count&&cacheURL){
        NSData *data=[NSPropertyListSerialization dataWithPropertyList:@{@"version":@(KParserVersion),@"size":size,@"modified":modified,@"chapters":chapters} format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        [data writeToURL:cacheURL atomically:YES];
    }
    return chapters;
}

- (double)bookPercent {
    if(self.bookLength<=0||self.chapter>=(NSInteger)self.chapterStarts.count)return 0;
    return MIN(100.0,100.0*([self.chapterStarts[self.chapter]integerValue]+self.offset)/self.bookLength);
}
// 进度里同时记下全书百分比和时间，书架不用打开每本书就能显示。
- (void)savePosition {NSString *path=self.book[@"path"];if(!path)return;self.positions[path]=@{@"chapter":@(self.chapter),@"offset":@(self.offset),@"percent":@([self bookPercent]),@"updatedAt":@([NSDate.date timeIntervalSince1970])};[self savePositions];}
- (void)previous:(id)sender {
    NSArray *cs=self.book[@"chapters"];if(!cs.count)return;
    if(self.offset>0)self.offset=[self segmentStartBefore:self.offset inText:cs[self.chapter][@"text"]];
    else if(self.chapter>0){self.chapter--;NSString *text=cs[self.chapter][@"text"];self.offset=[self segmentStartBefore:text.length inText:text];}
    [self pageTurned];
}
- (void)next:(id)sender {
    NSArray *cs=self.book[@"chapters"];if(!cs.count)return;
    NSString *text=cs[self.chapter][@"text"];NSInteger end=[self segmentEndInText:text from:self.offset];
    if(end<(NSInteger)text.length)self.offset=end;
    else if(self.chapter+1<(NSInteger)cs.count){self.chapter++;self.offset=0;}
    else{[self stopAutoTurn];return;}  // 已经读到全书最后一段
    [self pageTurned];
}

- (void)pageTurned {
    [self savePosition];[self readerFollowPosition];[self updateUI];
    if(self.autoTurnTimer)self.autoTurnTimer.fireDate=[NSDate dateWithTimeIntervalSinceNow:self.autoTurnTimer.timeInterval];  // 手动翻页后重新计时
}
- (void)toggleText:(id)sender {NSUserDefaults *d=NSUserDefaults.standardUserDefaults;[d setBool:![d boolForKey:KHidden] forKey:KHidden];[self updateUI];}
- (void)selectChapter:(NSMenuItem *)sender {self.chapter=sender.tag;self.offset=0;[self savePosition];[self readerFollowPosition];[self updateUI];}
- (void)setLength:(NSMenuItem *)s {[NSUserDefaults.standardUserDefaults setInteger:s.tag forKey:KLength];[self applyTemporaryHighlights];[self updateUI];}
- (void)setCustomLength:(id)sender {
    NSAlert *alert=[NSAlert new];alert.messageText=@"自定义显示字数";alert.informativeText=@"请输入每段显示的字数（5–200）：";
    NSTextField *input=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,220,26)];NSInteger current=[NSUserDefaults.standardUserDefaults integerForKey:KLength];input.stringValue=current>0?[NSString stringWithFormat:@"%ld",(long)current]:@"30";input.placeholderString=@"例如：35";alert.accessoryView=input;
    [alert addButtonWithTitle:@"确定"];[alert addButtonWithTitle:@"取消"];
    [alert.window setInitialFirstResponder:input];
    if([alert runModal]!=NSAlertFirstButtonReturn)return;
    NSInteger value=input.integerValue;
    if(value<5||value>200){NSAlert *warning=[NSAlert new];warning.messageText=@"请输入 5–200 之间的字数";[warning runModal];return;}
    [NSUserDefaults.standardUserDefaults setInteger:value forKey:KLength];[self applyTemporaryHighlights];[self updateUI];
}
- (void)setFont:(NSMenuItem *)s {[NSUserDefaults.standardUserDefaults setDouble:s.tag forKey:KFont];[self updateUI];}
- (void)setColor:(NSMenuItem *)s {[NSUserDefaults.standardUserDefaults setObject:s.representedObject forKey:KColor];[self updateUI];}
- (void)setShortcut:(NSMenuItem *)s {NSInteger action=s.tag/10,index=s.tag%10;NSArray *keys=@[KPrevKey,KNextKey,KToggleKey];NSMutableDictionary *option=[[self shortcutOptions:action][index]mutableCopy];option[@"type"]=@"keyboard";[NSUserDefaults.standardUserDefaults setObject:option forKey:keys[action]];[self registerHotKeys];[self updateUI];[self warnIfShortcutFailed:action];}
- (void)clearRegisteredShortcuts {
    for(NSValue *v in self.hotKeyRefs){EventHotKeyRef ref=(EventHotKeyRef)v.pointerValue;if(ref)UnregisterEventHotKey(ref);}[self.hotKeyRefs removeAllObjects];
    if(self.globalMouseMonitor){[NSEvent removeMonitor:self.globalMouseMonitor];self.globalMouseMonitor=nil;}
    if(self.localMouseMonitor){[NSEvent removeMonitor:self.localMouseMonitor];self.localMouseMonitor=nil;}
}
- (void)handleMouseEvent:(NSEvent *)event {
    for(NSInteger action=0;action<3;action++){NSDictionary *config=[self shortcutConfiguration:action];if([config[@"type"]isEqual:@"mouse"]&&[config[@"button"]integerValue]==event.buttonNumber){[self handleHotKey:(UInt32)action+1];break;}}
}
- (void)registerHotKeys {
    [self clearRegisteredShortcuts];
    self.failedHotKeyActions=[NSMutableIndexSet indexSet];
    if([NSUserDefaults.standardUserDefaults boolForKey:KShortcutsPaused])return;
    BOOL hasMouseShortcut=NO;
    for(NSInteger a=0;a<3;a++){NSDictionary *opt=[self shortcutConfiguration:a];if([opt[@"type"]isEqual:@"mouse"]){hasMouseShortcut=YES;continue;}EventHotKeyRef ref=NULL;EventHotKeyID ident={'XIDU',(UInt32)a+1};OSStatus status=RegisterEventHotKey([opt[@"code"]unsignedIntValue],[opt[@"mods"]unsignedIntValue],ident,GetApplicationEventTarget(),0,&ref);if(status==noErr&&ref)[self.hotKeyRefs addObject:[NSValue valueWithPointer:ref]];else[self.failedHotKeyActions addIndex:a];}
    if(hasMouseShortcut){__weak typeof(self) weakSelf=self;self.globalMouseMonitor=[NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskOtherMouseDown handler:^(NSEvent *event){[weakSelf handleMouseEvent:event];}];self.localMouseMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskOtherMouseDown handler:^NSEvent *(NSEvent *event){[weakSelf handleMouseEvent:event];return event;}];}
}
- (void)handleHotKey:(UInt32)i {dispatch_async(dispatch_get_main_queue(),^{if(i==1)[self previous:nil];else if(i==2)[self next:nil];else if(i==3)[self toggleText:nil];});}
- (void)toggleLaunch:(id)sender API_AVAILABLE(macos(13.0)){NSError *error=nil;if(SMAppService.mainAppService.status==SMAppServiceStatusEnabled)[SMAppService.mainAppService unregisterAndReturnError:&error];else[SMAppService.mainAppService registerAndReturnError:&error];if(error){NSAlert*a=[NSAlert new];a.messageText=@"无法修改开机启动";a.informativeText=error.localizedDescription;[a runModal];}[self updateUI];}
// 自动翻页：每隔 N 秒翻到下一段。正文隐藏（含会议自动隐藏）、锁屏或屏幕休眠时跳过。
- (void)restartAutoTurn {
    [self.autoTurnTimer invalidate];self.autoTurnTimer=nil;
    NSInteger seconds=[NSUserDefaults.standardUserDefaults integerForKey:KAutoInterval];if(seconds<=0)return;
    __weak typeof(self) weakSelf=self;
    self.autoTurnTimer=[NSTimer scheduledTimerWithTimeInterval:seconds repeats:YES block:^(NSTimer *timer){
        typeof(self) strongSelf=weakSelf;if(!strongSelf.book||strongSelf.screenLocked||strongSelf.autoHidden||[NSUserDefaults.standardUserDefaults boolForKey:KHidden])return;
        [strongSelf next:nil];
    }];
}
- (void)stopAutoTurn {
    if(!self.autoTurnTimer)return;
    [NSUserDefaults.standardUserDefaults setInteger:0 forKey:KAutoInterval];[self restartAutoTurn];
}
- (void)setAutoTurn:(NSMenuItem *)sender {[NSUserDefaults.standardUserDefaults setInteger:sender.tag forKey:KAutoInterval];[self restartAutoTurn];}
- (void)toggleMeetingHide:(id)sender {NSUserDefaults *d=NSUserDefaults.standardUserDefaults;[d setBool:![d boolForKey:KMeetingHide] forKey:KMeetingHide];[self updateMeetingHide];[self updateUI];}
- (void)toggleClickToTurn:(id)sender {NSUserDefaults *d=NSUserDefaults.standardUserDefaults;[d setBool:![d boolForKey:KClickToTurn] forKey:KClickToTurn];}
- (void)toggleSmartBreak:(id)sender {NSUserDefaults *d=NSUserDefaults.standardUserDefaults;[d setBool:![d boolForKey:KSmartBreak] forKey:KSmartBreak];[self applyTemporaryHighlights];[self updateUI];}

- (void)toggleShortcutsPaused:(id)sender {
    NSUserDefaults *d=NSUserDefaults.standardUserDefaults;[d setBool:![d boolForKey:KShortcutsPaused] forKey:KShortcutsPaused];[self registerHotKeys];
}
- (void)quit:(id)sender {[NSApp terminate:nil];}
@end

static OSStatus HotKeyHandler(EventHandlerCallRef next, EventRef event, void *data){EventHotKeyID ident={0};GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(ident),NULL,&ident);AppDelegate *delegate=(__bridge AppDelegate *)data;[delegate handleHotKey:ident.id];return noErr;}

int main(int argc,const char *argv[]){@autoreleasepool{NSApplication *app=NSApplication.sharedApplication;AppDelegate *delegate=[AppDelegate new];app.delegate=delegate;[app setActivationPolicy:NSApplicationActivationPolicyAccessory];[app run];}return 0;}
