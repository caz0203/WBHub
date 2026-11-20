# 推送说明

仓库已初始化：1 个 commit（`dd02e221`）、11 个 tree、35 个 blob，SHA 全部校验通过。
remote 已设成 `https://github.com/caz0203/WBHub.git`。

---

## 第一步：建空仓库

打开 https://github.com/new

| 字段 | 填什么 |
| --- | --- |
| Repository name | `WBHub` |
| 公开/私有 | 随意（Actions 免费额度公开仓库不扣） |
| Add a README file | **不要勾** |
| Add .gitignore | **不要勾** |
| Choose a license | **None** |

点 Create repository。**必须是空仓库**，否则 push 会冲突。

---

## 第二步：拿一个能推代码的 token

你刚才授权拿到的是 `ghu_` 开头的 **GitHub App 令牌**，它没有 repo 写权限（实测：建仓 403、push 403）。需要换成 Personal Access Token：

1. 打开 https://github.com/settings/tokens
2. 右上 **Generate new token** → **Generate new token (classic)**
3. Note 填 `WBHub`，Expiration 选 30 days
4. 勾选权限：
   - ☑ **repo**（整个大类，推代码必需）
   - ☑ **workflow**（上传 .github/workflows 必需，漏了会被拒）
5. 拉到底 **Generate token**
6. 复制 `ghp_...` 那串（只显示一次）

> 也可以走 Fine-grained token：Repository access 选 `WBHub`，Permissions → Contents = Read and write，Workflows = Read and write。

---

## 第三步：推送

在仓库目录执行：

```bash
cd WBHub-repo

git remote -v
# origin  https://github.com/caz0203/WBHub.git (fetch)
# origin  https://github.com/caz0203/WBHub.git (push)

git push -u origin main
```

弹出登录时：

- Username：`caz0203`
- Password：**粘贴 `ghp_...` token**（不是账号密码，不是恢复码）

想免交互：

```bash
git push https://caz0203:ghp_你的token@github.com/caz0203/WBHub.git main
```

推完刷新仓库页，应能看到 35 个文件。

---

## 第四步：拿 IPA

1. 仓库页 → **Actions** 标签
2. 左侧 `Build unsigned IPA` → 右侧 **Run workflow** → 绿色按钮
3. 等 6~8 分钟转绿
4. 点进这次运行 → 底部 **Artifacts** → `WBHub-unsigned-ipa`
5. 解压得到 `WBHub.ipa`

装手机：

- **TrollStore**：ipa 传手机 → TrollStore → + → 选中 → Install
- **Sideloadly**：连电脑 → 拖 ipa → 填 Apple ID → Start

---

## 备用方案：不用命令行

**GitHub 网页直接传（不用 token）**

1. 空仓库页点 `uploading an existing file`
2. 把 `WBHub-repo` 里除 `.git` 外的所有文件/文件夹拖进去
3. Commit changes

`.github/workflows/build.yml` 网页上传也能保留目录结构，Actions 照样能跑。

**Working Copy（iOS App）**

Clone 空仓库 → 把文件拷进 App 的目录 → Commit → Push（App 里填 token）

---

## 附：也可以直接让我推

把 `ghp_` 开头的 PAT 发我，我在这台机器上直接跑推送 + 触发 Actions + 等产物，全程不需要你再操作。
（这台机器 GitHub 网络已打通：api.github.com 走 140.82.112.6，git 走 140.82.112.3）
