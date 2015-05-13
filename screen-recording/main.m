//
//  main.m
//  screen-recording
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import <Foundation/Foundation.h>
#import <AppKit/NSRunningApplication.h>
#import <AVFoundation/AVFoundation.h>
#import "RecordingDelegate.h"

AVCaptureSession* capture;

// Prints log message and exits the app.
// This always prints, even when not in debug mode.
// http://stackoverflow.com/questions/7254168/can-i-wrap-nslog-in-a-block-that-takes-a-variable-number-of-arguments
void logAndExit(NSString *formatString, ...) {
    va_list argumentList;
    va_start(argumentList, formatString);
    NSLogv(formatString, argumentList);
    va_end(argumentList);
    exit(-1);
}

void focusPidWithAppleScript(NSNumber* pidNumber) {
    // http://stackoverflow.com/questions/7925123/how-can-i-pass-a-string-from-applescript-to-objective-c
    // applescript code from: http://stackoverflow.com/a/2401792
    NSString* applescript = [NSString stringWithFormat:@"tell application \"System Events\"\n"
    "    set targets to every process whose unix id is %@\n"
    "    repeat with target in targets\n"
    "        set the frontmost of target to true\n"
    "    end repeat\n"
    "end tell", pidNumber];

    [[[NSAppleScript alloc] initWithSource:applescript] executeAndReturnError:nil ];
}

void focusPidWithAccessibilityApi(NSNumber* pidNumber){
    AXUIElementRef applicaitonRef = NULL;
    applicaitonRef = AXUIElementCreateApplication([pidNumber intValue]);
    if (applicaitonRef) {
        AXUIElementSetAttributeValue(applicaitonRef, kAXMainAttribute, kCFBooleanTrue);
        AXUIElementSetAttributeValue(applicaitonRef, kAXFrontmostAttribute, kCFBooleanTrue);
        CFRelease(applicaitonRef);
    }
}

void resetPosition(AXUIElementRef elementRef, CGRect *windowRect, int idx)
{
    Boolean isSettable = false;
    AXUIElementIsAttributeSettable(elementRef, kAXPositionAttribute, &isSettable);
    if (isSettable == true) {
        CGPoint     absWinPos = CGPointMake((idx-1)*(windowRect->size.width + 10),0);
        CGPoint     windowPosition;
        CFTypeRef   newPosition = AXValueCreate(kAXValueCGPointType, (void *)&absWinPos);
        CFTypeRef   position;
        
        NSLog(@"Reset position...");
        AXUIElementSetAttributeValue(elementRef, kAXPositionAttribute, newPosition);
        CFRelease(newPosition);
        
        // Get real window position
        AXUIElementCopyAttributeValue(elementRef, kAXPositionAttribute, &position);
        AXValueGetValue(position,kAXValueCGPointType,&windowPosition);
        CFRelease(position);
        
        windowRect->origin.x = windowPosition.x;
        windowRect->origin.y = windowPosition.y;
        NSLog(@"New Boulds: %@",[NSValue valueWithRect:*windowRect]);
    }
    else {
        NSLog(@"Can't set position...");
    }
}

void modifyWindowPositionByPid(pid_t pid, CGRect *windowRect, int idx)
{
    AXUIElementRef applicaitonRef = NULL;
    AXUIElementRef mainWindowRef = NULL;
    applicaitonRef = AXUIElementCreateApplication(pid);
    
    if (applicaitonRef) {
        AXUIElementCopyAttributeValue(applicaitonRef, kAXMainWindowAttribute, (CFTypeRef*)&mainWindowRef);
        if (mainWindowRef) {
            resetPosition(mainWindowRef, windowRect, idx);
        }
    }
    CFRelease(applicaitonRef);
}

// Print all owners to the console. Used for debugging.
void printOwners() {
    // code from https://github.com/square/zapp/blob/fcfb7fbd987cd44711e998f7071e414a88fa721c/Zapp/ZappVideoController.m#L24
    NSArray *windowList = objc_retainedObject(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    for (NSDictionary *info in windowList) {
        if (![[info objectForKey:(NSString *)kCGWindowName] isEqualToString:@""]) {
            Log(@"%@ pid: %@", [info objectForKey:(NSString *)kCGWindowOwnerName], [info objectForKey:(id)kCGWindowOwnerPID]);
        }
    }
}

BOOL checkDeviceNameFromWindowName(NSString *deviceName, NSString *windowName)
{
    NSString *comparePattern = [[NSString alloc] initWithFormat:@"iOS Simulator - %@ - ",deviceName];
    
    if ([windowName compare:comparePattern options:NSLiteralSearch range:NSMakeRange(0,[comparePattern length])] == 0) {
        return YES;
    }
    
    return NO;
}

BOOL simulatorCalulator(NSString *windowName, int *simulatorCounter)
{
    NSString *comparePattern = [[NSString alloc] initWithFormat:@"iOS Simulator "];
    if ([windowName compare:comparePattern options:NSLiteralSearch range:NSMakeRange(0,[comparePattern length])] == 0) {
        *simulatorCounter = *simulatorCounter + 1;
    }
    return YES;
}

extern void CGSInitialize(void);

// Locate window by owner name and return found, pid, bounds, and displayID.
//   found     - (NSNumber) 1 if we've found the window, 0 otherwise.
//   pid       - (NSNumber) the process id
//   bounds    - (NSValue) CGRect containing the window bounds
//   displayID - (NSNumber) the displayID that contains the found window
NSDictionary* findWindowBoundsAndPid(NSString* ownerName, NSString* deviceName) {
    // code from https://github.com/square/zapp/blob/fcfb7fbd987cd44711e998f7071e414a88fa721c/Zapp/ZappVideoController.m#L24
    CGDirectDisplayID displayID = 0;
    CGWindowID windowID = 0;
    int simulatorCounter = 0;
    //kCGWindowListOptionAll, kCGWindowListOptionOnScreenOnly
    NSArray *windowList = objc_retainedObject(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
    CGRect windowRect;
    for (NSDictionary *info in windowList) {
        NSString *WindowName = [info objectForKey:(NSString *)kCGWindowName];
        NSString *CGOwnerName = [info objectForKey:(NSString *)kCGWindowOwnerName];
        if ([CGOwnerName isEqualToString:ownerName] &&
            WindowName != NULL && ![WindowName isEqualToString:@""] &&
            simulatorCalulator(WindowName,&simulatorCounter) &&
            checkDeviceNameFromWindowName(deviceName, [info objectForKey:(NSString *)kCGWindowName])) {
            
            NSNumber* pid = [info objectForKey:(id)kCGWindowOwnerPID];
            
            CGSInitialize();
            windowID = [[info objectForKey:(NSString *)kCGWindowNumber] unsignedIntValue];
            CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)objc_unretainedPointer([info objectForKey:(NSString *)kCGWindowBounds]), &windowRect);
            
            modifyWindowPositionByPid([pid intValue], &windowRect, simulatorCounter);
            
            CGGetDisplaysWithRect(windowRect, 1, &displayID, NULL);
            
            return @{ @"found"  : windowID ? @YES : @NO, // NSNumber
                      @"pid"    : pid, // NSNumber
                      @"bounds" : [NSValue valueWithRect:windowRect],
                      @"displayID" : [NSNumber numberWithInt:displayID]
                    };
        }
    }

    return @{ @"found" : @NO };
}

NSDictionary* findWithRetry(NSString* ownerName, NSString* deviceName) {
    NSDictionary* result;
    for (int i = 0; i < 10; i++) {
        result = findWindowBoundsAndPid(ownerName,deviceName);

        // return if we've found a match, otherwise try again in a second.
        if ([[result objectForKey:@"found"] intValue]) {
            break;
        }
        [NSThread sleepForTimeInterval:1.0f];
    }

    return result;
}

// Locate iOS Window and return found, pid, bounds, and displayID.
NSDictionary* findiOSWindowBoundsAndPid(NSString *deviceName) {
    return findWithRetry(@"iOS Simulator",deviceName);
}

// Locate Android Window and return found, pid, bounds, and displayID.
NSDictionary* findAndroidWindowBoundsAndPid() {
    return findWithRetry(@"emulator64-x86",NULL);
}

// Deletes the file. Errors if the file is a directory or deletion fails.
void deleteFile(NSString* file) {
    NSFileManager* manager = [NSFileManager defaultManager];
    BOOL isDirectory;

    // Ensure file exists and isn't a directory before attempting removal.
    // isDeletableFileAtPath will return true even when the file doesn't exist.
    if ([manager fileExistsAtPath:file isDirectory:&isDirectory]) {
        if (isDirectory) { logAndExit(@"File must not be a directory. %@", file); }
        NSError* error;
        if (![manager removeItemAtPath:file error:&error]) {
            Log(@"Unable to delete file %@ Error: %@", file, [error localizedDescription]);
            exit(-1);
        }
    }
}

// Crops the display rect to contain only the window rect.
CGRect makeCropRect(int displayID, NSValue* windowValueWithRect) {
    // https://github.com/square/zapp/blob/fcfb7fbd987cd44711e998f7071e414a88fa721c/Zapp/ZappVideoController.m#L44
    CGRect windowRect = [windowValueWithRect rectValue];
    Log(@"makeCropRect: windowRect: %@", NSStringFromRect(NSRectFromCGRect((windowRect))));

    CGRect displayBounds = CGDisplayBounds(displayID);
    Log(@"makeCropRect: displayBounds: %@", NSStringFromRect(NSRectFromCGRect((displayBounds))));

    int x = windowRect.origin.x - displayBounds.origin.x;
    int y = displayBounds.size.height - displayBounds.origin.y - windowRect.origin.y - windowRect.size.height;
    int width = windowRect.size.width;
    int height = windowRect.size.height;
    return CGRectMake(x, y, width, height);
}

void stopRunning() {
    [capture stopRunning];
    // Must wait a few moments after ending or the movie will be corrupt.
    // the corruption is easy to reproduce when recording 10 seconds or less of video.
    [NSThread sleepForTimeInterval:5.0f];
    exit(0);
}

void run(NSString* os, NSString* path, NSString* deviceName) {
    #ifdef DEBUG
        NSLog(@"DEBUG mode enabled.");
    #endif
    deleteFile(path);

    NSDictionary* targetWindow;
    NSArray* validOS = @[@"ios", @"android"];
    switch ([validOS indexOfObject:os]) {
        case 0: // @"ios"
            targetWindow = findiOSWindowBoundsAndPid(deviceName);
            break;
        case 1: // @"android"
            targetWindow = findAndroidWindowBoundsAndPid();
            break;
        default:
            logAndExit(@"Unknown os: %@", os);
            break;
    }

    // only objects are stored in NSDictionary. no primitives
    // we must extract the int value of NSNumber to use as boolean
    // because a NSNumber of 0 is true. an int 0 is false.
    int found = [[targetWindow objectForKey:@"found"] intValue];
    Log(@"found: %i = %@", found, found ? @"Yes" : @"No");

    if (!found) {
        logAndExit(@"%@ window not found.", os);
    } else {
        Log(@"Found is true!");
    }

    NSNumber* pid = [targetWindow objectForKey:@"pid"];
    Log(@"pid: %@", pid);
    focusPidWithAccessibilityApi(pid);

    int displayID = [[targetWindow objectForKey:@"displayID"] intValue];
    Log(@"displayID: %i", displayID);

    NSValue* bounds = [targetWindow objectForKey:@"bounds"];
    Log(@"bounds: %@", bounds);

    CGRect cropRect = makeCropRect(displayID, bounds);
    Log(@"cropRect: %@", NSStringFromRect(NSRectFromCGRect((cropRect))));

    AVCaptureScreenInput* screen = [[AVCaptureScreenInput alloc] initWithDisplayID:displayID];
    screen.cropRect = cropRect;
    screen.removesDuplicateFrames = 1;
    screen.capturesCursor = 0;
    screen.capturesMouseClicks = 0;

    AVCaptureMovieFileOutput* movie = [[AVCaptureMovieFileOutput alloc] init];
    capture = [[AVCaptureSession alloc] init];
    
    // now that capture exists, register the exit signal handlers.
    signal(SIGTERM, stopRunning); // signal 15
    signal(SIGINT, stopRunning); // signal 2
    
    [capture beginConfiguration];
    [capture setSessionPreset:AVCaptureSessionPresetHigh];
    [capture addInput:screen];
    [capture addOutput:movie];
    [capture commitConfiguration];
    
    [capture startRunning];

    RecordingDelegate* delegate = [[RecordingDelegate alloc] init];
    
    [movie setDelegate:delegate];
    NSURL* pathURL = [NSURL fileURLWithPath:path];

    [movie startRecordingToOutputFileURL:pathURL recordingDelegate:delegate];
    
    // Only print recording once we've started to record.
    NSLog(@":: Recording %@ to %@", os, path);

    while (true) {
      [NSThread sleepForTimeInterval:10.0f];
    }
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            NSLog(@"Usage: ./screen-recording device /tmp/video.mov");
            exit(0);
        }

        //NSString* os = [NSString stringWithUTF8String:argv[1]]; // "ios"
        NSString* deviceName = [NSString stringWithUTF8String:argv[1]]; // "SimuitlDebug"
        NSString* path = [NSString stringWithUTF8String:argv[2]]; // "/tmp/video.mov"

        run(@"ios", path, deviceName);
    }

    return 0;
}