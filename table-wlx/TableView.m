/* TableView.wlx — a read-only native spreadsheet grid for Double Commander.
 * Workbook decoding runs off the UI thread in an isolated JavaScriptCore VM.
 * Only text values cross into AppKit; formulas, markup and links never execute.
 */
#import <Cocoa/Cocoa.h>
#import <JavaScriptCore/JavaScriptCore.h>
#include <dlfcn.h>
#include <fenv.h>
#include "listplug.h"
#include "build/parser.h"
#include "ODFGuard.h"

#define TV_VERSION "0.2.0"
#define TV_EXPORT __attribute__((visibility("default")))
static const char *kDetect =
    "EXT=\"CSV\"|EXT=\"TSV\"|EXT=\"XLSX\"|EXT=\"XLSM\"|EXT=\"XLSB\"|EXT=\"XLS\"|"
    "EXT=\"ODS\"|EXT=\"FODS\"|EXT=\"NUMBERS\"|EXT=\"DIF\"|EXT=\"SLK\"|EXT=\"SYLK\"|EXT=\"DBF\"";
static const NSUInteger kFileLimit = 20 * 1024 * 1024;
static const CGFloat kRow = 26, kCol = 160, kGutter = 56;

static void Masked(void (^block)(void)) {
    fenv_t saved; fegetenv(&saved); fesetenv(FE_DFL_ENV);
    @try { block(); } @finally { fesetenv(&saved); }
}
static void OnMain(void (^block)(void)) {
    if (NSThread.isMainThread) Masked(block);
    else dispatch_sync(dispatch_get_main_queue(), ^{ Masked(block); });
}
static NSString *Path(const char *value) {
    return value ? [NSFileManager.defaultManager stringWithFileSystemRepresentation:value length:strlen(value)] : nil;
}
static BOOL Supported(NSString *path) {
    return [@[@"csv",@"tsv",@"xlsx",@"xlsm",@"xlsb",@"xls",@"ods",@"fods",@"numbers",@"dif",@"slk",@"sylk",@"dbf"]
        containsObject:path.pathExtension.lowercaseString];
}
static NSString *ColumnName(NSInteger n) {
    NSMutableString *s = [NSMutableString string];
    do { [s insertString:[NSString stringWithFormat:@"%c", (int)('A' + n % 26)] atIndex:0]; n = n / 26 - 1; } while (n >= 0);
    return s;
}

/* libarchive is shipped with macOS, but its headers are not in the macOS SDK.
 * These public C declarations are the small read-only subset used here. Read
 * every ZIP entry with bounded buffers before handing the same bytes to SheetJS.
 * Nothing is extracted to disk; declared AND actual inflated sizes are capped. */
struct archive; struct archive_entry;
extern struct archive *archive_read_new(void);
extern int archive_read_support_format_zip(struct archive *);
extern int archive_read_open_memory(struct archive *, const void *, size_t);
extern int archive_read_next_header(struct archive *, struct archive_entry **);
extern int64_t archive_entry_size(struct archive_entry *);
extern const char *archive_entry_pathname(struct archive_entry *);
extern ssize_t archive_read_data(struct archive *, void *, size_t);
extern int archive_read_free(struct archive *);
static BOOL CheckZIP(NSData *data) {
    struct archive *a = archive_read_new();
    if (!a) return NO;
    archive_read_support_format_zip(a);
    BOOL ok = archive_read_open_memory(a, data.bytes, data.length) == 0;
    NSUInteger total = 0, entries = 0;
    struct archive_entry *entry;
    int rc = 1;
    while (ok && (rc = archive_read_next_header(a, &entry)) == 0) {
        if (++entries > 10000 || archive_entry_size(entry) > 64 * 1024 * 1024) { ok = NO; break; }
        const char *entryName=archive_entry_pathname(entry);
        BOOL odfXML=entryName && [Path(entryName).lastPathComponent.lowercaseString isEqual:@"content.xml"];
        NSMutableData *xml=odfXML?[NSMutableData data]:nil;
        char buf[65536]; ssize_t count;
        while ((count = archive_read_data(a, buf, sizeof(buf))) > 0) {
            total += (NSUInteger)count;
            if (odfXML) [xml appendBytes:buf length:(NSUInteger)count];
            if (total > 64 * 1024 * 1024) { ok = NO; break; }
        }
        if (count < 0 || (ok && odfXML && !CheckODFXML(xml))) ok = NO;
    }
    archive_read_free(a);
    return ok && rc == 1; /* ARCHIVE_EOF */
}

static NSDictionary *ReadWorkbook(NSString *path, NSString **error) {
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (![attrs[NSFileType] isEqual:NSFileTypeRegular] || [attrs[NSFileSize] unsignedLongLongValue] > kFileLimit) {
        *error = @"Preview supports regular files up to 20 MB. Export larger files to smaller tables."; return nil;
    }
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:nil];
    if (!data || data.length > kFileLimit) { *error = @"Unable to read this file."; return nil; }
    const uint8_t *bytes = data.bytes;
    if (data.length >= 4 && bytes[0] == 'P' && bytes[1] == 'K' && !CheckZIP(data)) {
        *error = @"Invalid or oversized spreadsheet archive (64 MB expanded limit)."; return nil;
    }
    NSString *ext = path.pathExtension.lowercaseString;
    BOOL delimited=[ext isEqual:@"csv"] || [ext isEqual:@"tsv"];
    NSString *possibleXML=delimited?nil:([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?:
                                       [[NSString alloc] initWithData:data encoding:NSUnicodeStringEncoding]);
    NSCharacterSet *prefixSpace=[NSCharacterSet characterSetWithCharactersInString:@" \r\n\t\uFEFF"];
    BOOL xmlInput=[[possibleXML stringByTrimmingCharactersInSet:prefixSpace] hasPrefix:@"<"];
    if (([ext isEqual:@"fods"] || xmlInput) && !CheckODFXML(data)) {
        *error = @"Invalid OpenDocument XML or repeated data exceeds safe preview limits."; return nil;
    }
    NSString *textInput=nil;
    if (delimited) {
        /* Preserve Unicode and leading zeros. A BOM selects UTF-16; otherwise
         * prefer UTF-8 and fall back to Windows-1252 for older exports. */
        NSString *text;
        if (data.length >= 2 && ((bytes[0] == 0xff && bytes[1] == 0xfe) || (bytes[0] == 0xfe && bytes[1] == 0xff)))
            text = [[NSString alloc] initWithData:data encoding:NSUnicodeStringEncoding];
        else text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?:
                    [[NSString alloc] initWithData:data encoding:NSWindowsCP1252StringEncoding];
        if (!text) { *error = @"Unsupported text encoding."; return nil; }
        textInput=text;
    }
    JSContext *context = [[JSContext alloc] init];
    [context evaluateScript:[[NSString alloc] initWithBytes:tv_xlsx length:sizeof(tv_xlsx)-1 encoding:NSUTF8StringEncoding]];
    [context evaluateScript:[[NSString alloc] initWithBytes:tv_csv length:sizeof(tv_csv)-1 encoding:NSUTF8StringEncoding]];
    [context evaluateScript:[[NSString alloc] initWithBytes:tv_adapter length:sizeof(tv_adapter)-1 encoding:NSUTF8StringEncoding]];
    JSValue *result = [context[@"tableRead"] callWithArguments:@[textInput ?: [data base64EncodedStringWithOptions:0], ext]];
    if (context.exception || !result.isObject) {
        /* Do not echo parser errors: they may contain workbook data or paths. */
        *error = @"Cannot decode this spreadsheet. It may be damaged, encrypted, or an unsupported version."; return nil;
    }
    NSDictionary *book = [result toDictionary];
    if (![book[@"sheets"] isKindOfClass:NSArray.class] || ![book[@"sheets"] count]) {
        *error = @"No worksheets found."; return nil;
    }
    return book;
}

@class TVView;
@interface TVGrid : NSView
@property(nonatomic, weak) TVView *owner;
@property(nonatomic, copy) NSArray<NSArray<NSString *> *> *rows;
@property(nonatomic) NSInteger columns, anchorRow, anchorCol, endRow, endCol;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *columnWidths;
@property(nonatomic, copy) NSArray<NSNumber *> *columnEdges;
@property(nonatomic) NSInteger resizingColumn;
@property(nonatomic) CGFloat resizeStartX, resizeStartWidth;
- (void)resetColumnWidths;
- (CGFloat)columnOrigin:(NSInteger)column;
- (NSInteger)columnAtX:(CGFloat)x;
@property(nonatomic) NSInteger dragMode; /* 0 cells, 1 rows, 2 columns */
- (void)selectRow:(NSInteger)row column:(NSInteger)col extend:(BOOL)extend;
- (void)handKeyToHost:(NSEvent *)event;
- (void)revealSelection;
- (NSString *)selectedText;
@end
@interface TVView : NSView
@property(nonatomic, strong) TVGrid *grid;
@property(nonatomic, strong) NSScrollView *scroll;
@property(nonatomic, strong) NSPopUpButton *sheetsMenu;
@property(nonatomic, strong) NSTextField *status;
@property(nonatomic, strong) NSTextField *cellAddress;
@property(nonatomic, strong) NSScrollView *cellScroll;
@property(nonatomic, strong) NSTextView *cellContent;
@property(nonatomic, strong) NSButton *clipboardButton;
@property(nonatomic, copy) NSArray<NSDictionary *> *sheets;
@property(atomic) NSUInteger generation;
@property(nonatomic) BOOL loading, headerRedrawPending;
@property(atomic) BOOL closed;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *pendingSearches;
- (void)openPath:(NSString *)path;
- (void)updateStatus;
- (void)sizeGrid;
- (void)claimFocusIfUnclaimed;
- (void)close;
- (BOOL)copySelection;
- (void)search:(NSString *)query flags:(int)flags;
@end

/* The value panel is for reading; grid selection and DC retain the keyboard.
 * Its scroll view still allows long, multiline values to be read in full. */
@interface TVCellContent : NSTextView @end
@implementation TVCellContent
- (BOOL)acceptsFirstResponder { return NO; }
@end

@implementation TVGrid
- (void)resetColumnWidths {
    self.columnWidths=[NSMutableArray arrayWithCapacity:self.columns];
    for (NSInteger c=0;c<self.columns;c++) [self.columnWidths addObject:@(kCol)];
    self.resizingColumn=-1;
    [self rebuildColumnEdges];
}
- (void)rebuildColumnEdges {
    NSMutableArray *edges=[NSMutableArray arrayWithObject:@(kGutter)];
    CGFloat x=kGutter;
    for (NSNumber *width in self.columnWidths) { x+=width.doubleValue; [edges addObject:@(x)]; }
    self.columnEdges=edges;
}
- (CGFloat)columnOrigin:(NSInteger)column {
    return self.columnEdges[column].doubleValue;
}
- (NSInteger)columnAtX:(CGFloat)x {
    for (NSInteger c=0;c<self.columns;c++) if (x<[self columnOrigin:c+1]) return c;
    return self.columns;
}
- (NSInteger)dividerAtPoint:(NSPoint)p {
    NSRect visible=self.visibleRect;
    if (p.y<visible.origin.y || p.y>=visible.origin.y+kRow || p.x<visible.origin.x+kGutter+4) return -1;
    for (NSInteger c=0;c<self.columns;c++) if (fabs(p.x-[self columnOrigin:c+1])<=4) return c;
    return -1;
}
- (void)resetCursorRects {
    [super resetCursorRects];
    NSRect visible=self.visibleRect;
    NSRect header=NSMakeRect(visible.origin.x+kGutter,visible.origin.y,MAX(0,visible.size.width-kGutter),kRow);
    for (NSInteger c=0;c<self.columns;c++) {
        NSRect edge=NSIntersectionRect(header,NSMakeRect([self columnOrigin:c+1]-4,visible.origin.y,8,kRow));
        if (!NSIsEmptyRect(edge)) [self addCursorRect:edge cursor:NSCursor.resizeLeftRightCursor];
    }
}
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay = YES; }
- (void)drawText:(NSString *)text rect:(NSRect)rect header:(BOOL)header selected:(BOOL)selected {
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *attrs = @{NSFontAttributeName:header ? [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium] : [NSFont systemFontOfSize:13],
        NSForegroundColorAttributeName:selected ? NSColor.selectedTextColor : NSColor.labelColor,
        NSParagraphStyleAttributeName:style};
    NSRect clip = NSInsetRect(rect, 7, 4);
    [NSGraphicsContext saveGraphicsState]; NSRectClip(clip);
    [[text stringByReplacingOccurrencesOfString:@"\n" withString:@" ↵ "] drawInRect:clip withAttributes:attrs];
    [NSGraphicsContext restoreGraphicsState];
}
- (void)drawRect:(NSRect)dirty {
    Masked(^{
        [NSColor.textBackgroundColor setFill]; NSRectFill(dirty);
        NSRect visible = self.visibleRect;
        NSInteger r0 = MAX(0, (NSInteger)((NSMinY(dirty)-kRow)/kRow));
        NSInteger r1 = MIN((NSInteger)self.rows.count, (NSInteger)ceil(NSMaxY(dirty)/kRow));
        NSInteger c0 = [self columnAtX:NSMinX(dirty)];
        NSInteger c1 = MIN(self.columns, [self columnAtX:NSMaxX(dirty)]+1);
        NSInteger loR=MIN(self.anchorRow,self.endRow), hiR=MAX(self.anchorRow,self.endRow);
        NSInteger loC=MIN(self.anchorCol,self.endCol), hiC=MAX(self.anchorCol,self.endCol);
        for (NSInteger r=r0; r<r1; r++) for (NSInteger c=c0; c<c1; c++) {
            NSRect rect=NSMakeRect([self columnOrigin:c],kRow+r*kRow,self.columnWidths[c].doubleValue,kRow);
            BOOL selected=self.anchorRow>=0 && r>=loR && r<=hiR && c>=loC && c<=hiC;
            if (selected) { [NSColor.selectedTextBackgroundColor setFill]; NSRectFill(rect); }
            else if (r%2) { [NSColor.alternatingContentBackgroundColors[1] setFill]; NSRectFill(rect); }
            [NSColor.gridColor set]; NSFrameRectWithWidth(rect,0.5);
            [self drawText:self.rows[r][c] rect:rect header:NO selected:selected];
        }
        /* Paint frozen headers LAST, at the viewport edges rather than at the
         * document origin. Both remain visible during two-axis scrolling. */
        [NSColor.controlBackgroundColor setFill];
        NSRectFill(NSMakeRect(visible.origin.x,visible.origin.y,visible.size.width,kRow));
        NSRectFill(NSMakeRect(visible.origin.x,visible.origin.y,kGutter,visible.size.height));
        /* A partial body redraw can still repaint the frozen strips. Use
         * viewport ranges here, so it cannot erase unrelated header labels. */
        NSInteger hc0=[self columnAtX:NSMinX(visible)], hc1=MIN(self.columns,[self columnAtX:NSMaxX(visible)]+1);
        NSInteger hr0=MAX(0,(NSInteger)((NSMinY(visible)-kRow)/kRow));
        NSInteger hr1=MIN((NSInteger)self.rows.count,(NSInteger)ceil(NSMaxY(visible)/kRow));
        for (NSInteger c=hc0;c<hc1;c++) {
            NSRect rect=NSMakeRect([self columnOrigin:c],visible.origin.y,self.columnWidths[c].doubleValue,kRow);
            [self drawText:ColumnName(c) rect:rect header:YES selected:NO];
            [NSColor.gridColor set]; NSFrameRectWithWidth(rect,0.5);
        }
        for (NSInteger r=hr0;r<hr1;r++) {
            NSRect rect=NSMakeRect(visible.origin.x,kRow+r*kRow,kGutter,kRow);
            [self drawText:[NSString stringWithFormat:@"%ld",(long)r+1] rect:rect header:YES selected:NO];
        }
        [NSColor.controlBackgroundColor setFill];
        NSRectFill(NSMakeRect(visible.origin.x,visible.origin.y,kGutter,kRow));
    });
}
- (void)selectRow:(NSInteger)row column:(NSInteger)col extend:(BOOL)extend {
    if (!self.rows.count || !self.columns) return;
    row=MAX(0,MIN((NSInteger)self.rows.count-1,row)); col=MAX(0,MIN(self.columns-1,col));
    if (!extend || self.anchorRow<0) { self.anchorRow=row; self.anchorCol=col; }
    self.endRow=row; self.endCol=col;
    self.needsDisplay=YES; [self.owner updateStatus];
}
- (void)selectAll:(id)sender {
    (void)sender;
    if (!self.rows.count || !self.columns) return;
    self.anchorRow=0; self.anchorCol=0; self.endRow=self.rows.count-1; self.endCol=self.columns-1;
    self.needsDisplay=YES; [self.owner updateStatus];
}
- (void)copy:(id)sender { (void)sender; [self.owner copySelection]; }
- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    self.resizingColumn=-1;
    if (!self.rows.count || !self.columns) return;
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];
    NSInteger divider=[self dividerAtPoint:p];
    if (divider>=0) {
        self.resizingColumn=divider;
        self.resizeStartX=event.locationInWindow.x;
        self.resizeStartWidth=self.columnWidths[divider].doubleValue;
        return;
    }
    NSRect visible=self.visibleRect;
    BOOL header=p.y<visible.origin.y+kRow, gutter=p.x<visible.origin.x+kGutter;
    NSInteger row=(p.y-kRow)/kRow, col=[self columnAtX:p.x];
    BOOL extend=(event.modifierFlags & NSEventModifierFlagShift)!=0;
    self.dragMode=gutter ? 1 : (header ? 2 : 0);
    if (header && gutter) { [self selectAll:nil]; return; }
    [self selectRow:header?0:row column:gutter?0:col extend:extend];
    if (gutter) { self.anchorCol=0; self.endCol=self.columns-1; }
    if (header) { self.anchorRow=0; self.endRow=self.rows.count-1; }
    self.needsDisplay=YES; [self.owner updateStatus];
}
- (void)mouseDragged:(NSEvent *)event {
    if (self.resizingColumn>=0) {
        self.columnWidths[self.resizingColumn]=@(MAX(48,MIN(4096,self.resizeStartWidth+event.locationInWindow.x-self.resizeStartX)));
        [self rebuildColumnEdges]; [self.owner sizeGrid];
        [self.window invalidateCursorRectsForView:self];
        return;
    }
    if (self.anchorRow<0) return;
    [self autoscroll:event];
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];
    NSInteger row=(p.y-kRow)/kRow, col=[self columnAtX:p.x];
    [self selectRow:self.dragMode==2?(NSInteger)self.rows.count-1:row
            column:self.dragMode==1?self.columns-1:col extend:YES];
}
- (void)mouseUp:(NSEvent *)event { (void)event; self.resizingColumn=-1; }
- (NSMenu *)menuForEvent:(NSEvent *)event {
    (void)event;
    NSMenu *menu=[[NSMenu alloc] initWithTitle:@"Table"];
    NSMenuItem *copy=[menu addItemWithTitle:@"Copy cells" action:@selector(copy:) keyEquivalent:@""]; copy.target=self;
    NSMenuItem *all=[menu addItemWithTitle:@"Select all cells" action:@selector(selectAll:) keyEquivalent:@""]; all.target=self;
    return menu;
}
- (void)revealSelection {
    if (self.endRow<0) return;
    NSRect cell=NSMakeRect([self columnOrigin:self.endCol],kRow+self.endRow*kRow,self.columnWidths[self.endCol].doubleValue,kRow);
    NSRect b=self.visibleRect;
    if (cell.origin.x<b.origin.x+kGutter) b.origin.x=MAX(0,cell.origin.x-kGutter);
    if (cell.size.width>b.size.width-kGutter) b.origin.x=MAX(0,cell.origin.x-kGutter);
    else if (NSMaxX(cell)>NSMaxX(b)) b.origin.x=NSMaxX(cell)-b.size.width;
    if (cell.origin.y<b.origin.y+kRow) b.origin.y=MAX(0,cell.origin.y-kRow);
    if (NSMaxY(cell)>NSMaxY(b)) b.origin.y=NSMaxY(cell)-b.size.height;
    [self scrollPoint:b.origin]; self.needsDisplay=YES;
}
- (NSString *)selectedText {
    if (self.anchorRow<0 || !self.rows.count) return nil;
    NSMutableString *out=[NSMutableString string];
    for (NSInteger r=MIN(self.anchorRow,self.endRow);r<=MAX(self.anchorRow,self.endRow);r++) {
        if (r>MIN(self.anchorRow,self.endRow)) [out appendString:@"\n"];
        for (NSInteger c=MIN(self.anchorCol,self.endCol);c<=MAX(self.anchorCol,self.endCol);c++) {
            if (c>MIN(self.anchorCol,self.endCol)) [out appendString:@"\t"];
            NSString *s=self.rows[r][c];
            if ([s rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\t\r\n\""]].location!=NSNotFound)
                s=[NSString stringWithFormat:@"\"%@\"",[s stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
            [out appendString:s];
            if (out.length>16*1024*1024) return nil;
        }
    }
    return out;
}
- (void)keyDown:(NSEvent *)event {
    NSEventModifierFlags mods=event.modifierFlags & (NSEventModifierFlagCommand|NSEventModifierFlagOption|NSEventModifierFlagControl|NSEventModifierFlagShift);
    if (mods & (NSEventModifierFlagOption|NSEventModifierFlagControl)) { [self handKeyToHost:event]; return; }
    if (mods==NSEventModifierFlagCommand && event.keyCode==8) { [self copy:nil]; return; }
    if (mods==NSEventModifierFlagCommand && event.keyCode==0) { [self selectAll:nil]; return; }
    NSInteger r=MAX(0,self.endRow),c=MAX(0,self.endCol);
    BOOL cmd=(mods & NSEventModifierFlagCommand)!=0, extend=(mods & NSEventModifierFlagShift)!=0;
    NSInteger page=MAX(1,(NSInteger)(self.visibleRect.size.height/kRow)-2);
    switch (event.keyCode) {
        case 123:c=cmd?0:c-1;break;
        case 124:c=cmd?self.columns-1:c+1;break;
        case 126:r=cmd?0:r-1;break;
        case 125:r=cmd?(NSInteger)self.rows.count-1:r+1;break;
        case 116:r-=page;break;
        case 121:r+=page;break;
        case 115:r=0;c=0;break;
        case 119:r=self.rows.count-1;c=self.columns-1;break;
        default:[self handKeyToHost:event];return;
    }
    [self selectRow:r column:c extend:extend]; [self revealSelection];
}
- (void)handKeyToHost:(NSEvent *)event {
    NSWindow *win=self.window;
    if (!win) return;
    BOOL moved=[win makeFirstResponder:self.owner.superview];
    if (!moved) moved=[win makeFirstResponder:win.contentView];
    if (!moved) [win makeFirstResponder:nil];
    if (win.firstResponder==self) return;
    NSEvent *key=[NSEvent keyEventWithType:NSEventTypeKeyDown location:event.locationInWindow
        modifierFlags:event.modifierFlags timestamp:event.timestamp windowNumber:event.windowNumber context:nil
        characters:event.characters charactersIgnoringModifiers:event.charactersIgnoringModifiers isARepeat:event.isARepeat keyCode:event.keyCode];
    [NSApp postEvent:key atStart:YES];
    __weak TVView *owner=self.owner;
    dispatch_async(dispatch_get_main_queue(), ^{ if (owner.window.isKeyWindow) [owner claimFocusIfUnclaimed]; });
}
@end

@implementation TVView
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self=[super initWithFrame:frame])) return nil;
    self.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    self.pendingSearches=[NSMutableArray array];
    self.sheetsMenu=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.sheetsMenu.target=self; self.sheetsMenu.action=@selector(changeSheet:);
    self.sheetsMenu.toolTip=@"Worksheet / Numbers table"; [self addSubview:self.sheetsMenu];
    self.clipboardButton=[NSButton buttonWithTitle:@"Copy cells" target:self action:@selector(copyClicked:)];
    [self addSubview:self.clipboardButton];
    self.status=[NSTextField labelWithString:@"Loading…"];
    self.status.font=[NSFont systemFontOfSize:11]; self.status.lineBreakMode=NSLineBreakByTruncatingTail;
    [self addSubview:self.status];
    self.cellAddress=[NSTextField labelWithString:@"Cell"];
    self.cellAddress.font=[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];
    [self addSubview:self.cellAddress];
    self.cellScroll=[[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.cellScroll.hasVerticalScroller=YES; self.cellScroll.autohidesScrollers=YES;
    self.cellScroll.borderType=NSBezelBorder;
    self.cellContent=[[TVCellContent alloc] initWithFrame:NSZeroRect];
    self.cellContent.editable=NO; self.cellContent.selectable=NO;
    self.cellContent.richText=NO; self.cellContent.font=[NSFont systemFontOfSize:13];
    self.cellContent.textContainerInset=NSMakeSize(5,5);
    self.cellContent.verticallyResizable=YES; self.cellContent.horizontallyResizable=NO;
    self.cellContent.autoresizingMask=NSViewWidthSizable;
    self.cellContent.textContainer.widthTracksTextView=YES;
    self.cellContent.textColor=NSColor.labelColor;
    self.cellContent.backgroundColor=NSColor.textBackgroundColor;
    [self.cellContent setAccessibilityLabel:@"Active cell value"];
    self.cellScroll.documentView=self.cellContent; [self addSubview:self.cellScroll];
    self.scroll=[[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.scroll.hasVerticalScroller=YES; self.scroll.hasHorizontalScroller=YES;
    self.scroll.autohidesScrollers=YES;
    self.grid=[[TVGrid alloc] initWithFrame:NSZeroRect]; self.grid.owner=self;
    self.grid.anchorRow=self.grid.endRow=-1; self.grid.rows=@[]; [self.grid resetColumnWidths];
    self.scroll.documentView=self.grid; [self addSubview:self.scroll];
    self.scroll.contentView.postsBoundsChangedNotifications=YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scrolled:)
        name:NSViewBoundsDidChangeNotification object:self.scroll.contentView];
    return self;
}
- (void)layout {
    [super layout];
    CGFloat w=self.bounds.size.width,h=self.bounds.size.height;
    self.sheetsMenu.frame=NSMakeRect(8,5,MAX(40,MIN(300,w-124)),26);
    self.clipboardButton.frame=NSMakeRect(MAX(50,w-108),5,100,26);
    CGFloat maximum=MIN(80,MAX(0,h-140)), valueWidth=MAX(0,w-68);
    /* Measure with the actual text container, font and wrapping width. First
     * give the scroll view its maximum viewport so legacy scroller space is
     * accounted for when long content needs a scrollbar. */
    self.cellScroll.frame=NSMakeRect(60,MAX(36,h-30-maximum),valueWidth,maximum);
    self.cellContent.frameSize=NSMakeSize(self.cellScroll.contentSize.width,MAX(1,maximum));
    __block CGFloat textHeight=0;
    Masked(^{
        NSLayoutManager *manager=self.cellContent.layoutManager;
        NSTextContainer *container=self.cellContent.textContainer;
        [manager ensureLayoutForTextContainer:container];
        textHeight=MAX(NSMaxY([manager usedRectForTextContainer:container]),
            [manager defaultLineHeightForFont:self.cellContent.font]);
        if (manager.extraLineFragmentTextContainer==container)
            textHeight=MAX(textHeight,NSMaxY(manager.extraLineFragmentRect));
        textHeight=ceil(textHeight+2*self.cellContent.textContainerInset.height);
    });
    CGFloat borderHeight=maximum-self.cellScroll.contentSize.height;
    CGFloat valueHeight=MIN(maximum,ceil(textHeight+borderHeight));
    CGFloat oldGridHeight=self.scroll.frame.size.height;
    self.scroll.frame=NSMakeRect(0,36,w,MAX(0,h-70-valueHeight));
    self.cellAddress.frame=NSMakeRect(8,MAX(36,h-28-valueHeight),48,18);
    self.cellScroll.frame=NSMakeRect(60,MAX(36,h-30-valueHeight),MAX(0,w-68),valueHeight);
    self.cellScroll.hidden=self.cellAddress.hidden=valueHeight<24;
    self.cellContent.frameSize=NSMakeSize(self.cellScroll.contentSize.width,MAX(self.cellScroll.contentSize.height,textHeight));
    self.status.frame=NSMakeRect(8,MAX(36,h-22),MAX(0,w-16),18);
    [self sizeGrid];
    if (self.scroll.frame.size.height<oldGridHeight && self.grid.anchorRow>=0 &&
        self.grid.anchorRow==self.grid.endRow && self.grid.anchorCol==self.grid.endCol)
        [self.grid revealSelection];
}
- (void)sizeGrid {
    self.grid.frameSize=NSMakeSize(MAX(self.scroll.contentSize.width,self.grid.columnEdges.lastObject.doubleValue),
        MAX(self.scroll.contentSize.height,kRow+self.grid.rows.count*kRow));
    self.grid.needsDisplay=YES;
}
- (void)scrolled:(NSNotification *)note {
    (void)note;
    [self.grid setNeedsDisplayInRect:self.grid.visibleRect];
    [self.window invalidateCursorRectsForView:self.grid];
    /* NSClipView may copy old pixels AFTER its bounds notification. Redraw the
     * frozen headers after that operation, even when only a thin strip was exposed. */
    if (self.headerRedrawPending) return;
    self.headerRedrawPending=YES;
    __weak TVView *weak=self;
    dispatch_async(dispatch_get_main_queue(), ^{
        TVView *view=weak; view.headerRedrawPending=NO;
        if (view && !view.closed) [view.grid setNeedsDisplayInRect:view.grid.visibleRect];
    });
}
- (void)openPath:(NSString *)path {
    NSUInteger token=++self.generation;
    self.loading=YES; self.sheets=@[]; [self.pendingSearches removeAllObjects];
    [self.sheetsMenu removeAllItems]; self.sheetsMenu.enabled=NO;
    self.grid.rows=@[]; self.grid.columns=0; self.grid.anchorRow=self.grid.endRow=-1;
    [self.grid resetColumnWidths]; self.cellContent.string=@""; self.cellAddress.stringValue=@"Cell"; self.needsLayout=YES;
    self.clipboardButton.enabled=NO; self.status.stringValue=@"Loading spreadsheet…"; [self sizeGrid];
    __weak TVView *weak=self;
    static dispatch_queue_t queue; static dispatch_once_t once;
    dispatch_once(&once, ^{ queue=dispatch_queue_create("org.dcplugins.table.decode", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(queue, ^{
        if (!weak || weak.closed || token!=weak.generation) return;
        @autoreleasepool { Masked(^{
            NSString *error=nil;
            NSDictionary *book=ReadWorkbook(path,&error);
            dispatch_async(dispatch_get_main_queue(), ^{ Masked(^{
                TVView *view=weak;
                if (!view || view.closed || token!=view.generation) return;
                view.loading=NO;
                if (!book) { view.status.stringValue=error ?: @"Cannot open spreadsheet."; [view.pendingSearches removeAllObjects]; return; }
                view.sheets=book[@"sheets"];
                for (NSDictionary *sheet in view.sheets) [view.sheetsMenu addItemWithTitle:sheet[@"name"]];
                view.sheetsMenu.enabled=YES;
                [view changeSheet:nil];
                NSArray *pending=[view.pendingSearches copy]; [view.pendingSearches removeAllObjects];
                for (NSDictionary *request in pending) [view search:request[@"query"] flags:[request[@"flags"] intValue]];
            }); });
        }); }
    });
}
- (void)changeSheet:(id)sender {
    (void)sender;
    NSInteger index=self.sheetsMenu.indexOfSelectedItem;
    if (index<0 || index>=(NSInteger)self.sheets.count) return;
    NSDictionary *sheet=self.sheets[index];
    self.grid.rows=sheet[@"rows"]; self.grid.columns=[sheet[@"columns"] integerValue]; [self.grid resetColumnWidths];
    self.grid.anchorRow=self.grid.endRow=-1; self.grid.anchorCol=self.grid.endCol=0;
    [self sizeGrid]; [self.grid scrollPoint:NSZeroPoint];
    [self.grid selectRow:0 column:0 extend:NO];
    self.clipboardButton.enabled=self.grid.rows.count && self.grid.columns;
    [self updateStatus];
}
- (void)updateStatus {
    NSInteger index=self.sheetsMenu.indexOfSelectedItem;
    BOOL limited=index>=0 && index<(NSInteger)self.sheets.count && [self.sheets[index][@"limited"] boolValue];
    NSString *selection=self.grid.anchorRow<0 ? @"" : [NSString stringWithFormat:@" · %@%ld:%@%ld",
        ColumnName(MIN(self.grid.anchorCol,self.grid.endCol)),(long)MIN(self.grid.anchorRow,self.grid.endRow)+1,
        ColumnName(MAX(self.grid.anchorCol,self.grid.endCol)),(long)MAX(self.grid.anchorRow,self.grid.endRow)+1];
    self.status.stringValue=[NSString stringWithFormat:@"%lu rows × %ld columns%@%@ · TableView %s",
        (unsigned long)self.grid.rows.count,(long)self.grid.columns,selection,limited?@" · Preview truncated":@"",TV_VERSION];
    self.status.toolTip=self.status.stringValue;
    BOOL active=self.grid.endRow>=0 && self.grid.endRow<(NSInteger)self.grid.rows.count && self.grid.endCol>=0 && self.grid.endCol<self.grid.columns;
    NSString *value=active?self.grid.rows[self.grid.endRow][self.grid.endCol]:@"";
    NSString *address=active?[NSString stringWithFormat:@"%@%ld",ColumnName(self.grid.endCol),(long)self.grid.endRow+1]:@"Cell";
    BOOL changed=![self.cellAddress.stringValue isEqual:address] || ![self.cellContent.string isEqual:value];
    self.cellAddress.stringValue=address;
    if (changed) {
        if (![self.cellContent.string isEqual:value]) self.cellContent.string=value;
        self.needsLayout=YES;
        [self layoutSubtreeIfNeeded];
        [self.cellContent scrollRangeToVisible:NSMakeRange(0,0)];
    }
}
- (BOOL)copySelection {
    NSString *text=[self.grid selectedText];
    if (!text) { NSBeep(); return NO; }
    NSPasteboard *pb=NSPasteboard.generalPasteboard; [pb clearContents];
    return [pb setString:text forType:NSPasteboardTypeString];
}
- (void)copyClicked:(id)sender { (void)sender; [self copySelection]; }
- (void)search:(NSString *)query flags:(int)flags {
    if (self.loading) { [self.pendingSearches addObject:@{@"query":query,@"flags":@(flags)}]; return; }
    if (!query.length || !self.grid.rows.count || !self.grid.columns) { NSBeep(); return; }
    NSInteger total=self.grid.rows.count*self.grid.columns;
    NSInteger start=self.grid.endRow<0?-1:self.grid.endRow*self.grid.columns+self.grid.endCol;
    BOOL back=(flags & lcs_backwards)!=0;
    if (flags & lcs_findfirst) start=back?total: -1;
    NSStringCompareOptions options=(flags & lcs_matchcase)?0:NSCaseInsensitiveSearch;
    for (NSInteger step=1;step<=total;step++) {
        NSInteger pos=((start+(back?-step:step))%total+total)%total;
        NSString *text=self.grid.rows[pos/self.grid.columns][pos%self.grid.columns];
        NSRange range=NSMakeRange(0,text.length),found;
        while ((found=[text rangeOfString:query options:options range:range]).location!=NSNotFound) {
            BOOL whole=!(flags & lcs_wholewords) ||
                ((found.location==0 || ![NSCharacterSet.alphanumericCharacterSet characterIsMember:[text characterAtIndex:found.location-1]]) &&
                 (NSMaxRange(found)==text.length || ![NSCharacterSet.alphanumericCharacterSet characterIsMember:[text characterAtIndex:NSMaxRange(found)]]));
            if (whole) { [self.grid selectRow:pos/self.grid.columns column:pos%self.grid.columns extend:NO]; [self.grid revealSelection]; return; }
            range=NSMakeRange(NSMaxRange(found),text.length-NSMaxRange(found));
        }
    }
    NSBeep();
}
/* Same focus policy as ImageView: take focus only from DC's bare viewer form,
 * never from a visible panel control in Quick View or from the sheet picker. */
- (BOOL)focusIsUnclaimed {
    NSWindow *win=self.window; NSResponder *fr=win.firstResponder;
    if (!fr || fr==win) return YES;
    if (![fr isKindOfClass:NSView.class]) return NO;
    NSView *v=(NSView *)fr, *content=win.contentView;
    if (v==self.grid) return NO;
    if (v==content) return YES;
    if ([v.superview isKindOfClass:NSClipView.class] && v.superview.superview==content) return YES;
    return [self isDescendantOf:v] || v.isHiddenOrHasHiddenAncestor;
}
- (void)claimFocusIfUnclaimed {
    if (self.window && !self.closed && [self focusIsUnclaimed]) [self.window makeFirstResponder:self.grid];
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidBecomeKeyNotification object:nil];
    if (!self.window) return;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowDidBecomeKey:)
        name:NSWindowDidBecomeKeyNotification object:self.window];
    if (self.window.isKeyWindow) [self windowDidBecomeKey:nil];
}
- (void)windowDidBecomeKey:(NSNotification *)note {
    (void)note; __weak TVView *weak=self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weak claimFocusIfUnclaimed]; });
}
- (void)close {
    self.closed=YES; self.generation++;
    [self.pendingSearches removeAllObjects]; [NSNotificationCenter.defaultCenter removeObserver:self];
    [self removeFromSuperview];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end

TV_EXPORT HWND ListLoad(HWND parent, char *file, int flags) {
    (void)flags; NSString *path=Path(file);
    if (!Supported(path)) return NULL;
    __block TVView *view;
    OnMain(^{
        NSView *host=(__bridge NSView *)parent;
        view=[[TVView alloc] initWithFrame:host?host.bounds:NSMakeRect(0,0,800,600)];
        if (host) [host addSubview:view];
        [view openPath:path];
    });
    return (HWND)CFBridgingRetain(view);
}
TV_EXPORT int ListLoadNext(HWND parent, HWND plugin, char *file, int flags) {
    (void)parent; (void)flags; NSString *path=Path(file);
    if (!plugin || !Supported(path)) return LISTPLUGIN_ERROR;
    OnMain(^{ [(__bridge TVView *)plugin openPath:path]; });
    return LISTPLUGIN_OK;
}
TV_EXPORT void ListCloseWindow(HWND plugin) {
    if (!plugin) return;
    OnMain(^{ TVView *view=CFBridgingRelease(plugin); [view close]; });
}
TV_EXPORT int ListSendCommand(HWND plugin, int command, int parameter) {
    (void)parameter; if (!plugin) return LISTPLUGIN_ERROR;
    __block int rc=LISTPLUGIN_ERROR;
    OnMain(^{
        TVView *view=(__bridge TVView *)plugin;
        if (command==lc_copy) rc=[view copySelection]?LISTPLUGIN_OK:LISTPLUGIN_ERROR;
        else if (command==lc_selectall) { [view.grid selectAll:nil]; rc=LISTPLUGIN_OK; }
        else if (command==lc_newparams) rc=LISTPLUGIN_OK;
    });
    return rc;
}
TV_EXPORT int ListSearchTextW(HWND plugin, const uint16_t *text, int flags) {
    if (!plugin || !text) return LISTPLUGIN_ERROR;
    NSUInteger len=0; while (text[len] && len<32768) len++;
    NSString *query=[[NSString alloc] initWithCharacters:text length:len];
    OnMain(^{ [(__bridge TVView *)plugin search:query flags:flags]; });
    return LISTPLUGIN_OK;
}
TV_EXPORT void ListGetDetectString(char *buffer, int length) {
    if (!buffer || length<=0) return;
    strncpy(buffer,kDetect,length-1); buffer[length-1]=0;
}
TV_EXPORT void ListSetDefaultParams(ListDefaultParamStruct *params) { (void)params; }
