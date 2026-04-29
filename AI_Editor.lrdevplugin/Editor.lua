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

-- 固定配置
local PYTHON_PATH = "C:/Users/glwuy/AppData/Local/Programs/Python/Python312/python.exe"
local WORKER_PATH = "D:/image/lr-ai-editor/worker/worker.py"
local PREVIEW_SIZE = 384
local MODEL = "litellm_proxy/mimo"
local LOG_FILE = "D:/image/lr_ai_log.txt"
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
    LrDevelopController.setValue(param, n)
    log(string.format("LrDevelopController.setValue成功: %s=%s", param, tostring(n)))
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

    -- 创建临时文件夹
    local timestamp = os.time()
    local tempDir = "C:/Users/glwuy/Desktop/lr_ai_" .. timestamp
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
    "Tint": %s
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

    -- 解析JSON
    local advice = resultContent:match('"advice"%s*:%s*"([^"]*)"')
    local exposure = resultContent:match('"exposure"%s*:%s*([%-?%d%.]+)')
    local contrast = resultContent:match('"contrast"%s*:%s*([%-?%d%.]+)')
    local highlights = resultContent:match('"highlights"%s*:%s*([%-?%d%.]+)')
    local shadows = resultContent:match('"shadows"%s*:%s*([%-?%d%.]+)')
    local whites = resultContent:match('"whites"%s*:%s*([%-?%d%.]+)')
    local blacks = resultContent:match('"blacks"%s*:%s*([%-?%d%.]+)')
    local texture = resultContent:match('"texture"%s*:%s*([%-?%d%.]+)')
    local clarity = resultContent:match('"clarity"%s*:%s*([%-?%d%.]+)')
    local dehaze = resultContent:match('"dehaze"%s*:%s*([%-?%d%.]+)')
    local vibrance = resultContent:match('"vibrance"%s*:%s*([%-?%d%.]+)')
    local saturation = resultContent:match('"saturation"%s*:%s*([%-?%d%.]+)')
    local temperature = resultContent:match('"temperature"%s*:%s*([%-?%d%.]+)')
    local tint = resultContent:match('"tint"%s*:%s*([%-?%d%.]+)')

    log("解析: advice=" .. (advice or "nil"))

    -- 显示结果
    local f = LrView.osFactory()
    local prefs = LrPrefs.prefsForPlugin()
    local canApply = advice and not advice:find("失败") and not advice:find("未返回") and not advice:find("超时")

    local resultDialog = f:column {
        spacing = f:control_spacing(),
        bind_to_object = prefs,

        f:static_text { title = "AI 建议:", font = "<bold>" },
        f:static_text { title = advice or "无", width_in_chars = 40, height_in_chars = 2 },

        f:separator {},

        f:static_text { title = "推荐参数:", font = "<bold>" },
        f:row {
            f:static_text { title = string.format("曝光: %.1f", tonumber(exposure) or 0) },
            f:static_text { title = string.format("对比度: %.0f", tonumber(contrast) or 0) },
        },
        f:row {
            f:static_text { title = string.format("高光: %.0f", tonumber(highlights) or 0) },
            f:static_text { title = string.format("阴影: %.0f", tonumber(shadows) or 0) },
        },
        f:row {
            f:static_text { title = string.format("白色: %.0f", tonumber(whites) or 0) },
            f:static_text { title = string.format("黑色: %.0f", tonumber(blacks) or 0) },
        },
        f:row {
            f:static_text { title = string.format("纹理: %.0f", tonumber(texture) or 0) },
            f:static_text { title = string.format("清晰: %.0f", tonumber(clarity) or 0) },
            f:static_text { title = string.format("去雾: %.0f", tonumber(dehaze) or 0) },
        },
        f:row {
            f:static_text { title = string.format("自然饱和: %.0f", tonumber(vibrance) or 0) },
            f:static_text { title = string.format("饱和度: %.0f", tonumber(saturation) or 0) },
        },
        f:row {
            f:static_text { title = string.format("色温: %.0f", tonumber(temperature) or 0) },
            f:static_text { title = string.format("色调: %.0f", tonumber(tint) or 0) },
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
                "准备应用到Develop滑块: Exposure=%s, Contrast=%s, Highlights=%s, Shadows=%s, Whites=%s, Blacks=%s, Texture=%s, Clarity=%s, Dehaze=%s, Vibrance=%s, Saturation=%s, Temperature=%s, Tint=%s",
                tostring(exposure),
                tostring(contrast),
                tostring(highlights),
                tostring(shadows),
                tostring(whites),
                tostring(blacks),
                tostring(texture),
                tostring(clarity),
                tostring(dehaze),
                tostring(vibrance),
                tostring(saturation),
                tostring(temperature),
                tostring(tint)
            ))
            LrApplicationView.switchToModule("develop")
            LrTasks.sleep(1)
            setDevelopValue("Exposure", exposure)
            setDevelopValue("Contrast", contrast)
            setDevelopValue("Highlights", highlights)
            setDevelopValue("Shadows", shadows)
            setDevelopValue("Whites", whites)
            setDevelopValue("Blacks", blacks)
            setDevelopValue("Texture", texture)
            setDevelopValue("Clarity", clarity)
            setDevelopValue("Dehaze", dehaze)
            setDevelopValue("Vibrance", vibrance)
            setDevelopValue("Saturation", saturation)
            setDevelopValue("Temperature", temperature)
            setDevelopValue("Tint", tint)
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
