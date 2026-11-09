/* Exercise the BUILT dylib through the WLX ABI: actual parsing, selection,
 * clipboard, search, navigation, bounded previews and stale-load cancellation. */
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#include <fenv.h>
#import <objc/message.h>
#include "../listplug.h"
static int failures;
static void Check(BOOL ok,const char *message) { printf("%s %s\n",ok?"PASS":"FAIL",message); if(!ok) failures++; }
static void Pump(double seconds) {
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while (until.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
static BOOL Wait(id view) {
    NSDate *limit=[NSDate dateWithTimeIntervalSinceNow:20];
    while ([[view valueForKey:@"loading"] boolValue] && limit.timeIntervalSinceNow>0) Pump(0.01);
    return ![[view valueForKey:@"loading"] boolValue];
}
static NSEvent *Mouse(NSView *view,NSInteger row,NSInteger col,NSEventType type,NSEventModifierFlags mods) {
    NSPoint p=[view convertPoint:NSMakePoint(56+col*160+30,26+row*26+12) toView:nil];
    return [NSEvent mouseEventWithType:type location:p modifierFlags:mods timestamp:0 windowNumber:view.window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
}
static void Select(NSView *grid,NSInteger r,NSInteger c,BOOL extend) {
    [grid mouseDown:Mouse(grid,r,c,NSEventTypeLeftMouseDown,extend?NSEventModifierFlagShift:0)];
}
static void WithHostFPTraps(void (^call)(void)) {
    fenv_t saved;
    fegetenv(&saved);
#if defined(__arm64__)
    uint64_t fpcr;
    __asm__ volatile("mrs %0, fpcr" : "=r"(fpcr));
    fpcr |= (1ull << 8) | (1ull << 9) | (1ull << 10);   /* IOE, DZE, OFE */
    __asm__ volatile("msr fpcr, %0" : : "r"(fpcr));
#elif defined(__x86_64__)
    uint32_t mxcsr;
    __asm__ volatile("stmxcsr %0" : "=m"(mxcsr));
    mxcsr &= ~((1u << 7) | (1u << 9) | (1u << 10));     /* unmask IM, ZM, OM */
    __asm__ volatile("ldmxcsr %0" : : "m"(mxcsr));
#endif
    call();
    fesetenv(&saved);
}

int main(int argc,char **argv) {
    @autoreleasepool {
        NSString *base=NSBundle.mainBundle.bundlePath.stringByDeletingLastPathComponent;
        NSString *plugin=[base stringByAppendingPathComponent:@"TableView.wlx"], *samples=[base stringByAppendingPathComponent:@"samples"];
        char *defaultArgs[]={"test_host",(char*)plugin.fileSystemRepresentation,(char*)samples.fileSystemRepresentation};
        if(argc==1) {
            argv=defaultArgs; argc=3;
            freopen([[base stringByAppendingPathComponent:@"gui-tests.log"] fileSystemRepresentation],"w",stdout);
            setbuf(stdout,NULL);
            freopen([[base stringByAppendingPathComponent:@"gui-errors.log"] fileSystemRepresentation],"w",stderr);
        }
        if(argc!=3) return 2;
        [NSApplication sharedApplication];
        void *lib=dlopen(argv[1],RTLD_NOW); if(!lib){fprintf(stderr,"%s\n",dlerror());return 2;}
        HWND (*load)(HWND,char*,int)=dlsym(lib,"ListLoad");
        int (*next)(HWND,HWND,char*,int)=dlsym(lib,"ListLoadNext");
        void (*close)(HWND)=dlsym(lib,"ListCloseWindow");
        int (*command)(HWND,int,int)=dlsym(lib,"ListSendCommand");
        int (*search)(HWND,const uint16_t*,int)=dlsym(lib,"ListSearchTextW");
        void (*detect)(char*,int)=dlsym(lib,"ListGetDetectString");
        char tiny[2]={0}; detect(tiny,2); Check(tiny[1]==0,"detect string honors buffer size");
        detect(NULL,0);
        NSWindow *win=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,800,500) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        win.releasedWhenClosed=NO;
        NSView *host=win.contentView;
        NSString *dir=[NSString stringWithUTF8String:argv[2]];
        NSString *(^File)(NSString*)=^NSString*(NSString *name){return [dir stringByAppendingPathComponent:name];};
        Check(load((__bridge HWND)host,(char*)File(@"other.txt").fileSystemRepresentation,0)==NULL,"unsupported extension falls through");
        __block HWND handle;
        WithHostFPTraps(^{ handle=load((__bridge HWND)host,(char*)File(@"sample.csv").fileSystemRepresentation,0); });
        id view=(__bridge id)handle; Check(handle && Wait(view),"CSV loading completes");
        NSView *grid=[view valueForKey:@"grid"];
        NSArray *(^Rows)(void)=^NSArray*{return [grid valueForKey:@"rows"];};
        Check(Rows().count==4 && [Rows()[1][2] isEqual:@"A, B"],"quoted commas parsed");
        Check([Rows()[2][2] isEqual:@"line one\nline two"],"quoted multiline cell preserved");
        Check([Rows()[3][0] isEqual:@"00123"],"CSV leading zeros preserved");
        Check([Rows()[3][2] isEqual:@"<script>alert(1)</script>"],"markup remains literal text");
        Select(grid,1,0,NO); Select(grid,2,1,YES);
        Check([[grid valueForKey:@"anchorRow"] integerValue]==1 && [[grid valueForKey:@"endCol"] integerValue]==1,"Shift-click rectangular range");
        Check(command(handle,lc_copy,0)==0,"copy command accepted");
        NSString *clip=[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
        Check([clip isEqual:@"Alpha\t42\nBeta\t0"],"Cmd+C ABI copies TSV rectangle without chrome");
        Select(grid,2,2,NO); command(handle,lc_copy,0);
        Check([[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] isEqual:@"\"line one\nline two\""],"clipboard quotes embedded newlines");
        [grid mouseDown:Mouse(grid,1,0,NSEventTypeLeftMouseDown,0)];
        [grid mouseDragged:Mouse(grid,3,2,NSEventTypeLeftMouseDragged,0)];
        Check([[grid valueForKey:@"endRow"] integerValue]==3 && [[grid valueForKey:@"endCol"] integerValue]==2,"mouse drag selects correct cells");
        command(handle,lc_selectall,0);
        Check([[grid valueForKey:@"endRow"] integerValue]==3 && [[grid valueForKey:@"endCol"] integerValue]==2,"select-all covers data only");
        uint16_t beta[]={'B','e','t','a',0}; search(handle,beta,lcs_findfirst);
        Check([[grid valueForKey:@"endRow"] integerValue]==2 && [[grid valueForKey:@"endCol"] integerValue]==0,"ABI find locates cell");
        uint16_t name[]={'n','a','m','e',0}; search(handle,name,lcs_findfirst|lcs_backwards);
        Check([[grid valueForKey:@"endRow"] integerValue]==0,"backward search and case folding");
        for(NSString *ext in @[@"xlsx",@"xlsm",@"xlsb",@"xls",@"ods",@"fods",@"dif",@"slk",@"dbf"]) {
            next(NULL,handle,(char*)File([@"sample." stringByAppendingString:ext]).fileSystemRepresentation,0);
            Check(Wait(view) && Rows().count>=4 && [Rows()[1][0] isEqual:@"Alpha"],[[NSString stringWithFormat:@"%@ decoded through built plugin",ext] UTF8String]);
            if([@[@"xlsx",@"xlsm",@"xlsb",@"xls"] containsObject:ext]) {
                Check([Rows()[4][0] isEqual:@"84"] && [Rows()[4][1] isEqual:@"2024-01-01"] && [Rows()[4][2] isEqual:@"$12.50"],"cached formula, date and currency display");
                NSPopUpButton *picker=[view valueForKey:@"sheetsMenu"];
                [picker selectItemAtIndex:1]; [NSApp sendAction:picker.action to:picker.target from:picker];
                Check([Rows()[0][0] isEqual:@"Other sheet"],"worksheet switching changes data");
            }
        }
        next(NULL,handle,(char*)File(@"sample.numbers").fileSystemRepresentation,0);
        Check(Wait(view) && Rows().count>=2 && [Rows()[1][0] isEqual:@"Apple sample"] && [Rows()[1][1] isEqual:@"42"],"Numbers IWA file decoded");
        for(NSString *name in @[@"semicolon.csv",@"utf16.tsv",@"cp1252.csv"]) {
            next(NULL,handle,(char*)File(name).fileSystemRepresentation,0); Wait(view);
            Check(Rows().count==2 && [Rows()[1][1] isEqual:@"42"],[[NSString stringWithFormat:@"%@ delimiter / encoding",name] UTF8String]);
        }
        Check([Rows()[1][0] isEqual:@"Café"],"Windows-1252 decoded accurately");
        next(NULL,handle,(char*)File(@"quotes.csv").fileSystemRepresentation,0); Wait(view);
        Check([Rows()[1][0] isEqual:@"007"] && [Rows()[1][1] isEqual:@"He said \"hello\""] && [Rows()[1][2] isEqual:@""] && [Rows()[2][1] isEqual:@"a\tb"],"escaped quotes, trailing empty cells and embedded tab");
        next(NULL,handle,(char*)File(@"directive.csv").fileSystemRepresentation,0); Wait(view);
        Check(Rows().count==2 && [Rows()[1][1] isEqual:@"42"],"Excel separator directive");
        next(NULL,handle,(char*)File(@"wide.csv").fileSystemRepresentation,0); Wait(view);
        Check(Rows().count==1 && [Rows()[0] count]==512 && [[[view valueForKey:@"status"] stringValue] containsString:@"truncated"],"wide CSV bounded before materializing extra cells");
        next(NULL,handle,(char*)File(@"long.csv").fileSystemRepresentation,0); Wait(view);
        Check([Rows()[0][0] length]==32768,"individual text value limit");
        next(NULL,handle,(char*)File(@"incomplete.csv").fileSystemRepresentation,0); Wait(view);
        Check(Rows().count==0,"incomplete quoted field reports error");
        next(NULL,handle,(char*)File(@"large.csv").fileSystemRepresentation,0); Wait(view);
        Check(Rows().count==100000 && [[[view valueForKey:@"status"] stringValue] containsString:@"truncated"],"large preview bounded and visibly marked");
        next(NULL,handle,(char*)File(@"broken.xlsx").fileSystemRepresentation,0); Wait(view);
        Check(Rows().count==0 && [[[view valueForKey:@"status"] stringValue] containsString:@"archive"],"corrupt archive fails cleanly");
        next(NULL,handle,(char*)File(@"repeated.fods").fileSystemRepresentation,0); Wait(view);
        Check(Rows().count==3 && [Rows()[0][2] isEqual:@"Third column"] && [Rows()[2][0] isEqual:@"7"],"hand-authored ODF sparse and repeated cells");
        next(NULL,handle,(char*)File(@"repeated-values.fods").fileSystemRepresentation,0); Wait(view);
        Check([Rows()[0][0] isEqual:@"x"] && [Rows()[0][2] isEqual:@"x"] && [Rows()[0][3] isEqual:@"Third column"],"repeated ODF columns beyond reported range preserved");
        for(NSString *bad in @[@"oversized.ods",@"oversized.csv",@"repetition-bomb.fods",@"repetition-bomb.ods",@"alias-bomb.fods",@"spaces-bomb.fods",@"renamed-bomb.xls"]) {
            next(NULL,handle,(char*)File(bad).fileSystemRepresentation,0); Wait(view);
            Check(Rows().count==0 && ![[view valueForKey:@"sheets"] count],"oversized input rejected before rendering");
        }
        next(NULL,handle,(char*)File(@"xml-looking.csv").fileSystemRepresentation,0); Wait(view);
        Check(Rows().count>0 && [Rows()[0][0] containsString:@"xml"],"CSV cannot invoke XML workbook decoder");
        next(NULL,handle,(char*)File(@"empty.csv").fileSystemRepresentation,0); Wait(view);
        Check(Rows().count==0,"empty file does not invent cells");
        next(NULL,handle,(char*)File(@"large.csv").fileSystemRepresentation,0);
        next(NULL,handle,(char*)File(@"sample.tsv").fileSystemRepresentation,0); Wait(view);
        Check(Rows().count==2 && [Rows()[1][0] isEqual:@"Alpha"],"superseded load cannot replace current document");
        uint16_t alpha[]={'A','l','p','h','a',0};
        next(NULL,handle,(char*)File(@"sample.csv").fileSystemRepresentation,0);
        search(handle,alpha,lcs_findfirst); search(handle,beta,0); Wait(view);
        Check([[grid valueForKey:@"endRow"] integerValue]==2,"searches during loading stay ordered");
        [view setFrameSize:NSMakeSize(480,320)]; [view layoutSubtreeIfNeeded];
        NSBitmapImageRep *rep=[view bitmapImageRepForCachingDisplayInRect:[view bounds]];
        [view cacheDisplayInRect:[view bounds] toBitmapImageRep:rep];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[dir stringByAppendingPathComponent:@"snapshot.png"] atomically:YES];
        Check(rep.pixelsWide>0,"real grid rendering snapshot");
        next(NULL,handle,(char*)File(@"large.csv").fileSystemRepresentation,0); close(handle); Pump(0.3);
        Check([(NSView*)view superview]==nil,"close cancels pending display handoff");
        printf("RESULT: %s (%d failures)\n",failures?"FAIL":"PASS",failures);
        return failures?1:0;
    }
}
