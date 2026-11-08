# Pixel World 启动器接口

启动器从这里读取更新信息和公告，地址按顺序尝试：

1. `https://pixelworld.zhuzhi.site/api/v1/`
2. `https://raw.githubusercontent.com/zhuzhi-09/PixelWorld/site/docs/api/v1/`

都失败时，更新检查退回到 GitHub API，公告不显示。路径中的 `v1` 是格式版本：以后格式不兼容时新建 `v2`，`v1` 继续保留给旧版启动器。

## update.json

由发布工作流（`.github/workflows/release.yml` 的 Update API 步骤，脚本 `tool/update_api.py`）在每次发布后自动生成，**不要手动修改**。

## notices.json

公告，**手动维护**：编辑后提交到 `site` 分支即可，启动器每次打开时读取，显示在首页「Minecraft 版本动态」上方。

```json
{
  "format": 1,
  "notices": [
    {
      "id": "2026-11-05-example",
      "level": "info",
      "title": "标题",
      "body": "正文，支持 Markdown",
      "url": "https://github.com/zhuzhi-09/PixelWorld/releases",
      "urlText": "查看详情",
      "platforms": ["windows", "android", "macos"],
      "channels": ["stable", "preview", "nightly"],
      "minVersion": "0.3.0",
      "maxVersion": "0.4.0",
      "start": "2026-11-05T00:00:00+08:00",
      "end": "2026-11-12T00:00:00+08:00",
      "dismissible": true
    }
  ]
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `id` | 是 | 唯一标识。用户关闭后按 id 记住，不再显示；内容有重要修改时换一个 id |
| `level` | 否 | `info`（默认）、`warning`、`error`，决定图标和颜色 |
| `title` / `body` | 是 | 标题和正文，正文支持 Markdown |
| `url` / `urlText` | 否 | 操作按钮 |
| `platforms` | 否 | 只在这些平台显示，省略为全部 |
| `channels` | 否 | 只在这些更新通道显示，省略为全部 |
| `minVersion` / `maxVersion` | 否 | 只在这个版本范围内显示（包含两端） |
| `start` / `end` | 否 | 显示的时间范围 |
| `dismissible` | 否 | 能否关闭，默认 `true` |
