# AFMC FIND iPhone

原生 SwiftUI 客户端，默认用手机内嵌 TorrServerKit 搜索与磁力边下边播，不需要电脑桥接。这是独立的 iOS 应用仓库。验收记录留在本机的 AFMC-FIND 文档里，不放进这个仓库。

## 环境与构建

沿用现有 Xcode 27.2、Swift 5、iOS 18 最低版本；当前无需安装任何新工具。

```sh
cd ios
xcodebuild -project AFMC.xcodeproj -scheme AFMC \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build
xcodebuild test -project AFMC.xcodeproj -scheme AFMC \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -parallel-testing-enabled NO
```

`project.yml` 是 XcodeGen 源配置，仅在改变工程文件列表/配置时运行现有 `xcodegen generate`。

## 内嵌引擎

已安装官方 TorrServer MatriX.149 的 `TorrServerKit.xcframework`，位于 `../.tools/tskit/`，不提交二进制。来源：
https://github.com/YouROK/TorrServer/releases/tag/MatriX.149

启动后在手机 `127.0.0.1:8099` 运行；先添加资源，按返回哈希查询元数据，选择具体视频文件。引擎许可为 GPL-3.0，分发前需单独审查，不承诺 App Store 可发布。

## 调试验收

用户要求所有测试静音。Debug 版包含 `--auto-*` 的启动默认静音，其他测试也传 `--mute`。不改变系统音量；正常手动启动不强制静音。

- `--auto-query <关键词>`：搜索。
- `--auto-open <标题片段>`：搜索后进入详情。
- `--auto-magnet <磁力>` / `--auto-torrent <URL>`：内嵌播放。
- `--auto-detail-torrent <URL>`：通过真实详情流程验证文件选择。
- `--auto-play <视频 URL>`：直链播放。
- `--embedded`：使用内嵌引擎。
- `--debug-hud`：显示时间、速率、播放器状态及 muted 值。

回归证据留在本机，不放进这个仓库。合成多文件种子只验证元数据及选集流程，没有有效做种时不能作为播放成功证据。

## 真机安装

沿用已配置的开发签名，不新建账户或更改证书。iPhone 13 Pro 当前设备 ID：`00008110-001E3D182252801E`。

```sh
xcodebuild -project AFMC.xcodeproj -scheme AFMC -configuration Debug \
  -destination 'platform=iOS,id=00008110-001E3D182252801E' \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=CCGNJLM854 \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic build
```

构建和安装成功不代表完整功能通过；真机验收结果以当前状态入口为准。
