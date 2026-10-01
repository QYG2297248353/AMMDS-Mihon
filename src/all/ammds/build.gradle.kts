import io.github.keiyoushi.gradle.api.ContentWarning

plugins {
    alias(kei.plugins.extension)
}

keiyoushi {
    name = "AMMDS"
    // versionName 由 libVersion + versionCode 拼成，因此这里跟着服务端版本走：
    //   3  -> 1.6.3 修正章节序号恒为 1 导致 Mihon 章节排序/下一章错乱
    //   82 -> 1.6.82 随服务端 1.6.82 发版（代码未变，给已安装用户一个可更新的版本）
    versionCode = 82
    contentWarning = ContentWarning.SAFE
    libVersion = "1.6"

    // AMMDS 是自托管服务，服务器地址必须允许用户修改；默认值只是官方演示站点。
    // custom(...) 会生成一个带校验的「Custom base URL」设置项，无需自行实现地址配置。
    //
    // 这里刻意不声明 deeplink：自托管意味着 host 不固定，写死 host 的深链对绝大多数用户无效，
    // 深链接入列为后续阶段（见 TODO.md「二十二、Deep Link」）。
    source {
        name = "AMMDS"
        lang = "all"
        baseUrl {
            custom("https://ammds.lifebus.top")
        }
    }
}
