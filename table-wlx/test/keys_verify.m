/* Esc, unused viewer keys and focus policy through the actual built plugin.
 * The host records the freshly re-posted events, not direct keyDown forwarding.
 */
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#include "../listplug.h"
static int failures;
static void Check(BOOL ok,const char *label){printf("%s %s\n",ok?"PASS":"FAIL",label);if(!ok)failures++;}
static void Pump(void){NSDate *end=[NSDate dateWithTimeIntervalSinceNow:0.08];while(end.timeIntervalSinceNow>0){NSEvent *e=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:0.01] inMode:NSDefaultRunLoopMode dequeue:YES];if(e)[NSApp sendEvent:e];}}
@interface TestWindow:NSWindow
@property(nonatomic) BOOL key;
@end
@implementation TestWindow
- (BOOL)isKeyWindow{return self.key;}
@end
@interface Host:NSView
@property(nonatomic) NSInteger count;
@end
@implementation Host
- (BOOL)acceptsFirstResponder{return YES;}
- (void)keyDown:(NSEvent*)e{(void)e;self.count++;}
@end
static NSEvent *Key(NSWindow *win,unsigned short code,NSString *s,NSEventModifierFlags mods){return[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:mods timestamp:0 windowNumber:win.windowNumber context:nil characters:s charactersIgnoringModifiers:s isARepeat:NO keyCode:code];}
int main(int argc,char **argv){@autoreleasepool{
    NSString *base=NSBundle.mainBundle.bundlePath.stringByDeletingLastPathComponent;
    NSString *plugin=[base stringByAppendingPathComponent:@"TableView.wlx"], *sample=[base stringByAppendingPathComponent:@"samples/sample.csv"];
    char *defaults[]={"keys_verify",(char*)plugin.fileSystemRepresentation,(char*)sample.fileSystemRepresentation};
    if(argc==1){argv=defaults;argc=3;freopen([[base stringByAppendingPathComponent:@"gui-keys.log"]fileSystemRepresentation],"w",stdout);setbuf(stdout,NULL);}
    if(argc!=3)return 2;
    [NSApplication sharedApplication];
    void *lib=dlopen(argv[1],RTLD_NOW);if(!lib)return 2;
    HWND(*load)(HWND,char*,int)=dlsym(lib,"ListLoad");void(*close)(HWND)=dlsym(lib,"ListCloseWindow");
    TestWindow *win=[[TestWindow alloc]initWithContentRect:NSMakeRect(0,0,700,400) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];win.releasedWhenClosed=NO;
    Host *host=[[Host alloc]initWithFrame:NSMakeRect(0,0,700,400)];win.contentView=host;[win orderFront:nil];
    [win makeFirstResponder:host];
    HWND h=load((__bridge HWND)host,argv[2],0);id view=(__bridge id)h;NSView *grid=[view valueForKey:@"grid"];
    Pump();Check(win.firstResponder==host,"hidden viewer does not take focus early");
    win.key=YES;[NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidBecomeKeyNotification object:win];Pump();
    Check(win.firstResponder==grid,"key F3 viewer takes keyboard focus");
    for(NSNumber *code in @[@53,@45,@35,@12,@18]){
        NSInteger before=host.count;
        [grid keyDown:Key(win,code.unsignedShortValue,code.intValue==53?@"\e":@"n",0)];Pump();
        Check(host.count==before+1,"Esc / N / P / Q / digit re-posted through NSApplication");
    }
    [grid keyDown:Key(win,124,@"",NSEventModifierFlagOption)];Pump();Check(host.count==6,"Alt+Right handed to host");
    NSDate *limit=[NSDate dateWithTimeIntervalSinceNow:20];
    while([[view valueForKey:@"loading"]boolValue] && limit.timeIntervalSinceNow>0)Pump();
    [grid keyDown:Key(win,124,@"",NSEventModifierFlagShift)];
    Check([[grid valueForKey:@"anchorCol"]integerValue]==0 && [[grid valueForKey:@"endCol"]integerValue]==1,"Shift+arrow extends selected range");
    NSInteger before=host.count;[grid keyDown:Key(win,121,@"",0)];Check(host.count==before,"Page Down belongs to grid");
    close(h);
    NSView *panel=[[NSView alloc]initWithFrame:NSMakeRect(0,0,100,100)];[host addSubview:panel];
    NSTextField *field=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,90,24)];[panel addSubview:field];[win makeFirstResponder:field];NSResponder *focus=win.firstResponder;
    h=load((__bridge HWND)host,argv[2],0);Pump();Check(win.firstResponder==focus,"Quick View preserves panel control focus");close(h);
    printf("RESULT: %s (%d failures)\n",failures?"FAIL":"PASS",failures);return failures?1:0;
}}
