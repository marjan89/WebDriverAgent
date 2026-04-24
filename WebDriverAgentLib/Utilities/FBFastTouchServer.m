/**
 * FBFastTouchServer — binary TCP socket for low-latency touch injection.
 * Bypasses HTTP/JSON/W3C entirely. Calls XCTest event synthesis directly.
 */

#import "FBFastTouchServer.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <XCTest/XCTest.h>

#import "XCSynthesizedEventRecord.h"
#import "XCPointerEventPath.h"
#import "XCTRunnerDaemonSession.h"
#import "XCTestManager_ManagerInterface-Protocol.h"

static const uint8_t CMD_TAP = 0x01;
static const uint8_t CMD_SWIPE = 0x02;
static const uint8_t CMD_BUTTON = 0x03;

static const uint8_t STATUS_OK = 0x00;
static const uint8_t STATUS_ERROR = 0x01;

#pragma pack(push, 1)
typedef struct {
    uint8_t cmd;
    float x;
    float y;
    float x2;
    float y2;
    float duration;
} FastTouchMessage;
#pragma pack(pop)

@implementation FBFastTouchServer

+ (void)startOnPort:(uint16_t)port
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [self runServerOnPort:port];
    });
}

+ (void)runServerOnPort:(uint16_t)port
{
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        NSLog(@"[FastTouch] socket() failed: %s", strerror(errno));
        return;
    }

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    // Disable Nagle's algorithm for minimum latency
    int flag = 1;
    setsockopt(server_fd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);

    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[FastTouch] bind() failed on port %d: %s", port, strerror(errno));
        close(server_fd);
        return;
    }

    listen(server_fd, 2);
    NSLog(@"[FastTouch] Listening on port %d (21-byte binary protocol)", port);

    while (1) {
        int client_fd = accept(server_fd, NULL, NULL);
        if (client_fd < 0) {
            NSLog(@"[FastTouch] accept() failed: %s", strerror(errno));
            continue;
        }

        // Disable Nagle on client socket too
        setsockopt(client_fd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));
        NSLog(@"[FastTouch] Client connected");

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            [self handleClient:client_fd];
        });
    }
}

+ (void)handleClient:(int)client_fd
{
    FastTouchMessage msg;
    while (1) {
        // Read exactly 21 bytes
        ssize_t total = 0;
        while (total < (ssize_t)sizeof(msg)) {
            ssize_t n = read(client_fd, ((uint8_t *)&msg) + total, sizeof(msg) - total);
            if (n <= 0) {
                NSLog(@"[FastTouch] Client disconnected");
                close(client_fd);
                return;
            }
            total += n;
        }

        uint8_t status = STATUS_OK;

        switch (msg.cmd) {
            case CMD_TAP:
                [self executeTapAtX:msg.x y:msg.y];
                break;
            case CMD_SWIPE:
                [self executeSwipeFromX:msg.x fromY:msg.y toX:msg.x2 toY:msg.y2 duration:msg.duration];
                break;
            case CMD_BUTTON:
                // Button presses handled via HTTP — not implemented here
                status = STATUS_ERROR;
                break;
            default:
                NSLog(@"[FastTouch] Unknown command: 0x%02x", msg.cmd);
                status = STATUS_ERROR;
                break;
        }

        // Send 1-byte response
        write(client_fd, &status, 1);
    }
}

+ (id<XCTestManager_ManagerInterface>)daemonProxy
{
    return ((XCTRunnerDaemonSession *)[XCTRunnerDaemonSession sharedSession]).daemonProxy;
}

+ (void)executeTapAtX:(float)x y:(float)y
{
    XCPointerEventPath *path = [[XCPointerEventPath alloc] initForTouchAtPoint:CGPointMake(x, y)
                                                                        offset:0.0];
    [path liftUpAtOffset:0.01];

    XCSynthesizedEventRecord *record = [[XCSynthesizedEventRecord alloc]
        initWithName:@"fast-tap"
        interfaceOrientation:0];
    [record addPointerEventPath:path];

    // Fire directly on the XPC proxy — no FBRunLoopSpinner, no waiting.
    // XPC dispatches on its own queue asynchronously.
    [[self daemonProxy] _XCT_synthesizeEvent:record
                                  completion:^(NSError *error) {
        if (error) NSLog(@"[FastTouch] tap error: %@", error);
    }];
}

+ (void)executeSwipeFromX:(float)fx fromY:(float)fy toX:(float)tx toY:(float)ty duration:(float)duration
{
    if (duration < 0.001) duration = 0.01;

    XCPointerEventPath *path = [[XCPointerEventPath alloc] initForTouchAtPoint:CGPointMake(fx, fy)
                                                                        offset:0.0];
    [path moveToPoint:CGPointMake(tx, ty) atOffset:duration];
    [path liftUpAtOffset:duration + 0.01];

    XCSynthesizedEventRecord *record = [[XCSynthesizedEventRecord alloc]
        initWithName:@"fast-swipe"
        interfaceOrientation:0];
    [record addPointerEventPath:path];

    [[self daemonProxy] _XCT_synthesizeEvent:record
                                  completion:^(NSError *error) {
        if (error) NSLog(@"[FastTouch] swipe error: %@", error);
    }];
}

@end
