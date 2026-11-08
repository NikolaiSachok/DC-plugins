/* Real-artifact PDF scrolling, vector rendering, zoom, copy and navigation.
 * usage: pdf_verify <ImageView.wlx> <output-directory> */
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
static int failures;
static void check(BOOL ok, const char *name) { printf("%s %s\n", ok ? "PASS" : "FAIL", name); if (!ok) failures++; }
static void pump(void) { for (int i=0;i<20;i++) {
    NSEvent *e=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]
        inMode:NSDefaultRunLoopMode dequeue:YES]; if(e) [NSApp sendEvent:e];
}}
static NSView *find(NSView *v, NSString *name) { if([NSStringFromClass(v.class) isEqual:name]) return v;
    for(NSView *c in v.subviews) { NSView *r=find(c,name); if(r) return r; } return nil; }
static void key(NSView *v, unsigned short code, unichar ch, NSEventModifierFlags flags) {
    NSString *s=[NSString stringWithCharacters:&ch length:1];
    [v keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0
        windowNumber:v.window.windowNumber context:nil characters:s charactersIgnoringModifiers:s isARepeat:NO keyCode:code]];
}
int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=3) return 2;
    [NSApplication sharedApplication];
    /* Preserve the user's clipboard, as copy_verify does. */
    NSMutableArray *saved=[NSMutableArray array];
    for (NSPasteboardItem *original in NSPasteboard.generalPasteboard.pasteboardItems) {
        NSPasteboardItem *item=[[NSPasteboardItem alloc] init];
        for (NSString *type in original.types) {
            NSData *data=[original dataForType:type]; if(data) [item setData:data forType:type];
        }
        [saved addObject:item];
    }
    NSString *dir=@(argv[2]);
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *path=[dir stringByAppendingPathComponent:@"pages.pdf"];
    CGRect box=CGRectMake(40,30,600,800);
    CGContextRef ctx=CGPDFContextCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],&box,NULL);
    for(int i=0;i<3;i++) {
        NSDictionary *props=i==1 ? @{ @"Rotate":@90 } : @{};
        CGPDFContextBeginPage(ctx,(__bridge CFDictionaryRef)props);
        CGContextSetRGBFillColor(ctx,i==0?1:0,i==1?1:0,i==2?1:0,1);
        CGContextFillRect(ctx,box);
        CGPDFContextEndPage(ctx);
    }
    CGPDFContextClose(ctx); CGContextRelease(ctx);
    void *h=dlopen(argv[1],RTLD_NOW); if(!h) {puts(dlerror());return 2;}
    void *(*load)(void*,char*,int)=dlsym(h,"ListLoad");
    int (*next)(void*,void*,char*,int)=dlsym(h,"ListLoadNext");
    void (*closeView)(void*)=dlsym(h,"ListCloseWindow");
    int (*command)(void*,int,int)=dlsym(h,"ListSendCommand");
    void (*detect)(char*,int)=dlsym(h,"ListGetDetectString");
    char extensions[4096]; detect(extensions,sizeof extensions); check(strstr(extensions,"EXT=\"PDF\"")!=NULL,"detects PDF");
    NSWindow *win=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,800,500) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    [win orderFront:nil];
    void *handle=load((__bridge void*)win.contentView,(char*)path.fileSystemRepresentation,2);
    check(handle!=NULL,"opens PDF"); if(!handle) return 1;
    NSView *view=(__bridge NSView*)handle, *canvas=find(view,@"IVCanvas");
    NSScrollView *scroll=(id)find(view,@"IVScrollView"); pump();
    check(fabs(NSHeight(canvas.frame)-2232)<1 && fabs(NSWidth(canvas.frame)-800)<1,
        "continuous pages respect rotated page geometry");
    check(NSMinY(scroll.contentView.bounds)<1,"opens at first page");
    CGFloat fit=scroll.magnification;
    check(fit>0.5 && fit<0.7,"fits first page rather than whole document");
    key(canvas,121,NSPageDownFunctionKey,NSEventModifierFlagFunction);
    CGFloat down=NSMinY(scroll.contentView.bounds);
    check(down>100,"PgDown scrolls document");
    key(canvas,116,NSPageUpFunctionKey,NSEventModifierFlagFunction);
    check(NSMinY(scroll.contentView.bounds)<down,"PgUp scrolls back");
    key(canvas,24,'=',NSEventModifierFlagCommand); check(scroll.magnification>fit,"Cmd+= zooms in");
    key(canvas,27,'-',NSEventModifierFlagCommand); check(scroll.magnification<1,"Cmd+- zooms out");
    key(canvas,29,'0',NSEventModifierFlagCommand); check(fabs(scroll.magnification-1)<0.001,"Cmd+0 actual size");
    key(canvas,119,NSEndFunctionKey,NSEventModifierFlagFunction);
    check(fabs(NSMaxY(scroll.contentView.bounds)-NSHeight(canvas.frame))<1,"End reaches final page");
    key(canvas,115,NSHomeFunctionKey,NSEventModifierFlagFunction); check(fabs(NSMinY(scroll.contentView.bounds))<1,"Home reaches first page");
    int copied=command(handle,1,0);
    check(copied==0 && [NSPasteboard.generalPasteboard dataForType:NSPasteboardTypePDF].length>0,"Cmd+C copies original PDF");
    NSBitmapImageRep *rep=[canvas bitmapImageRepForCachingDisplayInRect:NSMakeRect(0,0,600,800)];
    [canvas cacheDisplayInRect:NSMakeRect(0,0,600,800) toBitmapImageRep:rep];
    NSColor *pixel=[[rep colorAtX:300 y:400] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];

    check(pixel.redComponent>0.9 && pixel.greenComponent<0.2,"PDF content rendered at crop-box origin");
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[dir stringByAppendingPathComponent:@"first-page.png"] atomically:YES];
    NSString *bad=[dir stringByAppendingPathComponent:@"broken.pdf"];
    [@"not a PDF" writeToFile:bad atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    check(load(NULL,(char*)bad.fileSystemRepresentation,0)==NULL,"invalid PDF falls through");
    check(next(NULL,handle,(char*)bad.fileSystemRepresentation,0)==1,"failed navigation preserves current PDF");
    check(next(NULL,handle,(char*)path.fileSystemRepresentation,2)==0,"next PDF reuses view");
    for (int flags=2; flags<=34; flags+=32) {
        next(NULL,handle,(char*)path.fileSystemRepresentation,flags);
        key(canvas,119,NSEndFunctionKey,NSEventModifierFlagFunction);
        [view setFrameSize:NSMakeSize(850,650)];
        check(NSMinY(scroll.contentView.bounds)>1000,"fit resize preserves PDF reading position");
        [view setFrameSize:NSMakeSize(800,500)];
    }
    check(next(NULL,handle,(char*)path.fileSystemRepresentation,0)==0 &&
        fabs(NSMinY(scroll.contentView.bounds))<1,"actual size also opens at top");
    NSString *png=[dir stringByAppendingPathComponent:@"first-page.png"];
    check(next(NULL,handle,(char*)png.fileSystemRepresentation,2)==0,"PDF to image navigation");
    check(next(NULL,handle,(char*)path.fileSystemRepresentation,2)==0,"image to PDF navigation");
    NSString *locked=[dir stringByAppendingPathComponent:@"locked.pdf"];
    ctx=CGPDFContextCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:locked],&box,
        (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGPDFContextUserPassword:@"test-password",
            (__bridge NSString *)kCGPDFContextOwnerPassword:@"owner-password"});
    CGPDFContextBeginPage(ctx,NULL);CGPDFContextEndPage(ctx);CGPDFContextClose(ctx);CGContextRelease(ctx);
    check(load(NULL,(char*)locked.fileSystemRepresentation,0)==NULL,"password-locked PDF falls through");
    closeView(handle);
    [NSPasteboard.generalPasteboard clearContents];
    if(saved.count) [NSPasteboard.generalPasteboard writeObjects:saved];
    puts(failures?"RESULT: FAIL":"RESULT: PASS"); return failures?1:0;
}}
