// POSIX directory access for ff_posix.cpp, kept apart because FatFs and
// <dirent.h> both define DIR.
#pragma once
#include <cstdint>
#include <string>

namespace posix_dir
{
// Path under `root` for a FatFs path, matching names case-insensitively.
std::string resolve(const std::string& root, const char* fatfs_path);
void*       open(const std::string& path);
// Next entry other than . and ..; false at the end.
bool next(void* d, std::string& name, bool& is_dir, uint64_t& size);
void rewind(void* d);
void close(void* d);
} // namespace posix_dir
