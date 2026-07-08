#if __has_include(<libmtp.h>)
#include <libmtp.h>
#elif __has_include("/opt/homebrew/include/libmtp.h")
#include "/opt/homebrew/include/libmtp.h"
#elif __has_include("/usr/local/include/libmtp.h")
#include "/usr/local/include/libmtp.h"
#else
#error "libmtp.h not found. Install libmtp with Homebrew."
#endif
