# ==============================================================================
# LR AI Editor: Unit Tests (LiteLLM版本)
# ==============================================================================

import pytest
import json
import base64
import sys
from pathlib import Path
from PIL import Image
from unittest.mock import AsyncMock, MagicMock, patch

# Add worker to path
sys.path.insert(0, str(Path(__file__).parent))

import config
from worker import analyze_image, main


# ==============================================================================
# Test Fixtures
# ==============================================================================

@pytest.fixture
def test_image_path(tmp_path):
    """创建一个测试图片"""
    img = Image.new('RGB', (100, 100), color=(150, 150, 200))
    img_path = tmp_path / "test_image.jpg"
    img.save(img_path, "JPEG", quality=50)
    return str(img_path)


@pytest.fixture
def temp_dir_with_request(tmp_path, test_image_path):
    """创建临时目录和请求文件"""
    request_data = {
        "image_path": test_image_path,
        "model": "openai/kimi-k2.6",
        "style_prompt": ""
    }
    request_file = tmp_path / "request.json"
    with open(request_file, "w", encoding="utf-8") as f:
        json.dump(request_data, f)
    return tmp_path


# ==============================================================================
# Unit Tests
# ==============================================================================

class TestConfig:
    """测试配置"""

    def test_api_key_exists(self):
        """测试API Key配置"""
        assert hasattr(config, 'API_KEY')
        assert len(config.API_KEY) > 0

    def test_api_base_exists(self):
        """测试API Base配置"""
        assert hasattr(config, 'API_BASE')
        assert config.API_BASE.startswith("http")

    def test_default_model_exists(self):
        """测试默认模型"""
        assert hasattr(config, 'DEFAULT_MODEL')
        assert "litellm_proxy/" in config.DEFAULT_MODEL

    def test_prompts_exist(self):
        """测试Prompt配置"""
        assert hasattr(config, 'SYSTEM_PROMPT')
        assert hasattr(config, 'BASE_PROMPT')
        assert len(config.SYSTEM_PROMPT) > 0
        assert len(config.BASE_PROMPT) > 0


class TestAnalyzeImage:
    """测试图片分析"""

    @pytest.mark.asyncio
    async def test_analyze_returns_valid_structure(self, test_image_path):
        """测试返回结构正确"""
        mock_response = MagicMock()
        mock_response.choices = [MagicMock()]
        mock_response.choices[0].message.content = json.dumps({
            "advice": "建议增加曝光",
            "exposure": 0.5,
            "contrast": 10,
            "highlights": -20,
            "shadows": 15,
            "saturation": 5
        })

        with patch('worker.acompletion', new_callable=AsyncMock) as mock_completion:
            mock_completion.return_value = mock_response

            result = await analyze_image(test_image_path, "openai/kimi-k2.6")

            assert "advice" in result
            assert "exposure" in result
            assert isinstance(result["exposure"], float)

    @pytest.mark.asyncio
    async def test_value_clamping(self, test_image_path):
        """测试数值范围限制"""
        mock_response = MagicMock()
        mock_response.choices = [MagicMock()]
        mock_response.choices[0].message.content = json.dumps({
            "advice": "test",
            "exposure": 100,  # 超出范围
            "contrast": -150,
            "highlights": 200,
            "shadows": -200,
            "saturation": 300
        })

        with patch('worker.acompletion', new_callable=AsyncMock) as mock_completion:
            mock_completion.return_value = mock_response

            result = await analyze_image(test_image_path, "openai/kimi-k2.6")

            # 验证范围被限制到MVP自动修图安全范围
            assert result["exposure"] == 0.35
            assert result["contrast"] == -10
            assert result["highlights"] == 20
            assert result["shadows"] == -10
            assert result["saturation"] == 8

    @pytest.mark.asyncio
    async def test_error_handling(self, test_image_path):
        """测试错误处理"""
        with patch('worker.acompletion', new_callable=AsyncMock) as mock_completion:
            mock_completion.side_effect = Exception("API错误")

            result = await analyze_image(test_image_path, "openai/kimi-k2.6")

            assert "失败" in result["advice"]
            assert result["exposure"] == 0


class TestMain:
    """测试main函数"""

    def test_main_creates_result(self, temp_dir_with_request):
        """测试main创建结果文件"""
        mock_response = MagicMock()
        mock_response.choices = [MagicMock()]
        mock_response.choices[0].message.content = json.dumps({
            "advice": "测试建议",
            "exposure": 0.3,
            "contrast": 15,
            "highlights": 0,
            "shadows": 0,
            "saturation": 0
        })

        with patch('worker.acompletion', new_callable=AsyncMock) as mock_completion:
            mock_completion.return_value = mock_response

            sys.argv = ["worker.py", str(temp_dir_with_request)]
            main()

            result_file = temp_dir_with_request / "result.json"
            assert result_file.exists()

            with open(result_file, "r", encoding="utf-8") as f:
                result = json.load(f)

            assert result["advice"] == "测试建议"


# ==============================================================================
# Integration Test (真实API)
# ==============================================================================

class TestIntegration:
    """集成测试 - 需要真实API"""

    @pytest.mark.asyncio
    @pytest.mark.skipif(
        not config.API_KEY.startswith("sk-"),
        reason="需要有效的API Key"
    )
    async def test_real_kimi_api(self, test_image_path):
        """真实Kimi API测试"""
        result = await analyze_image(
            test_image_path,
            config.DEFAULT_MODEL,
            style_prompt=""
        )

        assert "advice" in result
        assert isinstance(result["advice"], str)
        print(f"\nAI建议: {result['advice']}")
        print(f"参数: exposure={result['exposure']}, contrast={result['contrast']}")
