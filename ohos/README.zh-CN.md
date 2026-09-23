# Codex CLI 鸿蒙 ARM64 原生移植

基于本机安装的同版本 Codex CLI 0.153.4，上游提交
`3d2ee51ca2d5db578f328aa75e20aa22c0197c9a`。
源码位于 Windows `D:\AlProject\codex-ohos`，在 WSL 中对应
`/mnt/d/AlProject/codex-ohos`。

这是在鸿蒙终端中运行的原生命令行程序，不需要 Node.js。
既可在 WSL 交叉编译，也可在设备端（HiShell，host == target）原生构建。
已在正式系统设备上验证原生二进制可启动运行；命令沙箱受平台 seccomp
策略限制不可用，需以非沙箱模式运行（见「设备部署和验证」）。

## SDK

使用独立安装的 OpenHarmony 原生 SDK，按实际安装位置设置路径：

```sh
export OHOS_SDK_NATIVE=/path/to/openharmony/native
```

SDK 版本为 6.0.0.47 / API 20，目标为 `aarch64-unknown-linux-ohos`。
CLI 通过 Cargo 编译。
程序依赖设备系统提供的 `libc.so` 和 `libtime_service_ndk.so`。
SDK 中的同名文件是链接桩，不能作为运行库复制到设备。

## 在当前 WSL 环境重建

```sh
export CARGO_HOME=/home/yujihui/codex-ohos-tools/cargo
export RUSTUP_HOME=/home/yujihui/codex-ohos-tools/rustup
export PATH=/home/yujihui/codex-ohos-tools/bin:/home/yujihui/codex-ohos-tools/cargo/bin:$PATH
export CARGO_TARGET_DIR=/home/yujihui/codex-ohos-target
cd /mnt/d/AlProject/codex-ohos
export OHOS_LIBCAP_WORK_DIR=/home/yujihui/codex-ohos-tools/libcap-build
CARGO_TARGET_DIR=/home/yujihui/codex-ohos-bwrap-target bash ohos/build-bwrap.sh
export BINARY_SIGN_TOOL=/path/to/openharmony/toolchains/lib/binary-sign-tool
export BWRAP_BINARY=/home/yujihui/codex-ohos-bwrap-target/aarch64-unknown-linux-ohos/release/bwrap.signed
"$BINARY_SIGN_TOOL" sign -selfSign 1 \
  -inFile "${BWRAP_BINARY%.signed}" -outFile "$BWRAP_BINARY"
export CODEX_BWRAP_SHA256=$(sha256sum "$BWRAP_BINARY" | cut -d ' ' -f 1)
CARGO_PROFILE_RELEASE_LTO=false bash ohos/build.sh build release
python3 ohos/package.py "$CARGO_TARGET_DIR/aarch64-unknown-linux-ohos/release/codex" \
  --sdk-native "$OHOS_SDK_NATIVE" --name codex-ohos-arm64-0.153.4-signed \
  --sign-tool "$BINARY_SIGN_TOOL" \
  --bwrap "$BWRAP_BINARY" --libcap-license "$OHOS_LIBCAP_WORK_DIR/libcap-2.78/License"
```

编译产物为
`/home/yujihui/codex-ohos-target/aarch64-unknown-linux-ohos/release/codex`。
压缩包内包含 `codex-resources/bwrap` 和 libcap 的许可证。
为避免覆盖，打包脚本要求使用尚不存在的包目录名称。
可复用的构建和打包参数见 [英文说明](README.md)。

## 设备端原生构建（HiShell）

也可以在 ARM64 鸿蒙 PC 上直接原生编译（host == target），无需交叉 sysroot
和编译器包装脚本：Harmonybrew 工具链本身就以 OpenHarmony 为目标，SDK 封装的
`ld.lld` 在链接期自动签名。设备上的二进制正是这样产出并验证的。HiShell 内
一次性准备：

- 安装 [Harmonybrew](https://gitee.com/openharmony-sig/harmonybrew)，再
  `brew install llvm-gcc-compat ohos-sdk-native protobuf perl make cmake
  python3 git`。`llvm-gcc-compat` 提供 `cc`/`clang`；`protobuf` 提供已签名的
  `protoc`（vendored 的 `protoc` 未签名，在设备上无法执行）。鸿蒙裸用户态
  不含这些构建工具。
- `rustup` 是 keg-only：把 `$(brew --prefix rustup)/bin` 加入 `PATH`，再
  `rustup toolchain install 1.95.0`、`rustup target add
  aarch64-unknown-linux-ohos`。若默认 CDN 报 "could not download nonexistent
  rust version"，把 `RUSTUP_DIST_SERVER` 指向静态镜像（如
  `https://mirror.sjtu.edu.cn/rust-static`）。

然后在源码目录：

```sh
export OHOS_SDK_NATIVE="$(brew --prefix ohos-sdk-native)"   # 未设置时自动探测
export RUSTY_V8_ARCHIVE=/path/to/librusty_v8.a               # 复用交叉编译好的 V8
export RUSTY_V8_SRC_BINDING_PATH=/path/to/src_binding_ptrcomp_sandbox_release_aarch64-unknown-linux-ohos.rs
bash ohos/build-native.sh build dev          # 或 build release
export OHOS_LIBCAP_WORK_DIR="$HOME/codex-ohos-bwrap"
bash ohos/build-bwrap.sh                      # libcap + bwrap，链接期自动签名
cp "$OHOS_LIBCAP_WORK_DIR/cargo-target/aarch64-unknown-linux-ohos/release/bwrap" \
   "target-ohos/aarch64-unknown-linux-ohos/debug/codex-resources/bwrap"
```

`build-native.sh` 会导出 `PROTOC` 和 `LIBCLANG_PATH`，并装一个只屏蔽
`liblzma`、`bzip2` 的 `pkg-config` shim，让这两个 crate 回落到自带的静态源码，
而不是 Harmonybrew 的动态库（否则 CLI 会带上 `package.py` 拒绝的
`NEEDED liblzma.so.5`/`libbz2.so.1.0`）。共享的 `ohos-host-env.sh` 会遮蔽
PATH 上缺失的两个工具：`uname`（在鸿蒙上报 `OpenHarmony`，第三方 configure
脚本不识别）和 `install`（`/system/bin` 下的 toybox applet，libcap 的 makefile
需要它）。

若设备的 crates.io CDN 停滞，可从网速快的机器预填 cargo 缓存后离线构建：把
缺失的 `.crate`（`Cargo.lock` 中 `source` 为 registry 的包）拷进
`~/.cargo/registry/cache/index.crates.io-*/`，再导出 `CARGO_NET_OFFLINE=true`。
git 依赖仍需能访问 GitHub。

## 设备部署和验证

正式版鸿蒙电脑要求 ELF 代码签名。必须先给 bwrap 签名，再计算其
SHA-256 并重建 CLI；打包脚本先 strip CLI、再签名。签名后不可再修改
二进制文件，否则签名或沙箱完整性校验会失效。

设备还需允许“运行外部来源的扩展程序”，并使用具有相应权限的
DevBox/CodeArts IDE 等本机开发终端。普通 `uid=2000(shell)` 的 hdc
环境可能拒绝签名程序，返回 `Permission denied`（退出码 126）。
此时应通过获授权的本机终端运行，文件推送成功不能视为运行成功。
日常使用建议将签名包放入用户文档目录；华为文档中的传输目录为
`/storage/media/100/local/files/Docs`，本机终端中可见路径以设备为准。

将 `ohos/dist/` 中的压缩包传到允许执行原生程序的设备目录，解压后
进入包目录。以下以开发设备可写的 `/data/local/tmp` 为例；真实系统
是否允许通过 hdc 执行这些操作，需要在该设备上确认。

```sh
mkdir -p /data/local/tmp/codex-home /data/local/tmp/codex-tmp
chmod 700 /data/local/tmp/codex-home /data/local/tmp/codex-tmp
export CODEX_HOME=/data/local/tmp/codex-home
export TMPDIR=/data/local/tmp/codex-tmp
./codex --version
./codex --help
./smoke-test.sh
./codex login --device-auth
```

登录时在另一台设备打开输出的网址并输入设备码。交互界面需要支持
PTY 的终端；非交互场景使用 `./codex exec`。

更新此移植版应重新运行本仓库的构建和打包脚本。上游安装器会按
Linux/aarch64 选择 Linux-musl 包，不能用于鸿蒙。保持独立解压目录，
不要放入 Codex 受管安装目录或设置 `CODEX_MANAGED_BY_*` 环境标记。
可在 `$CODEX_HOME/config.toml` 的顶层加入下面一行，关闭上游版本提示：

```toml
check_for_update_on_startup = false
```

沙箱需要设备内核允许 namespace、seccomp 等功能。冒烟脚本会检查
程序启动及只读目录的写入拒绝，但不能代替完整的网络隔离、登录、
PTY 和文件编辑验证。遇到沙箱错误应继续定位设备能力和策略。

在鸿蒙 PC 的 HiShell 内，沙箱完全无法建立。终端应用运行在一个 seccomp
过滤器下（`/proc/self/status` 里 `Seccomp: 2`），任何
`unshare(CLONE_NEWUSER/NEWNS/NEWPID)` 都会被 `SIGSYS` 杀死；同时进程带有
ambient capabilities（`CapPrm=CapAmb=0x2a`），于是自带的 `bwrap` 在建立任何
namespace 之前就因 "Unexpected capabilities but not setuid" 中止。两者都是
子进程无法解除的应用域策略，且 seccomp 过滤器跨 `fork`/`exec` 继承，`codex`
和 `bwrap` 同样受限。`bwrap` 本身没问题——它能构建、签名、运行
（`bwrap --version`）——只是内核禁止它所需的 namespace，因此 `smoke-test.sh`
的 `--version`/`--help`/`bwrap --version` 检查通过，而最后的只读隔离步骤按
设计失败。要在设备上使用 Codex，请以非沙箱方式运行
`--dangerously-bypass-approvals-and-sandbox`（或 `-s danger-full-access`），
把 HiShell 应用沙箱当作隔离边界；此时 Codex 会以
`sandbox: danger-full-access` 启动会话，且不会调用 `bwrap`。普通
`uid=2000(shell)` 的 hdc 会话既无该 seccomp 过滤器也无 ambient caps，但它
无法从共享存储执行已签名二进制（退出码 126），所以也不是可用的沙箱宿主。

## 已处理的兼容问题

- `/system/bin/sh` 路径、鸿蒙 libc 的 ioctl/socket 类型。
- OpenSSL 交叉编译，以及 zstd 不可用的 `qsort_r`。
- 去除 X11/Wayland、D-Bus 依赖；文本复制使用终端 OSC 52。
- CLI/MCP OAuth 自动存储改用文件，保证保存、读取和退出登录一致。
- 从系统证书目录读取 TLS 根证书，保留证书验证。

## Code Mode host（V8）

`v8`（rusty_v8）crate 未发布 `aarch64-unknown-linux-ohos` 预编译包，因此
`ohos/build-v8.sh` 直接编译 crate 自带的 V8 15.0 源码：对
`v8-150.4.0` 应用 `ohos/v8/v8-ohos-source.patch`（OpenHarmony ifdef 与 OHOS gn
工具链），用 gn + ninja 交叉编译出 `librusty_v8.a`，并重新生成 crate 未随附的
指针压缩 + sandbox bindgen 绑定。设置 `RUSTY_V8_ARCHIVE` 与
`RUSTY_V8_SRC_BINDING_PATH` 后，`ohos/build.sh` 会额外编译
`codex-code-mode-host`；打包时用 `--code-mode-host` 一并装入。
构建前需设置 `OHOS_SDK_NATIVE` 和 `V8_ICU_DATA`，分别指向独立 SDK
和与 crate 内 ICU 版本匹配的 `icudtl.dat` 数据文件。详见
[英文说明](README.md)。

语音 host 和图形剪贴板仍不在最小 CLI 内。
Git、rg 及 MCP 服务所需运行时需设备另行提供。
现有 Windows CLI 没有被此移植替换。

## 验证记录

- ARM64 Release CLI 和 bubblewrap 成功链接。
- 鸿蒙目标的登录/OAuth 测试代码通过 `cargo check --tests`，未在设备执行。
- Linux 宿主 167 项 shell 测试、172 项剪贴板/存储/OAuth 测试通过。
- `just fix`、`just fmt` 和补丁空白检查通过。
- OAuth 网关测试首次受宿主代理变量影响；仅清除测试进程的代理变量后，
  两项失败测试及完整的 172 项筛选均通过。
- 尚未实机验证；包内 `build-info.json` 的 `device_tested` 为 `false`。
- 2026-09-21：API 24 / OpenHarmony-6.1.1.130 设备完成传输和 SHA-256
  校验；普通 hdc shell 执行原 CLI、原 bwrap 及已签名 bwrap 均被拒绝，
  尚未进入程序，不能判断运行时和沙箱兼容性。
- 2026-09-22：源码构建的 V8 host 已在真机执行 code mode JavaScript
  （`text(6 * 7);` 返回 `42`），验证 V8 初始化、ICU 数据与 JIT 可用。
- 2026-09-22：CLI、`codex-code-mode-host` 与 `bwrap` 已在设备上原生构建
  （host == target，Harmonybrew + rustup 1.95.0）并验证：`codex --version`
  返回 `codex-cli 0.153.4`；`codex --help`、`codex exec --help`、
  `codex-code-mode-host --help` 均退出 0；`codex exec
  --dangerously-bypass-approvals-and-sandbox` 能以
  `sandbox: danger-full-access` 启动会话并到达模型网络层，证明原生二进制
  无需 `bwrap` 即可端到端运行。HiShell 下自带沙箱仍不可用，因为 seccomp
  过滤器阻断了 `unshare`（见「设备部署和验证」）。

参考：[华为原生工具签名与部署说明](https://consumer.huawei.com/cn/support/content/zh-cn16078461/)、
[外部扩展程序设置说明](https://consumer.huawei.com/cn/support/content/zh-cn16079826/)。
