#ifndef DIZUN_CARCHIVE_H
#define DIZUN_CARCHIVE_H

// Thin umbrella over the vendored libarchive public headers. The static
// libraries themselves (libarchive.a, liblzma.a) come from the
// LibarchiveXCF / LiblzmaXCF binary targets; z/bz2 link Apple's SDK.

#include <archive.h>
#include <archive_entry.h>

#endif

// Switch libarchive's string conversion to UTF-8 (idempotent).
void dizun_archive_use_utf8_locale(void);
