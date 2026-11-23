// Locale bridge: libarchive's string conversion follows the C locale,
// which is ASCII-only until setlocale runs. UTF-8 names must never be
// "untranslatable", so every entry point switches to a UTF-8 locale
// first (idempotent).
#include <locale.h>

#include "include/CArchive.h"

static int dizun_locale_ready = 0;

void dizun_archive_use_utf8_locale(void) {
    if (!dizun_locale_ready) {
        if (setlocale(LC_ALL, "en_US.UTF-8") == NULL) {
            setlocale(LC_CTYPE, "UTF-8");
        }
        dizun_locale_ready = 1;
    }
}
