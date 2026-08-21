#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

struct fb_info_t {
  uint8_t magic;
  uint16_t width;
  uint16_t height;
  uint16_t pitch;
  uint8_t bpp;
  uint32_t *addr;
} __arttribute__((packed));
#define FB_INFO ((struct fb_info_t *)0x7900)
