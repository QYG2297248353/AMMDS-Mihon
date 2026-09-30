package eu.kanade.tachiyomi.extension.all.ammds

import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import android.text.InputType
import androidx.preference.EditTextPreference
import androidx.preference.PreferenceScreen
import eu.kanade.tachiyomi.source.ConfigurableSource
import eu.kanade.tachiyomi.source.UnmeteredSource
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import keiyoushi.annotation.Source
import keiyoushi.network.get
import keiyoushi.source.KeiSource
import keiyoushi.utils.getPreferencesLazy
import keiyoushi.utils.parseAs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import okhttp3.Dns
import okhttp3.Headers
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Response
import java.io.IOException

/**
 * AMMDS 漫画源。
 * <p>
 * AMMDS 是自托管漫画管理服务，因此这个源与普通网站源有三处关键差异：
 * <ul>
 *   <li>服务器地址由用户填写（`baseUrl { custom(...) }` 生成设置项），不写死；</li>
 *   <li>用「Mihon 授权码」鉴权，而不是账号密码——授权码可单独撤销、可设过期时间，
 *       用户不必把 AMMDS 密码交给阅读器；</li>
 *   <li>实现 [UnmeteredSource]：这是用户自己的服务器，不应按公共漫画站限流。</li>
 * </ul>
 * 所有漫画、章节、页面与图片都只经过 `/api/mihon`，扩展拿不到也不需要真实存储路径。
 * <p>
 * 类必须是抽象的：`baseUrl { custom(...) }` 由 KSP 生成注入 baseUrl 的子类，
 * 抽象基类才是该模式的正确形态（`name` / `lang` / `id` 同样由 DSL 注入，不要在此声明）。
 *
 * @author ms
 */
@Source
abstract class Ammds :
    KeiSource(),
    ConfigurableSource,
    UnmeteredSource {

    private val preferences: SharedPreferences by getPreferencesLazy()

    private val authorizationCode: String
        get() = preferences.getString(PREF_AUTHORIZATION_CODE, "")!!.trim()

    override fun Headers.Builder.configureHeaders() = apply {
        if (authorizationCode.isNotBlank()) {
            set("Authorization", "Bearer $authorizationCode")
        }
    }

    override fun OkHttpClient.Builder.configureClient() = apply {
        // 自托管服务器常以局域网 IP 或私有域名部署，DoH 解析不到这些地址
        dns(Dns.SYSTEM)
    }

    /**
     * 浏览：按标题升序返回整个书库。
     * <p>
     * 自建书库没有「热度」可言，稳定可预期的顺序比任何推荐排序都更有用。
     */
    override suspend fun getPopularManga(page: Int): MangasPage = getMangaList(PATH_MANGA, page, sort = "title", order = "asc")

    override suspend fun getLatestUpdates(page: Int): MangasPage = getMangaList(PATH_MANGA, page, sort = "updatedAt", order = "desc")

    override suspend fun getSearchMangaList(page: Int, query: String, filters: FilterList): MangasPage = if (query.isBlank()) {
        getPopularManga(page)
    } else {
        getMangaList(PATH_MANGA_SEARCH, page, query = query)
    }

    /**
     * 拉取一页漫画列表。
     *
     * @param path  接口路径（列表或搜索）
     * @param page  页码，从 1 开始
     * @param query 搜索关键词，仅搜索接口使用
     * @param sort  服务端排序字段
     * @param order 排序方向
     * @return 漫画分页结果
     */
    private suspend fun getMangaList(
        path: String,
        page: Int,
        query: String? = null,
        sort: String? = null,
        order: String? = null,
    ): MangasPage {
        val url = apiUrl(path).newBuilder()
            .addQueryParameter("page", page.toString())
            .addQueryParameter("pageSize", PAGE_SIZE.toString())
            .apply {
                query?.let { addQueryParameter("q", it) }
                sort?.let { addQueryParameter("sort", it) }
                order?.let { addQueryParameter("order", it) }
            }
            .build()

        val data = request(url).parseAs<MangaListDto>()
        return MangasPage(data.items.map { it.toSManga(baseUrl) }, page * PAGE_SIZE < data.total)
    }

    override suspend fun fetchMangaUpdate(
        manga: SManga,
        chapters: List<SChapter>,
        fetchDetails: Boolean,
        fetchChapters: Boolean,
    ): SMangaUpdate = coroutineScope {
        val details = async { if (fetchDetails) getMangaDetails(manga.url) else manga }
        val chapterList = async { if (fetchChapters) getChapterList(manga.url) else chapters }
        SMangaUpdate(details.await(), chapterList.await())
    }

    /**
     * 拉取漫画详情。
     *
     * @param mangaId 漫画 ID
     * @return 漫画详情
     */
    private suspend fun getMangaDetails(mangaId: String): SManga = request(apiUrl("$PATH_MANGA/$mangaId")).parseAs<MangaDto>().toSManga(baseUrl)

    /**
     * 拉取章节列表。
     * <p>
     * 服务端按章节序号升序返回，这里倒序排列：阅读器把最新章节放在最前面更符合阅读习惯。
     *
     * @param mangaId 漫画 ID
     * @return 章节列表
     */
    private suspend fun getChapterList(mangaId: String): List<SChapter> = request(apiUrl("$PATH_MANGA/$mangaId/chapters"))
        .parseAs<ChapterListDto>()
        .items
        .map { it.toSChapter(mangaId) }
        .sortedByDescending { it.chapter_number }

    override suspend fun getPageList(chapter: SChapter): List<Page> {
        val chapterId = chapter.chapterId
        val data = request(apiUrl("$PATH_CHAPTER/$chapterId/pages")).parseAs<PageListDto>()
        return data.items.map { it.toPage(baseUrl) }
    }

    /**
     * 通过 Web 详情页地址反查漫画，支持把 `…/home/comic/details/{id}` 直接丢进搜索框。
     *
     * @param url 待识别的地址
     * @return 漫画详情；不是本站地址或不是详情页时返回 null
     */
    override suspend fun getMangaByUrl(url: HttpUrl): SManga? {
        val host = baseUrl.toHttpUrlOrNull()?.host ?: return null
        if (url.host != host) {
            return null
        }
        val segments = url.pathSegments
        val index = segments.indexOf("details")
        if (index < 0) {
            return null
        }
        val mangaId = segments.getOrNull(index + 1)?.takeIf { it.isNotBlank() } ?: return null
        return getMangaDetails(mangaId)
    }

    override fun getMangaUrl(manga: SManga) = "$baseUrl/home/comic/details/${manga.url}"

    override fun getChapterUrl(chapter: SChapter) = "$baseUrl/home/comic/reader?comic=${chapter.mangaId}&chapter=${chapter.chapterId}"

    override fun setupPreferenceScreen(screen: PreferenceScreen) {
        val codePreference = EditTextPreference(screen.context).apply {
            key = PREF_AUTHORIZATION_CODE
            title = "授权码"
            summary = CODE_HINT
            setDefaultValue("")
            dialogTitle = "授权码"
            dialogMessage = "AMMDS 管理端 → 系统 → 密钥管理 → 新建密钥，类型选「Mihon 扩展」"
            setOnBindEditTextListener {
                it.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            }
        }

        // 监听器单独挂载：在 codePreference 的初始化表达式里引用它自身会编译不过
        codePreference.setOnPreferenceChangeListener { _, newValue ->
            codePreference.summary = maskedCode(newValue as String)
            verifyConnection(codePreference)
            true
        }

        screen.addPreference(codePreference)
        verifyConnection(codePreference)
    }

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * 校验服务器地址与授权码，并把结果写回授权码那一项的说明文字。
     * <p>
     * 扩展 API 里的 {@code Preference} 是没有 {@code (Context)} 构造器的编译期桩，
     * 因此不能像普通 AndroidX 用法那样再加一个「测试连接」按钮；
     * 改为打开设置页与修改授权码时自动校验一次，结果直接显示在设置项上。
     * <p>
     * 失败原因分两类提示：「连不上」（地址/网络问题）与「连上了但授权码不对」，
     * 用户据此就知道该改服务器地址还是该换授权码。
     *
     * @param preference 授权码设置项，用于回显校验结果
     */
    private fun verifyConnection(preference: EditTextPreference) {
        if (authorizationCode.isBlank()) {
            preference.summary = CODE_HINT
            return
        }

        preference.summary = "正在校验…"
        scope.launch {
            val summary = try {
                val user = request(apiUrl(AUTH_ME_PATH)).parseAs<UserDto>()
                "✓ 已连接：${user.displayName}"
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                "✕ ${e.message}"
            }

            mainHandler.post { preference.summary = summary }
        }
    }

    /**
     * 把授权码遮蔽为等长的星号，避免设置页明文展示长期凭证。
     *
     * @param code 授权码
     * @return 遮蔽后的说明文字
     */
    private fun maskedCode(code: String) = if (code.isBlank()) CODE_HINT else "*".repeat(code.trim().length)

    /**
     * 发起 GET 请求，并把 HTTP 状态码翻译成用户能看懂的提示。
     * <p>
     * Mihon 只把非 2xx 当错误，而服务端返回的英文状态文本对用户没有意义，
     * 因此这里按协议约定逐类转换（见 TODO.md「二十、错误处理」）。
     *
     * @param url 请求地址
     * @return 响应，调用方负责用 parseAs 消费并关闭
     * @throws IllegalStateException 请求失败时抛出，message 面向用户
     */
    private suspend fun request(url: HttpUrl): Response {
        val response = try {
            client.get(url, ensureSuccess = false)
        } catch (e: IOException) {
            throw IllegalStateException("无法连接 AMMDS 服务器，请检查服务器地址与网络", e)
        }

        if (response.isSuccessful) {
            return response
        }

        val code = response.code
        response.close()
        throw IllegalStateException(
            when (code) {
                401 -> "授权码无效或已过期，请在扩展设置中重新填写"
                403 -> "当前账号没有访问该资源的权限"
                404 -> "漫画、章节或页面不存在，可能已在服务端删除"
                429 -> "请求过于频繁，请稍后再试"
                else -> "AMMDS 服务端异常（HTTP $code）"
            },
        )
    }

    /**
     * 拼装 `/api/mihon` 下的绝对地址。
     *
     * @param path 以 `/` 开头的协议路径
     * @return 绝对地址
     */
    private fun apiUrl(path: String) = "$baseUrl$path".toHttpUrl()

    /**
     * 章节 url 中的章节 ID：url 形如 `相册ID/章节ID`。
     */
    private val SChapter.chapterId: String
        get() = url.substringAfterLast('/')

    /**
     * 章节 url 中的相册 ID。
     */
    private val SChapter.mangaId: String
        get() = url.substringBefore('/')
}

private const val PAGE_SIZE = 20
private const val PATH_MANGA = "/api/mihon/manga"
private const val PATH_MANGA_SEARCH = "/api/mihon/manga/search"
private const val PATH_CHAPTER = "/api/mihon/chapter"
private const val AUTH_ME_PATH = "/api/mihon/auth/me"
private const val PREF_AUTHORIZATION_CODE = "authorization_code"
private const val CODE_HINT = "必填：在 AMMDS 管理端「密钥管理」中创建「Mihon 扩展」类型的密钥"
