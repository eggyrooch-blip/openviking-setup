# openviking-setup

> OpenViking × OpenClaw 一键配置脚本 — 单用户多 Agent 记忆共享方案

## 原项目致谢

本脚本基于 [volcengine/OpenViking](https://github.com/volcengine/OpenViking) 构建，OpenViking 是字节火山引擎开源的 AI Agent 上下文数据库，使用 Apache-2.0 许可证。感谢项目作者的出色工作。

## 这个脚本解决了什么

配置 OpenViking 作为 OpenClaw 记忆后端，需要手动完成：

| 步骤 | 复杂度 | 脚本是否自动完成 |
|------|--------|----------------|
| 创建 Python venv（必须用 Homebrew，非系统 Python） | 易踩坑 | ✅ |
| 安装 Go 并从源码编译 AGFS 库（`libagfsbinding.dylib`） | 复杂 | ✅ |
| 写入 `ov.conf`（VLM + Embedding 配置） | 繁琐 | ✅ |
| 下载并注册 OpenClaw 插件 | 多文件 | ✅ |
| 配置 LaunchAgent 开机自启（含 env vars） | 易出错 | ✅ |
| `gateway install --force` 后重新注入 env vars | **常见陷阱** | ✅ |
| 输出 `ov status` 验收结果 | 手动验证 | ✅ |

最容易漏的一步：`openclaw gateway install --force` 会重写 plist 导致 env vars 丢失，脚本会自动在重启后重新注入。

## ⚠️ 平台支持

| 平台 | 支持 | 安装方式 |
|------|------|---------|
| **macOS** | ✅ | 本脚本 `setup-openviking.sh` |
| **Linux** | ❌ 本脚本不支持 | 使用官方 `install.sh` |
| **Windows** | ❌ 本脚本不支持 | 使用官方 `install.ps1` |

Linux / Windows 用户请前往官方仓库获取对应安装脚本：
[volcengine/OpenViking / examples/openclaw-memory-plugin](https://github.com/volcengine/OpenViking/tree/main/examples/openclaw-memory-plugin)

### macOS 前置条件

- Homebrew 已安装
- OpenClaw >= 3.0 已安装
- 一个 OpenAI 兼容的 API Key（用于 Embedding 和 VLM）

推荐 API 服务：[EdgeFN 白山智算](https://ai.baishan.com)，同时支持 `BAAI/bge-m3`（Embedding）和 `GLM-4.5V`（VLM），国内直连，OpenAI 兼容。

## 快速开始

```bash
git clone https://github.com/eggyrooch-blip/openviking-setup.git
cd openviking-setup
bash setup-openviking.sh
```

脚本运行过程中会：
1. 展示配置预览，确认后才继续
2. 遇到已有配置时询问是否覆盖
3. 完成后输出 `ov status` 和已处理的记忆列表

## 自定义 API 服务

脚本默认使用 EdgeFN，你也可以通过环境变量替换为任何 OpenAI 兼容服务：

```bash
OPENVIKING_API_BASE="https://api.siliconflow.cn/v1" \
OPENVIKING_API_KEY="your-key" \
OPENVIKING_EMB_MODEL="BAAI/bge-m3" \
OPENVIKING_VLM_MODEL="Qwen/Qwen2.5-VL-72B-Instruct" \
bash setup-openviking.sh
```

## 脚本做了什么（8 步）

```
Step 1: 创建 Python venv（用 Homebrew Python 3.10+）
Step 2: 安装 Go（如未安装）
Step 3: 从源码编译 AGFS 库（libagfsbinding.dylib）
Step 4: 写入 ov.conf（VLM + Embedding 模型配置）
Step 5: 注入环境变量（openviking.env + plist）
Step 6: 部署 OpenClaw 插件 + 配置参数
Step 7: 重启 Gateway + 重新注入 env vars（关键步骤）
Step 8: 迁移 OpenClaw 原生记忆（可选，检测到数据时询问）
```

## 运行效果

脚本完成后会输出：

```
════════════════════════════════════════════════
  安装完成！以下是当前服务状态
════════════════════════════════════════════════

[健康检查]
  OpenViking health: {"status":"ok"}

[ov status]
[queue] (healthy)
...

[已处理的记忆 — viking://user/default/memories/]
...
```

## 迁移 OpenClaw 原生记忆

如果你之前使用过 OpenClaw 的原生记忆功能，可以用 `migrate-memory.py` 将历史记忆导入 OpenViking：

```bash
# 预览（不写入）
python3 migrate-memory.py

# 迁移默认 agent（main）
python3 migrate-memory.py --execute

# 迁移所有 agent
python3 migrate-memory.py --all --execute
```

**原理：** 脚本读取 `~/.openclaw/memory/{agent}.sqlite` 中的记忆文本，通过 OpenViking Sessions API 让 VLM 提取后写入 `viking://user/default/memories/`。

**注意：** 每条记忆需 VLM 处理（10-60 秒），记忆较多时整体耗时较长。脚本会在安装完成后自动询问是否运行。

## 常见问题

**`libagfsbinding.dylib not found`**
```bash
cd ~/OpenViking && ~/.openviking/venv/bin/pip install -e .
```

**`ModuleNotFoundError: No module named 'openviking.server'`**
```bash
rm -rf ~/.openviking/venv
/opt/homebrew/bin/python3 -m venv ~/.openviking/venv
~/.openviking/venv/bin/pip install openviking
```

**SSH 里 npm/openclaw 找不到**
```bash
export PATH=/opt/homebrew/bin:$PATH
```

## License

MIT — 本脚本。

OpenViking 原项目遵循 Apache-2.0，见 [volcengine/OpenViking](https://github.com/volcengine/OpenViking)。
