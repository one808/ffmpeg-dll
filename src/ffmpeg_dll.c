/*
 * ffmpeg_dll.c - FFmpeg DLL wrapper
 *
 * 导出一个函数：ffmpeg_run(callback, command)
 * 内部调用 FFmpeg 的 fftools 入口，日志通过回调返回
 */

#include "libavutil/log.h"
#include "libavutil/avstring.h"

#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdarg.h>

/* ── 类型定义 ── */

/* 日志回调：stdcall 约定，方便 C#/VB 等调用 */
typedef void (__stdcall *LogCallback)(const char*);

/* ── 外部符号 ── */

/* fftools/ffmpeg.c 的主入口 */
int ffmpeg_main(int argc, char **argv);

/* ── 全局状态 ── */

static LogCallback g_log_cb = NULL;

/* ── 日志转发 ── */

static void log_redirect(void *avcl, int level, const char *fmt, va_list vl)
{
    if (!g_log_cb)
        return;

    /* 过滤比当前级别低的日志 */
    if (level > av_log_get_level())
        return;

    char buf[4096];
    vsnprintf(buf, sizeof(buf), fmt, vl);

    /* 去掉尾部换行（回调约定） */
    size_t len = strlen(buf);
    while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r'))
        buf[--len] = '\0';

    g_log_cb(buf);
}

/* ── 命令行解析 ── */

/*
 * 把命令行字符串拆成 argc/argv，支持双引号。
 * 例如: "-i \"my file.mp4\" -c:v libx264 output.mp4"
 */
static int parse_command(const char *cmd, char ***argv_out)
{
    static char *argv[256];
    static char buf[8192];
    int argc = 0;
    const char *p = cmd;
    char *out = buf;

    /* argv[0] = "ffmpeg" (占位) */
    argv[argc++] = "ffmpeg";

    while (*p && argc < 255) {
        /* 跳过空白 */
        while (*p == ' ' || *p == '\t') p++;
        if (!*p) break;

        argv[argc] = out;
        int in_quote = 0;

        while (*p) {
            if (*p == '"') {
                in_quote = !in_quote;
                p++;
            } else if (*p == '\\' && p[1] == '"') {
                /* 转义引号 */
                *out++ = '"';
                p += 2;
            } else if ((*p == ' ' || *p == '\t') && !in_quote) {
                p++;
                break;
            } else {
                *out++ = *p++;
            }
        }
        *out++ = '\0';
        argc++;
    }

    *argv_out = argv;
    return argc;
}

/* ── 导出函数 ── */

/*
 * ffmpeg_run - 执行 FFmpeg 命令
 *
 * @callback: 日志回调，每行日志调用一次（可以为 NULL）
 * @command:  FFmpeg 命令行参数（不含 "ffmpeg" 本身）
 *
 * 返回值: FFmpeg 退出码（0 = 成功）
 *
 * 示例:
 *   ffmpeg_run(my_callback, "-i input.mp4 -c:v libx264 output.mp4");
 */
__declspec(dllexport)
int __stdcall ffmpeg_run(LogCallback callback, const char *command)
{
    if (!command || !*command)
        return -1;

    g_log_cb = callback;
    av_log_set_callback(log_redirect);

    char **argv;
    int argc = parse_command(command, &argv);

    int ret = ffmpeg_main(argc, argv);

    /* 清理 */
    g_log_cb = NULL;
    av_log_set_callback(av_log_default_callback);

    return ret;
}
