// FatFs API on plain files: the Chompi SD card is a folder (vhw::card_root()).
// Names match case-insensitively like FAT. FIL keeps fptr and obj.objsize up to
// date because the firmware reads them through f_tell/f_size/f_eof.
#include "ff.h"
#include "diskio.h"
#include "posix_dir.h"
#include "vhw.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <map>
#include <mutex>
#include <string>

namespace
{

std::mutex                 m_;
std::map<const FIL*, int>  files_;
std::map<const DIR*, void*> dirs_;

std::string resolve(const TCHAR* path)
{
    return posix_dir::resolve(vhw::card_root(), path);
}

FRESULT from_errno()
{
    switch(errno)
    {
        case ENOENT: return FR_NO_FILE;
        case ENOTDIR: return FR_NO_PATH;
        case EEXIST: return FR_EXIST;
        case EACCES:
        case EPERM: return FR_DENIED;
        default: return FR_DISK_ERR;
    }
}

int fd_of(const FIL* fp)
{
    std::lock_guard<std::mutex> l(m_);
    auto                        it = files_.find(fp);
    return it == files_.end() ? -1 : it->second;
}

void fill_info(FILINFO* fno, const char* name, bool is_dir, uint64_t size)
{
    if(!fno)
        return;
    std::memset(fno, 0, sizeof(*fno));
    fno->fsize   = FSIZE_t(size);
    fno->fattrib = is_dir ? AM_DIR : AM_ARC;
    std::strncpy(fno->fname, name, sizeof(fno->fname) - 1);
    std::strncpy(fno->altname, name, sizeof(fno->altname) - 1);
}

} // namespace

extern "C" {

FRESULT f_mount(FATFS* fs, const TCHAR* path, BYTE opt)
{
    struct stat st;
    return stat(vhw::card_root().c_str(), &st) == 0 ? FR_OK : FR_NOT_READY;
}

FRESULT f_open(FIL* fp, const TCHAR* path, BYTE mode)
{
    if(!fp)
        return FR_INVALID_OBJECT;
    std::memset(fp, 0, sizeof(*fp));
    int flags = (mode & FA_WRITE) ? ((mode & FA_READ) ? O_RDWR : O_WRONLY) : O_RDONLY;
    if(mode & FA_CREATE_ALWAYS)
        flags |= O_CREAT | O_TRUNC;
    else if(mode & FA_OPEN_ALWAYS)
        flags |= O_CREAT;
    else if(mode & FA_CREATE_NEW)
        flags |= O_CREAT | O_EXCL;
    int fd = ::open(resolve(path).c_str(), flags, 0644);
    if(fd < 0)
        return from_errno();
    struct stat st;
    fstat(fd, &st);
    fp->obj.objsize = FSIZE_t(st.st_size);
    fp->flag        = mode;
    fp->fptr        = 0;
    if(mode & FA_OPEN_APPEND)
        fp->fptr = fp->obj.objsize;
    std::lock_guard<std::mutex> l(m_);
    files_[fp] = fd;
    return FR_OK;
}

FRESULT f_close(FIL* fp)
{
    std::lock_guard<std::mutex> l(m_);
    auto                        it = files_.find(fp);
    if(it == files_.end())
        return FR_INVALID_OBJECT;
    ::close(it->second);
    files_.erase(it);
    return FR_OK;
}

FRESULT f_read(FIL* fp, void* buff, UINT btr, UINT* br)
{
    if(br)
        *br = 0;
    int fd = fd_of(fp);
    if(fd < 0)
        return FR_INVALID_OBJECT;
    ssize_t n = pread(fd, buff, btr, fp->fptr);
    if(n < 0)
        return FR_DISK_ERR;
    fp->fptr += n;
    if(br)
        *br = UINT(n);
    return FR_OK;
}

FRESULT f_write(FIL* fp, const void* buff, UINT btw, UINT* bw)
{
    if(bw)
        *bw = 0;
    int fd = fd_of(fp);
    if(fd < 0)
        return FR_INVALID_OBJECT;
    ssize_t n = pwrite(fd, buff, btw, fp->fptr);
    if(n < 0)
        return FR_DISK_ERR;
    fp->fptr += n;
    if(fp->fptr > fp->obj.objsize)
        fp->obj.objsize = fp->fptr;
    if(bw)
        *bw = UINT(n);
    return FR_OK;
}

FRESULT f_lseek(FIL* fp, FSIZE_t ofs)
{
    int fd = fd_of(fp);
    if(fd < 0)
        return FR_INVALID_OBJECT;
    if(ofs > fp->obj.objsize)
    {
        // FatFs grows a writable file to the new position, else stops at the end
        if(fp->flag & FA_WRITE)
        {
            if(ftruncate(fd, ofs) != 0)
                return FR_DISK_ERR;
            fp->obj.objsize = ofs;
        }
        else
            ofs = fp->obj.objsize;
    }
    fp->fptr = ofs;
    return FR_OK;
}

FRESULT f_truncate(FIL* fp)
{
    int fd = fd_of(fp);
    if(fd < 0)
        return FR_INVALID_OBJECT;
    if(ftruncate(fd, fp->fptr) != 0)
        return FR_DISK_ERR;
    fp->obj.objsize = fp->fptr;
    return FR_OK;
}

FRESULT f_sync(FIL* fp)
{
    return fd_of(fp) < 0 ? FR_INVALID_OBJECT : FR_OK;
}

FRESULT f_opendir(DIR* dp, const TCHAR* path)
{
    void* d = posix_dir::open(resolve(path));
    if(!d)
        return FR_NO_PATH;
    std::memset(dp, 0, sizeof(*dp));
    std::lock_guard<std::mutex> l(m_);
    dirs_[dp] = d;
    return FR_OK;
}

FRESULT f_closedir(DIR* dp)
{
    std::lock_guard<std::mutex> l(m_);
    auto                        it = dirs_.find(dp);
    if(it == dirs_.end())
        return FR_INVALID_OBJECT;
    posix_dir::close(it->second);
    dirs_.erase(it);
    return FR_OK;
}

FRESULT f_readdir(DIR* dp, FILINFO* fno)
{
    void* d;
    {
        std::lock_guard<std::mutex> l(m_);
        auto                        it = dirs_.find(dp);
        if(it == dirs_.end())
            return FR_INVALID_OBJECT;
        d = it->second;
    }
    if(!fno)
    {
        posix_dir::rewind(d);
        return FR_OK;
    }
    std::string name;
    bool        is_dir;
    uint64_t    size;
    if(posix_dir::next(d, name, is_dir, size))
        fill_info(fno, name.c_str(), is_dir, size);
    else
        std::memset(fno, 0, sizeof(*fno)); // end of directory: empty name
    return FR_OK;
}

FRESULT f_stat(const TCHAR* path, FILINFO* fno)
{
    struct stat st;
    std::string p = resolve(path);
    if(stat(p.c_str(), &st) != 0)
        return FR_NO_FILE;
    const char* name = std::strrchr(p.c_str(), '/');
    fill_info(fno, name ? name + 1 : p.c_str(), S_ISDIR(st.st_mode), uint64_t(st.st_size));
    return FR_OK;
}

FRESULT f_unlink(const TCHAR* path)
{
    std::string p = resolve(path);
    if(::unlink(p.c_str()) == 0 || ::rmdir(p.c_str()) == 0)
        return FR_OK;
    return from_errno();
}

FRESULT f_rename(const TCHAR* path_old, const TCHAR* path_new)
{
    std::string to = resolve(path_new);
    struct stat st;
    if(stat(to.c_str(), &st) == 0)
        return FR_EXIST; // FatFs doesn't overwrite
    return ::rename(resolve(path_old).c_str(), to.c_str()) == 0 ? FR_OK : from_errno();
}

FRESULT f_mkdir(const TCHAR* path)
{
    return ::mkdir(resolve(path).c_str(), 0755) == 0 ? FR_OK : from_errno();
}

DSTATUS disk_status(BYTE pdrv)
{
    struct stat st;
    return stat(vhw::card_root().c_str(), &st) == 0 ? 0 : STA_NODISK;
}

DWORD get_fattime(void)
{
    return 0;
}

} // extern "C"
