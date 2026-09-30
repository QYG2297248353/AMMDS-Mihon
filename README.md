# AMMDS-Mihon

[AMMDS](https://github.com/QYG2297248353/AMMDS) 的 [Mihon / Tachiyomi](https://mihon.app/) 扩展源码与发布仓库。

这个仓库**同时是扩展的发布源**：`dist/` 下的产物通过 `raw.githubusercontent.com` 对外提供，
在 Mihon 里把这个地址添加为「扩展仓库」即可安装与自动更新：

```text
https://raw.githubusercontent.com/QYG2297248353/AMMDS-Mihon/main/dist/ammds-store.pb
```

## 用户怎么用

```text
1. 在 AMMDS 管理端 → 系统 → 密钥管理 → 新建密钥，类型选「Mihon 扩展」，复制生成的授权码
2. Mihon：更多 → 设置 → 浏览 → 扩展仓库 → 添加，粘贴上面的 ammds-store.pb 地址
3. Mihon：扩展 → 找到 AMMDS → 安装
4. 打开 AMMDS 源 → 设置：
     Custom base URL : https://你的 AMMDS 域名或 IP:端口
     授权码           : amm.x...x.mihon      ← 填完会自动校验并显示「✓ 已连接：<用户名>」
5. 浏览 / 搜索 / 详情 / 章节 / 阅读
```

不想加仓库也可以直接安装 `dist/ammds-keiyoushi-extensions.apk`。

## 仓库结构

这是 [keiyoushi/extensions-source](https://github.com/keiyoushi/extensions-source) 的**精简检出**：
只保留构建框架与 AMMDS 这一个扩展，因此构建很快，也不需要拉取其余 130 多个扩展。
框架部分（`core/`、`compiler/`、`common/`、`gradle/`）来自上游，遵循其 Apache-2.0 许可。

```text
gradle/          Gradle wrapper、版本目录、build-logic 插件（来自上游）
common/          扩展模块共用的 AndroidManifest 与 ProGuard 规则（来自上游）
compiler/        KSP 处理器：由 source { } 生成 name/lang/id/baseUrl（来自上游）
core/            KeiSource 与 keiyoushi.utils 等运行时依赖（来自上游）
src/all/ammds/   ← AMMDS 扩展本体（本仓库唯一维护的代码）
  build.gradle.kts
  res/mipmap-*/  扩展图标
  src/eu/kanade/tachiyomi/extension/all/ammds/
    Ammds.kt     漫画源
    Dto.kt       /api/mihon 响应模型
  tools/
    build_store.py   构建后打包成 Mihon 扩展仓库索引
.github/scripts/  Mihon 仓库索引的 protobuf 定义与绑定（来自上游）
dist/             发布产物（见下）
```

## 构建

前置：**标准 JDK 21**（不要用 GraalVM，其 `jlink` 缺少 jmods，AGP 的 `JdkImageTransform` 会失败）、
Android SDK（`compileSdk 37` 缺失时构建会自动下载）、Python 3 与 `protobuf`（仅打包索引时需要）。

### 一键出包（推荐）

```powershell
$env:JAVA_HOME    = "C:\Program Files\Java\jdk-21"
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"

.\tools\build-release.ps1
```

脚本会读取 `signingkey.properties` 设置签名环境变量，然后执行
`assembleRelease` + `lintRelease`，最后把产物打包进 `dist/`。

### 手动构建

```powershell
$env:JAVA_HOME    = "C:\Program Files\Java\jdk-21"
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"

$props = ConvertFrom-StringData (Get-Content .\signingkey.properties -Raw)
$env:KEY_STORE_PASSWORD = $props.KEY_STORE_PASSWORD
$env:ALIAS              = $props.ALIAS
$env:KEY_PASSWORD       = $props.KEY_PASSWORD

.\gradlew.bat :src:all:ammds:assembleRelease :src:all:ammds:lintRelease

python .\src\all\ammds\tools\build_store.py --out-dir dist `
  --release-base-url https://raw.githubusercontent.com/QYG2297248353/AMMDS-Mihon/main/dist
```

> `signingkey.jks` 存在时签名配置就会启用，此时**必须**提供上面三个环境变量，
> 否则签名会失败。用 `tools/build-release.ps1` 可以避免踩这个坑。

## 发布 / 更新扩展

1. 改代码，并把 `src/all/ammds/build.gradle.kts` 里的 `versionCode` 加一
   （不改 `versionCode`，Mihon 不会认为有新版本）；
2. 跑一次 `.\tools\build-release.ps1`；
3. 提交并推送：

```powershell
git add -A
git commit -m "feat(ammds): ..."
git push
```

Mihon 端刷新扩展仓库后即可看到新版本。`dist/` 里的产物被直接提交进仓库，
所以理论上无需在本地构建（克隆后也能直接用）。

> 走 `raw.githubusercontent.com` 的代价是 CDN 有缓存，推送后新版本可能要几分钟才可见。
> 想避免这点，可以改用 GitHub Release 资产：
> `build_store.py --tag <tag> --release-base-url https://github.com/<owner>/<repo>/releases/download/<tag>`，
> 然后把 `dist/` 里的文件作为该 Release 的资产上传。

## 签名密钥（重要）

`signingkey.jks` 与 `signingkey.properties` **不在版本库里**（见 `.gitignore`），
它们只存在于本地。请务必备份：

* 丢了就无法再给已安装扩展推送更新（Mihon 会拒绝签名不一致的 APK），
  用户只能卸载后重装；
* 换机器构建时要把这两个文件一起带过去；
* 如果改用 CI 构建，请把它们放进仓库 Secrets（`KEY_STORE_PASSWORD` / `ALIAS` / `KEY_PASSWORD`），
  并把 `signingkey.jks` 编码后作为 Secret 文件写入工作目录。

`dist/ammds-store.pb` 里的 `signingKey` 字段就是这份证书的 SHA-256，
Mihon 用它校验下载到的 APK 是否真的由本仓库签名——因此**换密钥后必须重新生成 `dist/`**。

## 与 AMMDS 主仓库的关系

扩展的源码同时保存在主仓库的 `Mihon/src/all/ammds/`（用于对照上游与向上游提 PR）。
服务端 `/api/mihon` 协议、Mihon 授权码与完整接入说明见主仓库的
[docs/Mihon接入.md](https://github.com/QYG2297248353/AMMDS/blob/master/docs/Mihon%E6%8E%A5%E5%85%A5.md)。

## 许可

框架部分来自 keiyoushi/extensions-source，遵循 [Apache-2.0](LICENSE)。
AMMDS 扩展本体同样以 Apache-2.0 发布。
