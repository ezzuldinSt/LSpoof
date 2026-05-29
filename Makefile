ARCHS = arm64
TARGET = iphone:clang:latest:16.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = LocationSpoofer

LocationSpoofer_FILES = \
	Source/dylib_init.m \
	Source/LSHooking.m \
	Source/LocationSpoofer.m \
	Source/RouteSimulator.m \
	Source/BookmarksManager.m \
	Source/OverlayWindow.m \
	Source/MapPickerViewController.m \
	Source/MapPickerViewController+Route.m \
	Source/MapPickerViewController+Bookmarks.m \
	Source/PersistenceManager.m

LocationSpoofer_CFLAGS = -fobjc-arc -Wall -Wextra -ISource
LocationSpoofer_FRAMEWORKS = Foundation UIKit CoreLocation MapKit
LocationSpoofer_LDFLAGS = -install_name @executable_path/Frameworks/LocationSpoofer.dylib

include $(THEOS)/makefiles/library.mk
