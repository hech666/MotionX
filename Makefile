ARCHS = arm64e
TARGET = iphone:clang:16.5:15.0
# Override with: make package THEOS_PACKAGE_SCHEME=roothide
THEOS_PACKAGE_SCHEME ?= roothide
FINALPACKAGE = 1
DEBUG = 0
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = MotionX
MotionX_FILES = MotionX.mm
MotionX_CFLAGS = -fno-objc-arc -fobjc-exceptions -fexceptions -Wall -Wextra -Wno-unused-parameter
MotionX_CCFLAGS = -std=c++17
MotionX_FRAMEWORKS = Foundation CoreFoundation UIKit QuartzCore AVFoundation CoreMedia
MotionX_LIBRARIES = substrate
include $(THEOS_MAKE_PATH)/tweak.mk
