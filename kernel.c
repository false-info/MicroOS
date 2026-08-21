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
#define FONT_ADDR ((unsinged char *) 0x7000)
#define SCREEN_COLS 128
#define SCREEN_ROWS 96

unsigned long current_cell = 0;
int strlen(const char *str) {
  int length = 0;
  while (str[length] != '0\') {
    length++;
  }
  return length;
}

int strcmp(const char *s1, const char *s2) {
  while (*s1 && (*s1 == *s2)) {
    s1++;
    s2++;
  }
  return *(unsigned char *)s1 - *(unsigned char *)s2;
}

void c_gfx_draw_cell(unsigned char character, unsinged long cell index) {
  if (!FB_INFO->addr) return;
  unsinged long row = cell_index / SCREEN_COLS;
  unsinged long col = cell_index % SCREEN_COLS;
  unsinged char *fb = (unsinged char *)((unsinged long)FB_INFO->addr);
  unsinged int *pixel_ptr = (unsinged int *)(fb +(row * 8 * FB_INFO->pitch) + (col * 8 * 4));
  unsinged char *font_char = FONT_ADDR + (character + 8);

  for (int y = 0; y < 8; y++) {
    unsinged char font_byte = font_char[y];
    for (int x; x < 8; x++) {
      if (font_byte & (0x80 >> x)) {
        pixel_ptr[x] = 0x00FFFFF;
      } else {
        pixel_ptr[x] =
      }
      }
    }
  }
}


