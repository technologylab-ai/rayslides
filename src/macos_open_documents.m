#import <Foundation/NSArray.h>
#import <Foundation/NSObject.h>
#import <Foundation/NSPathUtilities.h>
#import <Foundation/NSString.h>
#import <Foundation/NSURL.h>

#include <stdbool.h>
#include <stddef.h>
#include <string.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

static char rayslides_pending_document[PATH_MAX];

// Importing AppKit's umbrella headers pulls Security.framework internals that
// are unavailable in some command-line SDK layouts. This narrow declaration
// is the complete NSOpenPanel surface used below; AppKit still supplies the
// implementation at link/runtime.
@interface NSOpenPanel : NSObject
+ (instancetype)openPanel;
- (void)setCanChooseFiles:(BOOL)value;
- (void)setCanChooseDirectories:(BOOL)value;
- (void)setAllowsMultipleSelection:(BOOL)value;
- (void)setResolvesAliases:(BOOL)value;
- (void)setTitle:(NSString *)value;
- (void)setPrompt:(NSString *)value;
- (void)setAllowedFileTypes:(NSArray<NSString *> *)value;
- (void)setDirectoryURL:(NSURL *)value;
- (NSInteger)runModal;
- (NSURL *)URL;
@end

static bool rayslides_queue_document_path(NSString *path)
{
    if (path == nil || ![[path.pathExtension lowercaseString] isEqualToString:@"sld"])
        return false;
    const char *utf8 = path.fileSystemRepresentation;
    size_t length = strlen(utf8);
    if (length == 0 || length >= sizeof(rayslides_pending_document)) return false;
    memcpy(rayslides_pending_document, utf8, length + 1);
    return true;
}

// GLFW owns NSApp's delegate. Add only the document-opening callbacks to that
// existing object so its termination, screen-change, and window behavior stay
// untouched. LaunchServices uses this path for Finder double-click/Open With.
@interface GLFWApplicationDelegate : NSObject
@end

@interface GLFWApplicationDelegate (RayslidesDocuments)
- (BOOL)application:(id)sender openFile:(NSString *)filename;
- (void)application:(id)sender openFiles:(NSArray<NSString *> *)filenames;
@end

@protocol RayslidesApplicationReply
- (void)replyToOpenOrPrint:(NSUInteger)reply;
@end

@implementation GLFWApplicationDelegate (RayslidesDocuments)

- (BOOL)application:(id)sender openFile:(NSString *)filename
{
    (void)sender;
    return rayslides_queue_document_path(filename);
}

- (void)application:(id<RayslidesApplicationReply>)sender openFiles:(NSArray<NSString *> *)filenames
{
    bool accepted = false;
    for (NSString *filename in filenames) {
        if (rayslides_queue_document_path(filename)) {
            accepted = true;
            break;
        }
    }
    [sender replyToOpenOrPrint:accepted ? 0 : 2];
}

@end

void rayslides_macos_install_open_document_handler(void)
{
    // The category is installed when this object file loads. Keeping an
    // explicit Zig-facing hook makes the platform boundary obvious and stops
    // the linker from treating the translation unit as otherwise unused.
}

size_t rayslides_macos_take_open_document(char *buffer, size_t capacity)
{
    size_t length = strlen(rayslides_pending_document);
    if (length == 0 || capacity <= length) return 0;
    memcpy(buffer, rayslides_pending_document, length + 1);
    rayslides_pending_document[0] = '\0';
    return length;
}

size_t rayslides_macos_choose_media(bool video, const char *initial_directory, char *buffer, size_t capacity)
{
    @autoreleasepool {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        [panel setCanChooseFiles:YES];
        [panel setCanChooseDirectories:NO];
        [panel setAllowsMultipleSelection:NO];
        [panel setResolvesAliases:YES];
        [panel setTitle:video ? @"Choose a video" : @"Choose an image"];
        [panel setPrompt:@"Choose"];
        [panel setAllowedFileTypes:video
            ? @[@"mp4", @"mov", @"m4v", @"webm", @"mkv", @"avi", @"mpg", @"mpeg"]
            : @[@"png", @"jpg", @"jpeg", @"bmp", @"gif", @"tga", @"qoi", @"svg"]];

        if (initial_directory != NULL && initial_directory[0] != '\0') {
            NSString *directory = [NSString stringWithUTF8String:initial_directory];
            if (directory != nil)
                [panel setDirectoryURL:[NSURL fileURLWithPath:directory isDirectory:YES]];
        }

        // NSModalResponseOK is 1 on every supported macOS release.
        if ([panel runModal] != 1 || [panel URL] == nil) return 0;
        const char *path = [[[panel URL] path] fileSystemRepresentation];
        if (path == NULL) return 0;
        size_t length = strlen(path);
        if (length == 0 || capacity <= length) return 0;
        memcpy(buffer, path, length + 1);
        return length;
    }
}
