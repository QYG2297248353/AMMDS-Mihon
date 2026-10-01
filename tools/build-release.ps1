<#
.SYNOPSIS
    一键构建并发布 AMMDS Mihon 扩展。

.DESCRIPTION
    一条命令完成：环境探测 → 找签名密钥 → 构建 → 打包进 dist/ →（可选）提交推送。

    环境探测（缺什么就给可执行的提示，不让你自己猜）：
      * JDK 17~21 标准 JDK：AGP 的 JdkImageTransform 依赖 jlink，GraalVM / JRE 都不行
      * Android SDK：ANDROID_HOME / ANDROID_SDK_ROOT / local.properties / 默认安装位置
      * Python 3 与 protobuf：打包扩展仓库索引需要
      * gradlew.bat

    签名密钥查找顺序（先命中先用）：
      1. 显式参数 -KeyStore / -SigningProperties
      2. <仓库>/secret/signingkey.jks 与 <仓库>/secret/signingkey.properties   ← 默认备份位置
      3. <仓库>/signingkey.jks 与 <仓库>/signingkey.properties                 ← 旧位置，兼容

    为什么密钥在 secret/ 还要做处理：上游的 ExtensionPlugin.kt 把密钥路径写死成
    rootProject.file("signingkey.jks")，密钥不在仓库根目录时它会**静默回退到 debug 签名**，
    打出来的包会让已安装用户无法覆盖更新。因此本脚本在构建期间把密钥就位到根目录，
    构建结束后恢复原状（根目录本来就有密钥时不改动它）。

    密钥与密码不进版本库（.gitignore 已含 /secret/、*.jks、signingkey.properties）。

.PARAMETER RepoRoot
    扩展仓库根目录，默认取本脚本所在目录的上一级。

.PARAMETER SecretDir
    密钥目录，默认 <RepoRoot>/secret。

.PARAMETER KeyStore
    显式指定 .jks 路径，覆盖自动查找。

.PARAMETER SigningProperties
    显式指定 signingkey.properties 路径，覆盖自动查找。

.PARAMETER ReleaseBaseUrl
    产物对外下载地址前缀，默认 raw.githubusercontent.com 的 main 分支 dist 目录。

.PARAMETER SkipLint
    跳过 lintRelease（仓库规范要求提交前通过，默认执行）。

.PARAMETER Publish
    打包完成后自动 git add dist、提交并推送。

.PARAMETER Proxy
    受限网络下给 Gradle 下载依赖用的本地代理，例如 http://127.0.0.1:7897。

.EXAMPLE
    .\tools\build-release.ps1

.EXAMPLE
    .\tools\build-release.ps1 -Publish

.EXAMPLE
    .\tools\build-release.ps1 -SecretDir D:\keys\ammds -Proxy http://127.0.0.1:7897
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$SecretDir,
    [string]$KeyStore,
    [string]$SigningProperties,
    [string]$ReleaseBaseUrl = "https://raw.githubusercontent.com/QYG2297248353/AMMDS-Mihon/main/dist",
    [switch]$SkipLint,
    [switch]$Publish,
    [string]$Proxy
)

$ErrorActionPreference = "Stop"

function Fail {
    param([string]$Message)
    Write-Host ""
    Write-Host $Message -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- 基础路径 ---
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path $RepoRoot).Path
if (-not $SecretDir) { $SecretDir = Join-Path $RepoRoot "secret" }
Write-Host "仓库:     $RepoRoot"
Write-Host "密钥目录: $SecretDir"

# ------------------------------------------------------------ 环境探测: JDK ---
function Get-JavaMajorVersion {
    param([string]$JavaPath)
    $line = & $JavaPath -version 2>&1 | Select-Object -First 1
    if ("$line" -match 'version "(\d+)(?:\.(\d+))?') {
        $first = [int]$Matches[1]
        if ($first -eq 1 -and $Matches[2]) { return [int]$Matches[2] }
        return $first
    }
    return 0
}

function Test-AndroidJdk {
    param([string]$JdkHome)
    if (-not (Test-Path (Join-Path $JdkHome "bin\java.exe"))) { return $false }
    if (-not (Test-Path (Join-Path $JdkHome "bin\jlink.exe"))) { return $false }
    return @(17, 18, 19, 20, 21) -contains (Get-JavaMajorVersion (Join-Path $JdkHome "bin\java.exe"))
}

function Resolve-JavaHome {
    if ($env:JAVA_HOME -and (Test-AndroidJdk $env:JAVA_HOME)) {
        Write-Host "JDK:      $env:JAVA_HOME"
        return
    }
    if ($env:JAVA_HOME) {
        Write-Host "JDK:      当前 JAVA_HOME（$env:JAVA_HOME）不适合 Android 构建，自动查找..." -ForegroundColor Yellow
    }
    $roots = @(
        "C:\Program Files\Java",
        "C:\Program Files\Eclipse Adoptium",
        (Join-Path $env:LOCALAPPDATA "Programs\Eclipse Adoptium"),
        "C:\Program Files\Android\Android Studio\jbr",
        "C:\Program Files\Android\Android Studio\jre"
    )
    $candidates = @()
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        if (Test-Path (Join-Path $root "bin\java.exe")) { $candidates += $root; continue }
        $candidates += (Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    }
    $ranked = $candidates | Sort-Object -Unique |
        Sort-Object @{ Expression = { if ($_ -match "graalvm") { 1 } else { 0 } } }, @{ Expression = { $_ } }
    foreach ($jdkHome in $ranked) {
        if (Test-AndroidJdk $jdkHome) {
            $env:JAVA_HOME = $jdkHome
            Write-Host "JDK:      $jdkHome（自动选用）"
            return
        }
    }
    Fail @"
未找到可用于 Android 构建的 JDK。需要标准 JDK 17~21 且带 jmods/jlink
（GraalVM 发行版与 JRE 都不满足，AGP 的 JdkImageTransform 会失败）。任选其一：
  1) 安装 JDK 21 后设置环境变量 JAVA_HOME 再重跑；
  2) 安装 Android Studio，脚本会自动使用其自带 JBR。
"@
}

# ---------------------------------------------------- 环境探测: Android SDK ---
function Resolve-AndroidSdk {
    $candidates = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)
    $localProperties = Join-Path $RepoRoot "local.properties"
    if (Test-Path $localProperties) {
        $line = Select-String -Path $localProperties -Pattern '^sdk\.dir=' | Select-Object -First 1
        if ($line) { $candidates += ($line.Line -replace '^sdk\.dir=', '').Trim() }
    }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA "Android\Sdk") }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path (Join-Path $candidate "platform-tools"))) {
            $env:ANDROID_HOME = $candidate
            $env:ANDROID_SDK_ROOT = $candidate
            Write-Host "SDK:      $candidate"
            return
        }
    }
    Fail @"
未找到 Android SDK。任选其一：
  1) 安装 Android Studio / 命令行工具后设置 ANDROID_HOME；
  2) 在 $RepoRoot\local.properties 中写入 sdk.dir=<SDK 路径>。
"@
}

# ---------------------------------------------------------- 环境探测: Python ---
function Resolve-Python {
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        Fail "未找到 python。打包扩展仓库索引需要 Python 3（python -m pip install protobuf）。"
    }
    $probe = & python -c "import google.protobuf, sys; print(sys.version.split()[0])" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Fail @"
Python 可以运行，但缺少 protobuf（打包索引需要）。执行：
  python -m pip install protobuf
原始错误：$probe
"@
    }
    Write-Host "Python:   $probe"
}

Write-Host ""
Write-Host "--- 环境探测 ---"
Resolve-JavaHome
Resolve-AndroidSdk
Resolve-Python
if (-not (Test-Path (Join-Path $RepoRoot "gradlew.bat"))) {
    Fail "未找到 $RepoRoot\gradlew.bat，请确认 -RepoRoot 指向扩展仓库根目录。"
}

# ---------------------------------------------------------------- 签名密钥 ---
function Find-SigningMaterial {
    $jks = $KeyStore
    $props = $SigningProperties
    if (-not $jks) {
        foreach ($candidate in @(
                (Join-Path $SecretDir "signingkey.jks"),
                (Join-Path $RepoRoot "signingkey.jks"))) {
            if (Test-Path $candidate) { $jks = $candidate; break }
        }
    }
    if (-not $props) {
        foreach ($candidate in @(
                (Join-Path $SecretDir "signingkey.properties"),
                (Join-Path $RepoRoot "signingkey.properties"))) {
            if (Test-Path $candidate) { $props = $candidate; break }
        }
    }
    return [pscustomobject]@{ KeyStore = $jks; Properties = $props }
}

Write-Host ""
Write-Host "--- 签名 ---"
$material = Find-SigningMaterial
$rootKeyStore = Join-Path $RepoRoot "signingkey.jks"
$stagedKeyStore = $false

if (-not $material.KeyStore) {
    Write-Warning @"
未找到签名密钥（已查找 $SecretDir 与仓库根目录）。
将用 Android 调试密钥签名——已安装过正式版扩展的用户**无法覆盖更新**，只能卸载重装。
正式发布请把 signingkey.jks 与 signingkey.properties 放到：
  $SecretDir
"@
} else {
    if (-not $material.Properties) {
        Fail "找到 $($material.KeyStore) 但缺少 signingkey.properties（需要 KEY_STORE_PASSWORD / ALIAS / KEY_PASSWORD）。"
    }
    $values = ConvertFrom-StringData (Get-Content $material.Properties -Raw)
    foreach ($name in @("KEY_STORE_PASSWORD", "ALIAS", "KEY_PASSWORD")) {
        if (-not $values[$name]) { Fail "$($material.Properties) 未定义 $name。" }
        Set-Item -Path "env:$name" -Value $values[$name]
    }
    Write-Host "密钥:     $($material.KeyStore)"
    Write-Host "别名:     $($values['ALIAS'])"

    # 上游把密钥路径写死为 rootProject.file("signingkey.jks")，不在根目录就会静默用 debug 签名。
    $resolvedKeyStore = (Resolve-Path $material.KeyStore).Path
    if ($resolvedKeyStore -ne $rootKeyStore) {
        if (Test-Path $rootKeyStore) {
            $rootHash = (Get-FileHash $rootKeyStore -Algorithm SHA256).Hash
            $wantHash = (Get-FileHash $resolvedKeyStore -Algorithm SHA256).Hash
            if ($rootHash -eq $wantHash) {
                Write-Host "就位:     仓库根目录已有同名密钥，内容一致，直接使用"
            } else {
                Fail @"
仓库根目录的 signingkey.jks 与指定密钥内容不一致，无法判断该用哪一份：
  根目录: $rootKeyStore
  指定值: $resolvedKeyStore
请删掉其中一份（或统一为同一份）后重跑，避免用错密钥签名。
"@
            }
        } else {
            Copy-Item -LiteralPath $resolvedKeyStore -Destination $rootKeyStore -Force
            $stagedKeyStore = $true
            Write-Host "就位:     已临时复制到仓库根目录供 Gradle 使用（构建后自动清理）"
        }
    }
}

# -------------------------------------------------------------- 代理（可选）---
$previousJavaToolOptions = $null
if ($Proxy) {
    $value = $Proxy.Trim()
    if ($value -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $value = "http://$value" }
    $uri = [System.Uri]$value
    $port = if ($uri.Port -gt 0 -and -not $uri.IsDefaultPort) { $uri.Port } else { 7890 }
    $options = "-Dhttps.proxyHost=$($uri.Host) -Dhttps.proxyPort=$port -Dhttp.proxyHost=$($uri.Host) -Dhttp.proxyPort=$port"
    $previousJavaToolOptions = $env:JAVA_TOOL_OPTIONS
    $env:JAVA_TOOL_OPTIONS = if ([string]::IsNullOrWhiteSpace($previousJavaToolOptions)) { $options } else { "$previousJavaToolOptions $options" }
    Write-Host "代理:     $($uri.Host):$port（仅 Gradle 依赖下载）"
}

# ------------------------------------------------------------------ 构建 ---
$tasks = @(":src:all:ammds:assembleRelease")
if (-not $SkipLint) { $tasks += ":src:all:ammds:lintRelease" }

# 记录构建前的签名指纹，构建后比对：指纹变化意味着已安装用户无法覆盖更新
$previousSigningKey = $null
$publishedJson = Join-Path $RepoRoot "dist\ammds-store.json"
if (Test-Path $publishedJson) {
    $previousSigningKey = (Get-Content $publishedJson -Raw | ConvertFrom-Json).signingKey
}

Write-Host ""
Write-Host "--- 构建 ---"
Write-Host "gradle $($tasks -join ' ')"
Push-Location $RepoRoot
try {
    & .\gradlew.bat @tasks --console=plain
    if ($LASTEXITCODE -ne 0) { throw "gradle 构建失败（退出码 $LASTEXITCODE）" }

    Write-Host ""
    Write-Host "--- 打包进 dist/ ---"
    & python .\src\all\ammds\tools\build_store.py --out-dir dist --release-base-url $ReleaseBaseUrl
    if ($LASTEXITCODE -ne 0) { throw "build_store.py 失败（退出码 $LASTEXITCODE）" }
} finally {
    Pop-Location
    if ($stagedKeyStore -and (Test-Path $rootKeyStore)) {
        Remove-Item -LiteralPath $rootKeyStore -Force
        Write-Host "清理:     已移除临时复制到仓库根目录的 signingkey.jks"
    }
    if ($Proxy) {
        if ([string]::IsNullOrWhiteSpace($previousJavaToolOptions)) {
            Remove-Item Env:JAVA_TOOL_OPTIONS -ErrorAction SilentlyContinue
        } else {
            $env:JAVA_TOOL_OPTIONS = $previousJavaToolOptions
        }
    }
}

# -------------------------------------------------------------- 结果汇总 ---
Write-Host ""
Write-Host "--- 产物 ---"
Get-ChildItem (Join-Path $RepoRoot "dist") | Sort-Object Name | ForEach-Object {
    Write-Host ("  {0}  ({1:N0} bytes)" -f $_.Name, $_.Length)
}
$sourceInfo = Join-Path $RepoRoot "src\all\ammds\build\keiyoushi-source-info.json"
if (Test-Path $sourceInfo) {
    $info = Get-Content $sourceInfo -Raw | ConvertFrom-Json
    Write-Host ("  版本: versionCode={0} versionName={1}" -f $info.versionCode, $info.versionName)
}

# 签名指纹比对：换密钥（或误用 debug 签名）会让已安装用户的自动更新全部失败
if ($previousSigningKey) {
    $newSigningKey = (Get-Content $publishedJson -Raw | ConvertFrom-Json).signingKey
    if ($newSigningKey -and $newSigningKey -ne $previousSigningKey) {
        Write-Host ""
        Write-Warning @"
签名指纹发生变化，已安装扩展的用户将无法覆盖更新（Mihon 会拒绝签名不一致的 APK），
他们只能卸载后重装：
  上次发布: $previousSigningKey
  本次产物: $newSigningKey
如果不是有意更换密钥，请检查是否漏放了 signingkey.jks（那样会回退成 debug 签名）。
"@
    } elseif ($newSigningKey) {
        Write-Host "  签名:     $newSigningKey（与上次发布一致）"
    }
}

# ------------------------------------------------------------------ 发布 ---
if ($Publish) {
    Write-Host ""
    Write-Host "--- 发布（提交并推送 dist/）---"
    Push-Location $RepoRoot
    try {
        git add dist
        $staged = git diff --cached --name-only
        if (-not $staged) {
            Write-Host "  dist/ 与上一次提交完全一致，无需发布。" -ForegroundColor Yellow
            Write-Host "  提示：不改 src/all/ammds/build.gradle.kts 的 versionCode，Mihon 不会认为有新版本。"
        } else {
            $staged | ForEach-Object { "  待提交: $_" }
            git commit -q -m "release: AMMDS Mihon 扩展产物"
            git push
            if ($LASTEXITCODE -ne 0) { throw "git push 失败（退出码 $LASTEXITCODE）" }
            Write-Host "  已推送。Mihon 端刷新扩展仓库后可见（CDN 缓存可能延迟几分钟）。" -ForegroundColor Green
        }
    } finally {
        Pop-Location
    }
} else {
    Write-Host ""
    Write-Host "下一步（发布）：" -ForegroundColor Cyan
    Write-Host "  git add dist; git commit -m 'release: AMMDS Mihon 扩展产物'; git push"
    Write-Host "或者下次直接加 -Publish 参数让本脚本一并完成。"
}
