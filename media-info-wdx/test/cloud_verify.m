/* Actual WDX ABI with only filesystem availability interposed. No cloud account
 * or downloads: synthetic flags model eviction while preserving file mtime. */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <sys/resource.h>

#include "../contplug.h"
extern const char *probePath;
extern BOOL offline, statError, sawPolicy, nonlocal;
static int failures;
static void Check(BOOL ok,const char *label) { printf("%s %s\n",ok?"PASS":"FAIL",label); if(!ok) failures++; }
int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=2) return 2;
    void *lib=dlopen(argv[1],RTLD_NOW); if(!lib){fprintf(stderr,"%s\n",dlerror());return 2;}
    int (*get)(char*,int,int,void*,int,int)=dlsym(lib,"ContentGetValue");
    int (*field)(int,char*,char*,int)=dlsym(lib,"ContentGetSupportedField");
    int width=-1,version=-1; char name[128],units[128];
    for(int i=0;field(i,name,units,sizeof(name))!=ft_nomorefields;i++) {
        if(strcmp(name,"Width")==0) width=i;
        if(strcmp(name,"Plugin version")==0) version=i;
    }
    Check(width>=0 && version>=0,"WDX fields discovered");
    NSString *dir=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *path=[dir stringByAppendingPathComponent:@"cloud.png"];
    CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx=CGBitmapContextCreate(NULL,320,200,8,0,cs,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGImageRef image=CGBitmapContextCreateImage(ctx);
    CGImageDestinationRef dst=CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],CFSTR("public.png"),1,NULL);
    CGImageDestinationAddImage(dst,image,NULL);CGImageDestinationFinalize(dst);
    CFRelease(dst);CGImageRelease(image);CGContextRelease(ctx);CGColorSpaceRelease(cs);
    probePath=path.fileSystemRepresentation;
    int original=getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,IOPOL_SCOPE_THREAD);
    for(NSNumber *policy in @[@(IOPOL_MATERIALIZE_DATALESS_FILES_ON),@(IOPOL_MATERIALIZE_DATALESS_FILES_OFF)]) {
        Check(setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,IOPOL_SCOPE_THREAD,policy.intValue)==0,"host policy configured");
        offline=YES; int32_t out=12345; sawPolicy=NO;
        Check(get((char*)probePath,width,0,&out,sizeof(out),0)==ft_fieldempty && out==12345 && sawPolicy,"cloud-only file skipped without touching value buffer");
        Check(get((char*)probePath,width,0,&out,sizeof(out),CONTENT_DELAYIFSLOW)==ft_fieldempty,"cloud-only file skipped for deferred request too");
        offline=NO;
        Check(get((char*)probePath,width,0,&out,sizeof(out),0)==ft_numeric_32 && out==320,"downloaded file yields metadata after earlier skip");
        offline=YES;
        Check(get((char*)probePath,width,0,&out,sizeof(out),0)==ft_fieldempty,"eviction hides cached metadata even with unchanged mtime");
        statError=YES; offline=NO;
        Check(get((char*)probePath,width,0,&out,sizeof(out),0)==ft_fieldempty,"unavailable parent or EDEADLK safely skips metadata");
        statError=NO;
        Check(get((char*)probePath,width,0,&out,sizeof(out),0)==ft_numeric_32 && out==320,"local metadata recovers after availability error");
        nonlocal=YES;
        Check(get((char*)probePath,width,0,&out,sizeof(out),0)==ft_fieldempty,"network volume skips metadata even for a cached file");
        nonlocal=NO;
        char text[64]={0}; offline=YES;
        Check(get((char*)probePath,version,0,text,sizeof(text),0)==ft_string,"version remains available for a cloud-only file");
        Check(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,IOPOL_SCOPE_THREAD)==policy.intValue,"host thread policy restored on every path");
    }
    NSString *audio=[dir stringByAppendingPathComponent:@"cloud.mp3"];
    [NSFileManager.defaultManager copyItemAtPath:path toPath:audio error:NULL];
    probePath=audio.fileSystemRepresentation; offline=YES;
    int32_t ignored=0;
    Check(get((char*)probePath,width,0,&ignored,sizeof(ignored),CONTENT_DELAYIFSLOW)==ft_fieldempty,
        "cloud-only AVFoundation file is skipped before delayed-work scheduling");
    offline=NO;
    Check(get((char*)probePath,width,0,&ignored,sizeof(ignored),CONTENT_DELAYIFSLOW)==ft_delayed,
        "local uncached AVFoundation file still uses normal delayed work");
    setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,IOPOL_SCOPE_THREAD,original);
    probePath=NULL; [NSFileManager.defaultManager removeItemAtPath:dir error:NULL];
    printf("RESULT: %s (%d failures)\n",failures?"FAIL":"PASS",failures);return failures?1:0;
}}
