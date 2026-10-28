# Developer ID 签名与 Apple 公证

此流程供发布者使用，普通用户无需执行。现有下载包是否已公证，以对应 Release 的说明及校验结果为准；增加此脚本本身不代表公证完成。

## 前提

- 发布者自己的 Apple Developer 身份、有效的 **Developer ID Application** 证书及其私钥；Apple Development / iOS Distribution 不能替代。
- 与签名团队一致的 notarization 凭据。使用 Xcode 自带 `notarytool` 将凭据保存在本机 Keychain，避免放进仓库、环境文件、命令历史或聊天。
- 签名会公开发布者身份。脚本不会自动选择本机其他团队或公司的证书。

在终端运行下列交互式命令，由发布者自行输入 Apple ID、团队信息和 App 专用密码；不要将密码提交给维护者：

```sh
xcrun notarytool store-credentials codex-accounts-notary
```

## 构建、提交、恢复检查

`SIGNING_IDENTITY` 为自己 Developer ID Application 证书的 SHA-1 指纹或完整名称（不是私钥）；`NOTARY_PROFILE` 只是上一步保存的条目名。

```sh
export SIGNING_IDENTITY='YOUR_DEVELOPER_ID_CERTIFICATE_SHA1'
export NOTARY_PROFILE=codex-accounts-notary
export PUBLIC_DIST_DIR="$PWD/dist/signed"
./scripts/build.sh

python3 scripts/notarize.py prepare \
  --app "$PUBLIC_DIST_DIR/Codex Accounts Beta.app" --output "$PWD/.notarization/beta"
python3 scripts/notarize.py submit \
  --app "$PUBLIC_DIST_DIR/Codex Accounts Beta.app" --output "$PWD/.notarization/beta"
python3 scripts/notarize.py finish \
  --app "$PUBLIC_DIST_DIR/Codex Accounts Beta.app" --output "$PWD/.notarization/beta"
```

- 构建启用 Hardened Runtime；设置签名身份时要求安全时间戳，未设置时仍仅生成本地 ad-hoc 包。
- `submit` 只上传一次并保存提交ID。`finish` 查询已知提交；尚在处理时稍后重跑 `finish`，不要重新上传。
- 上传错误或中断且没有确认ID时，先用 `xcrun notarytool history --keychain-profile "$NOTARY_PROFILE"` 核对；脚本保留提交意图并拒绝静默重复上传。
- Apple返回 Accepted 后，才装订票据、验证票据和代码签名、运行Gatekeeper及distribution检查，最后重新打包并生成SHA-256。不要在签名/公证后修改程序文件。
- `finish` 成功产物为 `.notarization/beta/Codex-Accounts-notarized.zip`。未 Accepted 或校验失败时不应替换公开下载。

发布前还需对最终带隔离属性的下载副本进行首次打开验证，检查账号添加、WebKit和菜单栏。Apple公证通过通常可避免「无法验证开发者」阻拦，但系统仍可能显示首次下载打开确认或账号登录提示；不能承诺所有电脑完全无提示。

参考：[Apple 公证工作流](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)、[Developer ID 分发](https://developer.apple.com/developer-id/)。
