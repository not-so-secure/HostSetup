#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
#  Red Team / Pentest Environment Setup
#  Target: Ubuntu / Debian amd64 / arm64
#  Usage:  sudo bash AllInOne.sh [OPTIONS]
#
#  Options:
#    --force           Reinstall already-installed tools
#    --only=a,b,...    Run only these sections (comma-separated)
#    --skip=a,b,...    Skip these sections
#    --help            Show usage
#
#  Section names:
#    apt go ohmyzsh gotools redtools pdtools python node
#    rustscan docker metasploit sliver seclists path
# ─────────────────────────────────────────────

# ── Global paths ──────────────────────────────
WORK_DIR=/opt/work
BIN=$WORK_DIR/bin
DATA=$WORK_DIR/data
PROXY=$WORK_DIR/proxy
LOG=$WORK_DIR/setup.log
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
GOBIN_DIR="$HOME/go/bin"

# ── Parse arguments ───────────────────────────
FORCE=false
ONLY=""
SKIP_TOOLS=""

usage() {
    cat <<EOF
Usage: bash AllInOne.sh [OPTIONS]

Options:
  --force           Reinstall already-installed tools
  --only=a,b,...    Run only these sections (comma-separated)
  --skip=a,b,...    Skip these sections
  --help            Show this help

Section names:
  apt go ohmyzsh gotools redtools pdtools python node
  rustscan docker metasploit sliver seclists path

Heavy tools (prompted interactively unless piped):
  metasploit (~500 MB), sliver (~200 MB), seclists (~1 GB), docker
EOF
}

for arg in "$@"; do
    case "$arg" in
        --force)    FORCE=true ;;
        --only=*)   ONLY="${arg#--only=}" ;;
        --skip=*)   SKIP_TOOLS="${arg#--skip=}" ;;
        --help|-h)  usage; exit 0 ;;
        *)          echo "Unknown argument: $arg" >&2; usage; exit 1 ;;
    esac
done

# ── Sudo wrapper (empty if already root) ──────
SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

# ── Shell / rc-file detection ─────────────────
RC_FILE="$HOME/.bashrc"
if [[ "${SHELL:-}" == */zsh ]] || ( command -v zsh &>/dev/null && [[ -f "$HOME/.zshrc" ]] ); then
    RC_FILE="$HOME/.zshrc"
fi

# ── Heavy-tool install flags (defaults) ───────
INSTALL_METASPLOIT=true
INSTALL_SLIVER=true
INSTALL_SECLISTS=true
INSTALL_DOCKER=true

# ── Logging ───────────────────────────────────
mkdir -p "$WORK_DIR"
# Terminal gets color; log file gets ANSI stripped
exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG")) 2>&1

RED='\033[0;31]'; GREEN='\033[0;32]'; YELLOW='\033[1;33]'; CYAN='\033[0;36]'; BOLD='\033[1m'; NC='\033[0m'
PASS=(); SKIP=(); FAIL=()

info()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*" >&2; }
section() { echo -e "\n${CYAN}${BOLD}══════════════════════════════════════${NC}\n${CYAN}${BOLD}  $*${NC}\n${CYAN}${BOLD}══════════════════════════════════════${NC}"; }

mark_pass() { PASS+=("$1"); info "$1  ✓"; }
mark_skip() { SKIP+=("$1"); warn "$1  — already installed, skipping"; }
mark_fail() { FAIL+=("$1"); error "$1  ✗  (check $LOG for details)"; }

# Binary exists in $BIN and --force not set
bin_installed() { [[ -f "$BIN/$1" ]] && [[ "$FORCE" == false ]]; }
# Command exists anywhere in PATH and --force not set
cmd_installed() { command -v "$1" &>/dev/null && [[ "$FORCE" == false ]]; }

# ── Lockfile (non-fatal if flock unavailable) ─
LOCKFILE=/tmp/autosetup.lock
if command -v flock &>/dev/null; then
    exec 9>"$LOCKFILE"
    flock -n 9 || { error "Another instance already running ($LOCKFILE). Aborting."; exit 1; }
fi

# ERR trap — prints location of unexpected failure
trap 'error "Unexpected error at line $LINENO in $BASH_SOURCE"' ERR

# ── Section filter ────────────────────────────
should_run() {
    local name=$1
    if [[ -n "$ONLY" ]]; then
        echo ",$ONLY," | grep -q ",$name," || return 1
    fi
    if [[ -n "$SKIP_TOOLS" ]]; then
        echo ",$SKIP_TOOLS," | grep -q ",$name," && return 1
    fi
    return 0
}

# ─────────────────────────────────────────────
#  GITHUB API WITH RATE-LIMIT RETRY
# ─────────────────────────────────────────────
github_api() {
    local url=$1
    local wait=60
    local i
    for i in 1 2 3 4 5; do
        local resp
        resp=$(curl -fsSL "$url") || { error "curl failed: $url"; return 1; }
        if echo "$resp" | jq -e '.message' 2>/dev/null | grep -qi "rate limit"; then
            warn "GitHub API rate limited — waiting ${wait}s (attempt $i/5)"
            sleep "$wait"
            wait=$(( wait * 2 ))
            continue
        fi
        echo "$resp"
        return 0
    done
    error "GitHub API still rate limited after 5 attempts: $url"
    return 1
}

# ─────────────────────────────────────────────
#  PRE-FLIGHT
# ─────────────────────────────────────────────
preflightChecks() {
    section "Pre-flight checks"

    [[ $EUID -eq 0 ]] || command -v sudo &>/dev/null \
        || { error "Not root and no sudo found. Aborting."; exit 1; }
    info "Privilege check OK"

    curl -fsSL --max-time 8 https://github.com > /dev/null 2>&1 \
        || { error "Cannot reach github.com. Check network. Aborting."; exit 1; }
    info "Network OK"

    local free_kb; free_kb=$(df /opt --output=avail | tail -1 | tr -d ' ')
    (( free_kb < 10485760 )) \
        && { error "Less than 10 GB free on /opt (${free_kb} KB available). Aborting."; exit 1; }
    info "Disk space OK  ($(( free_kb / 1024 / 1024 )) GB free on /opt)"

    local missing=()
    for cmd in curl wget jq git unzip tar gzip flock; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        warn "Installing missing base tools: ${missing[*]}"
        $SUDO apt-get update -y -qq
        $SUDO apt-get install -y -qq "${missing[@]}"
    fi
    info "Base tools OK"
}

# ─────────────────────────────────────────────
#  HEAVY-TOOL SELECTION MENU
# ─────────────────────────────────────────────
selectHeavyTools() {
    # Skip menu in non-interactive or when --only limits scope
    [[ ! -t 0 ]] && return
    [[ -n "$ONLY" ]] && return

    echo ""
    echo -e "${BOLD}Select heavy components to install:${NC}  (Enter = yes,  n = skip)"
    local r
    read -rp "  [?] Metasploit Framework  (~500 MB) ? [Y/n] " r; [[ "$r" =~ ^[Nn] ]] && INSTALL_METASPLOIT=false
    read -rp "  [?] Sliver C2             (~200 MB) ? [Y/n] " r; [[ "$r" =~ ^[Nn] ]] && INSTALL_SLIVER=false
    read -rp "  [?] SecLists wordlists    (~1  GB)  ? [Y/n] " r; [[ "$r" =~ ^[Nn] ]] && INSTALL_SECLISTS=false
    read -rp "  [?] Docker + Compose               ? [Y/n] " r; [[ "$r" =~ ^[Nn] ]] && INSTALL_DOCKER=false
    echo ""
}

# ─────────────────────────────────────────────
#  DOWNLOAD HELPERS
# ─────────────────────────────────────────────

# Internal: fetch and install one binary — no skip check, returns 1 on any failure
_fetch_bin() {
    local repo=$1 pattern=$2 bin_name=$3 inner_path=${4:-""}
    local dest="$BIN/$bin_name"

    info "[$repo]  fetching latest  →  $bin_name"

    local url
    url=$(github_api "https://api.github.com/repos/$repo/releases/latest" \
          | jq -r '.assets[].browser_download_url' \
          | grep -E "$pattern" | head -1) || return 1

    if [[ -z "$url" ]]; then
        warn "No asset matched pattern '$pattern' in $repo"
        return 1
    fi

    local tmp; tmp=$(mktemp -d)
    local archive="$tmp/download"

    wget -q --show-progress -O "$archive" "$url" || { rm -rf "$tmp"; return 1; }

    case "$url" in
        *.tar.gz|*.tgz)
            tar -xzf "$archive" -C "$tmp" || { rm -rf "$tmp"; return 1; }
            if [[ -n "$inner_path" ]]; then
                local resolved; resolved=$(ls "$tmp"/$inner_path 2>/dev/null | head -1)
                [[ -z "$resolved" ]] && { warn "Path '$inner_path' not found in archive"; rm -rf "$tmp"; return 1; }
                install -m 755 "$resolved" "$dest" || { rm -rf "$tmp"; return 1; }
            else
                local found; found=$(find "$tmp" -maxdepth 4 -type f -name "$bin_name" | head -1)
                [[ -z "$found" ]] && { warn "Binary '$bin_name' not found in archive"; rm -rf "$tmp"; return 1; }
                install -m 755 "$found" "$dest" || { rm -rf "$tmp"; return 1; }
            fi
            ;;
        *.zip)
            unzip -q "$archive" -d "$tmp" || { rm -rf "$tmp"; return 1; }
            if [[ -n "$inner_path" ]]; then
                local resolved; resolved=$(ls "$tmp"/$inner_path 2>/dev/null | head -1)
                [[ -z "$resolved" ]] && { warn "Path '$inner_path' not found in archive"; rm -rf "$tmp"; return 1; }
                install -m 755 "$resolved" "$dest" || { rm -rf "$tmp"; return 1; }
            else
                local found; found=$(find "$tmp" -maxdepth 4 -type f -name "$bin_name" | head -1)
                [[ -z "$found" ]] && { warn "Binary '$bin_name' not found in archive"; rm -rf "$tmp"; return 1; }
                install -m 755 "$found" "$dest" || { rm -rf "$tmp"; return 1; }
            fi
            ;;
        *.gz)
            gzip -d -c "$archive" > "$dest" || { rm -rf "$tmp"; return 1; }
            chmod 755 "$dest"
            ;;
        *)
            install -m 755 "$archive" "$dest" || { rm -rf "$tmp"; return 1; }
            ;;
    esac

    rm -rf "$tmp"
    return 0
}

# Public: download with skip check — always returns 0 so callers never die on failure
download_from_git() {
    local repo=$1 pattern=$2 bin_name=$3 inner_path=${4:-""}

    bin_installed "$bin_name" && { mark_skip "$bin_name"; return 0; }

    if _fetch_bin "$repo" "$pattern" "$bin_name" "$inner_path"; then
        mark_pass "$bin_name"
    else
        mark_fail "$bin_name"
    fi
    return 0
}

# Store a Windows drop file — skip if exists and --force not set
store_windows_drop() {
    local repo=$1 pattern=$2 dest=$3
    if [[ -f "$dest" ]] && [[ "$FORCE" == false ]]; then
        info "Windows drop exists: $(basename "$dest") (skip)"
        return 0
    fi
    local url
    url=$(github_api "https://api.github.com/repos/$repo/releases/latest" \
          | jq -r '.assets[].browser_download_url' \
          | grep -E "$pattern" | head -1) || return 0
    [[ -z "$url" ]] && { warn "No Windows drop matched '$pattern' in $repo"; return 0; }
    wget -q --show-progress -O "$dest" "$url" \
        && info "Stored Windows drop: $(basename "$dest")" \
        || warn "Failed to store Windows drop: $(basename "$dest")"
    return 0
}

# ─────────────────────────────────────────────
#  SECTION: APT PACKAGES
# ─────────────────────────────────────────────
installAptBasic() {
    # Sentinel: presence of all marker packages means apt section already ran
    if dpkg -l nmap hashcat strace zsh &>/dev/null 2>&1 \
       && [[ "$FORCE" == false ]]; then
        mark_skip "apt-packages"
        return
    fi

    info "Updating package lists..."
    $SUDO apt-get update -y --fix-missing

    info "Installing core utilities..."
    $SUDO apt-get install -y \
        build-essential git curl wget jq unzip tar gzip \
        p7zip-full util-linux || warn "Some core utilities failed to install"

    info "Installing network tools..."
    $SUDO apt-get install -y \
        nmap masscan tcpdump socat \
        netcat-traditional dnsutils whois net-tools || warn "Some network tools failed to install"

    info "Installing web / fuzzing tools..."
    $SUDO apt-get install -y \
        sqlmap nikto wfuzz dirb || warn "Some web tools failed to install"

    info "Installing password / credential tools..."
    $SUDO apt-get install -y \
        hashcat john hydra || warn "Some credential tools failed to install"

    info "Installing debug / analysis tools..."
    $SUDO apt-get install -y \
        ltrace strace gdb binutils || warn "Some debug tools failed to install"

    info "Installing language runtimes and build deps..."
    $SUDO apt-get install -y \
        python3 python3-pip python3-venv pipx \
        ruby-full \
        libpcap-dev libssl-dev libffi-dev || warn "Some runtime deps failed to install"

    info "Installing shell / terminal tools..."
    $SUDO apt-get install -y \
        zsh tmux byobu || warn "Some shell tools failed to install"

    info "Installing Node.js..."
    if ! command -v node &>/dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_lts.x | $SUDO bash -
        $SUDO apt-get install -y nodejs
    fi

    # Make pipx tools available immediately in this session
    export PATH="$HOME/.local/bin:$PATH"

    mark_pass "apt-packages"
}

# ─────────────────────────────────────────────
#  SECTION: GO RUNTIME
# ─────────────────────────────────────────────
installGo() {
    cmd_installed go && { mark_skip "go"; return; }

    info "Fetching latest Go version..."
    local ver; ver=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -1)
    info "Installing $ver (${ARCH})..."
    wget -q --show-progress "https://go.dev/dl/${ver}.linux-${ARCH}.tar.gz" -O /tmp/go.tar.gz
    $SUDO rm -rf /usr/local/go
    $SUDO tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz

    echo 'export PATH=/usr/local/go/bin:$HOME/go/bin:$PATH' \
        | $SUDO tee /etc/profile.d/go.sh > /dev/null
    export PATH=/usr/local/go/bin:$HOME/go/bin:$PATH
    export GOBIN="$GOBIN_DIR"

    mark_pass "go ($ver)"
}

# ─────────────────────────────────────────────
#  SECTION: GO TOOLS (via go install)
# ─────────────────────────────────────────────
installGoTools() {
    if ! command -v go &>/dev/null; then
        warn "Go not in PATH — skipping Go tools"
        return
    fi

    export GOBIN="$GOBIN_DIR"
    mkdir -p "$GOBIN_DIR"

    # Format: "binary_name:module_path@version"
    local tools=(
        # ── Fuzzing / web ────────────────────────
        "ffuf:github.com/ffuf/ffuf/v2@latest"
        "gobuster:github.com/OJ/gobuster/v3@latest"
        "gospider:github.com/jaeles-project/gospider@latest"
        "gowitness:github.com/sensepost/gowitness@latest"
        "getJS:github.com/003random/getJS@latest"
        # ── Vuln scanning ────────────────────────
        "afrog:github.com/zan8in/afrog/v2/cmd/afrog@latest"
        # ── Subdomain / DNS ──────────────────────
        "assetfinder:github.com/tomnomnom/assetfinder@latest"
        "httprobe:github.com/tomnomnom/httprobe@latest"
        "github-subdomains:github.com/gwen001/github-subdomains@latest"
        "github-endpoints:github.com/gwen001/github-endpoints@latest"
        # ── CIDR / IP ────────────────────────────
        "mapcidr:github.com/projectdiscovery/mapcidr/cmd/mapcidr@latest"
        # ── Secrets / code ───────────────────────
        "gitleaks:github.com/gitleaks/gitleaks/v8@latest"
        "gitdorks_go:github.com/damit5/gitdorks_go@latest"
        # ── Workflow utilities ───────────────────
        "waybackurls:github.com/tomnomnom/waybackurls@latest"
        "gf:github.com/tomnomnom/gf@latest"
        "anew:github.com/tomnomnom/anew@latest"
        "hakrawler:github.com/hakluke/hakrawler@latest"
        "fzf:github.com/junegunn/fzf@latest"
        "rush:github.com/shenwei356/rush@latest"
        "csvtk:github.com/shenwei356/csvtk/v2@latest"
        "eget:github.com/zyedidia/eget@latest"
        "sgn:github.com/EgeBalci/sgn@latest"
    )

    for entry in "${tools[@]}"; do
        local bin_name="${entry%%:*}"
        local pkg="${entry##*:}"
        if cmd_installed "$bin_name"; then
            mark_skip "$bin_name"
        else
            info "go install $pkg"
            go install "$pkg" \
                && mark_pass "$bin_name" \
                || mark_fail "$bin_name"
        fi
    done
}

# ─────────────────────────────────────────────
#  SECTION: OH-MY-ZSH (unattended)
# ─────────────────────────────────────────────
installOhmyzsh() {
    if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
        info "Installing oh-my-zsh (unattended)..."
        RUNZSH=no CHSH=no \
            sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    else
        info "oh-my-zsh already present"
    fi

    $SUDO chsh -s "$(command -v zsh)" "$USER" 2>/dev/null || true

    local pd="$HOME/.oh-my-zsh/custom/plugins"
    [[ -d "$pd/zsh-syntax-highlighting" ]] \
        || git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting "$pd/zsh-syntax-highlighting"
    [[ -d "$pd/zsh-autosuggestions" ]] \
        || git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions "$pd/zsh-autosuggestions"

    local zshrc="$HOME/.zshrc"
    if [[ -f "$zshrc" ]] && grep -q 'plugins=(git)' "$zshrc"; then
        sed -i 's/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/' "$zshrc"
    fi

    RC_FILE="$HOME/.zshrc"
    mark_pass "oh-my-zsh"
}

# ─────────────────────────────────────────────
#  SECTION: RED TEAM BINARIES (via download_from_git)
# ─────────────────────────────────────────────
installRedTools() {
    mkdir -p "$BIN" "$PROXY"

    # ── Recon / enumeration ──────────────────
    download_from_git "projectdiscovery/pdtm" \
        "linux_${ARCH}\.zip$"                       pdtm

    download_from_git "zu1k/nali" \
        "linux-${ARCH}.*\.gz$"                      nali

    download_from_git "ropnop/kerbrute" \
        "linux_${ARCH}$"                            kerbrute

    # ── Tunneling / pivoting ─────────────────
    download_from_git "fatedier/frp" \
        "linux_${ARCH}\.tar\.gz$"                   frpc    "frp_*/frpc"

    download_from_git "fatedier/frp" \
        "linux_${ARCH}\.tar\.gz$"                   frps    "frp_*/frps"

    download_from_git "jpillora/chisel" \
        "linux_${ARCH}\.gz$"                        chisel

    download_from_git "nicocha30/ligolo-ng" \
        "proxy_.*linux_${ARCH}\.tar\.gz$"           ligolo-proxy

    download_from_git "nicocha30/ligolo-ng" \
        "agent_.*linux_${ARCH}\.tar\.gz$"           ligolo-agent

    # ── Scanning / fingerprinting ────────────
    # findomain: amd64 has no arch suffix; arm64 uses 'aarch64'
    local _findomain_pat="findomain-linux$"
    [[ "$ARCH" == "arm64" ]] && _findomain_pat="findomain-linux-aarch64$"
    download_from_git "Findomain/Findomain"    "$_findomain_pat"           findomain

    download_from_git "shadow1ng/fscan"        "fscan_${ARCH}$"            fscan
    download_from_git "lcvvvv/kscan"           "linux_${ARCH}.*\.zip$"     kscan
    download_from_git "boy-hack/ksubdomain"    "linux_${ARCH}.*\.tar\.gz$" ksubdomain
    download_from_git "EdgeSecurityTeam/EHole" "linux_${ARCH}.*\.tar\.gz$" EHole

    # ── Tunneling ────────────────────────────
    download_from_git "ngrok/ngrok"            "linux-${ARCH}\.tgz$"       ngrok

    # ── Recon utility ────────────────────────
    download_from_git "4ra1n/MoreFind"         "linux.*${ARCH}.*\.tar\.gz$" MoreFind

    # ── Windows drops (kept in proxy/ for target delivery) ───
    info "Storing Windows agent drops in $PROXY ..."
    store_windows_drop "fatedier/frp"        "windows_amd64\.zip$"               "$PROXY/frp_windows.zip"
    store_windows_drop "jpillora/chisel"     "windows_amd64\.gz$"                "$PROXY/chisel_windows.gz"
    store_windows_drop "nicocha30/ligolo-ng" "agent_.*windows_amd64\.zip$"       "$PROXY/ligolo_agent_windows.zip"
}

# ─────────────────────────────────────────────
#  SECTION: PROJECTDISCOVERY SUITE (via pdtm)
# ─────────────────────────────────────────────
installPDTools() {
    export PATH="$BIN:$PATH"
    if cmd_installed nuclei; then
        mark_skip "pd-suite"
        return
    fi
    info "Installing ProjectDiscovery suite via pdtm..."
    pdtm -install-all -silent \
        && mark_pass "pd-suite (nuclei httpx subfinder naabu dnsx katana interactsh-client)" \
        || mark_fail "pd-suite"
}

# ─────────────────────────────────────────────
#  SECTION: PYTHON TOOLS (via pipx)
# ─────────────────────────────────────────────
installPythonTools() {
    export PATH="$HOME/.local/bin:$PATH"
    pipx ensurepath 2>/dev/null || true

    for pkg in impacket bloodhound netexec pwntools; do
        if pipx list 2>/dev/null | grep -q "$pkg" && [[ "$FORCE" == false ]]; then
            mark_skip "$pkg"
        else
            info "pipx install $pkg"
            pipx install "$pkg" --force 2>/dev/null \
                && mark_pass "$pkg" \
                || mark_fail "$pkg"
        fi
    done
}

# ─────────────────────────────────────────────
#  SECTION: NODE.JS GLOBAL TOOLS
# ─────────────────────────────────────────────
installNodeTools() {
    if cmd_installed js-beautify; then
        mark_skip "node-global-tools"
        return
    fi
    info "Installing Node.js global tools..."
    npm install -g js-beautify retire uglify-js 2>/dev/null \
        && mark_pass "node-global-tools" \
        || mark_fail "node-global-tools"
}

# ─────────────────────────────────────────────
#  SECTION: RUSTSCAN
# ─────────────────────────────────────────────
installRustScan() {
    cmd_installed rustscan && { mark_skip "rustscan"; return; }

    local tmp; tmp=$(mktemp)
    local url
    url=$(github_api "https://api.github.com/repos/RustScan/RustScan/releases/latest" \
          | jq -r '.assets[].browser_download_url' \
          | grep -E "${ARCH}\.deb$" | head -1) || { mark_fail "rustscan"; return; }

    if [[ -z "$url" ]]; then
        mark_fail "rustscan"; warn "Could not find rustscan .deb for ${ARCH}"; return
    fi

    wget -q --show-progress -O "$tmp" "$url" \
        && $SUDO dpkg -i "$tmp" \
        && rm "$tmp" \
        && mark_pass "rustscan" \
        || { mark_fail "rustscan"; rm -f "$tmp"; }
}

# ─────────────────────────────────────────────
#  SECTION: DOCKER + COMPOSE (heavy, optional)
# ─────────────────────────────────────────────
installDocker() {
    [[ "$INSTALL_DOCKER" == false ]] && { info "Docker skipped by user"; return; }
    cmd_installed docker && { mark_skip "docker"; return; }

    info "Installing Docker via get.docker.com..."
    curl -fsSL https://get.docker.com | $SUDO sh
    $SUDO systemctl enable --now docker 2>/dev/null || true
    mark_pass "docker"
}

# ─────────────────────────────────────────────
#  SECTION: METASPLOIT (heavy, optional, retry)
# ─────────────────────────────────────────────
installMetasploit() {
    [[ "$INSTALL_METASPLOIT" == false ]] && { info "Metasploit skipped by user"; return; }
    cmd_installed msfconsole && { mark_skip "metasploit"; return; }

    local attempts=3
    for i in $(seq 1 $attempts); do
        info "Metasploit install — attempt $i / $attempts"
        if curl -fsSL https://apt.metasploit.com/setup | $SUDO bash \
           && $SUDO apt-get install -y metasploit-framework; then
            mark_pass "metasploit"
            return
        fi
        warn "Attempt $i failed — retrying in 15 s..."
        sleep 15
    done
    mark_fail "metasploit"
}

# ─────────────────────────────────────────────
#  SECTION: SLIVER C2 (heavy, optional, retry)
# ─────────────────────────────────────────────
installSliver() {
    [[ "$INSTALL_SLIVER" == false ]] && { info "Sliver skipped by user"; return; }
    bin_installed sliver-server && { mark_skip "sliver"; return; }

    local attempts=3
    for i in $(seq 1 $attempts); do
        info "Sliver install — attempt $i / $attempts"
        # Remove partial downloads so each attempt is clean
        rm -f "$BIN/sliver-server" "$BIN/sliver-client"
        if _fetch_bin "BishopFox/sliver" "sliver-server_linux$" sliver-server \
        && _fetch_bin "BishopFox/sliver" "sliver-client_linux$" sliver-client; then
            "$BIN/sliver-server" unpack --force 2>/dev/null || true
            mark_pass "sliver"
            return
        fi
        warn "Attempt $i failed — retrying in 15 s..."
        sleep 15
    done
    mark_fail "sliver"
}

# ─────────────────────────────────────────────
#  SECTION: SECLISTS (heavy, optional)
# ─────────────────────────────────────────────
installWordlists() {
    [[ "$INSTALL_SECLISTS" == false ]] && { info "SecLists skipped by user"; return; }

    if [[ -d "$DATA/SecLists" ]] && [[ "$FORCE" == false ]]; then
        mark_skip "SecLists"
        return
    fi

    mkdir -p "$DATA"
    info "Cloning SecLists (~1 GB, this will take a while)..."
    git clone --depth=1 https://github.com/danielmiessler/SecLists "$DATA/SecLists"
    ln -sf "$DATA/SecLists" "$HOME/wordlists"
    mark_pass "SecLists"
}

# ─────────────────────────────────────────────
#  SECTION: PATH SETUP (idempotent)
# ─────────────────────────────────────────────
setupPath() {
    # Detect all existing rc files at runtime — handles the case where zsh
    # was just installed by this script (RC_FILE at top was still .bashrc)
    local rc_files=()
    [[ -f "$HOME/.bashrc" ]] && rc_files+=("$HOME/.bashrc")
    [[ -f "$HOME/.zshrc"  ]] && rc_files+=("$HOME/.zshrc")
    [[ ${#rc_files[@]} -eq 0 ]] && rc_files+=("$HOME/.bashrc")  # bare fallback

    for rc in "${rc_files[@]}"; do
        grep -q '/opt/work/bin'     "$rc" 2>/dev/null \
            || echo "export PATH=/opt/work/bin:\$HOME/go/bin:\$PATH" >> "$rc"
        grep -q '\.local/bin'       "$rc" 2>/dev/null \
            || echo 'export PATH=$HOME/.local/bin:$PATH'             >> "$rc"
        grep -q '/usr/local/go/bin' "$rc" 2>/dev/null \
            || echo 'export PATH=/usr/local/go/bin:$PATH'            >> "$rc"
        info "PATH configured in $rc"
    done

    # Point RC_FILE at zsh config for the summary message if it exists
    [[ -f "$HOME/.zshrc" ]] && RC_FILE="$HOME/.zshrc"
}

# ─────────────────────────────────────────────
#  FINAL SUMMARY
# ─────────────────────────────────────────────
printSummary() {
    section "Setup complete"
    info "Full log: $LOG"
    echo ""
    echo -e "${GREEN}${BOLD}Installed  (${#PASS[@]}):${NC}  ${PASS[*]:-none}"
    echo -e "${YELLOW}${BOLD}Skipped   (${#SKIP[@]}):${NC}  ${SKIP[*]:-none}"
    echo -e "${RED}${BOLD}Failed    (${#FAIL[@]}):${NC}  ${FAIL[*]:-none}"
    echo ""
    echo -e "${CYAN}Action required:${NC}  source $RC_FILE  (or open a new shell)"
    if (( ${#FAIL[@]} > 0 )); then
        echo -e "${YELLOW}Re-run failed tools with:${NC}  bash $0 --force"
    fi
}

# ─────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────
main() {
    preflightChecks
    selectHeavyTools

    should_run "apt"        && { section "APT packages";           installAptBasic;    }
    should_run "go"         && { section "Go runtime";             installGo;          }
    should_run "ohmyzsh"    && { section "Oh-My-Zsh";              installOhmyzsh;     }
    should_run "gotools"    && { section "Go tools";               installGoTools;     }
    should_run "redtools"   && { section "Red team binaries";      installRedTools;    }
    should_run "pdtools"    && { section "ProjectDiscovery suite"; installPDTools;     }
    should_run "python"     && { section "Python tools (pipx)";    installPythonTools; }
    should_run "node"       && { section "Node.js global tools";   installNodeTools;   }
    should_run "rustscan"   && { section "RustScan";               installRustScan;    }
    should_run "docker"     && { section "Docker";                 installDocker;      }
    should_run "metasploit" && { section "Metasploit";             installMetasploit;  }
    should_run "sliver"     && { section "Sliver C2";              installSliver;      }
    should_run "seclists"   && { section "SecLists wordlists";     installWordlists;   }
    should_run "path"       && { section "PATH setup";             setupPath;          }

    printSummary
}

main "$@"
