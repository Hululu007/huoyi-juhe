package com.fanrenxiuxianguanyingchuan

/** 应用层看到的 TDLib 登录状态机（照 TeleTV 的 AuthState 抄，手机号登录按修仙版需要加状态）。 */
sealed interface TdlibAuthState {
    /** TDLib 正在启动，还没定论。 */
    data object Initializing : TdlibAuthState

    /**
     * 等用户选登录方式：输手机号发验证码，或扫码。
     * 注意：这里不能像 TeleTV 那样一到 waitPhoneNumber 就自动要二维码——
     * 要了码状态就走到 waitOtherDeviceConfirmation，setAuthenticationPhoneNumber
     * 便不再合法，手机号登录就发不出验证码。所以先停在这里，等 Dart 侧选。
     */
    data object WaitPhoneNumber : TdlibAuthState

    /** 把这个登录链接画成二维码，手机扫码登录。 */
    data class ShowQr(val link: String) : TdlibAuthState

    /**
     * 短信验证码已发，等用户输码。[phoneNumber] 是收码的号码，
     * [timeout] 是码的有效秒数，[error] 是上次输错/过期的报错，
     * [checking] 是正在提交验证码。
     */
    data class WaitCode(
        val phoneNumber: String? = null,
        val timeout: Int? = null,
        val error: String? = null,
        val checking: Boolean = false,
    ) : TdlibAuthState

    /**
     * QR 扫完或码输完后，账号开了二步验证密码。
     * [hint] 是用户设的密码提示（没设为 null），[error] 是上次输错的报错，
     * [checking] 是正在提交密码。
     */
    data class WaitPassword(
        val hint: String? = null,
        val error: String? = null,
        val checking: Boolean = false,
    ) : TdlibAuthState

    /** 该手机号还没注册过 Telegram，等用户填名字完成注册。 */
    data object WaitRegistration : TdlibAuthState

    /** 已登录，可以拉数据。 */
    data object Ready : TdlibAuthState

    /** 不可恢复的错（凭证缺失、TDLib 报错）。 */
    data class Error(val message: String) : TdlibAuthState

    /** 正在退出：TDLib 在关会话（应用内退出或外部吊销）。
     *  过渡态，关完走到 [LoggedOut]。 */
    data object SigningOut : TdlibAuthState

    /** 会话已关。过渡态：应用清掉本地账号状态、重建 TDLib 客户端、
     *  重新进手机号/扫码登录，不是终态页面。 */
    data object LoggedOut : TdlibAuthState
}
