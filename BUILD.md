# 出包速查

## 一、GitHub Actions（推荐）

```bash
cd WBHub-iOS
git init
git add -A
git commit -m "WB Hub 1.0.0"
git branch -M main
git remote add origin https://github.com/<你的账号>/WBHub.git
git push -u origin main
```

推送后打开仓库 → **Actions** → `Build unsigned IPA` → 跑完在 **Artifacts** 里下 `WBHub-unsigned-ipa.zip`，里面就是 `WBHub.ipa`。

工作流做的事：
1. `macos-14` runner + Xcode 15.4
2. `xcodebuild -sdk iphoneos ARCHS=arm64` 编 Release
3. 全程 `CODE_SIGNING_ALLOWED=NO`，产物是未签名 `.app`
4. 打成 `Payload/WBHub.app` + zip → `WBHub.ipa`
5. 上传 Artifact（保留 30 天）

## 二、本机 Mac

```bash
cd WBHub-iOS
chmod +x build.sh
./build.sh
# 产物 ./WBHub.ipa
```

## 三、Xcode 直接跑

```bash
open WBHub.xcodeproj
```

- 真机调试：Target → Signing & Capabilities → 勾 Automatically manage signing → 选自己的 Team
- 出未签名包：

```bash
xcodebuild -project WBHub.xcodeproj -scheme WBHub -configuration Release \
  -sdk iphoneos -derivedDataPath build \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS="" build
```

产物在 `build/Build/Products/Release-iphoneos/WBHub.app`。

## 四、装到手机

| 方式 | 步骤 |
| --- | --- |
| 巨魔 TrollStore | 把 ipa 传到手机 → TrollStore → + → 选中 → Install |
| Sideloadly | 连电脑 → 拖 ipa → 填 Apple ID → Start → 手机信任描述文件 |
| AltStore | AltServer 装好 → 手机 AltStore → + → 选 ipa |
| Esign / Scarlet | 手机端导入 ipa → 选证书 → 装 |
| 证书重签 | `codesign -f -s "证书" --entitlements WBHub/WBHub.entitlements Payload/WBHub.app` 再 zip |

Bundle ID：`com.xiaoshuai.wbhub`

## 五、验证

```bash
# 手机和电脑同一 Wi-Fi，把 IP 换成手机局域网地址
curl http://192.168.x.x:8788/health
curl http://192.168.x.x:8788/v1/models -H "Authorization: Bearer sk-xxxx"

curl http://192.168.x.x:8788/v1/chat/completions \
  -H "Authorization: Bearer sk-xxxx" \
  -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"ping"}],"stream":true}'
```
