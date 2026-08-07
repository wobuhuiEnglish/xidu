#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <ServiceManagement/ServiceManagement.h>

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
    NSRegularExpression *chapterRE = [NSRegularExpression regularExpressionWithPattern:@"第[0-9零一二三四五六七八九十百千万两]+[章回卷部篇].{0,40}$" options:0 error:nil];
    NSMutableArray *chapters = [NSMutableArray array];
    __block NSMutableArray *body = [NSMutableArray array];
    __block NSString *title = @"正文";
    void (^appendChapter)(void) = ^{
        NSString *joined = CleanText([body componentsJoinedByString:@" "]);
        if (joined.length) [chapters addObject:@{@"title": title, @"text": joined}];
    };
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSTextCheckingResult *heading = [chapterRE firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (heading) {
            appendChapter();
            title = [[line substringWithRange:heading.range] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            body = [NSMutableArray array];
        } else if ([line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) {
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

typedef struct { __unsafe_unretained NSString *label; UInt32 keyCode; UInt32 modifiers; } Shortcut;
@class AppDelegate;
static OSStatus HotKeyHandler(EventHandlerCallRef next, EventRef event, void *data);

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate>
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
@property NSTextView *readerTextView;
@property NSPopUpButton *readerChapterPopup;
@property BOOL updatingReader;
@property NSMutableArray<NSMutableDictionary *> *library;
@property NSWindow *shelfWindow;
@property NSTableView *shelfTable;
- (void)handleHotKey:(UInt32)identifier;
- (NSDictionary *)importBookURL:(NSURL *)source error:(NSError **)outError;
- (void)saveLibrary;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d registerDefaults:@{KHidden:@NO, KLength:@0, KFont:@13, KColor:@"label", KPrevKey:@0, KNextKey:@0, KToggleKey:@0}];
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(showMenu:);
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(frontApplicationChanged:) name:NSWorkspaceDidActivateApplicationNotification object:nil];
    self.positions = [[d dictionaryForKey:KPositions] mutableCopy] ?: [NSMutableDictionary dictionary];
    self.library = [NSMutableArray array];
    for (NSDictionary *entry in [d arrayForKey:KLibrary] ?: @[]) [self.library addObject:[entry mutableCopy]];
    // 将旧版本保存的外部文件自动复制进托管书库，并迁移阅读进度。
    NSMutableArray *legacyPaths=[NSMutableArray arrayWithArray:[d stringArrayForKey:KRecent]?:@[]];
    NSString *legacyCurrent=[d stringForKey:KBook];if(legacyCurrent.length&&![legacyPaths containsObject:legacyCurrent])[legacyPaths insertObject:legacyCurrent atIndex:0];
    for(NSString *legacyPath in legacyPaths){
        if(![NSFileManager.defaultManager fileExistsAtPath:legacyPath])continue;
        BOOL managed=NO;for(NSDictionary *entry in self.library)if([entry[@"path"]isEqual:legacyPath]){managed=YES;break;}
        if(managed)continue;
        NSDictionary *entry=[self importBookURL:[NSURL fileURLWithPath:legacyPath] error:nil];
        if(entry){NSDictionary *oldPosition=self.positions[legacyPath];if(oldPosition)self.positions[entry[@"path"]]=oldPosition;if([legacyCurrent isEqual:legacyPath])[d setObject:entry[@"path"] forKey:KBook];}
    }
    [d setObject:self.positions forKey:KPositions];[self saveLibrary];
    self.hotKeyRefs = [NSMutableArray array];
    EventTypeSpec type = {kEventClassKeyboard, kEventHotKeyPressed};
    InstallApplicationEventHandler(&HotKeyHandler, 1, &type, (__bridge void *)self, NULL);
    NSString *path = [d stringForKey:KBook];
    if (path.length && [NSFileManager.defaultManager fileExistsAtPath:path]) [self openURL:[NSURL fileURLWithPath:path] showError:NO];
    [self registerHotKeys]; [self updateUI];
}

- (NSURL *)libraryDirectory {
    NSURL *support=[NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    NSURL *directory=[[support URLByAppendingPathComponent:@"隙读" isDirectory:YES] URLByAppendingPathComponent:@"Books" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];return directory;
}

- (void)saveLibrary {[NSUserDefaults.standardUserDefaults setObject:self.library forKey:KLibrary];}

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
    if (requested <= 0) requested = MAX(24, MIN(46, (NSInteger)(width / 42.0)));
    // Chrome 的应用菜单明显更宽。标题过长时 macOS 不是截断，而是把
    // 整个 NSStatusItem 从当前菜单栏布局移除，因此必须在切换前台应用时
    // 主动降低状态项的实际长度。
    NSString *bundleID = NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier ?: @"";
    if ([bundleID isEqualToString:@"com.google.Chrome"] || [bundleID hasPrefix:@"com.google.Chrome."]) requested = MIN(requested, 30);
    return requested;
}

- (void)frontApplicationChanged:(NSNotification *)notification {
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
    NSInteger count = MIN(self.segmentLength, (NSInteger)text.length - self.offset);
    return [text substringWithRange:NSMakeRange(self.offset, count)];
}

- (NSColor *)currentColor {
    NSString *key = [NSUserDefaults.standardUserDefaults stringForKey:KColor];
    if ([key isEqual:@"red"]) return NSColor.systemRedColor;
    if ([key isEqual:@"blue"]) return NSColor.systemBlueColor;
    if ([key isEqual:@"green"]) return NSColor.systemGreenColor;
    if ([key isEqual:@"gray"]) return NSColor.secondaryLabelColor;
    return NSColor.labelColor;
}

- (void)updateUI {
    self.statusItem.visible = YES;
    NSButton *button = self.statusItem.button;
    BOOL hidden = [NSUserDefaults.standardUserDefaults boolForKey:KHidden];
    if (hidden || !self.book) {
        button.title = @""; button.image = [NSImage imageWithSystemSymbolName:@"book.closed" accessibilityDescription:@"隙读"]; button.toolTip = self.book ? @"隙读：正文已隐藏" : @"隙读：点击选择书籍";
    } else {
        button.image = nil;
        NSFont *font = [NSFont systemFontOfSize:[NSUserDefaults.standardUserDefaults doubleForKey:KFont]];
        // “系统默认”不写死前景色，让菜单栏根据当前前台应用的深浅外观
        // 自动选择黑色或白色；Chrome 等应用会动态改变菜单栏材质。
        NSString *colorKey = [NSUserDefaults.standardUserDefaults stringForKey:KColor] ?: @"label";
        if ([colorKey isEqualToString:@"label"]) {
            button.font = font;
            button.contentTintColor = nil;
            button.title = self.currentText;
        } else {
            NSDictionary *attrs = @{NSFontAttributeName:font, NSForegroundColorAttributeName:self.currentColor};
            button.attributedTitle = [[NSAttributedString alloc] initWithString:self.currentText attributes:attrs];
        }
        button.toolTip = self.book[@"title"] ?: @"点击选择一本书";
    }
    [self rebuildMenu];
}

- (NSMenuItem *)item:(NSString *)title action:(SEL)action {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""]; item.target = self; return item;
}

- (void)rebuildMenu {
    NSMenu *menu = [NSMenu new];
    [menu addItem:[self item:@"添加书籍…" action:@selector(addBooks:)]];
    [menu addItem:[self item:@"打开书架…" action:@selector(openShelf:)]];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self item:@"上一段" action:@selector(previous:)]];
    [menu addItem:[self item:@"下一段" action:@selector(next:)]];
    NSMenuItem *expand=[self item:@"展开阅读…" action:@selector(openExpandedReader:)];expand.enabled=(self.book!=nil);[menu addItem:expand];
    [menu addItem:[self item:[NSUserDefaults.standardUserDefaults boolForKey:KHidden] ? @"显示正文" : @"隐藏正文" action:@selector(toggleText:)]];
    NSMenuItem *chapterRoot = [[NSMenuItem alloc] initWithTitle:@"章节目录" action:nil keyEquivalent:@""];
    NSMenu *chapterMenu = [NSMenu new]; NSArray *chapters = self.book[@"chapters"];
    for (NSInteger i=0; i<(NSInteger)chapters.count; i++) { NSMenuItem *entry = [self item:chapters[i][@"title"] action:@selector(selectChapter:)]; entry.tag=i; entry.state=(i==self.chapter?NSControlStateValueOn:NSControlStateValueOff); [chapterMenu addItem:entry]; }
    if (!chapterMenu.numberOfItems) [chapterMenu addItemWithTitle:@"请先打开书籍" action:nil keyEquivalent:@""];
    chapterRoot.submenu=chapterMenu; [menu addItem:chapterRoot];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self settingsItem]];
    if (self.book) {
        NSString *text=chapters[self.chapter][@"text"]; NSInteger progress=text.length?(NSInteger)(100.0*self.offset/text.length):0;
        NSMenuItem *info=[[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%@ · %@ · %ld%%",self.book[@"title"],chapters[self.chapter][@"title"],(long)progress] action:nil keyEquivalent:@""]; info.enabled=NO; [menu addItem:info];
    }
    [menu addItem:NSMenuItem.separatorItem]; [menu addItem:[self item:@"退出隙读" action:@selector(quit:)]];
    // 不把 NSMenu 直接绑定给宽状态项，否则 macOS 会强制菜单至少与正文等宽。
    // 独立弹出后，菜单只按自身内容计算宽度。
    self.popupMenu = menu;
    self.statusItem.menu = nil;
}

- (void)showMenu:(id)sender {
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
    lengthRoot.submenu=lengthMenu;[menu addItem:lengthRoot];
    NSMenuItem *sizeRoot=[[NSMenuItem alloc]initWithTitle:@"字号" action:nil keyEquivalent:@""];NSMenu *sizeMenu=[NSMenu new];
    for(NSNumber *n in @[@11,@12,@13,@14,@15]){NSMenuItem *e=[self item:[NSString stringWithFormat:@"%@ pt",n] action:@selector(setFont:)];e.tag=n.integerValue;e.state=((NSInteger)[d doubleForKey:KFont]==e.tag);[sizeMenu addItem:e];}sizeRoot.submenu=sizeMenu;[menu addItem:sizeRoot];
    NSMenuItem *colorRoot=[[NSMenuItem alloc]initWithTitle:@"文字颜色" action:nil keyEquivalent:@""];NSMenu *colorMenu=[NSMenu new];
    NSArray *names=@[@"系统默认",@"灰色",@"蓝色",@"绿色",@"红色"],*keys=@[@"label",@"gray",@"blue",@"green",@"red"];
    for(NSUInteger i=0;i<keys.count;i++){NSMenuItem *e=[self item:names[i] action:@selector(setColor:)];e.representedObject=keys[i];e.state=[[d stringForKey:KColor]isEqual:keys[i]];[colorMenu addItem:e];}colorRoot.submenu=colorMenu;[menu addItem:colorRoot];[menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self shortcutRoot:@"上一段快捷键" action:0 key:KPrevKey]];[menu addItem:[self shortcutRoot:@"下一段快捷键" action:1 key:KNextKey]];[menu addItem:[self shortcutRoot:@"显示/隐藏快捷键" action:2 key:KToggleKey]];[menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *launch=[self item:@"开机自动启动" action:@selector(toggleLaunch:)];if(@available(macOS 13.0,*))launch.state=(SMAppService.mainAppService.status==SMAppServiceStatusEnabled);[menu addItem:launch];root.submenu=menu;return root;
}

- (NSArray<NSDictionary *> *)shortcutOptions:(NSInteger)action {
    if(action==0)return @[@{@"name":@"⌥←",@"code":@(kVK_LeftArrow),@"mods":@(optionKey)},@{@"name":@"⌃←",@"code":@(kVK_LeftArrow),@"mods":@(controlKey)},@{@"name":@"⌘←",@"code":@(kVK_LeftArrow),@"mods":@(cmdKey)}];
    if(action==1)return @[@{@"name":@"⌥→",@"code":@(kVK_RightArrow),@"mods":@(optionKey)},@{@"name":@"⌃→",@"code":@(kVK_RightArrow),@"mods":@(controlKey)},@{@"name":@"⌘→",@"code":@(kVK_RightArrow),@"mods":@(cmdKey)}];
    return @[@{@"name":@"⌥Space",@"code":@(kVK_Space),@"mods":@(optionKey)},@{@"name":@"⌃Space",@"code":@(kVK_Space),@"mods":@(controlKey)},@{@"name":@"⌘⇧H",@"code":@(kVK_ANSI_H),@"mods":@(cmdKey|shiftKey)}];
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
    NSMenuItem *currentItem=[[NSMenuItem alloc]initWithTitle:[@"当前：" stringByAppendingString:current[@"name"]?:@"未设置"] action:nil keyEquivalent:@""];
    currentItem.enabled=NO; [m addItem:currentItem]; [m addItem:NSMenuItem.separatorItem];
    NSMenuItem *custom=[self item:@"自定义…" action:@selector(recordShortcut:)]; custom.tag=action; [m addItem:custom];
    NSMenuItem *presets=[[NSMenuItem alloc]initWithTitle:@"常用组合" action:nil keyEquivalent:@""]; NSMenu *presetMenu=[NSMenu new]; NSArray *opts=[self shortcutOptions:action];
    for(NSInteger i=0;i<(NSInteger)opts.count;i++){NSMenuItem *e=[self item:opts[i][@"name"] action:@selector(setShortcut:)];e.tag=action*10+i;e.state=([current[@"code"]unsignedIntValue]==[opts[i][@"code"]unsignedIntValue]&&[current[@"mods"]unsignedIntValue]==[opts[i][@"mods"]unsignedIntValue]);[presetMenu addItem:e];}
    presets.submenu=presetMenu;[m addItem:presets];root.submenu=m;return root;
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
        [NSUserDefaults.standardUserDefaults setObject:saved forKey:keys[action]];
        display.stringValue=saved[@"name"];[NSApp abortModal];return nil;
    }];
    [alert runModal]; if(monitor)[NSEvent removeMonitor:monitor];if(globalMonitor)[NSEvent removeMonitor:globalMonitor]; [self registerHotKeys]; [self updateUI];
}

- (void)selectBook:(id)sender {[self addBooks:sender];}

- (void)addBooks:(id)sender {
    NSOpenPanel *panel=[NSOpenPanel openPanel];panel.title=@"添加电子书到隙读书架";panel.allowedFileTypes=@[@"txt",@"epub"];panel.allowsMultipleSelection=YES;panel.canChooseDirectories=NO;
    if([panel runModal]!=NSModalResponseOK)return;
    NSMutableArray *failures=[NSMutableArray array];NSDictionary *first=nil;
    for(NSURL *url in panel.URLs){NSError *error=nil;NSDictionary *entry=[self importBookURL:url error:&error];if(!entry)[failures addObject:error.localizedDescription?:url.lastPathComponent];else if(!first)first=entry;}
    [self.shelfTable reloadData];[self updateUI];
    if(first&&!self.book)[self openURL:[NSURL fileURLWithPath:first[@"path"]] showError:YES];
    if(failures.count){NSAlert *alert=[NSAlert new];alert.messageText=@"部分书籍添加失败";alert.informativeText=[failures componentsJoinedByString:@"\n"];[alert runModal];}
}

- (void)openShelf:(id)sender {
    if(!self.shelfWindow){
        self.shelfWindow=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,620,420) styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable) backing:NSBackingStoreBuffered defer:NO];
        self.shelfWindow.title=@"隙读书架";self.shelfWindow.minSize=NSMakeSize(480,300);self.shelfWindow.releasedWhenClosed=NO;
        NSView *content=self.shelfWindow.contentView;
        NSScrollView *scroll=[[NSScrollView alloc]initWithFrame:NSMakeRect(20,66,content.bounds.size.width-40,content.bounds.size.height-86)];scroll.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;scroll.hasVerticalScroller=YES;scroll.borderType=NSBezelBorder;
        self.shelfTable=[[NSTableView alloc]initWithFrame:scroll.contentView.bounds];self.shelfTable.delegate=self;self.shelfTable.dataSource=self;self.shelfTable.doubleAction=@selector(openSelectedShelfBook:);self.shelfTable.target=self;self.shelfTable.rowHeight=30;self.shelfTable.usesAlternatingRowBackgroundColors=YES;
        NSTableColumn *title=[[NSTableColumn alloc]initWithIdentifier:@"title"];title.title=@"书名";title.width=350;[self.shelfTable addTableColumn:title];
        NSTableColumn *progress=[[NSTableColumn alloc]initWithIdentifier:@"progress"];progress.title=@"阅读进度";progress.width=190;[self.shelfTable addTableColumn:progress];
        scroll.documentView=self.shelfTable;[content addSubview:scroll];
        NSButton *add=[NSButton buttonWithTitle:@"添加书籍…" target:self action:@selector(addBooks:)];add.frame=NSMakeRect(20,20,110,30);add.autoresizingMask=NSViewMaxXMargin|NSViewMaxYMargin;[content addSubview:add];
        NSButton *open=[NSButton buttonWithTitle:@"继续阅读" target:self action:@selector(openSelectedShelfBook:)];open.frame=NSMakeRect(content.bounds.size.width-240,20,100,30);open.autoresizingMask=NSViewMinXMargin|NSViewMaxYMargin;[content addSubview:open];
        NSButton *remove=[NSButton buttonWithTitle:@"从书架移除" target:self action:@selector(removeSelectedShelfBook:)];remove.frame=NSMakeRect(content.bounds.size.width-130,20,110,30);remove.autoresizingMask=NSViewMinXMargin|NSViewMaxYMargin;[content addSubview:remove];
        [self.shelfWindow center];
    }
    [self.shelfTable reloadData];[self.shelfWindow makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {return self.library.count;}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    if(row<0||row>=(NSInteger)self.library.count)return @"";NSDictionary *entry=self.library[row];
    if([column.identifier isEqual:@"title"]){BOOL current=[self.book[@"path"]isEqual:entry[@"path"]];return [NSString stringWithFormat:@"%@%@",current?@"✓ ":@"",entry[@"title"]?:@"未命名"];
    }
    NSDictionary *position=self.positions[entry[@"path"]];if(!position)return @"未开始";
    if([self.book[@"path"]isEqual:entry[@"path"]]){NSArray *chapters=self.book[@"chapters"];NSInteger chapter=MAX(0,MIN([position[@"chapter"]integerValue],(NSInteger)chapters.count-1));NSString *text=chapters.count?chapters[chapter][@"text"]:@"";NSInteger percent=text.length?(NSInteger)(100.0*[position[@"offset"]integerValue]/text.length):0;return [NSString stringWithFormat:@"%@ · %ld%%",chapters.count?chapters[chapter][@"title"]:@"正文",(long)percent];}
    return [NSString stringWithFormat:@"第 %ld 章",(long)[position[@"chapter"]integerValue]+1];
}

- (void)openSelectedShelfBook:(id)sender {NSInteger row=self.shelfTable.selectedRow;if(row<0||row>=(NSInteger)self.library.count)return;NSDictionary *entry=self.library[row];if([self openURL:[NSURL fileURLWithPath:entry[@"path"]]showError:YES]){[self.shelfTable reloadData];}}

- (void)removeSelectedShelfBook:(id)sender {
    NSInteger row=self.shelfTable.selectedRow;if(row<0||row>=(NSInteger)self.library.count)return;NSDictionary *entry=self.library[row];
    NSAlert *alert=[NSAlert new];alert.messageText=[NSString stringWithFormat:@"从书架移除《%@》？",entry[@"title"]];alert.informativeText=@"会删除隙读保存的书库副本和阅读进度，但不会删除你原来导入的文件。";[alert addButtonWithTitle:@"移除"];[alert addButtonWithTitle:@"取消"];if([alert runModal]!=NSAlertFirstButtonReturn)return;
    NSString *path=entry[@"path"];[NSFileManager.defaultManager removeItemAtPath:path error:nil];[self.library removeObjectAtIndex:row];[self.positions removeObjectForKey:path];[self saveLibrary];[NSUserDefaults.standardUserDefaults setObject:self.positions forKey:KPositions];
    if([self.book[@"path"]isEqual:path]){[self.readerWindow close];self.book=nil;self.chapter=0;self.offset=0;[NSUserDefaults.standardUserDefaults removeObjectForKey:KBook];}
    [self.shelfTable reloadData];[self updateUI];
}

- (void)openExpandedReader:(id)sender {
    if(!self.book)return;
    if(!self.readerWindow){
        NSRect frame=NSMakeRect(0,0,760,680);
        self.readerWindow=[[NSWindow alloc]initWithContentRect:frame styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable) backing:NSBackingStoreBuffered defer:NO];
        self.readerWindow.delegate=self;self.readerWindow.title=@"隙读";self.readerWindow.minSize=NSMakeSize(480,360);self.readerWindow.releasedWhenClosed=NO;
        NSView *content=self.readerWindow.contentView;
        self.readerChapterPopup=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(18,content.bounds.size.height-48,content.bounds.size.width-36,30) pullsDown:NO];
        self.readerChapterPopup.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;self.readerChapterPopup.target=self;self.readerChapterPopup.action=@selector(readerChapterChanged:);[content addSubview:self.readerChapterPopup];
        NSScrollView *scroll=[[NSScrollView alloc]initWithFrame:NSMakeRect(18,18,content.bounds.size.width-36,content.bounds.size.height-78)];
        scroll.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;scroll.hasVerticalScroller=YES;scroll.borderType=NSBezelBorder;scroll.drawsBackground=YES;
        self.readerTextView=[[NSTextView alloc]initWithFrame:scroll.contentView.bounds];self.readerTextView.editable=NO;self.readerTextView.selectable=YES;self.readerTextView.richText=NO;self.readerTextView.verticallyResizable=YES;self.readerTextView.horizontallyResizable=NO;self.readerTextView.autoresizingMask=NSViewWidthSizable;self.readerTextView.minSize=NSMakeSize(0,scroll.contentView.bounds.size.height);self.readerTextView.maxSize=NSMakeSize(CGFLOAT_MAX,CGFLOAT_MAX);self.readerTextView.textContainer.widthTracksTextView=YES;self.readerTextView.textContainer.heightTracksTextView=NO;self.readerTextView.textContainer.containerSize=NSMakeSize(scroll.contentView.bounds.size.width,CGFLOAT_MAX);self.readerTextView.textContainerInset=NSMakeSize(22,24);self.readerTextView.font=[NSFont systemFontOfSize:18];self.readerTextView.textColor=NSColor.labelColor;self.readerTextView.backgroundColor=NSColor.textBackgroundColor;
        scroll.documentView=self.readerTextView;scroll.contentView.postsBoundsChangedNotifications=YES;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(readerDidScroll:) name:NSViewBoundsDidChangeNotification object:scroll.contentView];
        [content addSubview:scroll];[self.readerWindow center];
    }
    [self refreshReaderWindow];[self.readerWindow makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
}

- (void)refreshReaderWindow {
    if(!self.readerWindow||!self.book)return;
    NSArray *chapters=self.book[@"chapters"];if(!chapters.count)return;
    self.updatingReader=YES;
    [self.readerChapterPopup removeAllItems];for(NSDictionary *chapter in chapters)[self.readerChapterPopup addItemWithTitle:chapter[@"title"]];
    self.chapter=MAX(0,MIN(self.chapter,(NSInteger)chapters.count-1));[self.readerChapterPopup selectItemAtIndex:self.chapter];
    self.readerWindow.title=[NSString stringWithFormat:@"%@ — %@",self.book[@"title"],chapters[self.chapter][@"title"]];
    self.readerTextView.string=chapters[self.chapter][@"text"]?:@"";self.readerTextView.font=[NSFont systemFontOfSize:18];
    NSInteger target=MAX(0,MIN(self.offset,(NSInteger)self.readerTextView.string.length));
    [self.readerTextView.layoutManager ensureLayoutForTextContainer:self.readerTextView.textContainer];
    dispatch_async(dispatch_get_main_queue(), ^{[self.readerTextView scrollRangeToVisible:NSMakeRange(target,0)];self.updatingReader=NO;});
}

- (void)readerChapterChanged:(NSPopUpButton *)sender {self.chapter=sender.indexOfSelectedItem;self.offset=0;[self savePosition];[self refreshReaderWindow];[self updateUI];}

- (void)readerDidScroll:(NSNotification *)notification {
    if(self.updatingReader||!self.readerWindow.isVisible||!self.book)return;
    NSClipView *clip=notification.object;NSLayoutManager *layout=self.readerTextView.layoutManager;NSTextContainer *container=self.readerTextView.textContainer;
    NSPoint point=clip.bounds.origin;point.x-=self.readerTextView.textContainerOrigin.x;point.y-=self.readerTextView.textContainerOrigin.y;
    NSUInteger glyph=[layout glyphIndexForPoint:point inTextContainer:container fractionOfDistanceThroughGlyph:nil];
    NSUInteger character=(glyph<layout.numberOfGlyphs)?[layout characterIndexForGlyphAtIndex:glyph]:self.readerTextView.string.length;
    self.offset=MIN((NSInteger)character,(NSInteger)self.readerTextView.string.length);[self savePosition];[self updateUI];
}

- (void)windowWillClose:(NSNotification *)notification {if(notification.object==self.readerWindow){[self savePosition];[self updateUI];}}

- (void)removeBookFromShelf:(NSMenuItem *)sender {
    NSString *path=sender.representedObject;if(!path.length)return;NSString *title=[path.lastPathComponent stringByDeletingPathExtension];
    NSAlert *alert=[NSAlert new];alert.messageText=[NSString stringWithFormat:@"从书架移除《%@》？",title];alert.informativeText=@"将同时清除这本书的阅读进度，但不会删除原始 TXT/EPUB 文件。";[alert addButtonWithTitle:@"移除"];[alert addButtonWithTitle:@"取消"];
    if([alert runModal]!=NSAlertFirstButtonReturn)return;
    NSMutableArray *recent=[[[NSUserDefaults standardUserDefaults]stringArrayForKey:KRecent]mutableCopy]?:[NSMutableArray array];[recent removeObject:path];[[NSUserDefaults standardUserDefaults]setObject:recent forKey:KRecent];
    [self.positions removeObjectForKey:path];[[NSUserDefaults standardUserDefaults]setObject:self.positions forKey:KPositions];
    if([self.book[@"path"]isEqual:path]){[self.readerWindow close];self.book=nil;self.chapter=0;self.offset=0;[[NSUserDefaults standardUserDefaults]removeObjectForKey:KBook];}
    [self updateUI];
}

- (BOOL)openURL:(NSURL *)url showError:(BOOL)showError {
    NSError *error=nil;NSArray *chapters=nil;
    if([url.pathExtension.lowercaseString isEqual:@"epub"])chapters=ParseEPUB(url,&error);else{NSString *text=DecodeTextFile(url,&error);if(text)chapters=ParseTXT(text);}
    if(!chapters.count){if(showError){NSAlert *a=[NSAlert new];a.messageText=@"无法打开这本书";a.informativeText=error.localizedDescription?:@"没有找到可读取的正文";[a runModal];}return NO;}
    [self savePosition];NSDictionary *libraryEntry=[self libraryEntryForPath:url.path];NSString *displayTitle=libraryEntry[@"title"]?:url.URLByDeletingPathExtension.lastPathComponent;self.book=@{@"path":url.path,@"title":displayTitle,@"chapters":chapters};NSDictionary *pos=self.positions[url.path];self.chapter=[pos[@"chapter"]integerValue];self.offset=[pos[@"offset"]integerValue];
    NSUserDefaults *d=NSUserDefaults.standardUserDefaults;[d setObject:url.path forKey:KBook];NSMutableArray *recent=[[d stringArrayForKey:KRecent]mutableCopy]?:[NSMutableArray array];[recent removeObject:url.path];[recent insertObject:url.path atIndex:0];if(recent.count>10)[recent removeObjectsInRange:NSMakeRange(10,recent.count-10)];[d setObject:recent forKey:KRecent];[self refreshReaderWindow];[self updateUI];return YES;
}
- (void)savePosition {NSString *path=self.book[@"path"];if(!path)return;self.positions[path]=@{@"chapter":@(self.chapter),@"offset":@(self.offset)};[NSUserDefaults.standardUserDefaults setObject:self.positions forKey:KPositions];}
- (void)openRecent:(NSMenuItem *)sender {[self openURL:[NSURL fileURLWithPath:sender.representedObject] showError:YES];}
- (void)previous:(id)sender {NSArray *cs=self.book[@"chapters"];if(!cs.count)return;NSInteger step=self.segmentLength;if(self.offset>=step)self.offset-=step;else if(self.chapter>0){self.chapter--;self.offset=MAX(0,(NSInteger)[cs[self.chapter][@"text"]length]-step);}else self.offset=0;[self savePosition];[self refreshReaderWindow];[self updateUI];}
- (void)next:(id)sender {NSArray *cs=self.book[@"chapters"];if(!cs.count)return;NSInteger step=self.segmentLength;NSString *text=cs[self.chapter][@"text"];if(self.offset+step<(NSInteger)text.length)self.offset+=step;else if(self.chapter+1<(NSInteger)cs.count){self.chapter++;self.offset=0;}else self.offset=MAX(0,(NSInteger)text.length-step);[self savePosition];[self refreshReaderWindow];[self updateUI];}
- (void)toggleText:(id)sender {NSUserDefaults *d=NSUserDefaults.standardUserDefaults;[d setBool:![d boolForKey:KHidden] forKey:KHidden];[self updateUI];}
- (void)selectChapter:(NSMenuItem *)sender {self.chapter=sender.tag;self.offset=0;[self savePosition];[self refreshReaderWindow];[self updateUI];}
- (void)setLength:(NSMenuItem *)s {[NSUserDefaults.standardUserDefaults setInteger:s.tag forKey:KLength];[self updateUI];}
- (void)setCustomLength:(id)sender {
    NSAlert *alert=[NSAlert new];alert.messageText=@"自定义显示字数";alert.informativeText=@"请输入每段显示的字数（5–200）：";
    NSTextField *input=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,220,26)];NSInteger current=[NSUserDefaults.standardUserDefaults integerForKey:KLength];input.stringValue=current>0?[NSString stringWithFormat:@"%ld",(long)current]:@"30";input.placeholderString=@"例如：35";alert.accessoryView=input;
    [alert addButtonWithTitle:@"确定"];[alert addButtonWithTitle:@"取消"];
    [alert.window setInitialFirstResponder:input];
    if([alert runModal]!=NSAlertFirstButtonReturn)return;
    NSInteger value=input.integerValue;
    if(value<5||value>200){NSAlert *warning=[NSAlert new];warning.messageText=@"请输入 5–200 之间的字数";[warning runModal];return;}
    [NSUserDefaults.standardUserDefaults setInteger:value forKey:KLength];[self updateUI];
}
- (void)setFont:(NSMenuItem *)s {[NSUserDefaults.standardUserDefaults setDouble:s.tag forKey:KFont];[self updateUI];}
- (void)setColor:(NSMenuItem *)s {[NSUserDefaults.standardUserDefaults setObject:s.representedObject forKey:KColor];[self updateUI];}
- (void)setShortcut:(NSMenuItem *)s {NSInteger action=s.tag/10,index=s.tag%10;NSArray *keys=@[KPrevKey,KNextKey,KToggleKey];NSMutableDictionary *option=[[self shortcutOptions:action][index]mutableCopy];option[@"type"]=@"keyboard";[NSUserDefaults.standardUserDefaults setObject:option forKey:keys[action]];[self registerHotKeys];[self updateUI];}
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
    BOOL hasMouseShortcut=NO;
    for(NSInteger a=0;a<3;a++){NSDictionary *opt=[self shortcutConfiguration:a];if([opt[@"type"]isEqual:@"mouse"]){hasMouseShortcut=YES;continue;}EventHotKeyRef ref=NULL;EventHotKeyID ident={'XIDU',(UInt32)a+1};RegisterEventHotKey([opt[@"code"]unsignedIntValue],[opt[@"mods"]unsignedIntValue],ident,GetApplicationEventTarget(),0,&ref);if(ref)[self.hotKeyRefs addObject:[NSValue valueWithPointer:ref]];}
    if(hasMouseShortcut){__weak typeof(self) weakSelf=self;self.globalMouseMonitor=[NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskOtherMouseDown handler:^(NSEvent *event){[weakSelf handleMouseEvent:event];}];self.localMouseMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskOtherMouseDown handler:^NSEvent *(NSEvent *event){[weakSelf handleMouseEvent:event];return event;}];}
}
- (void)handleHotKey:(UInt32)i {dispatch_async(dispatch_get_main_queue(),^{if(i==1)[self previous:nil];else if(i==2)[self next:nil];else if(i==3)[self toggleText:nil];});}
- (void)toggleLaunch:(id)sender API_AVAILABLE(macos(13.0)){NSError *error=nil;if(SMAppService.mainAppService.status==SMAppServiceStatusEnabled)[SMAppService.mainAppService unregisterAndReturnError:&error];else[SMAppService.mainAppService registerAndReturnError:&error];if(error){NSAlert*a=[NSAlert new];a.messageText=@"无法修改开机启动";a.informativeText=error.localizedDescription;[a runModal];}[self updateUI];}
- (void)quit:(id)sender {[NSApp terminate:nil];}
@end

static OSStatus HotKeyHandler(EventHandlerCallRef next, EventRef event, void *data){EventHotKeyID ident={0};GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(ident),NULL,&ident);AppDelegate *delegate=(__bridge AppDelegate *)data;[delegate handleHotKey:ident.id];return noErr;}

int main(int argc,const char *argv[]){@autoreleasepool{NSApplication *app=NSApplication.sharedApplication;AppDelegate *delegate=[AppDelegate new];app.delegate=delegate;[app setActivationPolicy:NSApplicationActivationPolicyAccessory];[app run];}return 0;}
