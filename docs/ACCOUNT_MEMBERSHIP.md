# LifePages 账号与会员接入

未登录时点击「我的」中的头像或用户名区域，可以使用 Apple、Google、邮箱验证码或密码登录。首次登录会绑定当前访客书稿。用已绑定的方式登录其他设备可以恢复原账号的书稿。已有邮箱账号可通过「忘记密码」验证邮箱并设置密码，也可以登录后从「我的 → 设置 → 绑定登录方式」添加 Apple 或 Google。会员购买待后续接入。

## 填写客户端配置

配置模板位于 [account_membership.example.json](../config/account_membership.example.json)。注册 LifePages 后填入本 App 的值，接入时作为 Flutter 的 `--dart-define-from-file` 配置使用。当前界面阶段尚未读取这些字段。

- iOS 登录使用 Runner 中的 `GoogleService-Info.plist`，项目为 `lifepages-980b0`，Bundle ID 为 `com.caoyuming.lifePages`。更换 Firebase 项目时，一并更新 Runner 的 Google 回调 URL Scheme。Apple 登录能力通过 Runner 的签名权限配置。
- iOS 登录插件通过 CocoaPods 构建。新增或修改原生插件后，停止当前调试，从 Flutter 或 `ios/Runner.xcworkspace` 重新运行并覆盖安装。热重载只更新 Dart 代码。
- 订阅接入时在 App Store Connect 配置月度和年度产品 ID。价格和币种从商店商品读取。当前版上架链接和 Apple 标准 EULA 见 [App Store 提审材料](APP_STORE_SUBMISSION.md)。
- 邮箱首次验证即创建 LifePages 邮箱账号，使用 LifePages 自己的账号记录。

## 服务端配置

在后端部署环境预留以下字段。

```dotenv
LIFEPAGES_FIREBASE_PROJECT_ID=
LIFEPAGES_FIREBASE_API_KEY=
LIFEPAGES_ASC_ISSUER_ID=
LIFEPAGES_ASC_KEY_ID=
LIFEPAGES_ASC_PRIVATE_KEY_FILE=
LIFEPAGES_SMTP_HOST=
LIFEPAGES_SMTP_PORT=
LIFEPAGES_SMTP_SECURE=
LIFEPAGES_SMTP_USER=
LIFEPAGES_SMTP_PASS=
LIFEPAGES_SMTP_FROM=
LIFEPAGES_EMAIL_CODE_SECRET=
```

Firebase 登录通过 Identity Platform 验证凭证。服务端可从上述环境变量读取配置，也可在发行目录的 `config/firebase_auth.json` 提供 `project_id` 和 `api_key`，与 iOS 客户端使用同一个 Firebase 项目。Apple 登录私钥配置在 Firebase 控制台。会员权益以服务端验证的 App Store 交易为准，购买和恢复共用这条验证流程。

邮箱验证码的邮件发件人显示名在代码中固定为 LifePages。SMTP 凭证和验证码签名密钥只在服务器配置。
