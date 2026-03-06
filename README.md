# PProxy

花 0 秒时间，在任意服务器上启动代理客户端和 WebUI。

## 特性

- **单文件**：不需要克隆整个仓库，只需下载一个文件 `proxy.sh`，并运行它
- **最小依赖**：仅依赖 Bash 3.2+、Curl 和[最基本的 GNU 工具集](https://github.com/w568w/pproxy/blob/main/proxy.sh#L12)，几乎在任何发行版（包括 [Busybox](https://busybox.net/downloads/BusyBox.html) 和 [Toybox](https://landley.net/toybox/help.html)）上都可以运行。不需要 Root、也不建议使用 Root 身份运行
- **网络友好**：内置 GitHub 镜像源和智能测速选择，无需另外下载
- **整洁**：所有文件放置在同一目录的 `./proxy-data` 下，运行期间绝不创建任何额外目录、垃圾文件或临时文件
- **先进**：使用最新的 [Mihomo](https://github.com/MetaCubeX/mihomo) 内核 + [metacubexd](https://github.com/metacubex/metacubexd) 网页前端，支持几乎所有协议
- **兼容性和可移植性**：编写过程中尽可能考虑到了所有可能的情况并遵循最佳实践，不对系统/平台做任何假设，不存在任何行为硬编码
- **幂等**：多次运行不会产生副作用。运行两次 `proxy.sh` 不会下载两次 Mihomo 或 metacubexd，也不会启动两个代理服务。你可以在运行中任意时候用 <kbd>Ctrl</kbd> + <kbd>C</kbd> 中断，不会影响后续运行

## 如何使用？

```bash
wget https://raw.githubusercontent.com/w568w/pproxy/main/proxy.sh
```

如果无法访问 GitHub，可以使用镜像源下载，例如：

```bash
wget https://gh.llkk.cc/https://raw.githubusercontent.com/w568w/pproxy/main/proxy.sh
```

下载后执行 `bash proxy.sh https://example.com/subscription.yaml` 即可启动代理并下载订阅文件。

另外，若要为当前 Shell 环境配置代理，可以执行以下命令：

```bash
# 使用代理（将会设置 http_proxy、https_proxy、all_proxy 环境变量）
$ . ./proxy-data/on
# 取消代理（将取消上述环境变量）
$ . ./proxy-data/off
```

### 更多常用命令

```bash
# （如果需要下载，则）下载代理，然后（重新）启动代理，交互式输入配置并启动 WebUI 和隧道服务
# 如果之前已有配置文件则不会要求输入
$ bash proxy.sh
# 同上，下载订阅 URL 为配置文件（https:// 可以省略，但 URL 中至少要包含一个 . 或 /）
$ bash proxy.sh https://example.com/subscription.yaml
# 下载并启动代理，从标准输入读取配置文件（在 SSH 服务器上粘贴配置时很有用）
$ bash proxy.sh -

# 检查当前代理运行状态
$ bash proxy.sh status

# 停止代理
$ bash proxy.sh stop

# 对已运行在 9000 端口的 WebUI 进行端口映射，以便访问和管理
$ bash proxy.sh tunnel 9000

# 查看帮助信息
$ bash proxy.sh help 或 $ bash proxy.sh -h 或 $ bash proxy.sh --help
```

### 注意事项

- `proxy.sh` 仅支持 Clash / Clash Meta / Mihomo 的配置文件格式，从你的代理服务商获取配置文件时请注意。

## 如何卸载？

执行以下命令即可无痕卸载，不会留下任何残留文件、配置或包：

```bash
$ bash proxy.sh stop && rm -rf ./proxy-data proxy.sh
```

## 为什么是英文的？

1. 方便在某些中文不支持的环境中使用
2. 我懒。都是高中英语，应该不至于看不懂吧
3. 如果你真看不懂，也有国际化支持的打算，欢迎 PR
