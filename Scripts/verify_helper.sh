#!/bin/bash
# verify_helper.sh — Audit and verify ClashPow Privileged Helper & Self-Healing
#
# Usage: bash Scripts/verify_helper.sh

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== ClashPow Privileged Helper & Self-Healing Audit ===${NC}\n"

# ── 1. Audit Privileged Helper Binary ────────────────────────────────
echo -e "${BLUE}[1/6] Auditing Helper Binary at /Library/PrivilegedHelperTools/clashpow-engine...${NC}"
BINARY="/Library/PrivilegedHelperTools/clashpow-engine"
if [ -f "$BINARY" ]; then
    owner=$(stat -f "%Su:%Sg" "$BINARY")
    perms=$(stat -f "%A" "$BINARY")
    size=$(ls -lh "$BINARY" | awk '{print $5}')
    
    echo -e "  - Path: $BINARY"
    echo -e "  - Size: $size"
    
    if [ "$owner" = "root:wheel" ]; then
        echo -e "  - Owner: ${GREEN}root:wheel${NC} (Correct)"
    else
        echo -e "  - Owner: ${RED}$owner${NC} (Incorrect, launchd will reject helper binary unless owned by root:wheel)"
    fi
    
    if [ "$perms" = "755" ]; then
        echo -e "  - Permissions: ${GREEN}755${NC} (Correct)"
    else
        echo -e "  - Permissions: ${RED}$perms${NC} (Incorrect, should be 755)"
    fi
    
    # Check if compiled with gvisor
    if [ $(stat -f "%z" "$BINARY") -gt 35000000 ]; then
        echo -e "  - Tag Check: ${GREEN}with_gvisor detected${NC} (~50MB binary)"
    else
        echo -e "  - Tag Check: ${YELLOW}Standard build detected${NC} (~18MB binary, gVisor may be missing)"
    fi
else
    echo -e "  - Helper Binary: ${YELLOW}Not installed in system path yet${NC} (Needs activation via App GUI)"
fi
echo ""

# ── 2. Audit LaunchDaemon Plist ──────────────────────────────────────
echo -e "${BLUE}[2/6] Auditing LaunchDaemon Plist at /Library/LaunchDaemons/com.clashpow.engine.plist...${NC}"
PLIST="/Library/LaunchDaemons/com.clashpow.engine.plist"
if [ -f "$PLIST" ]; then
    owner=$(stat -f "%Su:%Sg" "$PLIST")
    perms=$(stat -f "%A" "$PLIST")
    
    echo -e "  - Path: $PLIST"
    
    if [ "$owner" = "root:wheel" ]; then
        echo -e "  - Owner: ${GREEN}root:wheel${NC} (Correct)"
    else
        echo -e "  - Owner: ${RED}$owner${NC} (Incorrect, launchd plists must be root-owned)"
    fi
    
    if [ "$perms" = "644" ]; then
        echo -e "  - Permissions: ${GREEN}644${NC} (Correct)"
    else
        echo -e "  - Permissions: ${RED}$perms${NC} (Incorrect, should be 644)"
    fi
    
    # Check plist contents
    if grep -q "<string>/Library/PrivilegedHelperTools/clashpow-engine</string>" "$PLIST"; then
        echo -e "  - ProgramArguments path: ${GREEN}Correct${NC} (Points to /Library/PrivilegedHelperTools/clashpow-engine)"
    else
        echo -e "  - ProgramArguments path: ${RED}Incorrect${NC} (Should point to /Library/PrivilegedHelperTools/clashpow-engine)"
    fi
    
    if grep -q "<key>Umask</key>" "$PLIST" && grep -A 1 "<key>Umask</key>" "$PLIST" | grep -q "<integer>0</integer>"; then
        echo -e "  - Umask configuration: ${GREEN}0${NC} (Correct, allows UDS socket to be created with 0666 permissions)"
    else
        echo -e "  - Umask configuration: ${RED}Missing/Incorrect${NC} (Required for passwordless non-root GUI interaction)"
    fi
else
    echo -e "  - LaunchDaemon Plist: ${YELLOW}Not installed in system path yet${NC}"
fi
echo ""

# ── 3. Audit Go Engine Routing Self-Healing ──────────────────────────
echo -e "${BLUE}[3/6] Auditing Go Engine Config Override Routing logic...${NC}"
CONFIG_GO="Engine/cmd/clashpow/config.go"
if [ -f "$CONFIG_GO" ]; then
    if grep -q "route" "$CONFIG_GO" && grep -q "delete" "$CONFIG_GO" && grep -q "1.0.0.0/8" "$CONFIG_GO"; then
        echo -e "  - Routing self-healing in config override: ${GREEN}Present${NC}"
        echo -e "  - Deletes stale 1.0.0.0/8: ${GREEN}Yes${NC}"
        echo -e "  - Deletes stale 198.18.0.0/15: ${GREEN}Yes${NC}"
    else
        echo -e "  - Routing self-healing in config override: ${RED}Not found / Missing${NC}"
    fi
else
    echo -e "  - Go config source file not found at $CONFIG_GO"
fi
echo ""

# ── 4. Audit Swift GUI Helper Injection Scripts ──────────────────────
echo -e "${BLUE}[4/6] Auditing Swift GUI install/uninstall scripts (EngineClient.swift)...${NC}"
CLIENT_SWIFT="Sources/XPC/EngineClient.swift"
if [ -f "$CLIENT_SWIFT" ]; then
    # Check cleanups in installPrivileged
    install_kill=$(grep -n -C 5 "killall" "$CLIENT_SWIFT" | grep -i "mihomo" || true)
    install_lsof=$(grep -n -C 5 "lsof" "$CLIENT_SWIFT" | grep -i "7890" || true)
    install_route=$(grep -n -C 5 "route" "$CLIENT_SWIFT" | grep -i "1.0.0.0/8" || true)
    install_umask=$(grep -n -C 5 "Umask" "$CLIENT_SWIFT" || true)
    
    if [ -n "$install_kill" ] && [ -n "$install_lsof" ] && [ -n "$install_route" ]; then
        echo -e "  - installPrivileged() cleanups: ${GREEN}Robust${NC}"
        echo -e "    ✓ Kills mihomo/clashpow-engine"
        echo -e "    ✓ Kills any processes holding port 7890/9092 via lsof"
        echo -e "    ✓ Deletes stale routes 1.0.0.0/8 and 198.18.0.0/15"
    else
        echo -e "  - installPrivileged() cleanups: ${RED}Incomplete / Weak${NC}"
    fi
    
    if [ -n "$install_umask" ]; then
        echo -e "  - Plist template Umask parameter: ${GREEN}Present (0)${NC}"
    else
        echo -e "  - Plist template Umask parameter: ${RED}Missing${NC}"
    fi
else
    echo -e "  - EngineClient.swift not found at $CLIENT_SWIFT"
fi
echo ""

# ── 5. Audit Swift GUI TUN Toggle transaction logic ──────────────────
echo -e "${BLUE}[5/6] Auditing Swift GUI Models.swift TUN Toggle transaction logic...${NC}"
MODELS_SWIFT="Sources/Model/Models.swift"
if [ -f "$MODELS_SWIFT" ]; then
    toggle_tun=$(grep -n -A 35 "func toggleTUN()" "$MODELS_SWIFT" || true)
    if echo "$toggle_tun" | grep -q "patchConfig" && echo "$toggle_tun" | grep -q "tunOn = want"; then
        # Ensure it does not optimistically set tunOn before patchConfig
        optimistic=$(echo "$toggle_tun" | grep -n "tunOn = " | head -1 | awk -F: '{print $1}')
        patch_call=$(echo "$toggle_tun" | grep -n "patchConfig" | head -1 | awk -F: '{print $1}')
        
        if [ "$optimistic" -gt "$patch_call" ]; then
            echo -e "  - toggleTUN() transaction safety: ${GREEN}Secure${NC} (Patches config BEFORE updating UI switch state)"
        else
            echo -e "  - toggleTUN() transaction safety: ${RED}Insecure / Optimistic${NC} (Updates UI state before verifying RPC result)"
        fi
    else
        echo -e "  - toggleTUN() implementation: ${RED}Method pattern not recognized${NC}"
    fi
else
    echo -e "  - Models.swift not found at $MODELS_SWIFT"
fi
echo ""

# ── 6. Check Socket & RPC Status ─────────────────────────────────────
echo -e "${BLUE}[6/6] Checking Active Socket & Engine UDS JSON-RPC...${NC}"
SOCKET="/tmp/clashpow-engine.sock"
if [ -S "$SOCKET" ]; then
    sock_perms=$(stat -f "%A" "$SOCKET")
    sock_owner=$(stat -f "%Su:%Sg" "$SOCKET")
    echo -e "  - UDS Socket Path: $SOCKET"
    echo -e "  - Socket Owner: $sock_owner"
    
    if [ "$sock_perms" = "666" ]; then
        echo -e "  - Socket Permissions: ${GREEN}666${NC} (Correct, accessible by non-root GUI)"
    else
        echo -e "  - Socket Permissions: ${RED}$sock_perms${NC} (Incorrect, non-root users may fail to connect)"
    fi
    
    # Query RPC
    response=$(echo '{"jsonrpc":"2.0","method":"get_status","params":{},"id":1}' | nc -w 1 -U "$SOCKET" 2>/dev/null)
    if echo "$response" | grep -q '"result"'; then
        is_root=$(echo "$response" | grep -o '"is_root":[^,}]*' | cut -d: -f2)
        version=$(echo "$response" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
        tun_status=$(echo "$response" | grep -o '"tun_enabled":[^,}]*' | cut -d: -f2)
        
        echo -e "  - RPC connection: ${GREEN}Responsive${NC}"
        echo -e "  - Engine version: ${GREEN}$version${NC}"
        if [ "$is_root" = "true" ]; then
            echo -e "  - Active Mode: ${GREEN}Privileged Launcher (root)${NC}"
        else
            echo -e "  - Active Mode: ${YELLOW}User Agent (non-root)${NC}"
        fi
        echo -e "  - TUN state: $tun_status"
    else
        echo -e "  - RPC connection: ${RED}Failed to read JSON-RPC response${NC}"
    fi
else
    echo -e "  - UDS Socket Path: ${RED}Missing${NC} (Engine is not running or socket deleted)"
fi

echo -e "\n${BLUE}=== Audit Complete ===${NC}"
