//
//  SUDiskImageUnarchiver.m
//  Sparkle
//
//  Created by Andy Matuschak on 6/16/08.
//  Copyright 2008 Andy Matuschak. All rights reserved.
//

#import "SUDiskImageUnarchiver.h"
#import "SUUnarchiver_Private.h"
#import "SULog.h"
#include <CoreServices/CoreServices.h>

@implementation SUDiskImageUnarchiver

+ (BOOL)canUnarchivePath:(NSString *)path
{
    return [[path pathExtension] isEqualToString:@"dmg"];
}

+ (BOOL)unsafeIfArchiveIsNotValidated
{
    return NO;
}

// Called on a non-main thread.
- (void)extractDMG
{
	@autoreleasepool {
        BOOL mountedSuccessfully = NO;

        SULog(@"Extracting %@ as a DMG", self.archivePath);

        // get a unique mount point path
        NSString *mountPoint = nil;
        FSRef tmpRef;
        NSFileManager *manager;
        NSError *error;
        NSArray *contents;

        do
		{
            // Using NSUUID would make creating UUIDs be done in Cocoa,
            // and thus managed under ARC. Sadly, the class is in 10.8 and later.
            CFUUIDRef uuid = CFUUIDCreate(NULL);
			if (uuid)
			{
                NSString *uuidString = CFBridgingRelease(CFUUIDCreateString(NULL, uuid));
				if (uuidString)
				{
                    mountPoint = [@"/Volumes" stringByAppendingPathComponent:uuidString];
                }
                CFRelease(uuid);
            }
		}
		while (noErr == FSPathMakeRefWithOptions((const UInt8 *)[mountPoint fileSystemRepresentation], kFSPathMakeRefDoNotFollowLeafSymlink, &tmpRef, NULL));

        NSData *promptData = nil;
        promptData = [NSData dataWithBytes:"yes\n" length:4];

        NSMutableArray *arguments = [@[@"attach", self.archivePath, @"-mountpoint", mountPoint, /*@"-noverify",*/ @"-nobrowse", @"-noautoopen"] mutableCopy];

        if (self.decryptionPassword) {
            NSMutableData *passwordData = [[self.decryptionPassword dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
            // From the hdiutil docs:
            // read a null-terminated passphrase from standard input
            //
            // Add the null terminator, then the newline
            [passwordData appendData:[NSData dataWithBytes:"\0" length:1]];
            [passwordData appendData:promptData];
            promptData = passwordData;

            [arguments addObject:@"-stdinpass"];
        }

        NSData *output = nil;
        NSInteger taskResult = -1;
		@try
		{
            NSTask *task = [[NSTask alloc] init];
            task.launchPath = @"/usr/bin/hdiutil";
            task.currentDirectoryPath = @"/";
            task.arguments = arguments;
            
            NSPipe *inputPipe = [NSPipe pipe];
            NSPipe *outputPipe = [NSPipe pipe];
            
            task.standardInput = inputPipe;
            task.standardOutput = outputPipe;
            
            [task launch];
            
            [self notifyProgress:0.125];

            [inputPipe.fileHandleForWriting writeData:promptData];
            [inputPipe.fileHandleForWriting closeFile];
            
            // Read data to end *before* waiting until the task ends so we don't deadlock if the stdout buffer becomes full if we haven't consumed from it
            output = [outputPipe.fileHandleForReading readDataToEndOfFile];
            
            [task waitUntilExit];
            taskResult = task.terminationStatus;
        }
        @catch (NSException *)
        {
            goto reportError;
        }

        [self notifyProgress:0.5];

		if (taskResult != 0)
		{
            NSString *resultStr = output ? [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding] : nil;
            SULog(@"hdiutil failed with code: %ld data: <<%@>>", (long)taskResult, resultStr);
            goto reportError;
        }
        mountedSuccessfully = YES;

        // Now that we've mounted it, we need to copy out its contents.
        manager = [[NSFileManager alloc] init];
        contents = [manager contentsOfDirectoryAtPath:mountPoint error:&error];
		if (error)
		{
            SULog(@"Couldn't enumerate contents of archive mounted at %@: %@", mountPoint, error);
            goto reportError;
        }

        double itemsCopied = 0;
        double totalItems = [contents count];

		for (NSString *item in contents)
		{
            NSString *fromPath = [mountPoint stringByAppendingPathComponent:item];
            NSString *toPath = [[self.archivePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:item];

            // We skip any files in the DMG which are not readable.
            if (![manager isReadableFileAtPath:fromPath]) {
                continue;
            }

            itemsCopied += 1.0;
            [self notifyProgress:0.5 + itemsCopied/(totalItems*2.0)];
            SULog(@"copyItemAtPath:%@ toPath:%@", fromPath, toPath);

			if (![manager copyItemAtPath:fromPath toPath:toPath error:&error])
			{
                goto reportError;
            }
        }

        [self unarchiverDidFinish];
        goto finally;

    reportError:
        [self unarchiverDidFailWithError:error];

    finally:
        if (mountedSuccessfully) {
            @try {
                [NSTask launchedTaskWithLaunchPath:@"/usr/bin/hdiutil" arguments:@[@"detach", mountPoint, @"-force"]];
            } @catch (NSException *exception) {
                SULog(@"Failed to unmount %@", mountPoint);
                SULog(@"Exception: %@", exception);
            }
        } else {
            SULog(@"Can't mount DMG %@", self.archivePath);
        }
    }
}

- (void)unarchiveWithCompletionBlock:(void (^)(NSError * _Nullable))block progressBlock:(void (^ _Nullable)(double progress))progress
{
    [super unarchiveWithCompletionBlock:block progressBlock:progress];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		[self extractDMG];
    });
}

+ (void)load
{
    [self registerImplementation:self];
}

- (BOOL)isEncrypted:(NSData *)resultData
{
    BOOL result = NO;
	if(resultData)
	{
        NSString *data = [[NSString alloc] initWithData:resultData encoding:NSUTF8StringEncoding];

        if ((data != nil) && !NSEqualRanges([data rangeOfString:@"passphrase-count"], NSMakeRange(NSNotFound, 0)))
		{
            result = YES;
        }
    }
    return result;
}

@end
