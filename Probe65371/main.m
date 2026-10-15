/*
 * main.m — Probe65371 entry point.
 *
 * Delegates to NSExtensionMain, which reads NSPrincipalClass from Info.plist
 * and calls -beginRequestWithExtensionContext: on ProbeExtensionController.
 */

#import <Foundation/Foundation.h>

extern int NSExtensionMain(int argc, char * _Nonnull argv[]);

int main(int argc, char *argv[]) {
    return NSExtensionMain(argc, argv);
}
