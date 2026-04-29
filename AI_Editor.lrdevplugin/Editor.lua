local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'
local LrPrefs = import 'LrPrefs'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrExportSession = import 'LrExportSession'
local LrProgressScope = import 'LrProgressScope'
local LrApplicationView = import 'LrApplicationView'
local LrDevelopController = import 'LrDevelopController'

-- 插件目录路径
local PLUGIN_PATH = _PLUGIN.path

-- 配置 (使用相对路径)
local PYTHON_PATH = "python"  -- 使用系统 PATH 中的 python
local WORKER_PATH = PLUGIN_PATH .. "/../worker/worker.py"  -- worker 在插件目录的上级目录
local PREVIEW_SIZE = 384
local MODEL = "litellm_proxy/mimo"
local LOG_FILE = PLUGIN_PATH .. "/lr_ai_log.txt"
local WAIT_TIMEOUT_SECONDS = 70

local function log(msg)
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(os.date("%H:%M:%S") .. " " .. msg .. "\n")
        f:close()
    end
end

local function jsonEscape(value)
    local s = tostring(value or "")
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\r", "\\r")
    s = s:gsub("\n", "\\n")
    return s
end

local function jsonNumber(value, defaultValue)
    local n = tonumber(value)
    if n then
        return tostring(n)
    end
    return tostring(defaultValue or 0)
end

local function developSetting(settings, preferredKey, fallbackKey, defaultValue)
    local value = nil
    if settings then
        value = settings[preferredKey]
        if value == nil and fallbackKey then
            value = settings[fallbackKey]
        end
    end
    return jsonNumber(value, defaultValue)
end

local function metadataValue(photo, key)
    local ok, value = LrTasks.pcall(function()
        return photo:getFormattedMetadata(key)
    end)
    if not ok then
        log("读取元数据失败: " .. tostring(key) .. " => " .. tostring(value))
        return ""
    end
    if value then
        return tostring(value)
    end
    return ""
end

local function setDevelopValue(param, value)
    local n = tonumber(value)
    if not n then
        return
    end
    local ok, err = LrTasks.pcall(function()
        LrDevelopController.setValue(param, n)
    end)
    if ok then
        log(string.format("LrDevelopController.setValue成功: %s=%s", param, tostring(n)))
    else
        log(string.format("LrDevelopController.setValue失败: %s=%s, err=%s", param, tostring(n), tostring(err)))
    end
end

local function getDevelopValue(param, defaultValue)
    local ok, value = LrTasks.pcall(function()
        return LrDevelopController.getValue(param)
    end)
    if ok and value ~= nil then
        return tonumber(value) or defaultValue
    end
    log(string.format("读取Develop参数失败: %s => %s", param, tostring(value)))
    return defaultValue
end

local function resultNumber(content, key)
    return content:match('"' .. key .. '"%s*:%s*([%-?%d%.]+)')
end

LrTasks.startAsyncTask(function()
    log("=== 开始AI分析 ===")

    local catalog = LrApplication.activeCatalog()
    local photo = catalog:getTargetPhoto()

    if not photo then
        log("错误: 未选择照片")
        LrDialogs.message("请先选择一张照片")
        return
    end

    log("照片已选中")

    local f = LrView.osFactory()
    local prefs = LrPrefs.prefsForPlugin()
    prefs.stylePrompt = prefs.stylePrompt or ""

    local promptDialog = f:column {
        spacing = f:control_spacing(),
        bind_to_object = prefs,

        f:static_text {
            title = "输入这次修图的风格或微调要求:",
            font = "<bold>"
        },
        f:edit_field {
            value = LrView.bind 'stylePrompt',
            width_in_chars = 62,
            height_in_chars = 4
        },
        f:static_text {
            title = "例如: 自然干净的人像，肤色优先，只微调曝光和色彩，不要压暗背景太多。",
            width_in_chars = 62
        },
    }

    local promptResult = LrDialogs.presentModalDialog {
        title = "AI 修图要求",
        contents = promptDialog,
    }
    if promptResult == "cancel" then
        log("用户取消输入修图要求")
        return
    end
    log("用户修图要求: " .. tostring(prefs.stylePrompt))

    -- 创建临时文件夹 (使用插件目录)
    local timestamp = os.time()
    local tempDir = PLUGIN_PATH .. "/temp_" .. timestamp
    LrFileUtils.createAllDirectories(tempDir)
    log("临时目录: " .. tempDir)

    local progress = LrProgressScope { title = "AI分析中..." }

    -- 导出预览图
    progress:setCaption("导出预览图...")

    local exportSettings = {
        LR_format = "JPEG",
        LR_jpeg_quality = 0.5,
        LR_export_colorSpace = "sRGB",
        LR_size_doConstrain = true,
        LR_size_maxWidth = PREVIEW_SIZE,
        LR_size_maxHeight = PREVIEW_SIZE,
        LR_export_destinationType = "specificFolder",
        LR_export_destinationPathPrefix = tempDir,
        LR_export_useSubfolder = false,
        LR_collisionHandling = "overwrite",
    }

    local exportSession = LrExportSession {
        photosToExport = { photo },
        exportSettings = exportSettings
    }

    local previewPath
    for _, rendition in exportSession:renditions() do
        local success, pathOrMessage = rendition:waitForRender()
        if not success then
            log("导出失败: " .. pathOrMessage)
            LrDialogs.message("导出失败", pathOrMessage)
            progress:done()
            return
        end
        previewPath = pathOrMessage:gsub("\\", "/")
    end
    log("导出完成: " .. previewPath)

    progress:setCaption("调用AI模型...")

    -- 读取当前照片已有的Develop滑块值。getValue必须在Develop模块中调用。
    LrApplicationView.switchToModule("develop")
    LrTasks.sleep(1)
    local currentSettings = {
        Exposure = getDevelopValue("Exposure", 0),
        Contrast = getDevelopValue("Contrast", 0),
        Highlights = getDevelopValue("Highlights", 0),
        Shadows = getDevelopValue("Shadows", 0),
        Whites = getDevelopValue("Whites", 0),
        Blacks = getDevelopValue("Blacks", 0),
        Texture = getDevelopValue("Texture", 0),
        Clarity = getDevelopValue("Clarity", 0),
        Dehaze = getDevelopValue("Dehaze", 0),
        Vibrance = getDevelopValue("Vibrance", 0),
        Saturation = getDevelopValue("Saturation", 0),
        Temperature = getDevelopValue("Temperature", 6500),
        Tint = getDevelopValue("Tint", 0),
        HueAdjustmentRed = getDevelopValue("HueAdjustmentRed", 0),
        HueAdjustmentOrange = getDevelopValue("HueAdjustmentOrange", 0),
        HueAdjustmentYellow = getDevelopValue("HueAdjustmentYellow", 0),
        HueAdjustmentGreen = getDevelopValue("HueAdjustmentGreen", 0),
        HueAdjustmentAqua = getDevelopValue("HueAdjustmentAqua", 0),
        HueAdjustmentBlue = getDevelopValue("HueAdjustmentBlue", 0),
        SaturationAdjustmentRed = getDevelopValue("SaturationAdjustmentRed", 0),
        SaturationAdjustmentOrange = getDevelopValue("SaturationAdjustmentOrange", 0),
        SaturationAdjustmentYellow = getDevelopValue("SaturationAdjustmentYellow", 0),
        SaturationAdjustmentGreen = getDevelopValue("SaturationAdjustmentGreen", 0),
        SaturationAdjustmentAqua = getDevelopValue("SaturationAdjustmentAqua", 0),
        SaturationAdjustmentBlue = getDevelopValue("SaturationAdjustmentBlue", 0),
        LuminanceAdjustmentRed = getDevelopValue("LuminanceAdjustmentRed", 0),
        LuminanceAdjustmentOrange = getDevelopValue("LuminanceAdjustmentOrange", 0),
        LuminanceAdjustmentYellow = getDevelopValue("LuminanceAdjustmentYellow", 0),
        LuminanceAdjustmentGreen = getDevelopValue("LuminanceAdjustmentGreen", 0),
        LuminanceAdjustmentAqua = getDevelopValue("LuminanceAdjustmentAqua", 0),
        LuminanceAdjustmentBlue = getDevelopValue("LuminanceAdjustmentBlue", 0),
        ParametricShadows = getDevelopValue("ParametricShadows", 0),
        ParametricDarks = getDevelopValue("ParametricDarks", 0),
        ParametricLights = getDevelopValue("ParametricLights", 0),
        ParametricHighlights = getDevelopValue("ParametricHighlights", 0),
        Sharpness = getDevelopValue("Sharpness", 40),
        SharpenRadius = getDevelopValue("SharpenRadius", 1.0),
        SharpenDetail = getDevelopValue("SharpenDetail", 25),
        SharpenEdgeMasking = getDevelopValue("SharpenEdgeMasking", 0),
        LuminanceSmoothing = getDevelopValue("LuminanceSmoothing", 0),
        ColorNoiseReduction = getDevelopValue("ColorNoiseReduction", 25),
        PostCropVignetteAmount = getDevelopValue("PostCropVignetteAmount", 0),
        PostCropVignetteMidpoint = getDevelopValue("PostCropVignetteMidpoint", 50),
        PostCropVignetteFeather = getDevelopValue("PostCropVignetteFeather", 50),
        GrainAmount = getDevelopValue("GrainAmount", 0),
        GrainSize = getDevelopValue("GrainSize", 25),
        GrainFrequency = getDevelopValue("GrainFrequency", 50),
        SplitToningShadowHue = getDevelopValue("SplitToningShadowHue", 0),
        SplitToningShadowSaturation = getDevelopValue("SplitToningShadowSaturation", 0),
        SplitToningHighlightHue = getDevelopValue("SplitToningHighlightHue", 0),
        SplitToningHighlightSaturation = getDevelopValue("SplitToningHighlightSaturation", 0),
        SplitToningBalance = getDevelopValue("SplitToningBalance", 0),
        LensProfileEnable = getDevelopValue("LensProfileEnable", 0),
        AutoLateralCA = getDevelopValue("AutoLateralCA", 0),
        LensManualDistortionAmount = getDevelopValue("LensManualDistortionAmount", 0),
        LensVignettingAmount = getDevelopValue("LensVignettingAmount", 0),
        LensVignettingMidpoint = getDevelopValue("LensVignettingMidpoint", 50),
    }
    log(string.format(
        "当前Develop参数: Exposure=%s, Contrast=%s, Highlights=%s, Shadows=%s, Whites=%s, Blacks=%s, Texture=%s, Clarity=%s, Dehaze=%s, Vibrance=%s, Saturation=%s, Temperature=%s, Tint=%s",
        tostring(currentSettings.Exposure),
        tostring(currentSettings.Contrast),
        tostring(currentSettings.Highlights),
        tostring(currentSettings.Shadows),
        tostring(currentSettings.Whites),
        tostring(currentSettings.Blacks),
        tostring(currentSettings.Texture),
        tostring(currentSettings.Clarity),
        tostring(currentSettings.Dehaze),
        tostring(currentSettings.Vibrance),
        tostring(currentSettings.Saturation),
        tostring(currentSettings.Temperature),
        tostring(currentSettings.Tint)
    ))

    -- 写入请求文件
    local requestPath = tempDir .. "/request.json"
    local requestFile = io.open(requestPath, "w")
    requestFile:write(string.format([[
{
  "image_path": "%s",
  "model": "%s",
  "style_prompt": "%s",
  "current_settings": {
    "Exposure": %s,
    "Contrast": %s,
    "Highlights": %s,
    "Shadows": %s,
    "Whites": %s,
    "Blacks": %s,
    "Texture": %s,
    "Clarity": %s,
    "Dehaze": %s,
    "Vibrance": %s,
    "Saturation": %s,
    "Temperature": %s,
    "Tint": %s,
    "HueAdjustmentRed": %s,
    "HueAdjustmentOrange": %s,
    "HueAdjustmentYellow": %s,
    "HueAdjustmentGreen": %s,
    "HueAdjustmentAqua": %s,
    "HueAdjustmentBlue": %s,
    "SaturationAdjustmentRed": %s,
    "SaturationAdjustmentOrange": %s,
    "SaturationAdjustmentYellow": %s,
    "SaturationAdjustmentGreen": %s,
    "SaturationAdjustmentAqua": %s,
    "SaturationAdjustmentBlue": %s,
    "LuminanceAdjustmentRed": %s,
    "LuminanceAdjustmentOrange": %s,
    "LuminanceAdjustmentYellow": %s,
    "LuminanceAdjustmentGreen": %s,
    "LuminanceAdjustmentAqua": %s,
    "LuminanceAdjustmentBlue": %s,
    "ParametricShadows": %s,
    "ParametricDarks": %s,
    "ParametricLights": %s,
    "ParametricHighlights": %s,
    "Sharpness": %s,
    "SharpenRadius": %s,
    "SharpenDetail": %s,
    "SharpenEdgeMasking": %s,
    "LuminanceSmoothing": %s,
    "ColorNoiseReduction": %s,
    "PostCropVignetteAmount": %s,
    "PostCropVignetteMidpoint": %s,
    "PostCropVignetteFeather": %s,
    "GrainAmount": %s,
    "GrainSize": %s,
    "GrainFrequency": %s,
    "SplitToningShadowHue": %s,
    "SplitToningShadowSaturation": %s,
    "SplitToningHighlightHue": %s,
    "SplitToningHighlightSaturation": %s,
    "SplitToningBalance": %s,
    "LensProfileEnable": %s,
    "AutoLateralCA": %s,
    "LensManualDistortionAmount": %s,
    "LensVignettingAmount": %s,
    "LensVignettingMidpoint": %s
  },
  "metadata": {
    "fileName": "%s",
    "cameraModel": "%s",
    "lens": "%s",
    "iso": "%s",
    "focalLength": "%s",
    "aperture": "%s",
    "shutterSpeed": "%s",
    "captureTime": "%s"
  }
}
]],
        jsonEscape(previewPath),
        jsonEscape(MODEL),
        jsonEscape(prefs.stylePrompt),
        developSetting(currentSettings, "Exposure", "Exposure2012", 0),
        developSetting(currentSettings, "Contrast", "Contrast2012", 0),
        developSetting(currentSettings, "Highlights", "Highlights2012", 0),
        developSetting(currentSettings, "Shadows", "Shadows2012", 0),
        developSetting(currentSettings, "Whites", "Whites2012", 0),
        developSetting(currentSettings, "Blacks", "Blacks2012", 0),
        developSetting(currentSettings, "Texture", nil, 0),
        developSetting(currentSettings, "Clarity", "Clarity2012", 0),
        developSetting(currentSettings, "Dehaze", nil, 0),
        developSetting(currentSettings, "Vibrance", nil, 0),
        developSetting(currentSettings, "Saturation", nil, 0),
        developSetting(currentSettings, "Temperature", nil, 6500),
        developSetting(currentSettings, "Tint", nil, 0),
        developSetting(currentSettings, "HueAdjustmentRed", nil, 0),
        developSetting(currentSettings, "HueAdjustmentOrange", nil, 0),
        developSetting(currentSettings, "HueAdjustmentYellow", nil, 0),
        developSetting(currentSettings, "HueAdjustmentGreen", nil, 0),
        developSetting(currentSettings, "HueAdjustmentAqua", nil, 0),
        developSetting(currentSettings, "HueAdjustmentBlue", nil, 0),
        developSetting(currentSettings, "SaturationAdjustmentRed", nil, 0),
        developSetting(currentSettings, "SaturationAdjustmentOrange", nil, 0),
        developSetting(currentSettings, "SaturationAdjustmentYellow", nil, 0),
        developSetting(currentSettings, "SaturationAdjustmentGreen", nil, 0),
        developSetting(currentSettings, "SaturationAdjustmentAqua", nil, 0),
        developSetting(currentSettings, "SaturationAdjustmentBlue", nil, 0),
        developSetting(currentSettings, "LuminanceAdjustmentRed", nil, 0),
        developSetting(currentSettings, "LuminanceAdjustmentOrange", nil, 0),
        developSetting(currentSettings, "LuminanceAdjustmentYellow", nil, 0),
        developSetting(currentSettings, "LuminanceAdjustmentGreen", nil, 0),
        developSetting(currentSettings, "LuminanceAdjustmentAqua", nil, 0),
        developSetting(currentSettings, "LuminanceAdjustmentBlue", nil, 0),
        developSetting(currentSettings, "ParametricShadows", nil, 0),
        developSetting(currentSettings, "ParametricDarks", nil, 0),
        developSetting(currentSettings, "ParametricLights", nil, 0),
        developSetting(currentSettings, "ParametricHighlights", nil, 0),
        developSetting(currentSettings, "Sharpness", nil, 40),
        developSetting(currentSettings, "SharpenRadius", nil, 1.0),
        developSetting(currentSettings, "SharpenDetail", nil, 25),
        developSetting(currentSettings, "SharpenEdgeMasking", nil, 0),
        developSetting(currentSettings, "LuminanceSmoothing", nil, 0),
        developSetting(currentSettings, "ColorNoiseReduction", nil, 25),
        developSetting(currentSettings, "PostCropVignetteAmount", nil, 0),
        developSetting(currentSettings, "PostCropVignetteMidpoint", nil, 50),
        developSetting(currentSettings, "PostCropVignetteFeather", nil, 50),
        developSetting(currentSettings, "GrainAmount", nil, 0),
        developSetting(currentSettings, "GrainSize", nil, 25),
        developSetting(currentSettings, "GrainFrequency", nil, 50),
        developSetting(currentSettings, "SplitToningShadowHue", nil, 0),
        developSetting(currentSettings, "SplitToningShadowSaturation", nil, 0),
        developSetting(currentSettings, "SplitToningHighlightHue", nil, 0),
        developSetting(currentSettings, "SplitToningHighlightSaturation", nil, 0),
        developSetting(currentSettings, "SplitToningBalance", nil, 0),
        developSetting(currentSettings, "LensProfileEnable", nil, 0),
        developSetting(currentSettings, "AutoLateralCA", nil, 0),
        developSetting(currentSettings, "LensManualDistortionAmount", nil, 0),
        developSetting(currentSettings, "LensVignettingAmount", nil, 0),
        developSetting(currentSettings, "LensVignettingMidpoint", nil, 50),
        jsonEscape(metadataValue(photo, "fileName")),
        jsonEscape(metadataValue(photo, "cameraModel")),
        jsonEscape(metadataValue(photo, "lens")),
        jsonEscape(metadataValue(photo, "isoSpeedRating")),
        jsonEscape(metadataValue(photo, "focalLength")),
        jsonEscape(metadataValue(photo, "aperture")),
        jsonEscape(metadataValue(photo, "shutterSpeed")),
        jsonEscape(metadataValue(photo, "captureTime"))
    ))
    requestFile:close()
    log("请求文件: " .. requestPath)

    -- 用wscript隐藏启动cmd，cmd负责记录worker输出，避免弹出控制台窗口。
    local cmdPath = tempDir .. "/run_worker.cmd"
    local workerLogPath = tempDir .. "/worker.log"
    local cmdFile = io.open(cmdPath, "w")
    cmdFile:write("@echo off\n")
    cmdFile:write("chcp 65001 >nul\n")
    cmdFile:write(string.format('"%s" "%s" "%s" > "%s" 2>&1\n', PYTHON_PATH, WORKER_PATH, tempDir, workerLogPath))
    cmdFile:close()
    log("cmd文件: " .. cmdPath)
    log("worker日志: " .. workerLogPath)

    local vbsPath = tempDir .. "/run_worker.vbs"
    local commandLine = string.format('cmd.exe /c "%s"', cmdPath)
    local vbsFile = io.open(vbsPath, "w")
    vbsFile:write('Set shell = CreateObject("WScript.Shell")\n')
    vbsFile:write(string.format('shell.Run "%s", 0, False\n', commandLine:gsub('"', '""')))
    vbsFile:close()
    log("vbs文件: " .. vbsPath)

    LrTasks.execute(string.format('wscript.exe "%s"', vbsPath))
    log("已隐藏启动Python进程")

    -- 等待结果文件
    local resultPath = tempDir .. "/result.json"
    local maxWait = WAIT_TIMEOUT_SECONDS
    local waited = 0

    while not LrFileUtils.exists(resultPath) and waited < maxWait do
        if progress:isCanceled() then
            log("用户取消")
            progress:done()
            return
        end
        LrTasks.sleep(1)
        waited = waited + 1
        progress:setPortionComplete(waited, maxWait)
        progress:setCaption(string.format("AI分析中... %d秒", waited))
        if waited % 10 == 0 then
            log("等待... " .. waited .. "秒")
        end
    end

    progress:done()

    if not LrFileUtils.exists(resultPath) then
        log("超时! 等待了" .. waited .. "秒")
        LrDialogs.message("超时", "AI分析超时，已等待 " .. waited .. " 秒\n日志: " .. LOG_FILE .. "\nWorker日志: " .. workerLogPath)
        return
    end

    log("收到结果，耗时" .. waited .. "秒")

    -- 读取结果
    local resultFile = io.open(resultPath, "r")
    local resultContent = resultFile:read("*a")
    resultFile:close()
    log("结果: " .. resultContent)

    local rawText = ""
    local rawPath = tempDir .. "/raw.txt"
    if LrFileUtils.exists(rawPath) then
        local rawFile = io.open(rawPath, "r")
        rawText = rawFile:read("*a")
        rawFile:close()
        log("原始LLM输出: " .. rawText)
    end

    -- 解析JSON到参数表
    local params = {}
    params.advice = resultContent:match('"advice"%s*:%s*"([^"]*)"')
    params.exposure = resultNumber(resultContent, "exposure")
    params.contrast = resultNumber(resultContent, "contrast")
    params.highlights = resultNumber(resultContent, "highlights")
    params.shadows = resultNumber(resultContent, "shadows")
    params.whites = resultNumber(resultContent, "whites")
    params.blacks = resultNumber(resultContent, "blacks")
    params.texture = resultNumber(resultContent, "texture")
    params.clarity = resultNumber(resultContent, "clarity")
    params.dehaze = resultNumber(resultContent, "dehaze")
    params.vibrance = resultNumber(resultContent, "vibrance")
    params.saturation = resultNumber(resultContent, "saturation")
    params.temperature = resultNumber(resultContent, "temperature")
    params.tint = resultNumber(resultContent, "tint")
    params.hueRed = resultNumber(resultContent, "hue_red")
    params.hueOrange = resultNumber(resultContent, "hue_orange")
    params.hueYellow = resultNumber(resultContent, "hue_yellow")
    params.hueGreen = resultNumber(resultContent, "hue_green")
    params.hueAqua = resultNumber(resultContent, "hue_aqua")
    params.hueBlue = resultNumber(resultContent, "hue_blue")
    params.satRed = resultNumber(resultContent, "saturation_red")
    params.satOrange = resultNumber(resultContent, "saturation_orange")
    params.satYellow = resultNumber(resultContent, "saturation_yellow")
    params.satGreen = resultNumber(resultContent, "saturation_green")
    params.satAqua = resultNumber(resultContent, "saturation_aqua")
    params.satBlue = resultNumber(resultContent, "saturation_blue")
    params.lumRed = resultNumber(resultContent, "luminance_red")
    params.lumOrange = resultNumber(resultContent, "luminance_orange")
    params.lumYellow = resultNumber(resultContent, "luminance_yellow")
    params.lumGreen = resultNumber(resultContent, "luminance_green")
    params.lumAqua = resultNumber(resultContent, "luminance_aqua")
    params.lumBlue = resultNumber(resultContent, "luminance_blue")
    params.curveShadows = resultNumber(resultContent, "parametric_shadows")
    params.curveDarks = resultNumber(resultContent, "parametric_darks")
    params.curveLights = resultNumber(resultContent, "parametric_lights")
    params.curveHighlights = resultNumber(resultContent, "parametric_highlights")
    params.sharpness = resultNumber(resultContent, "sharpness")
    params.sharpenRadius = resultNumber(resultContent, "sharpen_radius")
    params.sharpenDetail = resultNumber(resultContent, "sharpen_detail")
    params.sharpenMasking = resultNumber(resultContent, "sharpen_masking")
    params.luminanceNr = resultNumber(resultContent, "luminance_noise_reduction")
    params.colorNr = resultNumber(resultContent, "color_noise_reduction")
    params.vignetteAmount = resultNumber(resultContent, "post_crop_vignette_amount")
    params.vignetteMidpoint = resultNumber(resultContent, "post_crop_vignette_midpoint")
    params.vignetteFeather = resultNumber(resultContent, "post_crop_vignette_feather")
    params.grainAmount = resultNumber(resultContent, "grain_amount")
    params.grainSize = resultNumber(resultContent, "grain_size")
    params.grainFrequency = resultNumber(resultContent, "grain_frequency")
    params.shadowHue = resultNumber(resultContent, "shadow_hue")
    params.shadowSat = resultNumber(resultContent, "shadow_saturation")
    params.highlightHue = resultNumber(resultContent, "highlight_hue")
    params.highlightSat = resultNumber(resultContent, "highlight_saturation")
    params.splitBalance = resultNumber(resultContent, "balance")
    params.lensProfileEnable = resultNumber(resultContent, "profile_enable")
    params.autoLateralCA = resultNumber(resultContent, "auto_lateral_ca")
    params.manualDistortion = resultNumber(resultContent, "manual_distortion")
    params.lensVignettingAmount = resultNumber(resultContent, "vignetting_amount")
    params.lensVignettingMidpoint = resultNumber(resultContent, "vignetting_midpoint")

    log("解析: advice=" .. (params.advice or "nil"))

    -- 显示结果
    local f = LrView.osFactory()
    local prefs = LrPrefs.prefsForPlugin()
    local canApply = params.advice and not params.advice:find("失败") and not params.advice:find("未返回") and not params.advice:find("超时")

    local resultDialog = f:column {
        spacing = f:control_spacing(),
        bind_to_object = prefs,

        f:static_text { title = "AI 建议:", font = "<bold>" },
        f:static_text { title = params.advice or "无", width_in_chars = 40, height_in_chars = 2 },

        f:separator {},

        f:static_text { title = "推荐参数:", font = "<bold>" },
        f:row {
            f:static_text { title = string.format("曝光: %.1f", tonumber(params.exposure) or 0) },
            f:static_text { title = string.format("对比度: %.0f", tonumber(params.contrast) or 0) },
        },
        f:row {
            f:static_text { title = string.format("高光: %.0f", tonumber(params.highlights) or 0) },
            f:static_text { title = string.format("阴影: %.0f", tonumber(params.shadows) or 0) },
        },
        f:row {
            f:static_text { title = string.format("白色: %.0f", tonumber(params.whites) or 0) },
            f:static_text { title = string.format("黑色: %.0f", tonumber(params.blacks) or 0) },
        },
        f:row {
            f:static_text { title = string.format("纹理: %.0f", tonumber(params.texture) or 0) },
            f:static_text { title = string.format("清晰: %.0f", tonumber(params.clarity) or 0) },
            f:static_text { title = string.format("去雾: %.0f", tonumber(params.dehaze) or 0) },
        },
        f:row {
            f:static_text { title = string.format("自然饱和: %.0f", tonumber(params.vibrance) or 0) },
            f:static_text { title = string.format("饱和度: %.0f", tonumber(params.saturation) or 0) },
        },
        f:row {
            f:static_text { title = string.format("色温: %.0f", tonumber(params.temperature) or 0) },
            f:static_text { title = string.format("色调: %.0f", tonumber(params.tint) or 0) },
        },

        f:separator {},

        f:static_text { title = "HSL 推荐:", font = "<bold>" },
        f:row {
            f:static_text { title = string.format("橙 明/饱/相: %.0f / %.0f / %.0f", tonumber(params.lumOrange) or 0, tonumber(params.satOrange) or 0, tonumber(params.hueOrange) or 0) },
        },
        f:row {
            f:static_text { title = string.format("黄 明/饱/相: %.0f / %.0f / %.0f", tonumber(params.lumYellow) or 0, tonumber(params.satYellow) or 0, tonumber(params.hueYellow) or 0) },
        },
        f:row {
            f:static_text { title = string.format("绿 明/饱/相: %.0f / %.0f / %.0f", tonumber(params.lumGreen) or 0, tonumber(params.satGreen) or 0, tonumber(params.hueGreen) or 0) },
        },

        f:separator {},

        f:static_text { title = "曲线 / 细节 / 效果:", font = "<bold>" },
        f:row {
            f:static_text { title = string.format("曲线 阴/暗/亮/高: %.0f / %.0f / %.0f / %.0f", tonumber(params.curveShadows) or 0, tonumber(params.curveDarks) or 0, tonumber(params.curveLights) or 0, tonumber(params.curveHighlights) or 0) },
        },
        f:row {
            f:static_text { title = string.format("锐化: %.0f  半径: %.1f  降噪: %.0f/%.0f", tonumber(params.sharpness) or 0, tonumber(params.sharpenRadius) or 0, tonumber(params.luminanceNr) or 0, tonumber(params.colorNr) or 0) },
        },
        f:row {
            f:static_text { title = string.format("暗角: %.0f  颗粒: %.0f", tonumber(params.vignetteAmount) or 0, tonumber(params.grainAmount) or 0) },
        },
        f:row {
            f:static_text { title = string.format("分离色调 阴影: %.0f/%.0f  高光: %.0f/%.0f", tonumber(params.shadowHue) or 0, tonumber(params.shadowSat) or 0, tonumber(params.highlightHue) or 0, tonumber(params.highlightSat) or 0) },
        },
        f:row {
            f:static_text { title = string.format("镜头校正: 配置 %.0f  色差 %.0f  畸变 %.0f", tonumber(params.lensProfileEnable) or 0, tonumber(params.autoLateralCA) or 0, tonumber(params.manualDistortion) or 0) },
        },

        f:separator {},

        f:static_text { title = "LLM 原始输出:", font = "<bold>" },
        f:edit_field {
            value = rawText ~= "" and rawText or resultContent,
            width_in_chars = 70,
            height_in_chars = 10,
            enabled = false
        },

        f:separator {},

        canApply and f:checkbox {
            title = "应用这些参数到照片",
            value = LrView.bind 'applyParams',
            checked_value = true,
            unchecked_value = false
        } or f:static_text {
            title = "分析失败，不能应用参数。",
            width_in_chars = 50
        },
    }

    prefs.applyParams = canApply == true

    local dialogResult = LrDialogs.presentModalDialog {
        title = "AI 分析结果",
        contents = resultDialog,
    }

    if dialogResult ~= "cancel" and prefs.applyParams then
        log("用户选择应用参数")
        local applyOk, applyErr = LrTasks.pcall(function()
            log(string.format(
                "准备应用到Develop滑块: Exposure=%s, Contrast=%s, Highlights=%s, Shadows=%s",
                tostring(params.exposure),
                tostring(params.contrast),
                tostring(params.highlights),
                tostring(params.shadows)
            ))
            LrApplicationView.switchToModule("develop")
            LrTasks.sleep(1)
            setDevelopValue("Exposure", params.exposure)
            setDevelopValue("Contrast", params.contrast)
            setDevelopValue("Highlights", params.highlights)
            setDevelopValue("Shadows", params.shadows)
            setDevelopValue("Whites", params.whites)
            setDevelopValue("Blacks", params.blacks)
            setDevelopValue("Texture", params.texture)
            setDevelopValue("Clarity", params.clarity)
            setDevelopValue("Dehaze", params.dehaze)
            setDevelopValue("Vibrance", params.vibrance)
            setDevelopValue("Saturation", params.saturation)
            setDevelopValue("Temperature", params.temperature)
            setDevelopValue("Tint", params.tint)
            setDevelopValue("HueAdjustmentRed", params.hueRed)
            setDevelopValue("HueAdjustmentOrange", params.hueOrange)
            setDevelopValue("HueAdjustmentYellow", params.hueYellow)
            setDevelopValue("HueAdjustmentGreen", params.hueGreen)
            setDevelopValue("HueAdjustmentAqua", params.hueAqua)
            setDevelopValue("HueAdjustmentBlue", params.hueBlue)
            setDevelopValue("SaturationAdjustmentRed", params.satRed)
            setDevelopValue("SaturationAdjustmentOrange", params.satOrange)
            setDevelopValue("SaturationAdjustmentYellow", params.satYellow)
            setDevelopValue("SaturationAdjustmentGreen", params.satGreen)
            setDevelopValue("SaturationAdjustmentAqua", params.satAqua)
            setDevelopValue("SaturationAdjustmentBlue", params.satBlue)
            setDevelopValue("LuminanceAdjustmentRed", params.lumRed)
            setDevelopValue("LuminanceAdjustmentOrange", params.lumOrange)
            setDevelopValue("LuminanceAdjustmentYellow", params.lumYellow)
            setDevelopValue("LuminanceAdjustmentGreen", params.lumGreen)
            setDevelopValue("LuminanceAdjustmentAqua", params.lumAqua)
            setDevelopValue("LuminanceAdjustmentBlue", params.lumBlue)
            setDevelopValue("ParametricShadows", params.curveShadows)
            setDevelopValue("ParametricDarks", params.curveDarks)
            setDevelopValue("ParametricLights", params.curveLights)
            setDevelopValue("ParametricHighlights", params.curveHighlights)
            setDevelopValue("Sharpness", params.sharpness)
            setDevelopValue("SharpenRadius", params.sharpenRadius)
            setDevelopValue("SharpenDetail", params.sharpenDetail)
            setDevelopValue("SharpenEdgeMasking", params.sharpenMasking)
            setDevelopValue("LuminanceSmoothing", params.luminanceNr)
            setDevelopValue("ColorNoiseReduction", params.colorNr)
            setDevelopValue("PostCropVignetteAmount", params.vignetteAmount)
            setDevelopValue("PostCropVignetteMidpoint", params.vignetteMidpoint)
            setDevelopValue("PostCropVignetteFeather", params.vignetteFeather)
            setDevelopValue("GrainAmount", params.grainAmount)
            setDevelopValue("GrainSize", params.grainSize)
            setDevelopValue("GrainFrequency", params.grainFrequency)
            setDevelopValue("SplitToningShadowHue", params.shadowHue)
            setDevelopValue("SplitToningShadowSaturation", params.shadowSat)
            setDevelopValue("SplitToningHighlightHue", params.highlightHue)
            setDevelopValue("SplitToningHighlightSaturation", params.highlightSat)
            setDevelopValue("SplitToningBalance", params.splitBalance)
            setDevelopValue("LensProfileEnable", params.lensProfileEnable)
            setDevelopValue("AutoLateralCA", params.autoLateralCA)
            setDevelopValue("LensManualDistortionAmount", params.manualDistortion)
            setDevelopValue("LensVignettingAmount", params.lensVignettingAmount)
            setDevelopValue("LensVignettingMidpoint", params.lensVignettingMidpoint)
        end)
        if applyOk then
            log("LrDevelopController应用流程完成")
            LrDialogs.showBezel("参数已应用!")
        else
            log("应用参数失败: " .. tostring(applyErr))
            LrDialogs.message("应用失败", tostring(applyErr) .. "\n日志: " .. LOG_FILE)
        end
    else
        log("用户未应用参数")
    end

    -- 清理
    LrFileUtils.delete(tempDir)
    log("=== 完成 ===")

end)
