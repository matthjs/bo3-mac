TARGET = BO3MacFix.dylib

DEBUG   ?= 0
ARCH    ?= x86_64
SDK     ?= macosx
OSXVER  ?= 10.13

SYSROOT  := $(shell xcrun --sdk $(SDK) --show-sdk-path)
ifeq ($(SYSROOT),)
$(error Could not find SDK "$(SDK)")
endif
CLANG    := clang
CC       := $(CLANG) -isysroot $(SYSROOT) -arch $(ARCH) -mmacosx-version-min=$(OSXVER)

CFLAGS  = -O1 -Wall -g -I include/ -I src/ -fvisibility=hidden
LDFLAGS = -shared -Wl,-undefined -Wl,dynamic_lookup -Llib -ldobby

FRAMEWORKS = -framework CoreFoundation -framework IOKit -framework CoreGraphics -framework ImageIO \
             -framework Foundation -framework AppKit -framework CoreText -framework Metal -framework QuartzCore \
             -weak_framework MetalFX

SOURCES = source/bo3macfix.c source/bo3macnative.m source/utilities.c source/steam.c source/steam_emu.c source/exports.c

# MetalFX needs macOS 13 and the launcher requires 14, so this file is built
# for 14 while the rest keeps the older target.
CC14 := $(CLANG) -isysroot $(SYSROOT) -arch $(ARCH) -mmacosx-version-min=14.0
METALFX_OBJ = metalfx.o

all: $(TARGET)

$(METALFX_OBJ): source/metalfx.m source/metalfx.h source/offsets.h
	$(CC14) $(CFLAGS) -c -o $@ source/metalfx.m

$(TARGET): $(SOURCES) $(METALFX_OBJ)
	$(CC) $(CFLAGS) $(FRAMEWORKS) $(DEFINES) $(LDFLAGS) -o $@ $(SOURCES) $(METALFX_OBJ)

clean:
	rm -f -- $(TARGET) $(METALFX_OBJ)
