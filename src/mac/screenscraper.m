/*
 * Copyright 2013 Google Inc. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <wordexp.h>
#import "../screenscraper.h"
#import "../latency-benchmark.h"
#import <Cocoa/Cocoa.h>
#import <mach-o/dyld.h>


const float float_epsilon = 0.0001;
bool near_integer(float f) {
  return fabsf(remainderf(f, 1)) < float_epsilon;
}

static const CGWindowImageOption image_options =
    kCGWindowImageBestResolution | kCGWindowImageShouldBeOpaque;

screenshot *take_screenshot(uint32_t x, uint32_t y, uint32_t width,
    uint32_t height) {
  // TODO: support multiple monitors.
  NSScreen *screen = [[NSScreen screens] objectAtIndex:0];
  CGRect screen_rect = [screen convertRectToBacking:[screen frame]];
  CGRect capture_rect = { .origin.x = x, .origin.y = y, .size.width = width,
      .size.height = height };
  // Clamp to the screen.
  capture_rect = CGRectIntersection(capture_rect, screen_rect);
  // Convert to logical pixels from backing store pixels.
  CGRect converted_capture_rect = [screen convertRectFromBacking:capture_rect];
  // Make sure we are at an integer logical pixel to satisfy
  // CGWindowListCreateImage.
  if (!near_integer(converted_capture_rect.origin.x) ||
      !near_integer(converted_capture_rect.origin.y)) {
    debug_log(
        "Can't take screenshot at odd coordinates on a high DPI display.");
    return NULL;
  }
  // Round width/height up to the next logical pixel.
  converted_capture_rect.size.width = ceilf(converted_capture_rect.size.width);
  converted_capture_rect.size.height =
      ceilf(converted_capture_rect.size.height);
  // Update capture_rect with the final rounded values.
  capture_rect = [screen convertRectToBacking:converted_capture_rect];
  CGImageRef window_image = CGWindowListCreateImage(converted_capture_rect,
      kCGWindowListOptionAll, kCGNullWindowID, image_options);
  int64_t screenshot_time = get_nanoseconds();
  if (!window_image) {
    debug_log("CGWindowListCreateImage failed");
    return NULL;
  }
  size_t image_width = CGImageGetWidth(window_image);
  size_t image_height = CGImageGetHeight(window_image);
  assert(image_width == capture_rect.size.width);
  assert(image_height == capture_rect.size.height);
  size_t stride = CGImageGetBytesPerRow(window_image);
  // Assert 32bpp BGRA pixel format.
  size_t bpp = CGImageGetBitsPerPixel(window_image);
  size_t bpc = CGImageGetBitsPerComponent(window_image);
  CGBitmapInfo bitmap_info = CGImageGetBitmapInfo(window_image);
  // I think something will probably break if we're not little endian.
  assert(kCGBitmapByteOrder32Little == kCGBitmapByteOrder32Host);
  // We expect little-endian, alpha "first", which in reality comes out to BGRA
  // byte order.
  bool correct_byte_order =
      (bitmap_info & kCGBitmapByteOrderMask) == kCGBitmapByteOrder32Little;
  bool correct_alpha_location = bitmap_info & kCGBitmapAlphaInfoMask &
      (kCGImageAlphaFirst | kCGImageAlphaNoneSkipFirst |
       kCGImageAlphaPremultipliedFirst);
  if (bpp != 32 || bpc != 8 || !correct_byte_order || !correct_alpha_location) {
    debug_log("Incorrect image format from CGWindowListCreateImage. "
              "bpp = %d, bpc = %d, byte order = %s, alpha location = %s",
              bpp, bpc, correct_byte_order ? "correct" : "wrong",
              correct_alpha_location ? "correct" : "wrong");
    CFRelease(window_image);
    return NULL;
  }
  CFDataRef image_data =
      CGDataProviderCopyData(CGImageGetDataProvider(window_image));
  CFRelease(window_image);
  const uint8_t *pixels = CFDataGetBytePtr(image_data);
  screenshot *shot = (screenshot *)malloc(sizeof(screenshot));
  shot->width = (int32_t)image_width;
  shot->height = (int32_t)image_height;
  shot->stride = (int32_t)stride;
  shot->pixels = pixels;
  shot->time_nanoseconds = screenshot_time;
  shot->platform_specific_data = (void *)image_data;
  return shot;
}

void free_screenshot(screenshot *shot) {
  CFRelease((CFDataRef)shot->platform_specific_data);
  free(shot);
}

bool send_keystroke(int keyCode) {
  CGEventRef down = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)keyCode, true);
  CGEventRef up = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)keyCode, false);
  CGEventPost(kCGHIDEventTap, down);
  CGEventPost(kCGHIDEventTap, up);
  CFRelease(down);
  CFRelease(up);
  return true;
}

bool send_keystroke_b() { return send_keystroke(11); }
bool send_keystroke_t() { return send_keystroke(17); }
bool send_keystroke_w() { return send_keystroke(13); }
bool send_keystroke_z() { return send_keystroke(6); }

bool send_scroll_down(x, y) {
  CGFloat devicePixelRatio =
      [[[NSScreen screens] objectAtIndex:0] backingScaleFactor];
  CGWarpMouseCursorPosition(
      CGPointMake(x / devicePixelRatio, y / devicePixelRatio));
  CGEventRef scrollEvent = CGEventCreateScrollWheelEvent(NULL,
      kCGScrollEventUnitPixel, 1, -20);
  CGEventPost(kCGHIDEventTap, scrollEvent);
  CFRelease(scrollEvent);
  return true;
}

static AbsoluteTime start_time = { .hi = 0, .lo = 0 };
int64_t get_nanoseconds() {
  // TODO: Apple deprecated UpTime(), so switch to mach_absolute_time.
  if (UnsignedWideToUInt64(start_time) == 0) {
    start_time = UpTime();
    return 0;
  }
  return UnsignedWideToUInt64(AbsoluteDeltaToNanoseconds(UpTime(), start_time));
}

void debug_log(const char *message, ...) {
#ifdef DEBUG
  va_list list;
  va_start(list, message);
  vprintf(message, list);
  va_end(list);
  putchar('\n');
#endif
}

static pid_t browser_process_pid = 0;

bool open_browser(const char *program, const char *args, const char *url) {
  assert(url);
  if (browser_process_pid) {
    debug_log("Warning: calling open_browser, but browser already open.");
  }
  if (program == NULL) {
    return [[NSWorkspace sharedWorkspace] openURL:
            [NSURL URLWithString:[NSString stringWithUTF8String:url]]];
  }
  if (args == NULL) {
    args = "";
  }

  char command_line[4096];
  snprintf(command_line, sizeof(command_line), "'%s' %s '%s'", program, args, url);
  command_line[sizeof(command_line) - 1] = '\0';

  wordexp_t expanded_args;
  memset(&expanded_args, 0, sizeof(expanded_args));
  // On OS X, wordexp requires SIGCHLD. See: http://stackoverflow.com/questions/20534788/why-does-wordexp-fail-with-wrde-syntax-on-os-x
  signal(SIGCHLD, SIG_DFL);
  int result = wordexp(command_line, &expanded_args, 0);
  signal(SIGCHLD, SIG_IGN);
  if (result) {
    debug_log("Failed to parse command line: %s", command_line);
    return false;
  }
  browser_process_pid = fork();
  if (!browser_process_pid) {
    // child process, launch the browser!
    execv(expanded_args.we_wordv[0], expanded_args.we_wordv);
    exit(1);
  }
  wordfree(&expanded_args);
  return true;
}

bool close_browser() {
  if (browser_process_pid == 0) {
    debug_log("Browser not open");
    return false;
  }
  int r = kill(browser_process_pid, SIGKILL);
  browser_process_pid = 0;
  if (r) {
    debug_log("Failed to close browser window");
    return false;
  }
  return true;
}


pid_t window_process_pid = 0;

bool open_native_reference_window(uint8_t *test_pattern_for_window) {
  if (window_process_pid != 0) {
    debug_log("Native reference window already open");
    return false;
  }
  char path[2048];
  uint32_t length = sizeof(path);
  if (_NSGetExecutablePath(path, &length)) {
    debug_log("Couldn't find executable path");
    return false;
  }
  char hex_pattern[hex_pattern_length + 1];
  hex_encode_magic_pattern(test_pattern_for_window, hex_pattern);
  window_process_pid = fork();
  if (!window_process_pid) {
    // Child process. It would be nice to just call into Cocoa from here, but
    // Cocoa can't handle running after a call to fork(), so instead we must
    // restart the process.
    execl(path, path, "-p", hex_pattern, NULL);
  }
  // Parent process. Wait for the child to launch and show its window before
  // returning.
  usleep(2000000 /* 2 seconds */);
  return true;
}

bool close_native_reference_window() {
  if (window_process_pid == 0) {
    debug_log("Native reference window not open");
    return false;
  }
  int r = kill(window_process_pid, SIGKILL);
  window_process_pid = 0;
  if (r) {
    debug_log("Failed to close native reference window");
    return false;
  }
  return true;
}
