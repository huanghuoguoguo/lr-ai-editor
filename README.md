# LR AI Editor

Lightroom Classic AI修图助手 - MVP版本

## 功能

- 选中照片后，AI分析并给出修图建议
- 可指定风格方向（如"电影感"、"高对比黑白"等）
- 可选择直接应用AI推荐的参数

## 架构

```
Lightroom (Lua插件)
    ↓ 导出小预览图 (512-1024px)
    ↓ 写入请求JSON
Python Worker
    ↓ Base64编码图片
    ↓ 调用LiteLLM Proxy
视觉模型 (GPT-4o / Claude / Gemini / Ollama)
    ↓ 返回JSON (建议 + 参数)
Lightroom
    ↓ 显示结果对话框
    ↓ 可选：applyDevelopSettings() 应用参数
```

## 安装

### 1. 安装LiteLLM

```bash
pip install litellm
```

### 2. 创建LiteLLM配置

```yaml
# litellm_config.yaml
model_list:
  - model_name: gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: os.environ/OPENAI_API_KEY

  - model_name: claude-vision
    litellm_params:
      model: claude-3-5-sonnet-20241022
      api_key: os.environ/ANTHROPIC_API_KEY

  - model_name: local-vision
    litellm_params:
      model: ollama/llava
      api_base: http://localhost:11434

general_settings:
  master_key: your-master-key  # 可选
```

### 3. 启动LiteLLM Proxy

```bash
litellm --config litellm_config.yaml --port 4000
```

### 4. 安装Python Worker依赖

```bash
cd worker
pip install -r requirements.txt
```

### 5. 安装Lightroom插件

1. 将 `plugin` 文件夹重命名为 `LR_AI_Editor.lrplugin`
2. Lightroom → 文件 → 插件管理器 → 添加插件
3. 在插件设置中配置 `worker.py` 的路径

## 使用

1. 在Lightroom中选中一张照片
2. 菜单 → 文件 → 插件额外功能 → AI Analyze Photo
3. 选择模型、输入风格描述（可选）
4. 等待AI分析
5. 查看建议，选择是否应用参数

## 配置项

### config.lua

| 参数 | 说明 |
|------|------|
| litellmUrl | LiteLLM Proxy地址 |
| previewSize | 预览图尺寸 (512/768/1024) |
| previewQuality | 预览图质量 (0.5) |
| defaultModel | 默认模型名 |

### config.py

| 参数 | 说明 |
|------|------|
| LITELLM_BASE_URL | LiteLLM地址 |
| LITELLM_API_KEY | LiteLLM密钥 |
| DEFAULT_MODEL | 默认模型 |

## 图片大小控制

- 预览图尺寸: 512-1024px
- JPEG质量: 50%
- 不发送原图，严格控制体积

## 支持的调整参数

- Exposure (曝光)
- Contrast (对比度)
- Highlights (高光)
- Shadows (阴影)
- Saturation (饱和度)
- Temperature (色温)
- Tint (色调)