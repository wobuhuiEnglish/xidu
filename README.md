# 隙读

隙读是一款轻量的 macOS 菜单栏电子书阅读器，可以把正文显示在菜单栏中，适合利用零碎时间阅读。

## 功能

- 支持 TXT 和 EPUB
- 菜单栏显示正文，可随时隐藏
- 上一段、下一段和显示/隐藏快捷键可自定义
- 支持鼠标侧键
- 显示长度、字号和文字颜色可调
- 独立展开阅读窗口
- 展开阅读窗口内支持查找（当前章节或整本书）、划线与摘录
- 托管书架、批量添加与阅读进度保存
- 在 Finder 中双击或用“打开方式”即可加入书架并打开
- 导入书籍后保存本地副本，原文件移动或删除不影响阅读
- 支持 Apple 芯片和 Intel Mac

## 下载与安装

前往 [Releases](https://github.com/wobuhuiEnglish/xidu/releases/latest) 下载最新版 DMG。

1. 双击打开 DMG。
2. 将“隙读”拖入“应用程序”。
3. 启动隙读，然后从菜单栏图标添加 TXT 或 EPUB。

当前发行版尚未经过 Apple Developer ID 公证。如果 macOS 阻止首次启动，请在 Finder 的“应用程序”中右键“隙读”，选择“打开”，然后再次确认。

## 从源码构建

需要 macOS 13 或更高版本，以及 Xcode Command Line Tools。

```bash
./build.sh
```

构建结果位于 `build/隙读.app`。脚本默认生成同时支持 `arm64` 和 `x86_64` 的 Universal 应用。

## 隐私

隙读完全在本机运行，不上传电子书、阅读进度或其他个人数据。托管书库位于用户的 `Application Support/隙读/Books` 目录，阅读进度、书架和划线也保存在 `Application Support/隙读` 下。

## 许可证

本项目采用 [GNU General Public License v3.0](LICENSE)。

