-- ==============================================================================
-- LR AI Editor: User Configuration
-- ==============================================================================

return {
    -- LiteLLM Proxy地址
    litellmUrl = "http://localhost:4000/v1",

    -- 预览图尺寸 (严格控制: 512-1024px)
    previewSize = 768,

    -- 预览图质量 (0.5 = 50%, 保持小体积)
    previewQuality = 0.5,

    -- Python路径 (留空则使用系统PATH中的python)
    pythonPath = "",

    -- Worker脚本路径 (需要用户在LR中配置)
    workerPath = "",

    -- 默认模型 (LiteLLM中配置的模型名)
    defaultModel = "gpt-4o",

    -- 临时文件夹位置
    tempFolder = "",  -- 留空则使用桌面
}