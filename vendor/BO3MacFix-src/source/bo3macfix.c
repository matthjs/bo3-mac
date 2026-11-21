#include <_stdio.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdarg.h>
#include <ctype.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include "dyld-interposing.h"
#include "metalfx.h"
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/mman.h>
#include <sandbox.h>
#include <spawn.h>
#include <errno.h>
#include <sys/wait.h>
#include <crt_externs.h>
#include <CommonCrypto/CommonDigest.h>
#include <os/lock.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <IOKit/hid/IOHIDDevice.h>

#include "bo3macnative.h"
#include "codhavoktypes.h"
#include "dobby.h"
#include "utilities.h"
#include "offsets.h"
#include "steam.h"
#include "steam_emu.h"

#include "versioninfo.h"

#ifdef MACFIX_DEBUG
#define Version_Prefix "[" LAUNCHER_NAME " DEBUG]"
#else
#define Version_Prefix "[" LAUNCHER_NAME " " LAUNCHER_FULL_VERSION "]"
#endif
#define Error_Prefix "^7[^6" LAUNCHER_NAME "^7] "

#define Basegame_Path "../../../"

#define Macfix_Path "../../../BO3MacFix"

typedef struct _SESSIONMODE_STATE {
    int32_t mode : 4;
    int32_t campaignMode : 2;
    int32_t network : 4;
    int32_t matchmaking : 4;
    int32_t game : 4;
    int32_t viewport : 4;
} SESSIONMODE_STATE;

// The base address of the CoDBlkOps3_Exe executable
uint64_t game_base_address = 0x0;
// The hashed network password used for network encryption.
uint64_t network_password = 0;
// Whether to only allow friends to join the session.
bool friends_only = false;

// Returns the current gamemode string as used in paths
static const char *GetGamemodeString() {
    SESSIONMODE_STATE modeState = *(SESSIONMODE_STATE *)(game_base_address + ADDR_sSessionModeState);
    switch (modeState.mode) {
        case 0:
            return "zm";
        case 1:
            return "mp";
        case 2:
            return "cp";
        default:
            return "core";
    }
}

// game functions we call upon
static void(*build_usermods_path)(const char *filename, const char *extension, size_t out_size, char *out_path, int type_maybe, char *workshop_id);
static void *(*DB_FindXAssetHeader)(int type, char *name, bool errorIfMissing, int waitTime);
static void (*Dvar_SetFromStringByName)(const char *dvarName, const char *string, bool createIfMissing);
static void (*Com_Error)(char *file, int line, int code, char *fmt, ...);
static uint16_t (*Sys_Checksum)(uint8_t *payload, int paylen);
static uint8_t (*MSG_ReadByte)(void *msg);
static void (*MSG_WriteByte)(void *msg, int64_t c);

// Makes sure incoming checksums have our password
install_hook_name(Sys_VerifyPacketChecksum, int, uint8_t *payload, int paylen) {
    if (paylen >= 2) {
        int newlen = paylen - 2;
        uint16_t payload_checksum = *(uint16_t *)(payload + newlen);
        uint16_t expected_checksum = (uint16_t)network_password ^ Sys_Checksum(payload, newlen);
        if (payload_checksum == expected_checksum)
            return newlen;
#ifdef MACFIX_DEBUG
        printf("Mismatched packet checksum! (%04x != %04x)\n", payload_checksum, expected_checksum);
#endif
    }
    return -1;
}

// Adds our password onto checksums
install_hook_name(Sys_CheckSumPacketCopy, uint16_t, uint8_t *dest, uint8_t *payload, int paylen) {
    uint16_t ret = orig_Sys_CheckSumPacketCopy(dest, payload, paylen);
    ret ^= (uint16_t)network_password;
    return ret;
}

#define ZBR_PREFIX_BYTE (uint8_t)((network_password & 0xFF0000) >> 16)
#define ZBR_PREFIX_BYTE2 (uint8_t)((network_password & 0xFF000000) >> 24)

// Adds password into lobby messages
install_hook_name(LobbyMsgRW_PrepReadMsg, bool, void *msg) {
    bool orig = orig_LobbyMsgRW_PrepReadMsg(msg);
    if (orig && network_password != 0 && ZBR_PREFIX_BYTE != 0) {
        uint8_t prefbyte1 = MSG_ReadByte(msg);
        uint8_t prefbyte2 = MSG_ReadByte(msg);
        if (!ZBR_PREFIX_BYTE || (((prefbyte1 == ZBR_PREFIX_BYTE) && (prefbyte2 == ZBR_PREFIX_BYTE2))))
            return true;
#ifdef MACFIX_DEBUG
        printf("Failed prepreadmsg password (Got %02x %02x, expected %02x %02x)\n", prefbyte1, prefbyte2, ZBR_PREFIX_BYTE, ZBR_PREFIX_BYTE2);
#endif
        return false;
    }
    return orig;
}
install_hook_name(LobbyMsgRW_PrepWriteMsg, bool, void *lobbyMsg, uint8_t *data, int length, int msgType) {
    bool orig = orig_LobbyMsgRW_PrepWriteMsg(lobbyMsg, data, length, msgType);
    if (orig && network_password != 0) {
        MSG_WriteByte(lobbyMsg, ZBR_PREFIX_BYTE);
        MSG_WriteByte(lobbyMsg, ZBR_PREFIX_BYTE2);
    }
    return orig;
}

// Prints out logs to stdout that would normally go in the logging window
install_hook_name(someLoggingFunction, void, int bla, int bla2, char *str, int bla3) {
#ifdef MACFIX_DEBUG
    printf("%s", str);
#endif
    orig_someLoggingFunction(bla, bla2, str, bla3);
    return;
}

/*
// Hooks some early window creation function to set the window title to ours
install_hook_name(someWindowCreationFunction, bool, void *r3, int r4) {
    bool r = orig_someWindowCreationFunction(r3, r4);
    set_window_title("Call of Duty: Black Ops III on Mac");
    return r;
}
*/

// Hooks the SDL window title setting function
bool added_menu_bar = false;
install_hook_name(SDL_SetWindowTitle, void, void *sdlWindow, const char *title)
{
    // verify the window title we're setting is the main game window
    if (strcmp("Call of Duty: Black Ops III", title) == 0)
    {
        title = "Call of Duty: Black Ops III on Mac";
        set_window_title(title);
        if (added_menu_bar == false) {
            //add_menu_bar();
            added_menu_bar = true;
        }
    }
    orig_SDL_SetWindowTitle(sdlWindow, title);
}

// Adds the version of our mod to the version info in the corner
install_hook_name(Live_SystemInfo, bool, int controllerIndex, int info, char *outputString, int outputLen) {
    bool r = orig_Live_SystemInfo(controllerIndex, info, outputString, outputLen);
    if (info == 0 && r == true) {
        char newStr[200];
        snprintf(newStr, sizeof(newStr), Version_Prefix " %s", outputString);
        // snprintf, not strncpy, so a long string still ends in a NUL
        if (outputLen > 0)
            snprintf(outputString, outputLen, "%s", newStr);
    }
    return r;
}

// Rejects instant messages from users who aren't friends if friends only is enabled.
install_hook_name(dwInstantDispatchMessage, bool, uint64_t userId, int controllerIndex, uint8_t *data, int datalen) {
    if (friends_only) {
        if (!steam_friends_with_user(userId) && // user isn't a friend
            userId != steam_id().id && // user isn't ourselves
            (userId >> 32) == 0x01100001) { // user is a steamid, not a guest or gameserver
#ifdef MACFIX_DEBUG
            printf("Rejecting instant message from %016llx due to friendsonly\n", userId);
#endif
            return true;
        }
    }
    if (datalen >= 2) {
        if (data[0] != 0x31) {
#ifdef MACFIX_DEBUG
            printf("Rejecting instant message from %016llx since it's invalid (1)\n", userId);
#endif
            return true;
        }
        if (data[1] == 0x65 || data[1] == 0x6D) {
#ifdef MACFIX_DEBUG
            printf("Rejecting instant message from %016llx since it's invalid (2)\n", userId);
#endif
            return true;
        }
    }
#ifdef MACFIX_DEBUG
    printf("Dispatching instant message from %016llx\n", userId);
#endif
    return orig_dwInstantDispatchMessage(userId, controllerIndex, data, datalen);
}

#define C2M_Path Macfix_Path "/cod2map/cod2map64.exe"

// Hashes the navmesh/navvolume data that goes into a conversion. The hash is
// saved next to the converted file, so a Workshop map update (or another map
// with the same name) gets converted again instead of reusing stale data.
static void hash_nav_data(const clumpheader *header, const NavMeshData *nm, const NavVolumeData *nv,
                          char *out_hex, size_t out_hex_len) {
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    CC_SHA256_Update(&ctx, header, sizeof(*header));
    CC_SHA256_Update(&ctx, nm->navMeshSettingsBuffer, nm->navMeshSettingsBufferSize);
    CC_SHA256_Update(&ctx, nm->userEdgePairsBuffer, nm->userEdgePairsBufferSize);
    CC_SHA256_Update(&ctx, nm->clusterGraphBuffer, nm->clusterGraphBufferSize);
    CC_SHA256_Update(&ctx, nm->mediatorBuffer, nm->mediatorBufferSize);
    CC_SHA256_Update(&ctx, nm->metadataBuffer, nm->metadataBufferSize);
    CC_SHA256_Update(&ctx, nm->clearanceCacheSeederBuffer, nm->clearanceCacheSeederBufferSize);
    if (nv != NULL) {
        CC_SHA256_Update(&ctx, nv->smallNavVolumeSettingsBuffer, nv->smallNavVolumeSettingsBufferSize);
        CC_SHA256_Update(&ctx, nv->smallNavVolumeMediatorBuffer, nv->smallNavVolumeMediatorBufferSize);
        CC_SHA256_Update(&ctx, nv->bigNavVolumeSettingsBuffer, nv->bigNavVolumeSettingsBufferSize);
        CC_SHA256_Update(&ctx, nv->bigNavVolumeMediatorBuffer, nv->bigNavVolumeMediatorBufferSize);
    }
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    bytes_to_hex(digest, sizeof(digest), out_hex, out_hex_len);
}

static bool read_hash_file(const char *path, char *out_hex, size_t out_hex_len) {
    FILE *fp = fopen(path, "r");
    if (fp == NULL)
        return false;
    bool ok = fgets(out_hex, (int)out_hex_len, fp) != NULL;
    fclose(fp);
    if (ok)
        out_hex[strcspn(out_hex, "\r\n")] = '\0';
    return ok;
}

static void write_hash_file(const char *path, const char *hex) {
    FILE *fp = fopen(path, "w");
    if (fp == NULL)
        return;
    fprintf(fp, "%s\n", hex);
    fclose(fp);
}

// Runs cod2map64 under Wine and waits for it. The arguments go straight to
// posix_spawn rather than through a shell: the map name comes from a Workshop
// item, and inside a popen() command line a name like "zm_$(...)" would run
// as a shell command. The output is read to the end, because closing the pipe
// early can kill the converter with SIGPIPE halfway through.
static bool run_map_conversion(const char *wine, const char *clump_arg, const char *out_arg) {
    const char *argv[] = { wine, C2M_Path, "-mac_navmesh", clump_arg, out_arg, NULL };
    printf("executing: \"%s\" %s -mac_navmesh \"%s\" \"%s\"\n", wine, C2M_Path, clump_arg, out_arg);

    int fds[2];
    if (pipe(fds) != 0)
        return false;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, fds[0]);
    posix_spawn_file_actions_addclose(&actions, fds[1]);

    pid_t pid = 0;
    int err = posix_spawn(&pid, wine, &actions, NULL, (char *const *)argv, *_NSGetEnviron());
    posix_spawn_file_actions_destroy(&actions);
    close(fds[1]);
    if (err != 0) {
        close(fds[0]);
        printf("failed to start wine: %s\n", strerror(err));
        return false;
    }

    char buf[0x400];
    ssize_t n;
    while ((n = read(fds[0], buf, sizeof(buf))) != 0) {
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }
        fwrite(buf, 1, (size_t)n, stdout);
    }
    close(fds[0]);

    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    printf("conversion finished (status %d)\n", status);
    return true;
}

// Initialises the navmesh and navvolume for the map.
// If we haven't made conversions already, call our conversion tool's binary.
install_hook_name(HKAI_InitMapData, void, const char *mapname, char restart) {
    printf("HKAI_InitMapData for %s\n", mapname);

    char physicsPath[0x200];
    char physicsAltPath[0x200];
    char physicsHashPath[0x200];
    char physicsAltVolumePath[0x200];
    snprintf(physicsPath, sizeof(physicsPath), "Physics/%s_navmesh.hkt", mapname);
    snprintf(physicsAltPath, sizeof(physicsAltPath), Macfix_Path "/Physics/%s_navmesh.hkt", mapname);
    snprintf(physicsHashPath, sizeof(physicsHashPath), Macfix_Path "/Physics/%s_navmesh.sha256", mapname);
    snprintf(physicsAltVolumePath, sizeof(physicsAltVolumePath), Macfix_Path "/Physics/%s_navvolume.hkt", mapname);

    // bees are broken on Demon Within - don't trust the original navmesh/navvolume
    bool shouldFixBees = strcmp(mapname, "cp_mi_cairo_infection2") == 0;
    // maps that ship a Mac navmesh don't need converting
    if (access(physicsPath, F_OK) == 0 && !shouldFixBees) {
        orig_HKAI_InitMapData(mapname, restart);
        return;
    }
    bool haveConverted = access(physicsAltPath, F_OK) == 0;

    if (!haveConverted && get_wine_path() == NULL)
        Com_Error(__FILE__, __LINE__, 2, Error_Prefix "You do not have Wine installed, so we can't convert the map '^2%s^7'.", mapname);
    if (!shouldFixBees) {
        char full_path[0x200];
        build_usermods_path(mapname, ".ff", 0x200, full_path, 2, (char *)(game_base_address + ADDR_g_workshopMapId));
        printf("map fastfile is '%s'\n", full_path);
    }

    char xasset_path[0x200];
    snprintf(xasset_path, 0x200, "maps/%s/%s_navmesh", GetGamemodeString(), mapname);
    NavMeshData *old_navmesh = DB_FindXAssetHeader(0x61, xasset_path, 1, -1);
    if (old_navmesh == NULL)
        Com_Error(__FILE__, __LINE__, 2, Error_Prefix "Failed to load '^3%s^7' for map '^2%s^7'.", xasset_path, mapname);

    snprintf(xasset_path, 0x200, "maps/%s/%s_navvolume", GetGamemodeString(), mapname);
    NavVolumeData *old_navvolume = DB_FindXAssetHeader(0x62, xasset_path, 0, -1);

    // set out a header for the conversion clump
    clumpheader header;
    memset(&header, 0, sizeof(clumpheader));
    header.navMeshSettingsBufferSize = old_navmesh->navMeshSettingsBufferSize;
    header.userEdgePairsBufferSize = old_navmesh->userEdgePairsBufferSize;
    header.clusterGraphBufferSize = old_navmesh->clusterGraphBufferSize;
    header.mediatorBufferSize = old_navmesh->mediatorBufferSize;
    header.metadataBufferSize = old_navmesh->metadataBufferSize;
    header.clearanceCacheSeederBufferSize = old_navmesh->clearanceCacheSeederBufferSize;
    if (old_navvolume != NULL) {
        header.bool_hasNavVolume = 1;
        header.smallNavVolumeSettingsBufferSize = old_navvolume->smallNavVolumeSettingsBufferSize;
        header.smallNavVolumeMediatorBufferSize = old_navvolume->smallNavVolumeMediatorBufferSize;
        header.bigNavVolumeSettingsBufferSize = old_navvolume->bigNavVolumeSettingsBufferSize;
        header.bigNavVolumeMediatorBufferSize = old_navvolume->bigNavVolumeMediatorBufferSize;
    }

    char nav_hash[(CC_SHA256_DIGEST_LENGTH * 2) + 1];
    hash_nav_data(&header, old_navmesh, old_navvolume, nav_hash, sizeof(nav_hash));

    if (haveConverted) {
        char saved_hash[sizeof(nav_hash)];
        if (!read_hash_file(physicsHashPath, saved_hash, sizeof(saved_hash))) {
            // converted before hashes were recorded, or shipped with the fix
            // (Demon Within): trust it and record what it was made from
            write_hash_file(physicsHashPath, nav_hash);
            orig_HKAI_InitMapData(mapname, restart);
            return;
        }
        if (strcmp(saved_hash, nav_hash) == 0) {
            orig_HKAI_InitMapData(mapname, restart);
            return;
        }
        printf("navmesh for %s changed since it was converted\n", mapname);
        if (get_wine_path() == NULL) {
            // an old conversion beats refusing to load a map that worked before
            printf("no wine to reconvert, using the old conversion\n");
            orig_HKAI_InitMapData(mapname, restart);
            return;
        }
    }

    // make sure the new physics folder exists
    if (access(Macfix_Path "/Physics/", F_OK) != 0)
        mkdir(Macfix_Path "/Physics/", 0755);

    // write out the header and all the navmesh/navvolume data to the clump
    FILE *clumpfile = fopen(Macfix_Path "/Physics/convert.clump", "wb");
    if (clumpfile == NULL)
        Com_Error(__FILE__, __LINE__, 2, Error_Prefix "Failed to create map conversion clump file.");
    fwrite(&header, sizeof(clumpheader), 1, clumpfile);
    fwrite(old_navmesh->navMeshSettingsBuffer, old_navmesh->navMeshSettingsBufferSize, 1, clumpfile);
    fwrite(old_navmesh->userEdgePairsBuffer, old_navmesh->userEdgePairsBufferSize, 1, clumpfile);
    fwrite(old_navmesh->clusterGraphBuffer, old_navmesh->clusterGraphBufferSize, 1, clumpfile);
    fwrite(old_navmesh->mediatorBuffer, old_navmesh->mediatorBufferSize, 1, clumpfile);
    fwrite(old_navmesh->metadataBuffer, old_navmesh->metadataBufferSize, 1, clumpfile);
    fwrite(old_navmesh->clearanceCacheSeederBuffer, old_navmesh->clearanceCacheSeederBufferSize, 1, clumpfile);
    if (old_navvolume != NULL) {
        fwrite(old_navvolume->smallNavVolumeSettingsBuffer, old_navvolume->smallNavVolumeSettingsBufferSize, 1, clumpfile);
        fwrite(old_navvolume->smallNavVolumeMediatorBuffer, old_navvolume->smallNavVolumeMediatorBufferSize, 1, clumpfile);
        fwrite(old_navvolume->bigNavVolumeSettingsBuffer, old_navvolume->bigNavVolumeSettingsBufferSize, 1, clumpfile);
        fwrite(old_navvolume->bigNavVolumeMediatorBuffer, old_navvolume->bigNavVolumeMediatorBufferSize, 1, clumpfile);
    }
    fclose(clumpfile);

    // drop the old conversion and its hash, so a failed run can't leave stale
    // output that looks valid
    unlink(physicsAltPath);
    unlink(physicsAltVolumePath);
    unlink(physicsHashPath);

    // call Wine with our cod2map64 binary, passing in the clump
    char cwd[1025];
    char clump_arg[0x600];
    char out_arg[0x600];
    getcwd(cwd, sizeof(cwd));
    snprintf(clump_arg, sizeof(clump_arg), "Z:%s/" Macfix_Path "/Physics/convert.clump", cwd);
    snprintf(out_arg, sizeof(out_arg), "Z:%s/" Macfix_Path "/Physics/%s", cwd, mapname);
    unsetenv("DYLD_INSERT_LIBRARIES"); // stop steam from fucking with our wine
    if (!run_map_conversion(get_wine_path(), clump_arg, out_arg)) {
        unlink(Macfix_Path "/Physics/convert.clump");
        Com_Error(__FILE__, __LINE__, 2, Error_Prefix "Failed to start map conversion process for '^2%s^7'.", mapname);
    }
    unlink(Macfix_Path "/Physics/convert.clump");

    // make sure we have a navmesh file generated
    if (access(physicsAltPath, F_OK) != 0)
        Com_Error(__FILE__, __LINE__, 2, Error_Prefix "Failed to convert map '^2%s^7' to Mac navmesh format.", mapname);
    write_hash_file(physicsHashPath, nav_hash);

    orig_HKAI_InitMapData(mapname, restart);
}

// patches all instance of the old network version with the new network version
static void network_version_patch() {
    uint16_t original_network_version = 18530;
    uint16_t patched_network_version = 18532;
    // all the places the original network version is hardcoded
    uint32_t netver_addresses[] = {
        0x00E078E4, 0x00E181D3, 0x00E83E4E, 0x00EB8389, 0x00EB91A9,
        0x00F988A0, 0x0104E0CB, 0x0105973D, 0x01059844, 0x0105C368,
        0x0105C5DC, 0x011F7C3E, 0x011F7C43, 0x011F7C49, 0x0120B547,
        0x0120B56A, 0x0123244C, 0x0126F78C, 0x0126F897, 0x0126F8BC,
        0x0126F90D, 0x0126F96F, 0x012D35DA, 0x013B5C1D, 
    };
    int num_netver_addrs = sizeof(netver_addresses) / sizeof(netver_addresses[0]);
    // enumerate through every one of these instances
    for (int i = 0; i < num_netver_addrs; i++) {
        // find the offset of the old number in the mov instruction
        int o = 0;
        bool found = false;
        for (o = 0; o < 16; o++)  {
            if (memcmp((void *)(game_base_address + netver_addresses[i] + o), &original_network_version, sizeof(uint16_t)) == 0) {
                found = true;
                break;
            }
        }
        if (found == true) {
            DobbyCodePatch((void *)(game_base_address + netver_addresses[i] + o), (uint8_t *)&patched_network_version, sizeof(uint16_t));
        } else {
            printf("failed to find network patch for %08x\n", netver_addresses[i]);
        }
    }
    // patch the tu version used to get the ffotd
    uint8_t original_tuver[] = "tu30";
    uint8_t patched_tuver[] = "tu32";
    uint32_t tuver_addresses[] = {
        0x016AA513, 0x017251FB, 0x01725209, 0x0172529C, 0x017252AB,
        0x017252B7, 
    };
    int num_tuver_addrs = sizeof(tuver_addresses) / sizeof(tuver_addresses[0]);
    // enumerate through every one of these instances
    for (int i = 0; i < num_tuver_addrs; i++) {
        int o = 0;
        bool found = false;
        for (o = 0; o < 16; o++)  {
            if (memcmp((void *)(game_base_address + tuver_addresses[i] + o), original_tuver, sizeof(original_tuver) - 1) == 0) {
                found = true;
                break;
            }
        }
        if (found == true) {
            DobbyCodePatch((void *)(game_base_address + tuver_addresses[i] + o), patched_tuver, sizeof(patched_tuver) - 1);
        } else {
            printf("failed to find string patch for %08x\n", tuver_addresses[i]);
        }
    }
    // patch the version reported by Lua_CoD_LuaCall_GetProtocolVersion
    uint32_t new_lua_version = 0x4690C800;
    DobbyCodePatch((void *)(game_base_address + ADDR_Lua_CoD_LuaCall_GetProtocolVersion_Inst + 3), (uint8_t *)&new_lua_version, sizeof(uint32_t));
    // set the LPC category version to match PC
    uint32_t newcategory = 0x0528;
    DobbyCodePatch((void *)(game_base_address + ADDR_LPC_GetRemoteManifest_Category_Inst + 6), (uint8_t *)&newcategory, sizeof(uint32_t));
    // set the CL version to match PC
    uint8_t mov_eax = 0xB8;
    int new_cl_version = 0xD3FC12;
    DobbyCodePatch((void *)(game_base_address + ADDR_LobbyHostMsg_SendJoinRequest_GetChangelistCall), &mov_eax, sizeof(uint8_t));
    DobbyCodePatch((void *)(game_base_address + ADDR_LobbyHostMsg_SendJoinRequest_GetChangelistCall + 1), (uint8_t *)&new_cl_version, sizeof(int));
}

void set_network_password(const char *password)
{
    if (password == NULL || strlen(password) < 1)
        network_password = 0;
    else
        network_password = gscu_canon_hash64(password);
}

int system_new(const char *command) {
    return -1;
}
FILE *popen_new(const char *command, const char *mode) {
    return NULL;
}
DYLD_INTERPOSE(system_new, system);
DYLD_INTERPOSE(popen_new, popen);

// this will get called in SDL2.0.7's FreeDevice, and not anywhere else, so it's safe
void IOHIDDeviceUnscheduleFromRunLoop_new(IOHIDDeviceRef device, CFRunLoopRef runLoop, CFStringRef runLoopMode)
{
    IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, runLoopMode);
    // release the device ref as per https://github.com/libsdl-org/SDL/commit/65fd63369411240dd54cad74916c6a6739e9363b
    //printf("releasing!\n");
    CFRelease(device);
}
DYLD_INTERPOSE(IOHIDDeviceUnscheduleFromRunLoop_new, IOHIDDeviceUnscheduleFromRunLoop);

// this will get called lots in SDL2.0.7's JoystickDeviceWasAddedCallback, so filter for PrimaryUsage
CFTypeRef IOHIDDeviceGetProperty_hook(IOHIDDeviceRef device, CFStringRef key)
{
    CFTypeRef orig = IOHIDDeviceGetProperty(device, key);
    // that address is the CFString for PrimaryUsage
    if (orig != NULL && key == (void *)(game_base_address + 0x1b8b420))
    { 
        //printf("device = %p\n", device);
        //printf("key = %p\n", key);
        // get the actual usage to see if SDL2.0.7 would be retaining it anyway
        uint32_t usage = 0;
        if (CFNumberGetValue(orig, kCFNumberSInt32Type, &usage))
        {
            // kHIDUsage_GD_Joystick, kHIDUsage_GD_GamePad, kHIDUsage_GD_MultiAxisController
            if ((usage < 9) && ((0x130U >> (usage & 0x1f) & 1) != 0)) {
                //printf("controller! retaining\n");
                // retain the device ref as per https://github.com/libsdl-org/SDL/commit/65fd63369411240dd54cad74916c6a6739e9363b
                CFRetain(device);
            }
        }
    }
    return orig;
}
DYLD_INTERPOSE(IOHIDDeviceGetProperty_hook, IOHIDDeviceGetProperty);

int sandbox_init_with_parameters(const char *profile, uint64_t flags, const char *const parameters[], char **errorbuf);

// The game resolves paths through ASL_ToNativePath constantly while it streams
// assets, and getcwd() costs several syscalls under Rosetta. On Leviathan it
// took up to a fifth of the file thread's time.
// The working directory only changes through chdir/fchdir, so cache it and
// drop the cache when the game calls either.
static os_unfair_lock cwd_lock = OS_UNFAIR_LOCK_INIT;
static char cached_cwd[1025];
static bool cached_cwd_valid = false;

static void get_cached_cwd(char *out, size_t out_len) {
    os_unfair_lock_lock(&cwd_lock);
    if (!cached_cwd_valid) {
        cached_cwd_valid = getcwd(cached_cwd, sizeof(cached_cwd)) != NULL;
        if (!cached_cwd_valid)
            cached_cwd[0] = '\0';
    }
    strlcpy(out, cached_cwd, out_len);
    os_unfair_lock_unlock(&cwd_lock);
}

static void invalidate_cached_cwd(void) {
    os_unfair_lock_lock(&cwd_lock);
    cached_cwd_valid = false;
    os_unfair_lock_unlock(&cwd_lock);
}

static int chdir_new(const char *path) {
    int ret = chdir(path);
    invalidate_cached_cwd();
    return ret;
}
DYLD_INTERPOSE(chdir_new, chdir);

static int fchdir_new(int fd) {
    int ret = fchdir(fd);
    invalidate_cached_cwd();
    return ret;
}
DYLD_INTERPOSE(fchdir_new, fchdir);

// The Mac port ships with Havok's Visual Debugger server turned on. While a
// map is loaded it listens on TCP port 25001 on every network interface and
// accepts anyone who connects. Nothing needs it, and the game has no setting
// for it, so refuse that one bind. The debugger then runs without a server.
// The game's own networking is UDP and uses other ports.
#define HAVOK_VDB_PORT 25001
static int bind_new(int fd, const struct sockaddr *addr, socklen_t len) {
    in_port_t port = 0;
    if (addr != NULL && addr->sa_family == AF_INET && len >= sizeof(struct sockaddr_in))
        port = ((const struct sockaddr_in *)addr)->sin_port;
    else if (addr != NULL && addr->sa_family == AF_INET6 && len >= sizeof(struct sockaddr_in6))
        port = ((const struct sockaddr_in6 *)addr)->sin6_port;
    if (ntohs(port) == HAVOK_VDB_PORT) {
        int type = 0;
        socklen_t type_len = sizeof(type);
        if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &type_len) == 0 && type == SOCK_STREAM) {
            printf("not starting the Havok Visual Debugger server on port %d\n", HAVOK_VDB_PORT);
            errno = EADDRNOTAVAIL;
            return -1;
        }
    }
    return bind(fd, addr, len);
}
DYLD_INTERPOSE(bind_new, bind);

// Each frame the image streamer re-sorts its list of streamed images by
// priority. When the list is the same length as last frame it uses an
// insertion sort, which is quick if the order barely changed but quadratic
// when many priorities change at once. Leviathan streams about 29,000 images,
// and there the sort took about 550 ms roughly once a second: the frame waits
// for it, so 120 fps dropped to 20-40 fps. Run the same insertion sort with a
// work budget, and finish with the engine's own quicksort (the path it takes
// when the length changed) once the budget runs out. That bounds the sort at
// a few milliseconds.
typedef bool (*stream_images_compare_t)(void *unused, uint32_t a, uint32_t b);
typedef void (*stream_images_quicksort_t)(uint32_t *begin, uint32_t *end, void *unused);
static stream_images_compare_t stream_images_compare;
static stream_images_quicksort_t stream_images_quicksort;

install_hook_name(StreamImages_InsertionSort, void, uint32_t *begin, uint32_t *end)
{
    size_t count = end - begin;
    size_t moves = 0, budget = 8 * count + 256;
    for (uint32_t *i = begin + 1; i < end; i++) {
        uint32_t value = *i;
        uint32_t *j = i;
        while (j > begin && stream_images_compare(NULL, value, j[-1])) {
            *j = j[-1];
            j--;
            if (++moves > budget) {
                *j = value;
                char unused;
                stream_images_quicksort(begin, end, &unused);
                return;
            }
        }
        *j = value;
    }
}

static void install_stream_sort_fix(void) {
    // Only hook the build these addresses come from.
    static const uint8_t insertion_sort[] = { 0x55, 0x48, 0x89, 0xe5, 0x41, 0x57, 0x41, 0x56, 0x41, 0x55, 0x41, 0x54, 0x53, 0x48, 0x83, 0xec, 0x18 };
    static const uint8_t compare[] = { 0x55, 0x48, 0x89, 0xe5, 0x89, 0xf0, 0x48, 0x8d, 0x3d };
    static const uint8_t quicksort[] = { 0x55, 0x48, 0x89, 0xe5, 0x41, 0x57, 0x41, 0x56, 0x41, 0x55, 0x41, 0x54, 0x53, 0x48, 0x83, 0xec, 0x28, 0x49, 0x89, 0xd4 };
    if (memcmp((void *)(game_base_address + ADDR_StreamImages_InsertionSort), insertion_sort, sizeof(insertion_sort)) != 0 ||
        memcmp((void *)(game_base_address + ADDR_StreamImages_Compare), compare, sizeof(compare)) != 0 ||
        memcmp((void *)(game_base_address + ADDR_StreamImages_QuickSort), quicksort, sizeof(quicksort)) != 0) {
        printf("[BO3MacFix] unexpected game build, not patching the image streamer sort\n");
        return;
    }
    stream_images_compare = (stream_images_compare_t)(game_base_address + ADDR_StreamImages_Compare);
    stream_images_quicksort = (stream_images_quicksort_t)(game_base_address + ADDR_StreamImages_QuickSort);
    install_hook_StreamImages_InsertionSort((void *)(game_base_address + ADDR_StreamImages_InsertionSort));
}

// The game starts with the Activision/Treyarch logo sequence followed by the
// Aspyr logo, played as one cinematic ("BO3_Global_Logo_LogoSequence;AspyrLogo")
// that can't be skipped. The function that starts it checks a dvar first and
// returns without playing anything when that dvar is off, so take that branch
// unconditionally: turn its `je` into a `jmp`.
static void install_intro_skip(void) {
    // cmp byte [rbx+0x8590], 0; jne; mov rdi, [dvar]; call Dvar_GetBool; test al, al;
    // je skip; lea rdi, ["BO3_Global_Logo_LogoSequence;AspyrLogo"]
    static const uint8_t intro_check[] = {
        0x80, 0xbb, 0x90, 0x85, 0x00, 0x00, 0x00, 0x75, 0x45, 0x48, 0x8b, 0x3d,
        0x0d, 0xa7, 0xa6, 0x10, 0xe8, 0x2c, 0xaf, 0x12, 0x00, 0x84, 0xc0, 0x74,
        0x35, 0x48, 0x8d, 0x3d, 0xde, 0x37, 0x85, 0x00
    };
    if (memcmp((void *)(game_base_address + ADDR_PlayIntro_DvarCheck), intro_check, sizeof(intro_check)) != 0) {
        printf("[BO3MacFix] unexpected game build, not skipping the intro\n");
        return;
    }
    uint8_t jmp_short = 0xeb;
    DobbyCodePatch((void *)(game_base_address + ADDR_PlayIntro_DvarCheck + ADDR_PlayIntro_Je_Offset), &jmp_short, sizeof(jmp_short));
}

#define EMUPATH_B "C:\\Emu\\AppAssets"
#define EMUPATH_F "C:/Emu/AppAssets"
install_hook_name(ASL_ToNativePath, void *, void *asl, char *in_str)
{
    char cwd[1025];
    get_cached_cwd(cwd, sizeof(cwd));
    size_t cwdlen = strlen(cwd);
    // an empty cwd would match every path and redirect all of them
    if (cwdlen == 0)
        return orig_ASL_ToNativePath(asl, in_str);

    char newpath[4096] = { 0 };
    char *in_filename = NULL;

    // check if the file being resolves is either in the game's Assets folder (the cwd)
    // or is C:/Emu/AppAssets, which is the assets folder again
    if (strncmp(cwd, in_str, cwdlen) == 0) {
        in_filename = in_str + cwdlen;
    } else if (strncmp(EMUPATH_B, in_str, strlen(EMUPATH_B)) == 0 ||
        strncmp(EMUPATH_F, in_str, strlen(EMUPATH_F)) == 0) {
        in_filename = in_str + strlen(EMUPATH_F);
    }
    // if it's in our cwd check if we have it in the BO3MacFix folder and redirect to read from there instead
    if (in_filename != NULL && strlen(in_filename) >= 2) {
        // check if it's an external mod or usermap, these need to go to / instead of /BO3MacFix/
        // not a perfect check but i'm not checking for every permutation and i want to check *before* path correction.
        // Only the part after the game folder is checked: a game installed under a
        // folder named "mods" would otherwise redirect every file.
        bool is_user_mod =
            strstr(in_filename, "/usermaps") != NULL || strstr(in_filename, "/mods") != NULL ||
            strstr(in_filename, "\\usermaps") != NULL || strstr(in_filename, "\\mods") != NULL;
        strncat(newpath, cwd, sizeof(newpath) - strlen(newpath) - 1);
        newpath[strlen(newpath)] = '/';
        if (is_user_mod)
            strncat(newpath, Basegame_Path, sizeof(newpath) - strlen(newpath) - 1);
        else
            strncat(newpath, Macfix_Path, sizeof(newpath) - strlen(newpath) - 1);
        newpath[strlen(newpath)] = '/';
        strncat(newpath, in_filename, sizeof(newpath) - strlen(newpath) - 1);
        // correct any backticks before checking if it exists
        for (int i = 0; i < strlen(newpath); i++)
            if (newpath[i] == '\\') newpath[i] = '/';
        // if the file exists redirect it, or if it's a mod
        if (is_user_mod || access(newpath, F_OK) == 0) {
#ifdef MACFIX_DEBUG
            // to avoid logspam only log files that exist
            if (access(newpath, F_OK) == 0)
                printf("redirecting %s to \"%s\"\n", in_filename, newpath);
#endif
            return orig_ASL_ToNativePath(asl, newpath);
        }
    }
    
    return orig_ASL_ToNativePath(asl, in_str);
}

// Workshop maps and mods show previewimage.png / loadingimage.png in the menus.
// The game decodes them with WIC and converts the frame to 32bpp BGR with
// WICConvertBitmapSource, but on the Mac that function is a stub that returns
// S_OK without setting its output, so the game calls through a NULL pointer
// and crashes when you hover over a workshop map. Decode the PNG with ImageIO
// instead and create the texture the way the game does: a B8G8R8X8 texture
// and a shader resource view, made through the game's D3D11 device. Return
// NULL on any failure, which makes the caller fall back to its default image.
typedef struct {
    uint32_t width, height, mip_levels, array_size, format;
    uint32_t sample_count, sample_quality, usage, bind_flags, cpu_access_flags, misc_flags;
} d3d11_texture2d_desc;
typedef struct {
    const void *sys_mem;
    uint32_t sys_mem_pitch, sys_mem_slice_pitch;
} d3d11_subresource_data;
typedef struct {
    uint32_t format, view_dimension;
    uint32_t most_detailed_mip, mip_levels;
    uint64_t unused;
} d3d11_srv_desc;
typedef int32_t (*d3d11_create_texture2d_t)(void *device, const d3d11_texture2d_desc *desc, const d3d11_subresource_data *data, void **texture);
typedef int32_t (*d3d11_create_srv_t)(void *device, void *resource, const d3d11_srv_desc *desc, void **srv);
typedef uint32_t (*com_release_t)(void *object);
typedef void (*workshop_texture_created_t)(void *srv, const d3d11_texture2d_desc *desc, int unused);

#define DXGI_FORMAT_B8G8R8X8_UNORM 88
#define D3D11_SRV_DIMENSION_TEXTURE2D 4
#define D3D11_BIND_SHADER_RESOURCE 8
#define WORKSHOP_TEXTURE_MAX_SIZE 4096

static void **workshop_texture_device;
static workshop_texture_created_t workshop_texture_created;

// The game builds these paths from its own folder, which can be the emulated
// C:/Emu/AppAssets or the working directory; resolve them the way
// ASL_ToNativePath does. Workshop items are already native Steam paths.
static void resolve_workshop_texture_path(const char *in, char *out, size_t out_len) {
    char cwd[1025];
    get_cached_cwd(cwd, sizeof(cwd));
    size_t cwdlen = strlen(cwd);
    const char *rest = NULL;
    if (cwdlen > 0 && strncmp(cwd, in, cwdlen) == 0)
        rest = in + cwdlen;
    else if (strncmp(EMUPATH_B, in, strlen(EMUPATH_B)) == 0 || strncmp(EMUPATH_F, in, strlen(EMUPATH_F)) == 0)
        rest = in + strlen(EMUPATH_F);
    if (rest != NULL && cwdlen > 0)
        snprintf(out, out_len, "%s/%s/%s", cwd, Basegame_Path, rest);
    else
        strlcpy(out, in, out_len);
    for (char *c = out; *c != '\0'; c++)
        if (*c == '\\') *c = '/';
}

// Returns a malloc'd BGRX pixel buffer, or NULL.
static uint8_t *decode_workshop_texture(const char *path, uint32_t *out_width, uint32_t *out_height) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    if (url == NULL)
        return NULL;
    CGImageSourceRef source = CGImageSourceCreateWithURL(url, NULL);
    CFRelease(url);
    if (source == NULL)
        return NULL;
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (image == NULL)
        return NULL;

    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    if (width == 0 || height == 0) {
        CGImageRelease(image);
        return NULL;
    }
    // keep absurd images from costing a lot of memory, scaling down if needed
    if (width > WORKSHOP_TEXTURE_MAX_SIZE || height > WORKSHOP_TEXTURE_MAX_SIZE) {
        double scale = (double)WORKSHOP_TEXTURE_MAX_SIZE / (width > height ? width : height);
        width = width * scale > 1 ? (size_t)(width * scale) : 1;
        height = height * scale > 1 ? (size_t)(height * scale) : 1;
    }

    uint8_t *pixels = calloc(width * height, 4);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    // B8G8R8X8 in memory: 32-bit little endian, alpha skipped, like WIC's 32bppBGR
    CGContextRef context = pixels && space ? CGBitmapContextCreate(pixels, width, height, 8, width * 4, space,
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little) : NULL;
    if (space != NULL)
        CGColorSpaceRelease(space);
    if (context == NULL) {
        free(pixels);
        CGImageRelease(image);
        return NULL;
    }
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    CGImageRelease(image);

    *out_width = (uint32_t)width;
    *out_height = (uint32_t)height;
    return pixels;
}

install_hook_name(load_workshop_texture, void *, const char *path) {
    if (workshop_texture_device == NULL || path == NULL)
        return NULL;

    char native_path[4096];
    resolve_workshop_texture_path(path, native_path, sizeof(native_path));
    uint32_t width, height;
    uint8_t *pixels = decode_workshop_texture(native_path, &width, &height);
    if (pixels == NULL)
        return NULL;

    void *device = *workshop_texture_device;
    if (device == NULL) {
        free(pixels);
        return NULL;
    }
    void **device_vtable = *(void ***)device;

    d3d11_texture2d_desc desc = {
        .width = width, .height = height, .mip_levels = 1, .array_size = 1,
        .format = DXGI_FORMAT_B8G8R8X8_UNORM, .sample_count = 1,
        .bind_flags = D3D11_BIND_SHADER_RESOURCE,
    };
    d3d11_subresource_data data = { pixels, width * 4, width * 4 * height };
    void *texture = NULL;
    int32_t hr = ((d3d11_create_texture2d_t)device_vtable[5])(device, &desc, &data, &texture);
    free(pixels);
    if (hr < 0 || texture == NULL)
        return NULL;

    d3d11_srv_desc srv_desc = {
        .format = DXGI_FORMAT_B8G8R8X8_UNORM, .view_dimension = D3D11_SRV_DIMENSION_TEXTURE2D,
        .most_detailed_mip = 0, .mip_levels = UINT32_MAX,
    };
    void *srv = NULL;
    hr = ((d3d11_create_srv_t)device_vtable[7])(device, texture, &srv_desc, &srv);
    if (hr < 0 || srv == NULL) {
        ((com_release_t)(*(void ***)texture)[2])(texture);
        return NULL;
    }
    workshop_texture_created(srv, &desc, 0);
    ((com_release_t)(*(void ***)texture)[2])(texture);
    return srv;
}

static void install_workshop_texture_fix(void) {
    // The hook always goes in, because the game's own loader crashes. Only
    // create textures on the build the device global and helper below come
    // from; anywhere else the hook returns NULL, as BO3MacFix always did.
    install_hook_load_workshop_texture((void *)(game_base_address + ADDR_load_workshop_texture));

    // the stub WICConvertBitmapSource: push rbp; mov rbp, rsp; xor eax, eax; pop rbp; ret
    static const uint8_t wic_convert_stub[] = { 0x55, 0x48, 0x89, 0xe5, 0x31, 0xc0, 0x5d, 0xc3 };
    // the loader's texture creation: lea r12, [device]; ... CreateTexture2D (vtable 0x28),
    // a B8G8R8X8 TEXTURE2D view (vtable 0x38), then call the helper with (srv, &desc, 0)
    static const uint8_t create_texture[] = {
        0x4c, 0x8d, 0x25, 0xd5, 0x66, 0x57, 0x10, 0x49, 0x8b, 0x3c, 0x24, 0x48,
        0x8b, 0x07, 0x4c, 0x8d, 0xbd, 0x68, 0xfb, 0xff, 0xff, 0x48, 0x89, 0xde,
        0x4c, 0x89, 0xf9, 0xff, 0x50, 0x28, 0x48, 0x8d, 0x95, 0x38, 0xfb, 0xff,
        0xff, 0x0f, 0x57, 0xc0, 0x0f, 0x11, 0x42, 0x08, 0x48, 0xb8, 0x58, 0x00,
        0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x48, 0x89, 0x02, 0xc7, 0x42, 0x0c,
        0xff, 0xff, 0xff, 0xff, 0x49, 0x8b, 0x3c, 0x24, 0x48, 0x8b, 0x07, 0x49,
        0x8b, 0x37, 0x4c, 0x8d, 0xa5, 0x70, 0xfb, 0xff, 0xff, 0x4c, 0x89, 0xe1,
        0xff, 0x50, 0x38, 0x49, 0x8b, 0x3c, 0x24, 0x31, 0xd2, 0x48, 0x89, 0xde,
        0xe8, 0x31, 0x36, 0x42, 0x00
    };
    if (memcmp((void *)(game_base_address + ADDR_WICConvertBitmapSource), wic_convert_stub, sizeof(wic_convert_stub)) != 0 ||
        memcmp((void *)(game_base_address + ADDR_load_workshop_texture_create), create_texture, sizeof(create_texture)) != 0) {
        printf("[BO3MacFix] unexpected game build, workshop preview images stay disabled\n");
        return;
    }
    workshop_texture_device = (void **)(game_base_address + ADDR_g_d3d11Device);
    workshop_texture_created = (workshop_texture_created_t)(game_base_address + ADDR_workshop_texture_created);
}

bool ISteamApps_BIsSubscribedApp(void *interface, AppId_t app) {
    return steam_dlc_owns(app);
}

bool ISteamApps_BIsDlcInstalled(void *interface, AppId_t app) {
    return steam_dlc_installed(app);
}

char playerNameBuffer[17] = {0};
void set_player_name(const char *name) {
    strncpy(playerNameBuffer, name, sizeof(playerNameBuffer) - 1);
    playerNameBuffer[sizeof(playerNameBuffer) - 1] = '\0';
}
const char *get_player_name() {
    return playerNameBuffer;
}

const char *ISteamFriends_GetPersonaName(void *interface) {
    // check the player name set dynamically first
    if (playerNameBuffer[0] != '\0' && strlen(playerNameBuffer) >= 1 && strlen(playerNameBuffer) <= 16)
        return playerNameBuffer;
    // then check the player name
    const char *envname = getenv("BO3MACFIX_PLAYERNAME");
    if (envname != NULL && strlen(envname) >= 1 && strlen(envname) <= 16)
        return envname;
    return steam_name();
}

install_hook_name(CSteamAPIContext_Init, bool, CSteamAPIContext *ctx) {
    if (offline_mode) {
        memcpy(ctx, steam_emu_get_context(), sizeof(CSteamAPIContext));
        return true;
    }
    bool r = orig_CSteamAPIContext_Init(ctx);
    if (r == true) {
        init_steam_context(ctx);
        // populate our caches
        steam_friends_refresh_cache();
        steam_dlc_refresh_cache();
        // replace ISteamApps DLC to use cached versions
        replace_vtable_entry(&(*ctx->m_pSteamApps)->BIsSubscribedApp, ISteamApps_BIsSubscribedApp);
        replace_vtable_entry(&(*ctx->m_pSteamApps)->BIsDlcInstalled, ISteamApps_BIsDlcInstalled);
        // replace ISteamFriends to do our username spoof
        replace_vtable_entry(&(*ctx->m_pSteamFriends)->GetPersonaName, ISteamFriends_GetPersonaName);
    }
    return r;
}

void lua_correct_path(const char *in_path, char *out_path, size_t out_path_len) {
    out_path[0] = '\0';
    strncat(out_path, Basegame_Path, out_path_len - strlen(out_path) - 1);
    strncat(out_path, in_path, out_path_len - strlen(out_path) - 1);
    for (int i = 0; i < strlen(out_path); i++)
        if (out_path[i] == '\\') out_path[i] = '/';
}

install_hook_name(hksf_fopen_internal, void *, char *filename, char *opentype, int unknown) {
    printf("Lua opening file '%s'\n", filename);
    char newpath[4096];
    lua_correct_path(filename, newpath, sizeof(newpath));
    printf("-> '%s'\n", newpath);
    return fopen(newpath, opentype);
}

static bool shown_dll_warning = false;
install_hook_name(hks_load_dll, bool, void *s, const char *filename, const char *func_name) {
    printf("Lua loadlib with '%s' (func: '%s')\n", filename, func_name);
    char newpath[4096];
    lua_correct_path(filename, newpath, sizeof(newpath));
    printf("-> '%s'\n", newpath);

    // so we can bundle support for workshop mods retroactively where the creator might not be able to / is unwilling to add a dylib
    // we check /BO3MacFix/natives/[dll name]-[dll hash].dylib
    // NOTE(Emma): might want to change to [dll name]-[workshop id].dylib for workshop mods to avoid updates breaking it if changes are insignificant enough
    char test_native_path[1024];
    uint8_t file_sha1_hash[0x14];
    char file_sha1_hash_str[(0x14 * 2) + 1];
    if (get_file_sha1(newpath, file_sha1_hash)) {
        if (bytes_to_hex(file_sha1_hash, sizeof(file_sha1_hash), file_sha1_hash_str, sizeof(file_sha1_hash_str))) {
            snprintf(test_native_path, sizeof(test_native_path), Macfix_Path "/natives/%s-%s.dylib", filename_from_path(newpath), file_sha1_hash_str);
            if (access(test_native_path, F_OK) == 0) {
                printf("--> %s\n", test_native_path);
                return orig_hks_load_dll(s, test_native_path, func_name);
            }
        }
    }

    // display an alert message (that makes sense) to the user informing them that the DLL load has failed
    if (!is_macos_dylib(newpath) && !shown_dll_warning) {
        printf("which isn't a macOS dylib, erroring...\n");
        char alert_msg[1024];
        snprintf(alert_msg, sizeof(alert_msg), "The mod you loaded tried to open a Windows DLL file. The game might work fine, but it might be unstable.\n\n%s: %s", filename_from_path(newpath), func_name);
        display_nsalert("BO3MacFix Mod Warning", alert_msg);
        // only show the warning once
        shown_dll_warning = true;
    }

    // TODO(Emma): we want to make sure the OS won't reject the dylib load because of Gatekeeper...

    return orig_hks_load_dll(s, newpath, func_name);
}

install_hook_name(CL_FirstSnapshot, void, void *arg) {
    bounce_dock_icon();
    return orig_CL_FirstSnapshot(arg);
}

install_hook_name(LiveSteam_RunEveryFrame, void, void) {
    if (offline_mode) return;
    orig_LiveSteam_RunEveryFrame();
}

install_hook_name(Com_GetBuildIntField, int, int field) {
    // if the field is this magic number ("Mac!"), return a version number
    if (field == 0x4D616321) {
        return 0x00000102; // 0x0102 for 1.2
    }
    return orig_Com_GetBuildIntField(field);
}

static int (*SDL_PrivateGameControllerAddMapping)(const char *mappingString, int priority);

// WIP(Emma): unfinished support for adding extra SDL controller mappings
static const char *extraGamepadMappings[] = {
    "030000004c050000a00b000000010000,PS4 Controller,a:b1,b:b2,back:b8,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b12,leftshoulder:b4,leftstick:b10,lefttrigger:a3,leftx:a0,lefty:a1,rightshoulder:b5,rightstick:b11,righttrigger:a4,rightx:a2,righty:a5,start:b9,x:b0,y:b3,",
    "030000004c050000c405000000000000,PS4 Controller,a:b1,b:b2,back:b8,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b12,leftshoulder:b4,leftstick:b10,lefttrigger:a3,leftx:a0,lefty:a1,rightshoulder:b5,rightstick:b11,righttrigger:a4,rightx:a2,righty:a5,start:b9,x:b0,y:b3,",
    "030000004c050000c405000000010000,PS4 Controller,a:b1,b:b2,back:b8,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b12,leftshoulder:b4,leftstick:b10,lefttrigger:a3,leftx:a0,lefty:a1,rightshoulder:b5,rightstick:b11,righttrigger:a4,rightx:a2,righty:a5,start:b9,x:b0,y:b3,",
    "030000004c050000cc09000000010000,PS4 Controller,a:b1,b:b2,back:b8,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b12,leftshoulder:b4,leftstick:b10,lefttrigger:a3,leftx:a0,lefty:a1,rightshoulder:b5,rightstick:b11,righttrigger:a4,rightx:a2,righty:a5,start:b9,x:b0,y:b3,",
    "050000004c050000e60c000000010000,PS5 Controller,a:b1,b:b2,back:b8,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b12,leftshoulder:b4,leftstick:b10,lefttrigger:a3,leftx:a0,lefty:a1,misc1:b13,rightshoulder:b5,rightstick:b11,righttrigger:a4,rightx:a2,righty:a5,start:b9,x:b0,y:b3,",
    "030000004c050000cc09000000000000,Sony DualShock 4 V2,a:b1,b:b2,back:b13,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b12,leftshoulder:b4,leftstick:b10,lefttrigger:a3,leftx:a0,lefty:a1,rightshoulder:b5,rightstick:b11,righttrigger:a4,rightx:a2,righty:a5,start:b9,x:b0,y:b3,",
    "030000004c050000a00b000000000000,Sony DualShock 4 Wireless Adaptor,a:b1,b:b2,back:b13,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b12,leftshoulder:b4,leftstick:b10,lefttrigger:a3,leftx:a0,lefty:a1,rightshoulder:b5,rightstick:b11,righttrigger:a4,rightx:a2,righty:a5,start:b9,x:b0,y:b3,",
    NULL
};
install_hook_name(SDL_GameControllerInitMappings, int, void)
{
    int r = orig_SDL_GameControllerInitMappings();
    int i = 0;
    const char *pMappingString = extraGamepadMappings[i];
    while (pMappingString) {
        SDL_PrivateGameControllerAddMapping(pMappingString, 0);
        i++;
        pMappingString = extraGamepadMappings[i];
    }
    return r;
}

// Entrypoint for the dylib
__attribute__((constructor)) static void dylib_main() {
    const char *image_path = _dyld_get_image_name(0);
    const char *image_name = filename_from_path(image_path);
    if (strcmp(image_name, "CoDBlkOps3_Exe") != 0)
        return;

    // get the base address of the binary
    game_base_address = get_base_address();

    // check for offline mode
    const char *offline_env = getenv("BO3MACFIX_OFFLINE");
    if (offline_env != NULL &&
        (strcasecmp(offline_env, "true") == 0 || strcasecmp(offline_env, "1") == 0)) {
        offline_mode = true;
        steam_emu_init();
        printf("[BO3MacFix] Running in offline mode — Steam not required\n");
    }

    // apply the hooks
    install_hook_HKAI_InitMapData((void *)(game_base_address + ADDR_HKAI_InitMapData));
    install_workshop_texture_fix();
    install_hook_Live_SystemInfo((void *)(game_base_address + ADDR_Live_SystemInfo));
    install_hook_someLoggingFunction((void *)(game_base_address + ADDR_someLoggingFunction));
    //install_hook_someWindowCreationFunction((void *)(game_base_address + ADDR_someWindowCreationFunction));
    install_hook_SDL_SetWindowTitle((void *)(game_base_address + ADDR_SDL_SetWindowTitle));
    install_hook_Sys_VerifyPacketChecksum((void *)(game_base_address + ADDR_Sys_VerifyPacketChecksum));
    install_hook_Sys_CheckSumPacketCopy((void *)(game_base_address + ADDR_Sys_CheckSumPacketCopy));
    install_hook_LobbyMsgRW_PrepReadMsg((void *)(game_base_address + ADDR_LobbyMsgRW_PrepReadMsg));
    install_hook_LobbyMsgRW_PrepWriteMsg((void *)(game_base_address + ADDR_LobbyMsgRW_PrepWriteMsg));
    install_hook_ASL_ToNativePath((void *)(game_base_address + ADDR_ASL_ToNativePath));
    install_hook_CSteamAPIContext_Init((void *)(game_base_address + ADDR_CSteamAPIContext_Init));
    install_hook_dwInstantDispatchMessage((void *)(game_base_address + ADDR_dwInstantMessageDispatch));
    install_hook_hks_load_dll((void *)(game_base_address + ADDR_hks_load_dll));
    install_hook_hksf_fopen_internal((void *)(game_base_address + ADDR_hksf_fopen_internal));
    install_hook_CL_FirstSnapshot((void *)(game_base_address + ADDR_CL_FirstSnapshot));
    install_hook_Com_GetBuildIntField((void *)(game_base_address + ADDR_Com_GetBuildIntField));
    install_hook_LiveSteam_RunEveryFrame((void *)(game_base_address + ADDR_LiveSteam_RunEveryFrame));
    install_stream_sort_fix();
    install_intro_skip();
    // MetalFX upscaling for the render resolution, and the LOD fix (metalfx.m)
    metalfx_init();
    //install_hook_SDL_GameControllerInitMappings((void *)(game_base_address + ADDR_SDL_GameControllerInitMappings));

    // set up functions that we later call
    build_usermods_path = (void *)(game_base_address + ADDR_build_usermods_path);
    DB_FindXAssetHeader = (void *)(game_base_address + ADDR_DB_FindXAssetHeader);
    Com_Error = (void *)(game_base_address + ADDR_Com_Error);
    Dvar_SetFromStringByName = (void *)(game_base_address + ADDR_Dvar_SetFromStringByName);
    Sys_Checksum = (void *)(game_base_address + ADDR_Sys_Checksum);
    MSG_ReadByte = (void *)(game_base_address + ADDR_MSG_ReadByte);
    MSG_WriteByte = (void *)(game_base_address + ADDR_MSG_WriteByte);
    SDL_PrivateGameControllerAddMapping = (void *)(game_base_address + ADDR_SDL_PrivateGameControllerAddMapping);

    // disable setting a fatal error in Scr_ErrorInternal, Aspyr forces it to always be true
    uint8_t error_patch[1] = { 0x00 };
    DobbyCodePatch((void *)(game_base_address + ADDR_Scr_ErrorInternalPatch + 4), error_patch, 1);

    // fix a crash bug
    uint8_t ret[1] = { 0xC3 };
    DobbyCodePatch((void *)(game_base_address + ADDR_Lua_CmdParseArgs), ret, sizeof(ret));

    // larp as v100 in the version number just to feel nice about yourself :3
    // probably not doing this until we're closer to v100
    //uint8_t larp[1] = { 100 };
    //DobbyCodePatch((void *)(game_base_address + ADDR_Live_SystemInfo_LarpInstr), larp, sizeof(larp));

    // set the network password rather than having it be 0 - should probably have a gui to set it
    const char *password_text = getenv("BO3MACFIX_NETWORKPASSWORD");
    if (password_text != NULL && strlen(password_text) >= 1) {
        set_network_password(password_text);
    } else {
        // some sort of safety net
    }

    // enable friends only if it's specified at env
    const char *friends_only_env = getenv("BO3MACFIX_FRIENDSONLY");
    if (friends_only_env != NULL &&
        (strcasecmp(friends_only_env, "true") == 0 || strcasecmp(friends_only_env, "1") == 0)) {
        friends_only = true;
    }
        
    // nop out where dw sets the Content-Length header, fixes a bug with modern macOS failing to log in online
    uint8_t curl_nops[(ADDR_Curl_ContentLengthSetEnd - ADDR_Curl_ContentLengthSetStart)];
    memset(curl_nops, 0x90, sizeof(curl_nops));
    DobbyCodePatch((void *)(game_base_address + ADDR_Curl_ContentLengthSetStart), curl_nops, sizeof(curl_nops));

    // replace the strcmp where HKAI_InitMapData checks to see if the map name is cp_mi_cairo_infection2
    uint8_t return_0[] = { 0xB8, 0, 0, 0, 0};
    DobbyCodePatch((void *)(game_base_address + ADDR_HKAI_InitMapData_DemonWithinCheck), return_0, sizeof(return_0));

    // patches the network version to match Windows
    network_version_patch();

    // pre-fetch the wine path so we don't need to search earlier
    get_wine_path();

    // i'll figure all that stuff out later :')
    //int sbr = sandbox_init_with_parameters("(version 1)(allow default)(debug allow)", 0, NULL, NULL);
    //printf("seatbelt init %i\n", sbr);
}
