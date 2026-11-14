export TARGET = iphone:clang:14.5:14.0
export ARCHS = arm64
INSTALL_TARGET_PROCESSES = TikTok

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TikSaveAll
TikSaveAll_FILES = Tweak.xm
TikSaveAll_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
TikSaveAll_FRAMEWORKS = UIKit Photos Foundation

include $(THEOS_MAKE_PATH)/tweak.mk