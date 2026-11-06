package com.fanrenxiuxianguanyingchuan

import android.os.Build
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.filterIsInstance
import kotlinx.coroutines.launch
import org.drinkless.tdlib.TdApi
import java.io.File

/**
 * 推 TDLib 的登录状态机，对外暴露应用层 [TdlibAuthState]（照 TeleTV 的 AuthRepository 抄）。
 *
 * 流程（手机号主路）：waitTdlibParameters -> setTdlibParameters ->
 *       waitPhoneNumber（停住，等用户选）-> setAuthenticationPhoneNumber ->
 *       waitCode（输短信验证码）-> [waitPassword（二步验证密码）->]
 *       [waitRegistration（未注册号填名字）->] ready。
 * 扫码备用路：waitPhoneNumber -> requestQrCodeAuthentication ->
 *       waitOtherDeviceConfirmation（出二维码）-> [waitPassword ->] ready。
 *
 * 与 TeleTV 的两处不同（修仙版需要）：
 * ① waitPhoneNumber 时不自动要二维码（否则手机号发不出码），等 Dart 侧选；
 * ② waitCode 不直接报错，做完整收码/输码/重发。
 *
 * 密码/验证码输错不会产生新的登录状态更新——TDLib 停在原状态，
 * 失败只体现在请求的错误回包里——所以重试循环由 [checkPassword] /
 * [checkCode] 自己管，失败时重发带错误的原状态。
 *
 * 与 TeleTV 的另一处不同：凭证与目录不从 BuildConfig/应用私有目录取，
 * 由 Dart 侧经 MethodChannel 传进来（凭证走构建期注入，目录是
 * getApplicationSupportDirectory()/tdlib）。
 */
class TdlibAuthRepository(
    private val client: TdlibClient,
    private val scope: CoroutineScope,
    private val apiId: Int,
    private val apiHash: String,
    private val databaseDir: File,
    private val filesDir: File,
    private val applicationVersion: String,
) {
    private val _state = MutableStateFlow<TdlibAuthState>(TdlibAuthState.Initializing)
    val state: StateFlow<TdlibAuthState> = _state.asStateFlow()

    // TDLib 是否正连着 Telegram。二维码登录链接只有连着时才刷新、才能确认；
    // 断开时正在显示的二维码是过期的，所以二维码页要显示“连不上”状态。
    private val _connected = MutableStateFlow(true)
    val connected: StateFlow<Boolean> = _connected.asStateFlow()
    private var disconnectJob: Job? = null

    private var parametersSent = false
    private var qrRequested = false
    private var lastAuthState: TdApi.AuthorizationState? = null

    fun start() {
        // 订阅后续的登录状态变化……
        scope.launch {
            client.updates
                .filterIsInstance<TdApi.UpdateAuthorizationState>()
                .collect { handle(it.authorizationState) }
        }
        // 跟踪连接健康度，供二维码页用。立刻重连就清掉警告；
        // 掉线先防抖，启动期常见的短暂重连不会闪“连不上”。
        scope.launch {
            client.updates
                .filterIsInstance<TdApi.UpdateConnectionState>()
                .collect { handleConnection(it.state) }
        }
        // ……再对一下当前状态，以防 TDLib 的第一条 updateAuthorizationState
        // 在上面订阅之前就发出来了（replay=0 的 SharedFlow 会丢掉，
        // 应用就卡在 Initializing）。
        scope.launch {
            runCatching { client.send<TdApi.AuthorizationState>(TdApi.GetAuthorizationState()) }
                .onSuccess { handle(it) }
                .onFailure { _state.value = TdlibAuthState.Error(it.message ?: "查询登录状态失败") }
        }
    }

    /**
     * Ready/Updating 表示连接是通的（Updating = 连着、正在同步）。
     * 其他状态表示没连上 Telegram，二维码刷不出来。
     */
    private fun handleConnection(state: TdApi.ConnectionState) {
        val live = state is TdApi.ConnectionStateReady || state is TdApi.ConnectionStateUpdating
        if (live) {
            disconnectJob?.cancel()
            disconnectJob = null
            _connected.value = true
        } else if (_connected.value && disconnectJob == null) {
            disconnectJob = scope.launch {
                delay(DISCONNECT_DEBOUNCE_MS)
                _connected.value = false
                disconnectJob = null
            }
        }
    }

    private suspend fun handle(authState: TdApi.AuthorizationState) {
        lastAuthState = authState
        // 二维码防重只针对同一次 waitPhoneNumber（更新订阅和启动对账
        // 可能都看到它）；其他状态都会结束这次，之后再进 waitPhoneNumber
        // 就重新要码。
        if (authState !is TdApi.AuthorizationStateWaitPhoneNumber) qrRequested = false
        when (authState) {
            is TdApi.AuthorizationStateWaitTdlibParameters -> setParameters()
            // 停住等用户选：手机号发验证码，或扫码。不要自动要二维码，
            // 否则 setAuthenticationPhoneNumber 不再合法。
            is TdApi.AuthorizationStateWaitPhoneNumber ->
                _state.value = TdlibAuthState.WaitPhoneNumber
            is TdApi.AuthorizationStateWaitOtherDeviceConfirmation ->
                _state.value = TdlibAuthState.ShowQr(authState.link)
            is TdApi.AuthorizationStateWaitCode ->
                _state.value = TdlibAuthState.WaitCode(
                    phoneNumber = authState.codeInfo.phoneNumber.takeIf { it.isNotBlank() },
                    timeout = authState.codeInfo.timeout.takeIf { it > 0 },
                )
            is TdApi.AuthorizationStateWaitPassword ->
                _state.value = TdlibAuthState.WaitPassword(
                    hint = authState.passwordHint.takeIf { it.isNotBlank() }
                )
            is TdApi.AuthorizationStateWaitRegistration ->
                _state.value = TdlibAuthState.WaitRegistration
            is TdApi.AuthorizationStateWaitEmailAddress,
            is TdApi.AuthorizationStateWaitEmailCode ->
                _state.value = TdlibAuthState.Error("需要邮箱验证登录，本路暂不支持，请用扫码登录。")
            is TdApi.AuthorizationStateReady -> _state.value = TdlibAuthState.Ready
            is TdApi.AuthorizationStateLoggingOut -> _state.value = TdlibAuthState.SigningOut
            is TdApi.AuthorizationStateClosed -> _state.value = TdlibAuthState.LoggedOut
            else -> Unit // Closing 等其他状态：界面不动
        }
    }

    /**
     * 退出：发 TDLib `LogOut`，它会清掉自己的本地数据库/文件，
     * 状态机走 loggingOut -> closed。请求失败（比如断网）经 [onError]
     * 上报，会话保持不动。
     */
    fun logOut(onError: (String) -> Unit) {
        scope.launch {
            runCatching { client.send<TdApi.Ok>(TdApi.LogOut()) }
                .onFailure { e -> onError(e.message ?: "退出登录失败") }
        }
    }

    /**
     * 扫码登录：要二维码。只能在等登录方式（waitPhoneNumber）或等密码
     * （waitPassword，换号重登）时调；正在显示二维码时直接返回当前状态
     * （链接由 TDLib 自动刷新）。
     */
    fun requestQrCode() {
        val authState = lastAuthState
        if (authState !is TdApi.AuthorizationStateWaitPhoneNumber &&
            authState !is TdApi.AuthorizationStateWaitPassword
        ) return
        scope.launch {
            runCatching { client.send<TdApi.Ok>(TdApi.RequestQrCodeAuthentication(LongArray(0))) }
                .onFailure { e ->
                    val s = _state.value
                    if (s is TdlibAuthState.WaitPassword) {
                        _state.value = s.copy(error = e.message, checking = false)
                    } else {
                        _state.value = TdlibAuthState.Error(e.message ?: "requestQrCodeAuthentication 失败")
                    }
                }
        }
    }

    /**
     * 手机号登录：发短信验证码。
     * 在 waitPhoneNumber 时按 [phone] 发码；在 waitCode 时是重发
     * （TDLib 只认原号码，换号请先重建客户端）。
     * 返回 "sent"（新发）或 "resent"（重发），失败抛异常说明原因。
     */
    suspend fun sendPhoneCode(phone: String): String {
        return when (val authState = lastAuthState) {
            is TdApi.AuthorizationStateWaitPhoneNumber -> {
                runCatching {
                    client.send<TdApi.Ok>(
                        TdApi.SetAuthenticationPhoneNumber(
                            phone,
                            TdApi.PhoneNumberAuthenticationSettings()
                        )
                    )
                }.onFailure { e -> throw phoneError(e) }.getOrThrow()
                "sent"
            }
            is TdApi.AuthorizationStateWaitCode -> {
                runCatching { client.send<TdApi.Ok>(TdApi.ResendAuthenticationCode()) }
                    .onFailure { e -> throw phoneError(e) }.getOrThrow()
                "resent"
            }
            null -> throw IllegalStateException("TDLib 还没就绪，请稍候再试")
            else -> throw IllegalStateException("当前状态不能发送验证码")
        }
    }

    /**
     * 验证码已发、用户要重发一遍：只能在 waitCode 时调。
     */
    suspend fun resendCode() {
        if (lastAuthState !is TdApi.AuthorizationStateWaitCode) {
            throw IllegalStateException("当前状态不能重新发送验证码")
        }
        runCatching { client.send<TdApi.Ok>(TdApi.ResendAuthenticationCode()) }
            .onFailure { e -> throw phoneError(e) }.getOrThrow()
    }

    /**
     * 提交短信验证码。成功后走正常的状态更新（-> Ready 或 -> WaitPassword）；
     * 失败重发带错误的 [TdlibAuthState.WaitCode]。重复提交直接忽略。
     */
    fun checkCode(code: String) {
        val current = _state.value as? TdlibAuthState.WaitCode ?: return
        if (current.checking) return
        _state.value = current.copy(error = null, checking = true)
        scope.launch {
            runCatching { client.send<TdApi.Ok>(TdApi.CheckAuthenticationCode(code)) }
                .onFailure { e ->
                    val message = when {
                        e is TdlibException && e.error.message == "PHONE_CODE_INVALID" ->
                            "验证码不正确，请重新输入"
                        e is TdlibException && e.error.message == "PHONE_CODE_EXPIRED" ->
                            "验证码已过期，请点“重新发送”再试一次"
                        else -> e.message ?: "验证码不正确，请重新输入"
                    }
                    // 只有还在等验证码时才把失败露出来。
                    val s = _state.value
                    if (s is TdlibAuthState.WaitCode) {
                        _state.value = s.copy(error = message, checking = false)
                    }
                }
        }
    }

    /**
     * 提交二步验证密码。成功后走正常的状态更新 -> Ready；
     * 失败重发带错误的 [TdlibAuthState.WaitPassword]。
     * 在仓库的 scope 上跑，提交中途切页面也不会断；重复提交直接忽略。
     */
    fun checkPassword(password: String) {
        val current = _state.value as? TdlibAuthState.WaitPassword ?: return
        if (current.checking) return
        _state.value = current.copy(error = null, checking = true)
        scope.launch {
            runCatching { client.send<TdApi.Ok>(TdApi.CheckAuthenticationPassword(password)) }
                .onFailure { e ->
                    val wrongPassword = e is TdlibException && e.error.message == "PASSWORD_HASH_INVALID"
                    val message = if (wrongPassword) {
                        "二步验证密码不正确，请重新输入"
                    } else {
                        e.message ?: "二步验证密码不正确，请重新输入"
                    }
                    // 只有还在等密码时才把失败露出来。
                    val s = _state.value
                    if (s is TdlibAuthState.WaitPassword) {
                        _state.value = s.copy(error = message, checking = false)
                    }
                }
        }
    }

    /**
     * 未注册的手机号：填名字完成注册。只能在 waitRegistration 时调。
     */
    suspend fun registerUser(firstName: String, lastName: String) {
        if (lastAuthState !is TdApi.AuthorizationStateWaitRegistration) {
            throw IllegalStateException("当前状态不需要填写名字")
        }
        runCatching {
            client.send<TdApi.Ok>(TdApi.RegisterUser(firstName, lastName, false))
        }.onFailure { e -> throw phoneError(e) }.getOrThrow()
    }

    /** 发码/重发/注册失败时，把 TDLib 的英文错误翻成能看懂的中文。 */
    private fun phoneError(e: Throwable): Throwable {
        if (e !is TdlibException) return e
        val message = when (e.error.message) {
            "PHONE_NUMBER_INVALID" -> "手机号格式不正确，请检查后重输"
            "PHONE_NUMBER_FLOOD" -> "该号码请求太频繁，请过一会儿再试"
            "PHONE_NUMBER_BANNED" -> "该号码被 Telegram 限制，请换个号码"
            "PHONE_CODE_INVALID" -> "验证码不正确，请重新输入"
            "PHONE_CODE_EXPIRED" -> "验证码已过期，请重新发送"
            "PHONE_NUMBER_UNOCCUPIED" -> "该号码还没注册过 Telegram"
            "FLOOD_WAIT" -> "请求太频繁，请过一会儿再试"
            else -> e.message ?: "发送验证码失败"
        }
        return IllegalStateException(message)
    }

    private suspend fun setParameters() {
        if (parametersSent) return
        if (apiId == 0 || apiHash.isBlank()) {
            _state.value = TdlibAuthState.Error("缺少 Telegram 凭证，扫码登录不可用。")
            return
        }
        parametersSent = true
        val params = TdApi.SetTdlibParameters().apply {
            useTestDc = false
            databaseDirectory = databaseDir.absolutePath
            filesDirectory = filesDir.absolutePath
            useFileDatabase = true
            useChatInfoDatabase = true
            useMessageDatabase = true
            useSecretChats = false
            apiId = this@TdlibAuthRepository.apiId
            apiHash = this@TdlibAuthRepository.apiHash
            systemLanguageCode = "zh"
            deviceModel = "Android"
            systemVersion = Build.VERSION.RELEASE ?: "Android"
            applicationVersion = this@TdlibAuthRepository.applicationVersion
        }
        runCatching { client.send<TdApi.Ok>(params) }
            .onFailure { _state.value = TdlibAuthState.Error(it.message ?: "setTdlibParameters 失败") }
    }

    private companion object {
        const val DISCONNECT_DEBOUNCE_MS = 2500L
    }
}
