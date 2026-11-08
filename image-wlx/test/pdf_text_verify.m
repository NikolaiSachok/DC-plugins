/* Text selection through the real WLX artifact, including rotated/cropped pages.
 * usage: pdf_text_verify <ImageView.wlx> <output-dir> [--no-clipboard] [--document <pdf>]
 * The optional flag runs geometry/event checks in a session without pasteboard access. */
#import <Cocoa/Cocoa.h>
#import <PDFKit/PDFKit.h>
#include <dlfcn.h>
@interface NSView (PluginZoom)
- (void)zoomIn:(id)sender;
@end
static int failures;
static void check(BOOL ok, const char *name) { printf("%s %s\n",ok?"PASS":"FAIL",name); if(!ok) failures++; }
static NSView *find(NSView *v, NSString *name) { if([NSStringFromClass(v.class) isEqual:name]) return v;
 for(NSView *c in v.subviews) { NSView *r=find(c,name); if(r) return r; } return nil; }
static void pump(void) { for(int i=0;i<15;i++) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]]; }
static NSEvent *mouse(NSView *canvas,NSPoint point,NSEventType type,NSInteger count,NSEventModifierFlags mods) {
 return [NSEvent mouseEventWithType:type location:[canvas convertPoint:point toView:nil] modifierFlags:mods
 timestamp:0 windowNumber:canvas.window.windowNumber context:nil eventNumber:0 clickCount:count pressure:1];
}
/* Fixture has crop/media origin (40,30). The second page rotates clockwise by
 * 90 degrees: its horizontal axis follows original y, its vertical axis x. */
static NSPoint canvasPoint(PDFPage *page,NSUInteger index,NSUInteger character,NSArray<NSValue*> *rects) {
 NSRect b=[[page selectionForRange:NSMakeRange(character,1)] boundsForPage:page], r=rects[index].rectValue;
 CGFloat x=NSMidX(b)-40,y=NSMidY(b)-30;
 return index==1 ? NSMakePoint(NSMinX(r)+y,NSMinY(r)+x)
                 : NSMakePoint(NSMinX(r)+x,NSMaxY(r)-y);
}
int main(int argc,char **argv) { @autoreleasepool {
 if(argc<3) return 2;
 BOOL clipboard=YES;
 NSString *external=nil;
 for(int i=3;i<argc;i++) {
  if(strcmp(argv[i],"--no-clipboard")==0) clipboard=NO;
  else if(strcmp(argv[i],"--document")==0 && i+1<argc) external=@(argv[++i]);
 }
 [NSApplication sharedApplication];
 NSMutableArray *saved=[NSMutableArray array];
 if(clipboard) for(NSPasteboardItem *original in NSPasteboard.generalPasteboard.pasteboardItems) {
  NSPasteboardItem *item=[[NSPasteboardItem alloc] init];for(NSString *type in original.types) {
   NSData *d=[original dataForType:type];if(d) [item setData:d forType:type]; } [saved addObject:item];
 }
 NSString *dir=@(argv[2]); [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
 NSString *path=[dir stringByAppendingPathComponent:@"selectable.pdf"];
 CGRect box=CGRectMake(40,30,600,800);
 CGContextRef ctx=CGPDFContextCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],&box,NULL);
 for(int i=0;i<2;i++) {
  CGPDFContextBeginPage(ctx,(__bridge CFDictionaryRef)(i==1?@{@"Rotate":@90}:@{}));
  [NSGraphicsContext saveGraphicsState];
  NSGraphicsContext.currentContext=[NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
  [@"Office ﬁeld efficiency" drawAtPoint:NSMakePoint(70,740) withAttributes:@{NSFontAttributeName:[NSFont fontWithName:@"Times-Roman" size:18],NSLigatureAttributeName:@2}];
  [@"Alpha beta gamma delta" drawAtPoint:NSMakePoint(70,700) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:18]}];
  [@"Second line of selectable text" drawAtPoint:NSMakePoint(70,660) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:18]}];
  [NSGraphicsContext restoreGraphicsState];CGPDFContextEndPage(ctx);
 }
 CGPDFContextClose(ctx);CGContextRelease(ctx);
 void *h=dlopen(argv[1],RTLD_NOW);if(!h){puts(dlerror());return 2;}
 void *(*load)(void*,char*,int)=dlsym(h,"ListLoad");
 int (*command)(void*,int,int)=dlsym(h,"ListSendCommand");
 int (*next)(void*,void*,char*,int)=dlsym(h,"ListLoadNext");
 void (*closeView)(void*)=dlsym(h,"ListCloseWindow");
 NSWindow *win=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,900,700) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];[win orderFront:nil];
 void *handle=load((__bridge void*)win.contentView,(char*)path.fileSystemRepresentation,2);
 check(handle!=NULL,"opens text PDF");if(!handle)return 1;
 NSView *view=(__bridge NSView*)handle,*canvas=find(view,@"IVCanvas");
 NSScrollView *scroll=(id)find(view,@"IVScrollView");pump();
 PDFDocument *doc=[canvas valueForKeyPath:@"pdf.pdfTextDocument"];
 NSArray<NSValue *> *rects=[canvas valueForKeyPath:@"pdf.pageRects"];
 check([doc.string containsString:@"Alpha beta gamma delta"],"fixture exposes native PDF text");
 for(NSUInteger i=0;i<2;i++) {
  PDFPage *page=[doc pageAtIndex:i];
  NSRange beta=[page.string rangeOfString:@"beta"];
  NSPoint start=canvasPoint(page,i,beta.location,rects),end=canvasPoint(page,i,beta.location+3,rects);
  [canvas scrollPoint:NSMakePoint(0,rects[i].rectValue.origin.y)]; pump();
  [canvas mouseDown:mouse(canvas,start,NSEventTypeLeftMouseDown,1,0)];
  [canvas mouseDragged:mouse(canvas,end,NSEventTypeLeftMouseDragged,1,0)];
  [canvas mouseUp:mouse(canvas,end,NSEventTypeLeftMouseUp,1,0)];
  PDFSelection *selection=[canvas valueForKey:@"textSelection"];
  check([selection.string containsString:@"et"],i?"drag selects text on rotated page":"drag selects text at nonzero page origin");
  [canvas mouseDown:mouse(canvas,end,NSEventTypeLeftMouseDown,1,0)];
  [canvas mouseDragged:mouse(canvas,start,NSEventTypeLeftMouseDragged,1,0)];
  [canvas mouseUp:mouse(canvas,start,NSEventTypeLeftMouseUp,1,0)];
  check([[(PDFSelection*)[canvas valueForKey:@"textSelection"] string] containsString:@"et"],"backward drag selects text");
  [canvas mouseDown:mouse(canvas,start,NSEventTypeLeftMouseDown,2,0)];
  check([[[(PDFSelection*)[canvas valueForKey:@"textSelection"] string] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] isEqual:@"beta"],"double click selects a word");
 }
 PDFPage *firstPage=[doc pageAtIndex:0];
 NSPoint linePoint=canvasPoint(firstPage,0,[firstPage.string rangeOfString:@"Alpha"].location+2,rects);
 [canvas mouseDown:mouse(canvas,linePoint,NSEventTypeLeftMouseDown,3,0)];
 check([[(PDFSelection*)[canvas valueForKey:@"textSelection"] string] containsString:@"Alpha beta gamma delta"],"triple click selects a line");
 NSPoint margin=NSMakePoint(700,linePoint.y);
 [canvas mouseDown:mouse(canvas,linePoint,NSEventTypeLeftMouseDown,1,0)];
 [canvas mouseDragged:mouse(canvas,margin,NSEventTypeLeftMouseDragged,1,0)];
 [canvas mouseUp:mouse(canvas,margin,NSEventTypeLeftMouseUp,1,0)];
 check([[(PDFSelection*)[canvas valueForKey:@"textSelection"] string] containsString:@"delta"],"drag into margin includes line ending");
 [scroll setMagnification:0.25];pump();
 NSPoint first=canvasPoint([doc pageAtIndex:0],0,0,rects);
 NSPoint last=canvasPoint([doc pageAtIndex:1],1,15,rects);
 [canvas mouseDown:mouse(canvas,last,NSEventTypeLeftMouseDown,1,0)];
 [canvas mouseDragged:mouse(canvas,first,NSEventTypeLeftMouseDragged,1,0)];
 [canvas mouseUp:mouse(canvas,first,NSEventTypeLeftMouseUp,1,0)];
 check([(PDFSelection *)[canvas valueForKey:@"textSelection"] pages].count==2,"backward selection crosses page boundary");
 PDFPage *copyPage=[doc pageAtIndex:0];
 NSPoint copyPoint=canvasPoint(copyPage,0,[copyPage.string rangeOfString:@"beta"].location,rects);
 [canvas mouseDown:mouse(canvas,copyPoint,NSEventTypeLeftMouseDown,2,0)];
 if(clipboard) check(command(handle,1,0)==0 && [[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] containsString:@"beta"],"WLX Cmd+C copies selected text");
 check(command(handle,3,0)==0 && [[(PDFSelection*)[canvas valueForKey:@"textSelection"] string] containsString:@"Second line"],"WLX Cmd+A selects document text");
 CGFloat zoom=scroll.magnification;
 [view zoomIn:nil];
 check(scroll.magnification>zoom && [[(PDFSelection*)[canvas valueForKey:@"textSelection"] string] containsString:@"Alpha"],"selection survives zoom");
 NSBitmapImageRep *rep=[canvas bitmapImageRepForCachingDisplayInRect:NSMakeRect(0,0,800,800)];
 [canvas cacheDisplayInRect:NSMakeRect(0,0,800,800) toBitmapImageRep:rep];
 [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[dir stringByAppendingPathComponent:@"selection.png"] atomically:YES];
 [scroll setMagnification:1];
 [canvas mouseDown:mouse(canvas,NSMakePoint(400,400),NSEventTypeLeftMouseDown,1,NSEventModifierFlagOption)];
 check([[canvas valueForKey:@"dragging"] boolValue],"Option-drag retains hand panning");
 [canvas mouseUp:mouse(canvas,NSMakePoint(400,400),NSEventTypeLeftMouseUp,1,NSEventModifierFlagOption)];
 check(next(NULL,handle,(char*)path.fileSystemRepresentation,2)==0 && [canvas valueForKey:@"textSelection"]==nil,"navigation clears previous text selection");
 if(clipboard) check(command(handle,1,0)==0 && [NSPasteboard.generalPasteboard dataForType:NSPasteboardTypePDF].length>0,"without selection Cmd+C still copies PDF");
 closeView(handle);
 if(external) {
  handle=load((__bridge void*)win.contentView,(char*)external.fileSystemRepresentation,2);
  check(handle!=NULL,"opens optional document");
  if(handle) {
   view=(__bridge NSView*)handle;canvas=find(view,@"IVCanvas");
   doc=[canvas valueForKeyPath:@"pdf.pdfTextDocument"];
   NSArray<NSValue*> *pages=[canvas valueForKeyPath:@"pdf.pageRects"];
   CGPDFDocumentRef raw=(__bridge CGPDFDocumentRef)[canvas valueForKeyPath:@"pdf.pdfDocument"];
   NSRegularExpression *words=[NSRegularExpression regularExpressionWithPattern:@"\\S+" options:0 error:NULL];
   NSUInteger checked=0,wrong=0;
   for(NSUInteger i=0;i<doc.pageCount;i++) {
    PDFPage *page=[doc pageAtIndex:i];NSString *text=page.string ?: @"";
    NSRect frame=pages[i].rectValue;
    CGAffineTransform transform=CGPDFPageGetDrawingTransform(CGPDFDocumentGetPage(raw,i+1),kCGPDFCropBox,
        CGRectMake(0,0,NSWidth(frame),NSHeight(frame)),0,true);
    for(NSTextCheckingResult *word in [words matchesInString:text options:0 range:NSMakeRange(0,text.length)]) {
     if(word.range.length<3) continue;
     PDFSelection *expected=[page selectionForRange:word.range];NSRect bounds=[expected boundsForPage:page];
     if(NSIsEmptyRect(bounds) || expected.selectionsByLine.count!=1) continue;
     NSPoint a=NSMakePoint(NSMinX(bounds)-0.5,NSMidY(bounds)),b=NSMakePoint(NSMaxX(bounds)+0.5,NSMidY(bounds));
     CGPoint pa=CGPointApplyAffineTransform(NSPointToCGPoint(a),transform),pb=CGPointApplyAffineTransform(NSPointToCGPoint(b),transform);
     NSPoint start=NSMakePoint(NSMinX(frame)+pa.x,NSMaxY(frame)-pa.y),end=NSMakePoint(NSMinX(frame)+pb.x,NSMaxY(frame)-pb.y);
     [canvas scrollRectToVisible:NSInsetRect(NSMakeRect(MIN(start.x,end.x),MIN(start.y,end.y),fabs(end.x-start.x)+1,fabs(end.y-start.y)+1),-4,-4)];
     [canvas mouseDown:mouse(canvas,start,NSEventTypeLeftMouseDown,1,0)];
     [canvas mouseDragged:mouse(canvas,end,NSEventTypeLeftMouseDragged,1,0)];
     [canvas mouseUp:mouse(canvas,end,NSEventTypeLeftMouseUp,1,0)];
     PDFSelection *actual=[canvas valueForKey:@"textSelection"];
     NSString *token=[text substringWithRange:word.range];
     if(![actual.string containsString:token] || !NSIntersectsRect([actual boundsForPage:page],bounds)) wrong++;
     checked++;
    }
   }
   printf("Optional document: %lu word drags checked, %lu mismatches (content omitted)\n",(unsigned long)checked,(unsigned long)wrong);
   check(checked>0 && wrong==0,"document word drags select text under pointer");
   closeView(handle);
  }
 }
 if(clipboard){[NSPasteboard.generalPasteboard clearContents];if(saved.count)[NSPasteboard.generalPasteboard writeObjects:saved];}
 puts(failures?"RESULT: FAIL":"RESULT: PASS");return failures?1:0;
}}
