# LifePages App Store 提审材料

适用于当前 iOS 版本。应用内以简体中文呈现。权限弹窗随系统语言提供简体中文和英文。

## App Store Connect 填写项

| 字段 | 内容 |
|---|---|
| App 名称 | LifePages |
| 副标题 | 口述故事，整理成回忆录 |
| Bundle ID | `com.caoyuming.lifePages` |
| 主要语言 | 简体中文 |
| 主要类别 | 生活 |
| 隐私政策网址 | `https://onesay.top/lifepages/privacy` |
| 技术支持网址 | `https://onesay.top/lifepages/support` |
| 用户隐私选项网址（可选） | `https://onesay.top/lifepages/permissions` |
| 许可协议 | 使用 Apple 默认标准 EULA |
| 关键词 | 回忆录,口述历史,讲述,家庭故事,录音,传记,成长记录,书稿,人生故事 |

隐私网址填在「App 隐私」，支持网址和介绍填在当前 iOS 版本资料。「App 信息 → 许可协议」保留 Apple 标准协议，应用内和简介中的链接指向官方 EULA。 [Apple 许可协议说明](https://developer.apple.com/help/app-store-connect/manage-app-information/provide-a-custom-license-agreement/) · [App 隐私填写说明](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)

### 简体中文简介

```text
把家人的讲述整理成一本回忆录。

从故乡、家庭和人生转折等主题开始。您可以打字，也可以按住麦克风记录原声。开启 AI 后，LifePages 可将讲述转写成文字，提出后续问题，并把素材整理成可供您确认的草稿。

在书架中选择章节模板，添加章节，自由编辑正文并插入照片。完成后可预览和导出 PDF，也可为章节生成原声二维码，把故事和讲述者的声音一起分享给家人。

隐私政策：https://onesay.top/lifepages/privacy
使用条款（Apple 标准 EULA）：https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
```

### 英文简介备选

仅在需要填写英文商店资料时使用。审核备注应说明当前 App 界面以简体中文显示。

```text
Turn spoken family stories into a memoir.

Start with a chapter template and record a story in your own voice or type it out. With your permission, LifePages can transcribe recordings, ask follow-up questions, and draft passages for you to review.

Edit your chapters, add photos, and export your book as a PDF. Add a QR code to share a chapter and its original recordings with family.

Privacy Policy: https://onesay.top/lifepages/privacy
Terms of Use (Apple Standard EULA): https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
```

### App Review 备注

```text
LifePages is a Chinese-language memoir editor. You can review the main flow as a guest.

1. Open 书架 (Bookshelf), create a book or open the default memoir, and select a chapter.
2. Open 聊天 (Chat). Send a text reply or press and hold the microphone. Review the Aliyun AI data disclosure and grant microphone access only if testing audio. The speaker button has a separate disclosure for Volcengine text-to-speech.
3. In 书架, open the book, edit a chapter, and use 插入图片 (Add Photo) to choose an image. Open 预览 (Preview) to review PDF export.
4. Go to 我的 → 设置 (Me → Settings) for Privacy Policy, Apple Terms of Use, Permissions, Support and AI Data Controls.

The app uses the microphone for voice input and the iOS photo picker for images. The RTC SDK includes camera interfaces. The app's recording and playback flows do not start the camera.
```

如果需要审核登录，请使用专用审核邮箱和已设置的密码，在审核信息的专用字段填写并验证。勿使用个人账号、一次性验证码或生产密钥。 [App Review 指南](https://developer.apple.com/app-store/review/guidelines/)

## App 隐私问卷

| 数据类型 | LifePages 用途 | 与用户关联 |
|---|---|---|
| 姓名 | 个人资料与回忆录署名 | 是 |
| 电子邮件地址 | 注册、登录、账号恢复 | 是 |
| 用户 ID | 访客身份、账户认证和书稿同步 | 是 |
| 照片或视频 | 头像和回忆录图片 | 是 |
| 音频数据 | 口述转写、原声播放与分享 | 是 |
| 其他用户内容 | 讲述、AI 聊天、书稿与记忆 | 是 |
| 产品交互 | 服务端记录每日 AI 追问用量 | 是 |
| 客户支持 | 用户主动发送的反馈与附件。若符合 Apple 的可选披露条件，可按实际情况判断。 | 按支持处理情况 |

上述应用内功能数据主要选「App 功能」。用于根据讲述内容生成个性化回复的内容同时评估「产品个性化」。当前 LifePages 自身没有广告或跨应用广告跟踪。最终问卷还需合并实际归档的 SDK 报告和供应商处理方式。现有归档中，FirebaseAuth 声明了用户 ID 与其他诊断数据，GoogleSignIn 还声明了姓名、电子邮件、电话、粗略位置、设备 ID、用户 ID、其他用量和其他数据。核对这些字段在本版本中的实际收集和用途后再提交。 [Apple 隐私数据分类](https://developer.apple.com/app-store/app-privacy-details/) · [第三方 SDK 要求](https://developer.apple.com/support/third-party-SDK-requirements/)

## 提交前确认

- **账号删除**。当前版本的支持页接受数据请求，应用内完整删号流程仍需实现并验证。该流程应删除账号及关联数据、注销会话，并处理通过 Apple 登录的授权撤销。 [Apple 账号删除要求](https://developer.apple.com/support/offering-account-deletion-in-your-app/)
- **支持邮箱**。沿用 ChatChat 技术支持邮箱 `jakiemanus@gmail.com`。确认该邮箱可受理 LifePages 用户请求。
- **截图与年龄分级**。使用当前版本画面。Runner 当前同时声明 iPhone 和 iPad，按相应设备准备截图。在 App Store Connect 完成现行年龄分级问卷。 [Apple 截图规格](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/) · [Apple 年龄分级](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating/)
- **出口合规**。按最终归档内的 Firebase、RTC 等 SDK 及上架地区完成加密问卷。 [Apple 出口合规](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)
- **会员**。当前界面仅展示月卡、年卡，购买和恢复购买尚未开放。当前版简介和审核备注只描述已可用的功能。
