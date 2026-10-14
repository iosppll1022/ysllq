# Theos Makefile —— 编译为可注入的用户态 dylib（不越狱）
# 用法：安装 Theos 后，在本目录执行  `make`，产物在 ./.theos/obj/ 或 ./packages/
# 切换 .x / .m：默认用 Tweak.x；想用纯 ObjC 版，把 FILES 改成 inject_cloudkit.m 并删掉 Tweak.x。

TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e

# 关键：生成“可被 insert_dylib 注入”的独立 dylib，而不是走 Cydia 的 MobileSubstrate 自动加载
INSTALL_TARGET_PROCESSES = YSBrowser

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ysfakeck
ysfakeck_FILES = Tweak.x
# 纯 ObjC 版改成：  ysfakeck_FILES = inject_cloudkit.m
ysfakeck_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
ysfakeck_FRAMEWORKS = Foundation
# 用户态 Substrate：链接 CydiaSubstrate（Theos 自带 libsubstrate 头与桩）
ysfakeck_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
