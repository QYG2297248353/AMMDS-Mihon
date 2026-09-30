package eu.kanade.tachiyomi.extension.all.ammds

import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import keiyoushi.utils.tryParse
import kotlinx.serialization.Serializable
import kotlin.time.Instant

// 映射时统一用 this@XxxDto 限定右侧取值，原因不是风格问题而是正确性问题：
// SManga 自身也有 title / author / description / genre，在 SManga.create().apply { } 里
// 不加限定符时 `title = title` 读到的是 SManga 那个未初始化的 lateinit 属性（直接抛
// UninitializedPropertyAccessException），而 `author?.let { }` 这类写法会静默读到 null，
// 让字段无声丢失。写全限定符可以让这类遮蔽问题无法再复现。

/**
 * `/api/mihon/manga` 与 `/api/mihon/manga/search` 的分页响应。
 */
@Serializable
class MangaListDto(
    val items: List<MangaDto>,
    val total: Long,
)

/**
 * 漫画条目。服务端把列表与详情统一成同一模型，这里也复用同一个 DTO。
 */
@Serializable
class MangaDto(
    private val id: String,
    private val title: String,
    private val author: String? = null,
    private val description: String? = null,
    private val genre: String? = null,
    private val tags: List<String> = emptyList(),
    private val cover: String? = null,
) {
    fun toSManga(baseUrl: String) = SManga.create().apply {
        // url 只放 AMMDS 的稳定主键，Web 地址由 getMangaUrl() 拼装
        url = this@MangaDto.id
        title = this@MangaDto.title
        this@MangaDto.author?.takeIf { it.isNotBlank() }?.let { author = it }
        this@MangaDto.description?.takeIf { it.isNotBlank() }?.let { description = it }
        // 远端封面由服务端原样透传，仓库内的封面则返回 /api/mihon 下的相对地址
        thumbnail_url = this@MangaDto.cover?.let { if (it.startsWith("/")) baseUrl + it else it }
        genre = (listOfNotNull(this@MangaDto.genre) + this@MangaDto.tags)
            .filter { it.isNotBlank() }
            .joinToString(", ")
        status = SManga.UNKNOWN
    }
}

/**
 * `/api/mihon/manga/{id}/chapters` 的响应。
 */
@Serializable
class ChapterListDto(
    val items: List<ChapterDto>,
)

/**
 * 章节条目。
 * <p>
 * url 记的是 `相册ID/章节ID`：Mihon 的「在 WebView 中打开」需要一个同时包含两者的阅读器地址，
 * 而 AMMDS 阅读器正是以 `?comic=&chapter=` 两个查询参数定位章节的。
 */
@Serializable
class ChapterDto(
    private val id: String,
    private val title: String? = null,
    private val number: Int = 0,
    private val publishedAt: String? = null,
) {
    fun toSChapter(mangaId: String) = SChapter.create().apply {
        url = "$mangaId/${this@ChapterDto.id}"
        name = this@ChapterDto.title?.takeIf { it.isNotBlank() } ?: "第 ${this@ChapterDto.number} 章"
        chapter_number = this@ChapterDto.number.toFloat()
        date_upload = Instant.tryParse(this@ChapterDto.publishedAt)
    }
}

/**
 * `/api/mihon/chapter/{id}/pages` 的响应。
 */
@Serializable
class PageListDto(
    val items: List<PageDto>,
)

/**
 * 章节页。服务端返回的是 `/api/mihon/page/{id}/image` 相对地址，这里补全为可直接加载的绝对地址。
 */
@Serializable
class PageDto(
    private val page: Int,
    private val url: String,
) {
    fun toPage(baseUrl: String) = Page(
        this@PageDto.page - 1,
        imageUrl = this@PageDto.url.let { if (it.startsWith("/")) baseUrl + it else it },
    )
}

/**
 * `/api/mihon/auth/me` 的响应，用于「测试连接」。
 */
@Serializable
class UserDto(
    val id: String,
    val username: String,
    val displayName: String,
)
