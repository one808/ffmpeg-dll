# ffmpeg.dll

把 FFmpeg 编译成一个 DLL，一条命令搞定：

```c
ffmpeg_run(log_callback, "-i input.mp4 -c:v libx264 output.mp4");
```

## 工作原理

```
你的代码 → ffmpeg.dll (导出 ffmpeg_run)
               ↓ 运行时链接
          avcodec.dll, avformat.dll, avutil.dll, ... (shared 版)
```

- **不需要 ffmpeg.exe**
- **不需要安装编译环境**（CI 自动编译）
- 产物：`ffmpeg.dll` + shared 依赖 DLL

## 导出函数

```c
typedef void (__stdcall *LogCallback)(const char*);

// 返回 FFmpeg 退出码（0 = 成功）
int __stdcall ffmpeg_run(LogCallback callback, const char *command);
```

| 参数 | 说明 |
|------|------|
| `callback` | 日志回调，每行调用一次，可为 NULL |
| `command` | FFmpeg 参数（不含 "ffmpeg"），如 `"-i a.mp4 b.mp4"` |

## 使用方法

### C/C++（LoadLibrary）

```c
typedef void (__stdcall *LogCallback)(const char*);
typedef int (__stdcall *FFmpegRunFunc)(LogCallback, const char*);

HMODULE hDll = LoadLibraryA("ffmpeg.dll");
FFmpegRunFunc run = (FFmpegRunFunc)GetProcAddress(hDll, "ffmpeg_run");

run(on_log, "-i input.mp4 -c:v libx264 -crf 23 output.mp4");
```

### C\#（P/Invoke）

```csharp
[DllImport("ffmpeg.dll", CallingConvention = CallingConvention.StdCall)]
static extern int ffmpeg_run(LogCallback cb, [MarshalAs(UnmanagedType.LPStr)] string cmd);

[UnmanagedFunctionPointer(CallingConvention.StdCall)]
delegate void LogCallback(IntPtr msg);

static void OnLog(IntPtr ptr) {
    Console.WriteLine(Marshal.PtrToStringAnsi(ptr));
}

// 调用
int ret = ffmpeg_run(OnLog, "-i input.mp4 -c:v libx264 output.mp4");
```

### Python（ctypes）

```python
import ctypes

lib = ctypes.CDLL("./ffmpeg.dll")
CbType = ctypes.CFUNCTYPE(None, ctypes.c_char_p)

def on_log(msg):
    print(msg.decode(), end="")

lib.ffmpeg_run.restype = ctypes.c_int
ret = lib.ffmpeg_run(CbType(on_log), b"-i input.mp4 output.mp4")
```

## 自动编译（GitHub Actions）

1. Fork 或创建仓库，推送代码
2. Actions 自动触发编译（win32 + shared）
3. 下载 `ffmpeg-dll-win32` artifact 或 Release

## 手动编译（需要 MSYS2 MinGW32）

```bash
# 安装工具链
pacman -S mingw-w64-i686-gcc nasm yasm

# Clone FFmpeg
git clone --depth=1 --branch=release/7.1 https://github.com/FFmpeg/FFmpeg.git
cd FFmpeg

# Configure
./configure \
  --target-os=mingw32 --arch=x86 \
  --cross-prefix=i686-w64-mingw32- \
  --enable-shared --disable-static \
  --disable-doc --disable-ffplay --disable-ffprobe

# 编译
make -j$(nproc) || true

# 生成 DLL
i686-w64-mingw32-gcc -O2 -I. -Ifftools -c ../src/ffmpeg_dll.c -o fftools/ffmpeg_dll.o
i686-w64-mingw32-gcc -shared -o ../ffmpeg.dll \
  fftools/*.o \
  -L/usr/local/lib \
  -lavcodec -lavformat -lavutil -lswscale -lswresample -lavfilter \
  -lws2_32 -lbcrypt \
  -Wl,--out-implib,../libffmpeg.dll.a
```

## 文件清单

```
├── .github/workflows/build.yml   CI 自动编译
├── src/ffmpeg_dll.c               Wrapper 源码
├── example/example.c              调用示例
└── README.md
```

## License

FFmpeg is LGPL/GPL. The wrapper code in `src/` is public domain.
