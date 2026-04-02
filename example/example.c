/*
 * example.c - ffmpeg.dll 调用示例
 *
 * 编译 (VS2022 开发者命令行):
 *   cl example.c /link libffmpeg.dll.a
 *
 * 或者 LoadLibrary 方式（不需要 .lib）：
 *   cl example.c
 */

#include <stdio.h>
#include <windows.h>

/* ── 方式 1：直接链接 .lib ── */

/*
typedef void (__stdcall *LogCallback)(const char*);
extern int __stdcall ffmpeg_run(LogCallback cb, const char *cmd);

void __stdcall on_log(const char *msg) {
    printf("[ffmpeg] %s\n", msg);
}

int main(int argc, char *argv[]) {
    const char *cmd = argc > 1 ? argv[1] : "-version";
    int ret = ffmpeg_run(on_log, cmd);
    printf("Exit code: %d\n", ret);
    return ret;
}
*/

/* ── 方式 2：LoadLibrary（推荐，更灵活） ── */

typedef void (__stdcall *LogCallback)(const char*);
typedef int (__stdcall *FFmpegRunFunc)(LogCallback, const char*);

void __stdcall on_log(const char *msg) {
    printf("%s\n", msg);
}

int main(int argc, char *argv[]) {
    HMODULE hDll = LoadLibraryA("ffmpeg.dll");
    if (!hDll) {
        fprintf(stderr, "Cannot load ffmpeg.dll (error %lu)\n", GetLastError());
        return 1;
    }

    FFmpegRunFunc ffmpeg_run = (FFmpegRunFunc)GetProcAddress(hDll, "ffmpeg_run");
    if (!ffmpeg_run) {
        fprintf(stderr, "Cannot find ffmpeg_run export\n");
        FreeLibrary(hDll);
        return 1;
    }

    const char *cmd = argc > 1 ? argv[1] : "-version";
    int ret = ffmpeg_run(on_log, cmd);

    printf("\nExit code: %d\n", ret);
    FreeLibrary(hDll);
    return ret;
}
