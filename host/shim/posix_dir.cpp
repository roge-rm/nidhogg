#include "posix_dir.h"

#include <dirent.h>
#include <strings.h>
#include <sys/stat.h>

#include <cstring>

namespace posix_dir
{

std::string resolve(const std::string& root, const char* fatfs_path)
{
    std::string p(fatfs_path ? fatfs_path : "");
    if(p.size() >= 2 && p[1] == ':')
        p = p.substr(2);
    std::string out = root;
    size_t      i   = 0;
    while(i < p.size())
    {
        while(i < p.size() && p[i] == '/')
            i++;
        size_t j = p.find('/', i);
        if(j == std::string::npos)
            j = p.size();
        if(j == i)
            break;
        std::string comp = p.substr(i, j - i);
        i                = j;
        if(comp == ".")
            continue;
        struct stat st;
        if(stat((out + "/" + comp).c_str(), &st) != 0)
        {
            if(DIR* d = opendir(out.c_str()))
            {
                while(dirent* e = readdir(d))
                    if(strcasecmp(e->d_name, comp.c_str()) == 0)
                    {
                        comp = e->d_name;
                        break;
                    }
                closedir(d);
            }
        }
        out += "/" + comp;
    }
    return out;
}

void* open(const std::string& path)
{
    return opendir(path.c_str());
}

bool next(void* d, std::string& name, bool& is_dir, uint64_t& size)
{
    DIR* dir = static_cast<DIR*>(d);
    while(dirent* e = readdir(dir))
    {
        if(!std::strcmp(e->d_name, ".") || !std::strcmp(e->d_name, ".."))
            continue;
        struct stat st;
        if(fstatat(dirfd(dir), e->d_name, &st, 0) != 0)
            continue;
        name   = e->d_name;
        is_dir = S_ISDIR(st.st_mode);
        size   = uint64_t(st.st_size);
        return true;
    }
    return false;
}

void rewind(void* d)
{
    rewinddir(static_cast<DIR*>(d));
}

void close(void* d)
{
    closedir(static_cast<DIR*>(d));
}

} // namespace posix_dir
