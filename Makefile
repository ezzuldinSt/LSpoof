ARCHS = arm64
TARGET = iphone:clang:16.5:16.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = LocationSpoofer

LocationSpoofer_FILES = \
	Source/dylib_init.m \
	Source/LSHooking.m \
	Source/LocationSpoofer.m \
	Source/SessionController.m \
	Source/LSUI.m \
	Source/LSSettings.m \
	Source/LSSettingsViewController.m \
	Source/LSCoordinateEntryController.m \
	Source/LSPlaceSearchController.m \
	Source/RouteSimulator.m \
	Source/RouteGeometry.c \
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
