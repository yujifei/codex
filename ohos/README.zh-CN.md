# Codex CLI 鸿蒙 ARM64 原生移植

基于本机安装的同版本 Codex CLI 0.153.4，上游提交
`3d2ee51ca2d5db578f328aa75e20aa22c0197c9a`。
源码位于 Windows `D:\AlProject\codex-ohos`，在 WSL 中对应
`/mnt/d/AlProject/codex-ohos`。

这是在鸿蒙终端中运行的原生命令行程序，不需要 Node.js。
当前交付的是交叉编译版本。已连接正式系统设备并完成文件传输，
但普通 hdc shell 拒绝启动原生程序，尚未证明实机可用。

## 参考工程与 SDK

已读取你提供的 `~/external-ohos-144/src/external` 工程、
`ohos/external/tools/linux_local_debug_hap.sh` 和
`~/external-ohos-144/src/out/externalReleaseArm64/args.gn`。
使用与该浏览器原生构建相同的 SDK：

```sh
export OHOS_SDK_NATIVE=/home/yujihui/external-ohos-144/src/ohos_sdk/openharmony/native
```

SDK 版本为 6.0.0.47 / API 20，目标为 `aarch64-unknown-linux-ohos`。
CLI 通过 Cargo 编译，不需要触发 Chromium/HAP 的完整构建。
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
export BINARY_SIGN_TOOL=/home/yujihui/external-ohos-144/src/buildtools/HarmonyOS/command-line-tools/sdk/default/openharmony/toolchains/lib/binary-sign-tool
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

## 已处理的兼容问题

- `/system/bin/sh` 路径、鸿蒙 libc 的 ioctl/socket 类型。
- OpenSSL 交叉编译，以及 zstd 不可用的 `qsort_r`。
- 去除 X11/Wayland、D-Bus 依赖；文本复制使用终端 OSC 52。
- CLI/MCP OAuth 自动存储改用文件，保证保存、读取和退出登录一致。
- 从系统证书目录读取 TLS 根证书，保留证书验证。

当前未提供 V8 Code Mode host、语音 host 和图形剪贴板。
Git、rg 及 MCP 服务所需运行时需设备另行提供。
现有 Windows CLI 和浏览器工程没有被此移植替换。

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

参考：[华为原生工具签名与部署说明](https://consumer.huawei.com/cn/support/content/zh-cn16078461/)、
[外部扩展程序设置说明](https://consumer.huawei.com/cn/support/content/zh-cn16079826/)。
