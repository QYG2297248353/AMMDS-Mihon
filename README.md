# AMMDS-Mihon

[AMMDS](https://github.com/QYG2297248353/AMMDS) 的 [Mihon / Tachiyomi](https://mihon.app/) 扩展。

这个仓库**同时就是扩展的发布源**：`dist/` 下的产物通过 `raw.githubusercontent.com` 对外提供，
在 Mihon 里把它添加为「扩展仓库」即可安装并自动更新。

> 本 README 分两部分：**上半部分面向使用者**（怎么装、怎么连），
> **下半部分面向开发者**（架构、构建、发布索引）。

---

# 第一部分 · 使用说明

## 这是什么

AMMDS 是一个自托管的媒体库 CMS。装上这个扩展后，Mihon / Tachiyomi 就能直接浏览你的
AMMDS 漫画库：列表、搜索、详情、章节与在线阅读全部走 AMMDS 服务端的 `/api/mihon` 协议。

服务端地址由你自己填（自托管意味着域名/IP 不固定），扩展只负责把你的 AMMDS 数据
转换成阅读器认识的模型。

## 怎么用

```text
1. 在 AMMDS 管理端 → 系统 → 密钥管理 → 新建密钥，类型选「Mihon 扩展」，复制生成的授权码
   （形如 amm.x...x.mihon，只对 /api/mihon 有效，不能用于其它接口）

2. Mihon：更多 → 设置 → 浏览 → 扩展仓库 → 添加，粘贴下面的地址：
   https://raw.githubusercontent.com/QYG2297248353/AMMDS-Mihon/master/dist/ammds-store.pb

3. Mihon：扩展 → 找到「AMMDS」→ 安装

4. 打开 AMMDS 源 → 设置：
     Custom base URL : https://你的 AMMDS 域名或 IP:端口
     授权码          : amm.x...x.mihon      ← 填完会自动校验并显示「✓ 已连接：<用户名>」

5. 浏览 / 搜索 / 详情 / 章节 / 阅读
```

不想加扩展仓库，也可以直接安装 `dist/ammds-keiyoushi-extensions.apk`；
但**自动更新依赖上面的仓库地址**，手动装的包后续不会自动升级。

## 常见问题

| 现象 | 原因与处理 |
| --- | --- |
| 填完地址显示「已连接」，但进漫画页报错 | 扩展版本旧。刷新扩展仓库升级到最新版 |
| 一直提示未授权 | 授权码类型不对。必须是「Mihon 扩展」类型；账户密码登录也能用，但推荐授权码 |
| 连接失败 / 超时 | 手机与 AMMDS 服务端不在同一网络，或服务端地址填的是容器内网 IP |
| 封面/页面图裂 | 服务端需要较新版本（图片经服务端代理下发） |
| 装了新版本却没生效 | `raw.githubusercontent.com` 有 CDN 缓存，推送后可能要几分钟才可见 |

---

# 第二部分 · 开发说明

## 项目架构

这是 [keiyoushi/extensions-source](https://github.com/keiyoushi/extensions-source) 的**精简检出**：
只保留构建框架与 AMMDS 这一个扩展，因此构建很快，也不需要拉取其余 130 多个扩展。

```text
Mihon / Tachiyomi                     AMMDS 服务端
        │                                   │
        │  1. 用户在源设置里填 baseUrl + 授权码
        │                                   │
        │  2. GET /api/mihon/auth/me  ───────►│  校验授权码，返回用户信息
        │                                   │
        │  3. GET /api/mihon/manga ... ─────►│  漫画列表 / 搜索 / 详情
        │     GET /api/mihon/manga/{id}/chapters
        │     GET /api/mihon/chapter/{id}/pages
        │     GET /api/mihon/page/{id}/image ─►│  页面图片字节
        │                                   │
     阅读器渲染  ◄───────────────────────────┘
```

扩展**不做本地存储、不缓存业务数据**，只做协议转换：拿到 JSON → 映射成
`SManga` / `SChapter` / `Page`。因此服务端改字段时，只需要同步 `Dto.kt` 的映射。

两个容易踩的点：

* `@Source` 类必须是 **abstract**，`baseUrl { custom(...) }` 才会生成可编辑的
  「Custom base URL」设置项；写成非 abstract 会直接构建失败；
* 映射时右侧字段**必须显式限定接收者**（`this@MangaDto.title`）：
  `SManga.create().apply { this.title = title }` 里的右侧 `title` 会解析到 `SManga` 自己那个
  `lateinit` 属性，进漫画页会抛 `UninitializedPropertyAccessException`。

## 目录结构

```text
gradle/          Gradle wrapper、版本目录（含 SDK 版本）、build-logic 插件（来自上游）
common/          扩展模块共用的 AndroidManifest 与 ProGuard 规则（来自上游）
compiler/        KSP 处理器：由 source { } 生成 name/lang/id/baseUrl（来自上游）
core/            KeiSource 与 keiyoushi.utils 等运行时依赖（来自上游）
src/all/ammds/   ← AMMDS 扩展本体（本仓库唯一维护的代码）
  build.gradle.kts   keiyoushi { } 块：name / versionCode / contentWarning / libVersion / source
  res/mipmap-*/      扩展图标（多密度）
  src/eu/kanade/tachiyomi/extension/all/ammds/
    Ammds.kt         漫画源：列表、搜索、详情、章节、页面
    Dto.kt           /api/mihon 响应模型与到 SManga/SChapter/Page 的映射
  tools/
    build_store.py   构建前/后把产物打包成 Mihon 扩展仓库索引（含签名指纹）
tools/
  build-release.ps1  一键出包：签名环境变量 → assembleRelease + lintRelease → 打包 dist/
.github/scripts/     Mihon 仓库索引的 protobuf 定义（index.proto）与 Python 绑定
dist/                发布产物（已提交，见下）
signingkey.jks       签名密钥（**不在版本库**，见「签名密钥」）
signingkey.properties 密钥口令（**不在版本库**）
```

SDK 版本在 `gradle/kei.versions.toml`：`minSdk 26`、`compileSdk 37`、`targetSdk 37`。

## 环境要求

* **标准 JDK 21**（不要用 GraalVM：它缺少 jmods，AGP 的 `JdkImageTransform` 会失败）
* **Android SDK**（`compileSdk 37` 缺失时构建会自动下载）
* **Python 3 + `protobuf`** —— 仅生成扩展仓库索引时需要
* 首次构建需要联网拉取 Gradle 依赖与 Android 组件

## 构建与索引

### 一键出包（推荐）

```powershell
.\tools\build-release.ps1
```

一条命令完成全部环节：

1. **环境探测** —— 自动选可用的 JDK（必须是 17~21 且带 jmods/jlink 的标准 JDK，
   GraalVM / JRE 会在 AGP 的 `JdkImageTransform` 上失败）、Android SDK
   （`ANDROID_HOME` / `ANDROID_SDK_ROOT` / `local.properties` / 默认安装位置）、
   Python 3 + protobuf、`gradlew.bat`；缺什么就给可直接执行的处理提示。
2. **找签名密钥** —— 依次查找：显式参数 → `secret/` → 仓库根目录。
3. **构建** —— `assembleRelease` + `lintRelease`。
4. **打包** —— `build_store.py` 把 APK / JAR / 图标 / 索引写进 `dist/`。
5. **校验** —— 打印 versionCode/versionName，并比对签名指纹是否与上次发布一致。

常用参数：

```powershell
.\tools\build-release.ps1 -Publish                  # 打包后自动提交并推送 dist/
.\tools\build-release.ps1 -SecretDir D:\keys\ammds  # 换密钥目录
.\tools\build-release.ps1 -SkipLint                 # 跳过 lintRelease
.\tools\build-release.ps1 -Proxy http://127.0.0.1:7897   # 受限网络下给 Gradle 下载依赖
```

### 手动构建

```powershell
$env:JAVA_HOME    = "C:\Program Files\Java\jdk-21"
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"

$props = ConvertFrom-StringData (Get-Content .\secret\signingkey.properties -Raw)
$env:KEY_STORE_PASSWORD = $props.KEY_STORE_PASSWORD
$env:ALIAS              = $props.ALIAS
$env:KEY_PASSWORD       = $props.KEY_PASSWORD

# 上游把密钥路径写死为 rootProject.file("signingkey.jks")，
# 密钥在 secret/ 时要先就位到仓库根目录，否则会静默回退成 debug 签名
Copy-Item .\secret\signingkey.jks .\signingkey.jks

.\gradlew.bat :src:all:ammds:assembleRelease :src:all:ammds:lintRelease

python .\src\all\ammds\tools\build_store.py --out-dir dist `
  --release-base-url https://raw.githubusercontent.com/QYG2297248353/AMMDS-Mihon/master/dist

Remove-Item .\signingkey.jks
```

产物：

```text
src/all/ammds/build/outputs/apk/release/tachiyomi-all.ammds-v<版本>.apk
src/all/ammds/build/outputs/jar/release/tachiyomi-all.ammds-v<版本>.jar
src/all/ammds/build/keiyoushi-source-info.json      ← versionCode / versionName 来源
```

> `signingkey.jks` 存在时签名配置就会启用，此时**必须**提供上面三个环境变量，否则签名失败。
> 用 `tools/build-release.ps1` 可以避免踩这个坑。

### 只生成 / 更新索引

产物已在、只想重打索引时：

```powershell
python .\src\all\ammds\tools\build_store.py --out-dir dist `
  --release-base-url https://raw.githubusercontent.com/QYG2297248353/AMMDS-Mihon/master/dist
```

`build_store.py` 的关键行为：

* 向上查找最近的 `settings.gradle.kts` 定位扩展根目录，因此在哪个目录执行都可以；
* 从构建产物里解析签名证书指纹（`apksigner` / `keytool` 自动探测），写进索引的 `signingKey`；
  **探测不到会直接报错**，不会生成一个 `signingKey` 为空的索引（那种索引 Mihon 会拒绝）；
* 同时产出 `ammds-store.pb`（Mihon 实际读取的 gzip protobuf 索引）、
  `ammds-store.json`（可读形式，便于核对）与 `ammds-icon.png`。

### 发布 / 更新扩展

1. 改代码，并把 `src/all/ammds/build.gradle.kts` 里的 `versionCode` 加一
   （不改 `versionCode`，Mihon 不会认为有新版本）；
2. 跑一次 `.\tools\build-release.ps1`；
3. 提交并推送：

```powershell
git add -A
git commit -m "feat(ammds): ..."
git push
```

Mihon 端刷新扩展仓库即可看到新版本。`dist/` 里的产物被直接提交进仓库，
所以理论上无需在本地构建（克隆后也能直接用）。

> 走 `raw.githubusercontent.com` 的代价是 CDN 有缓存，推送后新版本可能要几分钟才可见。
> 想避免这点，可以改用 GitHub Release 资产：
> `build_store.py --tag <tag> --release-base-url https://github.com/<owner>/<repo>/releases/download/<tag>`，
> 然后把 `dist/` 里的文件作为该 Release 的资产上传。

## 签名密钥（重要）

扩展的签名材料放在 **`secret/`** 目录（**不在版本库里**，见 `.gitignore` 的
`/secret/`、`*.jks`、`signingkey.properties`）：

```text
secret/
├── signingkey.jks           签名密钥（alias `ammds`）
└── signingkey.properties    KEY_STORE_PASSWORD / ALIAS / KEY_PASSWORD
```

`tools/build-release.ps1` 默认就到 `secret/` 找这两份文件，也兼容放在仓库根目录的旧位置，
还可以用 `-KeyStore` / `-SigningProperties` / `-SecretDir` 显式指定。请务必备份该目录：

* 丢了就无法再给已安装扩展推送更新（Mihon 会拒绝签名不一致的 APK），用户只能卸载后重装；
* 换机器构建时要把这两份文件一起带过去；
* 如果改用 CI 构建，把它们放进仓库 Secrets（`KEY_STORE_PASSWORD` / `ALIAS` / `KEY_PASSWORD`），
  并把 `signingkey.jks` 编码后作为 Secret 文件写入工作目录。

> **一个容易踩的坑**：上游的 `ExtensionPlugin.kt` 把密钥路径写死成
> `rootProject.file("signingkey.jks")`，密钥不在仓库根目录时它**不会报错**，
> 而是静默回退到 debug 签名——打出来的包会让所有已安装用户无法覆盖更新。
> `tools/build-release.ps1` 会在构建期间把密钥就位到根目录、结束后清理，
> 并比对本次产物与上次发布的签名指纹，发生变化时醒目告警。

`dist/ammds-store.pb` 里的 `signingKey` 字段就是这份证书的 SHA-256，
Mihon 用它校验下载到的 APK 是否真的由本仓库签名——因此**换密钥后必须重新生成 `dist/`**。

## 与 AMMDS 主仓库的关系

扩展源码**只在本仓库维护**。主仓库（AMMDS 服务端）通过 **git 子模块**把它挂在自己工作区的
`AMMDS-Mihon/` 下，方便与服务端一起开发调试：

```powershell
# 主仓库里初始化子模块
git submodule update --init --recursive
```

注意子模块记录的是「固定提交」而不是「跟随分支」：在本仓库提交并推送后，
还要回主仓库提交一次新的 gitlink，主仓库才会指向这个新提交。

服务端 `/api/mihon` 协议、Mihon 授权码（`secret_mihon`）与完整接入说明见主仓库的
[docs/Mihon接入.md](https://github.com/QYG2297248353/AMMDS/blob/master/docs/Mihon%E6%8E%A5%E5%85%A5.md)。

## 许可

框架部分来自 keiyoushi/extensions-source，遵循 [Apache-2.0](LICENSE)。
AMMDS 扩展本体同样以 Apache-2.0 发布。
