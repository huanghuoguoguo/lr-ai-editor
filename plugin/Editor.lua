local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'
local LrPrefs = import 'LrPrefs'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrExportSession = import 'LrExportSession'
local LrProgressScope = import 'LrProgressScope'

local userConfig = require('config')
local prefs = LrPrefs.prefsForPlugin()

LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()
    local photo = catalog:getTargetPhoto()

    if not photo then
        LrDialogs.message("请先选择一张照片")
        return
    end

    -- 加载默认配置
    prefs.workerPath = prefs.workerPath or userConfig.workerPath
    prefs.tempFolder = prefs.tempFolder or LrPathUtils.getStandardFilePath('desktop')
    prefs.previewSize = prefs.previewSize or userConfig.previewSize
    prefs.model = prefs.model or userConfig.defaultModel
    prefs.stylePrompt = prefs.stylePrompt or ""

    -- 构建对话框
    local f = LrView.osFactory()

    local dialogContent = f:column {
        spacing = f:control_spacing(),
        bind_to_object = prefs,

        f:row {
            f:static_text { title = "Worker路径:", width = LrView.share "label_width" },
            f:edit_field { value = LrView.bind 'workerPath', width_in_chars = 40 },
            f:push_button {
                title = "浏览...",
                action = function()
                    local result = LrDialogs.runOpenPanel({
                        title = "选择 worker.py",
                        canChooseFiles = true,
                        canChooseDirectories = false,
                    })
                    if result and #result > 0 then prefs.workerPath = result[1] end
                end
            }
        },

        f:row {
            f:static_text { title = "模型:", width = LrView.share "label_width" },
            f:edit_field { value = LrView.bind 'model', width_in_chars = 20 }
        },

        f:row {
            f:static_text { title = "风格描述:", width = LrView.share "label_width" },
            f:edit_field {
                value = LrView.bind 'stylePrompt',
                width_in_chars = 40,
                height_in_chars = 2
            }
        },

        f:row {
            f:static_text { title = "预览尺寸:", width = LrView.share "label_width" },
            f:popup_menu {
                value = LrView.bind 'previewSize',
                items = {
                    { title = "512px (最快)", value = 512 },
                    { title = "768px (推荐)", value = 768 },
                    { title = "1024px (详细)", value = 1024 },
                }
            }
        },
    }

    local result = LrDialogs.presentModalDialog {
        title = "AI 修图分析",
        contents = dialogContent,
    }

    if result == "cancel" then return end

    -- 创建临时文件夹
    local timestamp = os.time()
    local tempDir = LrPathUtils.child(prefs.tempFolder, "lr_ai_" .. timestamp)
    LrFileUtils.createAllDirectories(tempDir)

    -- 导出预览图
    local previewPath = LrPathUtils.child(tempDir, "preview.jpg")

    local exportSettings = {
        LR_format = "JPEG",
        LR_jpeg_quality = userConfig.previewQuality,
        LR_export_colorSpace = "sRGB",
        LR_size_doConstrain = true,
        LR_size_maxWidth = prefs.previewSize,
        LR_size_maxHeight = prefs.previewSize,
        LR_export_destinationType = "specificFolder",
        LR_export_destinationPathPrefix = tempDir,
        LR_export_useSubfolder = false,
        LR_collisionHandling = "overwrite",
    }

    local exportSession = LrExportSession {
        photosToExport = { photo },
        exportSettings = exportSettings
    }

    local progress = LrProgressScope { title = "AI分析中..." }

    for _, rendition in exportSession:renditions() do
        local success, pathOrMessage = rendition:waitForRender()
        if not success then
            LrDialogs.message("导出失败", pathOrMessage)
            progress:done()
            return
        end
        previewPath = pathOrMessage
    end

    progress:setCaption("调用AI模型...")

    -- 写入请求文件
    local requestFile = io.open(LrPathUtils.child(tempDir, "request.json"), "w")
    requestFile:write(string.format([[
{
    "image_path": "%s",
    "model": "%s",
    "style_prompt": "%s"
}
]], previewPath, prefs.model, prefs.stylePrompt:gsub('"', '\\"')))
    requestFile:close()

    -- 启动Python Worker
    local batPath = LrPathUtils.child(tempDir, "run_worker.bat")
    local batFile = io.open(batPath, "w")
    batFile:write("@echo off\n")
    if userConfig.pythonPath and userConfig.pythonPath ~= "" then
        batFile:write(string.format('"%s" "%s" "%s"\n', userConfig.pythonPath, prefs.workerPath, tempDir))
    else
        batFile:write(string.format('python "%s" "%s"\n', prefs.workerPath, tempDir))
    end
    batFile:close()

    LrTasks.execute(string.format('start "LR AI Editor" "%s"', batPath))

    -- 等待结果
    local resultPath = LrPathUtils.child(tempDir, "result.json")
    local maxWait = 60  -- 最多等待60秒
    local waited = 0

    while not LrFileUtils.exists(resultPath) and waited < maxWait do
        if progress:isCanceled() then
            progress:done()
            return
        end
        LrTasks.sleep(1)
        waited = waited + 1
        progress:setPortionComplete(waited, maxWait)
    end

    progress:done()

    if not LrFileUtils.exists(resultPath) then
        LrDialogs.message("超时", "AI分析超时，请检查LiteLLM是否正常运行")
        return
    end

    -- 读取结果
    local resultFile = io.open(resultPath, "r")
    local resultContent = resultFile:read("*a")
    resultFile:close()

    -- 解析JSON (简化版解析)
    local advice = resultContent:match('"advice"%s*:%s*"([^"]*)"')
    local exposure = resultContent:match('"exposure"%s*:%s*([%-?%d%.]+)')
    local contrast = resultContent:match('"contrast"%s*:%s*([%-?%d%.]+)')
    local highlights = resultContent:match('"highlights"%s*:%s*([%-?%d%.]+)')
    local shadows = resultContent:match('"shadows"%s*:%s*([%-?%d%.]+)')
    local saturation = resultContent:match('"saturation"%s*:%s*([%-?%d%.]+)')
    local temperature = resultContent:match('"temperature"%s*:%s*([%-?%d%.]+)')
    local tint = resultContent:match('"tint"%s*:%s*([%-?%d%.]+)')

    -- 显示结果对话框
    local resultDialogContent = f:column {
        spacing = f:control_spacing(),
        bind_to_object = prefs,

        f:static_text { title = "AI 分析建议:", font = "<bold>" },
        f:static_text { title = advice or "无建议", width_in_chars = 50, height_in_chars = 3 },

        f:separator {},

        f:static_text { title = "推荐参数:", font = "<bold>" },
        f:row {
            f:static_text { title = string.format("曝光: %s", exposure or "0") },
            f:static_text { title = string.format("对比度: %s", contrast or "0") },
        },
        f:row {
            f:static_text { title = string.format("高光: %s", highlights or "0") },
            f:static_text { title = string.format("阴影: %s", shadows or "0") },
        },
        f:row {
            f:static_text { title = string.format("饱和度: %s", saturation or "0") },
        },

        f:separator {},

        f:checkbox {
            title = "应用这些参数到照片",
            value = LrView.bind 'applyParams',
            checked_value = true,
            unchecked_value = false
        },
    }

    prefs.applyParams = true

    local applyResult = LrDialogs.presentModalDialog {
        title = "AI 分析结果",
        contents = resultDialogContent,
    }

    -- 如果用户选择应用参数
    if applyResult ~= "cancel" and prefs.applyParams then
        catalog:withWriteAccessDo("AI参数应用", function()
            local settings = {}
            if exposure then settings.Exposure2012 = tonumber(exposure) end
            if contrast then settings.Contrast2012 = tonumber(contrast) end
            if highlights then settings.Highlights2012 = tonumber(highlights) end
            if shadows then settings.Shadows2012 = tonumber(shadows) end
            if saturation then settings.Saturation = tonumber(saturation) end
            if temperature then settings.Temperature = tonumber(temperature) end
            if tint then settings.Tint = tonumber(tint) end

            photo:applyDevelopSettings(settings)
        end)

        LrDialogs.showBezel("参数已应用!")
    end

    -- 清理临时文件
    LrFileUtils.delete(tempDir)

end)
