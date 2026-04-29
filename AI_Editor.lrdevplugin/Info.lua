return {
    LrSdkVersion = 8.0,
    LrToolkitIdentifier = 'com.lr-ai-editor.plugin',
    LrPluginName = 'LR AI Editor',
    LrPluginInfoUrl = 'https://github.com/yourname/lr-ai-editor',

    -- 注册到 "文件" → "增效工具额外功能" 菜单
    LrExportMenuItems = {
        {
            title = "AI Analyze Photo",
            file = "Editor.lua",
        }
    },

    -- 同时注册到 Library 模块的菜单
    LrLibraryMenuItems = {
        {
            title = "AI Analyze Photo",
            file = "Editor.lua",
        }
    }
}