/**
 * FBFastTouchServer — binary TCP socket for low-latency touch injection.
 *
 * Protocol (little-endian):
 *   Request:  [cmd:u8][x:f32][y:f32][x2:f32][y2:f32][duration:f32] = 21 bytes
 *   Response: [status:u8] = 1 byte (0=ok, 1=error)
 *
 * Commands:
 *   0x01 = tap at (x, y)
 *   0x02 = swipe from (x, y) to (x2, y2) over duration seconds
 *   0x03 = press button (x=button: 1=home, 2=volumeUp, 3=volumeDown)
 */

#import <Foundation/Foundation.h>

@interface FBFastTouchServer : NSObject

+ (void)startOnPort:(uint16_t)port;

@end
