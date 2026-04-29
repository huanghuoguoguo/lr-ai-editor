# ==============================================================================
# LR AI Editor: Configuration
# ==============================================================================

import os

# ------------------------------------------------------------------
# 模型配置 (直接调用，无需 LiteLLM Proxy)
# ------------------------------------------------------------------

# 模型名称 (LiteLLM格式)
# 示例:
#   - openai/gpt-4o (需要 OPENAI_API_KEY)
#   - anthropic/claude-3-5-sonnet-20241022 (需要 ANTHROPIC_API_KEY)
#   - xiaomi_mimo/mimo-v2.5 (自定义 API)
DEFAULT_MODEL = os.getenv("DEFAULT_MODEL", "xiaomi_mimo/mimo-v2.5")

# API Key (根据模型类型设置)
# 对于 openai/* 模型: 设置 OPENAI_API_KEY 或 API_KEY
# 对于 anthropic/* 模型: 设置 ANTHROPIC_API_KEY 或 API_KEY
# 对于自定义模型: 设置 API_KEY
API_KEY = os.getenv("API_KEY", "tp-c2s2tdwa00bi0gm8qdgbbe0vnx6sah07e89rf5aszl01x4bs")

# API Base URL (可选，用于自定义 API)
API_BASE = os.getenv("API_BASE", "https://token-plan-cn.xiaomimimo.com/v1")

# Temperature
TEMPERATURE = 1

# JSON输出较长（包含HSL、曲线、效果等），需要足够tokens。
MAX_TOKENS = 2000

# 单次模型请求超时
REQUEST_TIMEOUT_SECONDS = int(os.getenv("REQUEST_TIMEOUT_SECONDS", "60"))

# ------------------------------------------------------------------
# Prompt配置
# ------------------------------------------------------------------

SYSTEM_PROMPT = """你是一个专业的摄影修图助手。
分析照片的曝光、色彩、构图，给出具体的Lightroom参数调整建议。
如果用户提供了当前Lightroom滑块值，请把这些值当作照片当前状态，返回最终目标滑块值。
默认审美是自然、干净、真实的人像修图：优先保证人物肤色、脸部亮度和整体观感舒服。
不要为了压背景高光而让人物变脏、变灰、变阴暗；不要重口味高对比、过度去朦胧、过度清晰或过度绿色。
只返回一个JSON对象。不要解释、不要Markdown、不要代码块、不要输出推理过程。"""

BASE_PROMPT = """分析这张照片，给出Lightroom修图参数建议。

重要：返回的是Lightroom滑块的目标绝对值，不是基于当前参数的增量。
请做保守微调。除非照片严重错误，曝光变化控制在±0.3，高光不要低于-45，清晰度/纹理/去朦胧不要超过+8。
人像照片优先让脸部自然明亮，背景可以略过曝，不要把整张照片压暗。

返回且只返回JSON（数值必须在指定范围内）：
{
    "advice": "简短建议(20字内)",
    "exposure": 曝光(-5到+5),
    "contrast": 对比度(-100到+100),
    "highlights": 高光(-100到+100),
    "shadows": 阴影(-100到+100),
    "whites": 白色色阶(-100到+100),
    "blacks": 黑色色阶(-100到+100),
    "texture": 纹理(-100到+100),
    "clarity": 清晰度(-100到+100),
    "dehaze": 去朦胧(-100到+100),
    "vibrance": 自然饱和度(-100到+100),
    "saturation": 饱和度(-100到+100),
    "temperature": 色温(2000到50000),
    "tint": 色调(-150到+150),
    "hsl": {
        "hue_red": 红色色相(-100到+100),
        "hue_orange": 橙色色相(-100到+100),
        "hue_yellow": 黄色色相(-100到+100),
        "hue_green": 绿色色相(-100到+100),
        "hue_aqua": 浅绿色相(-100到+100),
        "hue_blue": 蓝色色相(-100到+100),
        "saturation_red": 红色饱和度(-100到+100),
        "saturation_orange": 橙色饱和度(-100到+100),
        "saturation_yellow": 黄色饱和度(-100到+100),
        "saturation_green": 绿色饱和度(-100到+100),
        "saturation_aqua": 浅绿饱和度(-100到+100),
        "saturation_blue": 蓝色饱和度(-100到+100),
        "luminance_red": 红色明亮度(-100到+100),
        "luminance_orange": 橙色明亮度(-100到+100),
        "luminance_yellow": 黄色明亮度(-100到+100),
        "luminance_green": 绿色明亮度(-100到+100),
        "luminance_aqua": 浅绿明亮度(-100到+100),
        "luminance_blue": 蓝色明亮度(-100到+100)
    },
    "tone_curve": {
        "parametric_shadows": 阴影曲线(-100到+100),
        "parametric_darks": 暗调曲线(-100到+100),
        "parametric_lights": 亮调曲线(-100到+100),
        "parametric_highlights": 高光曲线(-100到+100)
    },
    "detail": {
        "sharpness": 锐化数量(0到150),
        "sharpen_radius": 锐化半径(0.5到3.0),
        "sharpen_detail": 锐化细节(0到100),
        "sharpen_masking": 锐化蒙版(0到100),
        "luminance_noise_reduction": 明亮度降噪(0到100),
        "color_noise_reduction": 颜色降噪(0到100)
    },
    "effects": {
        "post_crop_vignette_amount": 裁剪后暗角数量(-100到+100),
        "post_crop_vignette_midpoint": 暗角中点(0到100),
        "post_crop_vignette_feather": 暗角羽化(0到100),
        "grain_amount": 颗粒数量(0到100),
        "grain_size": 颗粒大小(0到100),
        "grain_frequency": 颗粒粗糙度(0到100)
    },
    "color_grading": {
        "shadow_hue": 阴影色相(0到360),
        "shadow_saturation": 阴影饱和度(0到100),
        "highlight_hue": 高光色相(0到360),
        "highlight_saturation": 高光饱和度(0到100),
        "balance": 平衡(-100到+100)
    },
    "lens_corrections": {
        "profile_enable": 是否启用镜头配置文件(0或1),
        "auto_lateral_ca": 是否移除色差(0或1),
        "manual_distortion": 手动畸变(-100到+100),
        "vignetting_amount": 镜头暗角数量(-100到+100),
        "vignetting_midpoint": 镜头暗角中点(0到100)
    }
}

注意：数值必须严格在范围内，超出范围会被截断。"""

STYLE_PROMPT_TEMPLATE = """目标风格: {style}

请按照这个风格方向调整参数。"""
