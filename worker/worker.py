# ==============================================================================
# LR AI Editor: Worker (使用LiteLLM SDK)
# ==============================================================================

import sys
import os
import json
import base64
import asyncio
from pathlib import Path
from litellm import acompletion  # 异步版本
import config


def truncate_text(text: str, limit: int = 6000) -> str:
    if not text:
        return ""
    if not isinstance(text, str):
        text = str(text)
    if len(text) <= limit:
        return text
    return text[:limit] + f"\n...[truncated {len(text) - limit} chars]"


def log(message: str) -> None:
    print(message, flush=True)


def extract_json_object(text: str) -> str:
    """Return the last top-level JSON object found in text, or an empty string."""
    if not text:
        return ""
    start = -1
    depth = 0
    in_string = False
    escaped = False
    matches: list[str] = []

    for idx, char in enumerate(text):
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue

        if char == '"':
            in_string = True
        elif char == "{":
            if depth == 0:
                start = idx
            depth += 1
        elif char == "}" and depth > 0:
            depth -= 1
            if depth == 0 and start >= 0:
                candidate = text[start:idx + 1]
                if '"advice"' in candidate:
                    matches.append(candidate)
                start = -1

    return matches[-1] if matches else ""


def extract_number_after(text: str, key: str) -> float | None:
    import re

    escaped = re.escape(key)
    patterns = [
        rf"{escaped}\s*[:：][^-\d+]*([-+]?\d+(?:\.\d+)?)",
        rf"{escaped}[^-\d+]*建议\s*([-+]?\d+(?:\.\d+)?)",
    ]
    for pattern in patterns:
        matches = re.findall(pattern, text, flags=re.IGNORECASE)
        if matches:
            return float(matches[-1])
    return None


def result_from_reasoning(reasoning: str, current_settings: dict | None = None) -> dict | None:
    if not reasoning:
        return None
    reasoning_for_params = reasoning.split("所有数值")[0]

    field_specs = {
        "exposure": ("exposure", "曝光", -5, 5, 0),
        "contrast": ("contrast", "对比度", -100, 100, 0),
        "highlights": ("highlights", "高光", -100, 100, 0),
        "shadows": ("shadows", "阴影", -100, 100, 0),
        "whites": ("whites", "白色色阶", -100, 100, 0),
        "blacks": ("blacks", "黑色色阶", -100, 100, 0),
        "texture": ("texture", "纹理", -100, 100, 0),
        "clarity": ("clarity", "清晰度", -100, 100, 0),
        "dehaze": ("dehaze", "去朦胧", -100, 100, 0),
        "vibrance": ("vibrance", "自然饱和度", -100, 100, 0),
        "saturation": ("saturation", "饱和度", -100, 100, 0),
        "temperature": ("temperature", "色温", 2000, 50000, 6500),
        "tint": ("tint", "色调", -150, 150, 0),
    }

    extracted: dict[str, float] = {}
    for output_key, (english_key, chinese_key, low, high, fallback) in field_specs.items():
        value = extract_number_after(reasoning_for_params, english_key)
        if value is None:
            value = extract_number_after(reasoning_for_params, chinese_key)
        if value is None:
            value = fallback
        extracted[output_key] = max(low, min(high, value))

    useful = any(extracted[key] != field_specs[key][4] for key in extracted if key != "temperature")
    if not useful:
        return None

    extracted["advice"] = "从推理内容提取参数"
    extracted["raw_content"] = ""
    extracted["raw_reasoning"] = truncate_text(reasoning)
    return apply_mvp_safety_limits(extracted, current_settings)


HSL_FIELDS = {
    "hue_red": ("HueAdjustmentRed", -8, 8, 0),
    "hue_orange": ("HueAdjustmentOrange", -6, 6, 0),
    "hue_yellow": ("HueAdjustmentYellow", -10, 10, 0),
    "hue_green": ("HueAdjustmentGreen", -12, 12, 0),
    "hue_aqua": ("HueAdjustmentAqua", -8, 8, 0),
    "hue_blue": ("HueAdjustmentBlue", -8, 8, 0),
    "saturation_red": ("SaturationAdjustmentRed", -10, 8, 0),
    "saturation_orange": ("SaturationAdjustmentOrange", -8, 8, 0),
    "saturation_yellow": ("SaturationAdjustmentYellow", -18, 8, 0),
    "saturation_green": ("SaturationAdjustmentGreen", -22, 10, 0),
    "saturation_aqua": ("SaturationAdjustmentAqua", -10, 10, 0),
    "saturation_blue": ("SaturationAdjustmentBlue", -10, 10, 0),
    "luminance_red": ("LuminanceAdjustmentRed", -8, 10, 0),
    "luminance_orange": ("LuminanceAdjustmentOrange", -6, 12, 0),
    "luminance_yellow": ("LuminanceAdjustmentYellow", -15, 10, 0),
    "luminance_green": ("LuminanceAdjustmentGreen", -15, 12, 0),
    "luminance_aqua": ("LuminanceAdjustmentAqua", -8, 8, 0),
    "luminance_blue": ("LuminanceAdjustmentBlue", -8, 8, 0),
}


def normalize_hsl(result: dict, current_settings: dict | None = None) -> dict:
    source = result.get("hsl")
    if not isinstance(source, dict):
        source = {}
    normalized = {}
    for output_key, (lr_key, low, high, fallback) in HSL_FIELDS.items():
        try:
            value = float(source.get(output_key, current_settings.get(lr_key, fallback) if current_settings else fallback))
        except (TypeError, ValueError):
            value = fallback
        value = max(low, min(high, value))
        if current_settings:
            try:
                current = float(current_settings.get(lr_key, fallback))
                value = max(current - 8, min(current + 8, value))
            except (TypeError, ValueError):
                pass
        normalized[output_key] = value
    result["hsl"] = normalized
    return result


def apply_mvp_safety_limits(result: dict, current_settings: dict | None = None) -> dict:
    """Keep MVP auto-edits conservative enough for portraits."""
    limits = {
        "exposure": (-0.35, 0.35),
        "contrast": (-10, 12),
        "highlights": (-45, 20),
        "shadows": (-10, 25),
        "whites": (-25, 15),
        "blacks": (-15, 8),
        "texture": (-5, 8),
        "clarity": (-5, 8),
        "dehaze": (-5, 5),
        "vibrance": (-10, 12),
        "saturation": (-10, 8),
        "temperature": (5200, 7600),
        "tint": (-12, 12),
    }
    for key, (low, high) in limits.items():
        if key in result:
            try:
                result[key] = max(low, min(high, float(result[key])))
            except (TypeError, ValueError):
                pass
    if current_settings:
        key_map = {
            "exposure": ("Exposure", 0.25),
            "contrast": ("Contrast", 8),
            "highlights": ("Highlights", 20),
            "shadows": ("Shadows", 18),
            "whites": ("Whites", 15),
            "blacks": ("Blacks", 12),
            "texture": ("Texture", 6),
            "clarity": ("Clarity", 6),
            "dehaze": ("Dehaze", 5),
            "vibrance": ("Vibrance", 10),
            "saturation": ("Saturation", 8),
            "temperature": ("Temperature", 500),
            "tint": ("Tint", 8),
        }
        for output_key, (current_key, max_delta) in key_map.items():
            if output_key not in result:
                continue
            try:
                current = float(current_settings.get(current_key, result[output_key]))
                value = float(result[output_key])
                result[output_key] = max(current - max_delta, min(current + max_delta, value))
            except (TypeError, ValueError):
                pass
    return normalize_hsl(result, current_settings)


async def analyze_image(
    image_path: str,
    model: str,
    style_prompt: str = "",
    current_settings: dict | None = None,
    metadata: dict | None = None,
) -> dict:
    """使用LiteLLM调用视觉模型分析图片"""
    return await asyncio.wait_for(
        _analyze_image(image_path, model, style_prompt, current_settings, metadata),
        timeout=config.REQUEST_TIMEOUT_SECONDS,
    )


async def _analyze_image(
    image_path: str,
    model: str,
    style_prompt: str = "",
    current_settings: dict | None = None,
    metadata: dict | None = None,
) -> dict:
    log(f"analyze_image start: model={model}, api_base={config.API_BASE}, image={image_path}")

    # 读取并编码图片
    with open(image_path, "rb") as f:
        image_data = base64.b64encode(f.read()).decode("utf-8")
    log(f"image encoded: {len(image_data)} base64 chars")

    # 构建prompt
    user_prompt = config.BASE_PROMPT
    if style_prompt:
        user_prompt = config.STYLE_PROMPT_TEMPLATE.format(style=style_prompt) + "\n\n" + user_prompt
    if current_settings or metadata:
        context = {
            "current_settings": current_settings or {},
            "metadata": metadata or {},
        }
        user_prompt += "\n\n当前Lightroom上下文如下。请基于这些当前滑块值继续调整，返回目标绝对值，不要返回增量：\n"
        user_prompt += json.dumps(context, ensure_ascii=False, indent=2)

    # 构建消息
    messages = [
        {"role": "system", "content": config.SYSTEM_PROMPT},
        {
            "role": "user",
            "content": [
                {"type": "text", "text": user_prompt},
                {
                    "type": "image_url",
                    "image_url": {
                        "url": f"data:image/jpeg;base64,{image_data}"
                    }
                }
            ]
        }
    ]

    # 调用LiteLLM
    try:
        log("calling litellm...")
        response = await acompletion(
            model=model,
            messages=messages,
            api_key=config.API_KEY,
            api_base=config.API_BASE,
            temperature=config.TEMPERATURE,
            max_tokens=config.MAX_TOKENS,
            response_format={"type": "json_object"},
            timeout=config.REQUEST_TIMEOUT_SECONDS,
        )
        log("litellm response received")

        message = response.choices[0].message
        msg_dict = {}
        if hasattr(message, "model_dump"):
            dumped = message.model_dump()
            if isinstance(dumped, dict):
                msg_dict = dumped

        # Kimi k2.6 thinking模式：content可能为空，需要从reasoning_content提取
        content = msg_dict.get("content") or getattr(message, "content", "") or ""
        provider_fields = msg_dict.get("provider_specific_fields") or {}
        reasoning = (
            msg_dict.get("reasoning_content")
            or provider_fields.get("reasoning_content")
            or getattr(message, "reasoning_content", "")
            or ""
        )
        if not isinstance(content, str):
            content = str(content) if content else ""
        if not isinstance(reasoning, str):
            reasoning = str(reasoning) if reasoning else ""

        log(f"content长度: {len(content)}, reasoning长度: {len(reasoning)}")

        # 如果content为空但有reasoning，尝试从中提取JSON
        if not content and reasoning:
            extracted = extract_json_object(reasoning)
            if extracted:
                content = extracted
                log(f"从reasoning提取: {content}")
            else:
                fallback_result = result_from_reasoning(reasoning, current_settings)
                if fallback_result:
                    log("从reasoning文本提取参数")
                    return fallback_result
        elif content:
            extracted = extract_json_object(content)
            if extracted:
                content = extracted

        # 去掉代码块标记 ```json ... ```
        if content and content.strip().startswith('```'):
            import re
            content = re.sub(r'^```(?:json)?\s*', '', content.strip())
            content = re.sub(r'\s*```$', '', content)
            content = content.strip()
            log(f"去掉代码块后: {content[:100]}...")

        if not content:
            return {
                "advice": "AI未返回有效内容",
                "raw_content": truncate_text(content),
                "raw_reasoning": truncate_text(reasoning),
                "exposure": 0,
                "contrast": 0,
                "highlights": 0,
                "shadows": 0,
                "saturation": 0,
                "temperature": 6500,
                "tint": 0
            }

        # 解析JSON
        result = json.loads(content)

        def current_value(lr_key: str, fallback: float, *aliases: str) -> float:
            try:
                settings = current_settings or {}
                for key in (lr_key, *aliases):
                    if key in settings and settings.get(key) is not None:
                        return float(settings.get(key))
                return fallback
            except (TypeError, ValueError):
                return fallback

        def clamp(name: str, low: float, high: float, default: float) -> float:
            try:
                value = float(result.get(name, default))
            except (TypeError, ValueError):
                value = default
            return max(low, min(high, value))

        # 确保数值范围正确 (LR参数范围)
        result["exposure"] = clamp("exposure", -5, 5, current_value("Exposure", 0, "Exposure2012"))
        result["contrast"] = clamp("contrast", -100, 100, current_value("Contrast", 0, "Contrast2012"))
        result["highlights"] = clamp("highlights", -100, 100, current_value("Highlights", 0, "Highlights2012"))
        result["shadows"] = clamp("shadows", -100, 100, current_value("Shadows", 0, "Shadows2012"))
        result["whites"] = clamp("whites", -100, 100, current_value("Whites", 0, "Whites2012"))
        result["blacks"] = clamp("blacks", -100, 100, current_value("Blacks", 0, "Blacks2012"))
        result["texture"] = clamp("texture", -100, 100, current_value("Texture", 0))
        result["clarity"] = clamp("clarity", -100, 100, current_value("Clarity", 0, "Clarity2012"))
        result["dehaze"] = clamp("dehaze", -100, 100, current_value("Dehaze", 0))
        result["vibrance"] = clamp("vibrance", -100, 100, current_value("Vibrance", 0))
        result["saturation"] = clamp("saturation", -100, 100, current_value("Saturation", 0))
        result["temperature"] = clamp("temperature", 2000, 50000, current_value("Temperature", 6500))
        result["tint"] = clamp("tint", -150, 150, current_value("Tint", 0))
        result["raw_content"] = truncate_text(content)
        result["raw_reasoning"] = truncate_text(reasoning)

        return apply_mvp_safety_limits(result, current_settings)

    except Exception as e:
        log(f"analyze_image failed: {type(e).__name__}: {e}")
        return {
            "advice": f"分析失败: {str(e)}",
            "raw_content": "",
            "raw_reasoning": "",
            "error": f"{type(e).__name__}: {e}",
            "exposure": 0,
            "contrast": 0,
            "highlights": 0,
            "shadows": 0,
            "saturation": 0,
            "temperature": 6500,
            "tint": 0
        }


def main():
    if len(sys.argv) < 2:
        print("Usage: python worker.py <temp_dir>")
        sys.exit(1)

    temp_dir = Path(sys.argv[1])

    # 读取请求
    request_file = temp_dir / "request.json"
    if not request_file.exists():
        print("Error: request.json not found")
        sys.exit(1)

    with open(request_file, "r", encoding="utf-8") as f:
        request = json.load(f)

    image_path = request.get("image_path", "")
    model = request.get("model", config.DEFAULT_MODEL)
    style_prompt = request.get("style_prompt", "")
    current_settings = request.get("current_settings", {})
    metadata = request.get("metadata", {})

    # 运行分析
    try:
        result = asyncio.run(analyze_image(image_path, model, style_prompt, current_settings, metadata))
    except asyncio.TimeoutError:
        log(f"analysis timed out after {config.REQUEST_TIMEOUT_SECONDS}s")
        result = {
            "advice": f"分析超时: 模型请求超过{config.REQUEST_TIMEOUT_SECONDS}秒",
            "raw_content": "",
            "raw_reasoning": "",
            "error": f"Timeout after {config.REQUEST_TIMEOUT_SECONDS}s",
            "exposure": 0,
            "contrast": 0,
            "highlights": 0,
            "shadows": 0,
            "saturation": 0,
            "temperature": 6500,
            "tint": 0,
        }

    # 写入结果
    result_file = temp_dir / "result.json"
    with open(result_file, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    raw_file = temp_dir / "raw.txt"
    with open(raw_file, "w", encoding="utf-8") as f:
        f.write("=== raw_content ===\n")
        f.write(result.get("raw_content", "") or "")
        f.write("\n\n=== raw_reasoning ===\n")
        f.write(result.get("raw_reasoning", "") or "")
        if result.get("error"):
            f.write("\n\n=== error ===\n")
            f.write(result.get("error", ""))

    print(f"Analysis complete: {result_file}")


if __name__ == "__main__":
    main()
