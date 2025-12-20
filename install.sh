#!/usr/bin/env bash
#######################################
# System Health Monitor - Installation Script
# Automates installation and setup
#
# Usage: curl -fsSL https://raw.githubusercontent.com/calounx/pmanalysis/master/install.sh | bash
#######################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
readonly REPO_URL="https://github.com/calounx/pmanalysis.git"
readonly INSTALL_DIR="/opt/pmanalysis"
readonly BIN_DIR="/usr/local/bin"
readonly SCRIPT_NAME="health-check.sh"

#######################################
# Logging functions
#######################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

#######################################
# Check if running as root
#######################################

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo"
        exit 1
    fi
}

#######################################
# Detect OS and version
#######################################

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        log_error "Cannot detect OS. /etc/os-release not found."
        exit 1
    fi

    log_info "Detected OS: $OS $VERSION"

    # Check for supported OS
    if [[ "$OS" != "debian" && "$OS" != "ubuntu" ]]; then
        log_warning "This script is designed for Debian/Ubuntu. Your OS ($OS) may not be fully supported."
        read -p "Do you want to continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

#######################################
# Install dependencies
#######################################

install_dependencies() {
    log_info "Installing dependencies..."

    # Update package list
    apt-get update -qq

    # Required packages
    local packages=(
        "jq"
        "bc"
        "git"
    )

    # Optional but recommended packages
    local optional_packages=(
        "sysstat"    # Provides iostat
        "lsof"       # For process monitoring
        "net-tools"  # Provides netstat
    )

    # Install required packages
    for pkg in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            log_info "Installing $pkg..."
            apt-get install -y -qq "$pkg" > /dev/null 2>&1
        else
            log_info "$pkg is already installed"
        fi
    done

    # Install optional packages
    for pkg in "${optional_packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            log_info "Installing optional package $pkg..."
            apt-get install -y -qq "$pkg" > /dev/null 2>&1 || log_warning "Failed to install optional package $pkg"
        fi
    done

    log_success "Dependencies installed successfully"
}

#######################################
# Download repository
#######################################

download_repo() {
    log_info "Downloading System Health Monitor..."

    # Remove existing installation if present
    if [[ -d "$INSTALL_DIR" ]]; then
        log_warning "Existing installation found at $INSTALL_DIR"
        read -p "Remove and reinstall? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$INSTALL_DIR"
            log_info "Removed existing installation"
        else
            log_error "Installation cancelled"
            exit 1
        fi
    fi

    # Clone repository
    git clone -q "$REPO_URL" "$INSTALL_DIR"

    if [[ ! -d "$INSTALL_DIR" ]]; then
        log_error "Failed to download repository"
        exit 1
    fi

    log_success "Repository downloaded to $INSTALL_DIR"
}

#######################################
# Set up script
#######################################

setup_script() {
    log_info "Setting up health check script..."

    # Make script executable
    chmod +x "$INSTALL_DIR/$SCRIPT_NAME"

    # Create symbolic link in /usr/local/bin
    if [[ -L "$BIN_DIR/$SCRIPT_NAME" ]]; then
        rm "$BIN_DIR/$SCRIPT_NAME"
    fi

    ln -s "$INSTALL_DIR/$SCRIPT_NAME" "$BIN_DIR/$SCRIPT_NAME"
    log_success "Created symlink: $BIN_DIR/$SCRIPT_NAME -> $INSTALL_DIR/$SCRIPT_NAME"

    # Create history directory
    mkdir -p /var/lib/health-check
    chmod 755 /var/lib/health-check
    log_success "Created history directory: /var/lib/health-check"
}

#######################################
# Set up systemd timer (optional)
#######################################

setup_systemd_timer() {
    log_info "Setting up systemd timer for automated monitoring..."

    # Create systemd service file
    cat > /etc/systemd/system/health-check.service <<'EOF'
[Unit]
Description=System Health Monitor
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/health-check.sh --json
StandardOutput=append:/var/log/health-check.log
StandardError=append:/var/log/health-check-error.log
User=root

[Install]
WantedBy=multi-user.target
EOF

    # Create systemd timer file
    cat > /etc/systemd/system/health-check.timer <<'EOF'
[Unit]
Description=Run System Health Monitor every 6 hours
Requires=health-check.service

[Timer]
OnBootSec=5min
OnUnitActiveSec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # Reload systemd
    systemctl daemon-reload

    log_success "Systemd timer created"
}

#######################################
# Test installation
#######################################

test_installation() {
    log_info "Testing installation..."

    # Test if script runs
    if "$INSTALL_DIR/$SCRIPT_NAME" --version > /dev/null 2>&1; then
        log_success "Health check script is working correctly"
    else
        log_warning "Health check script test failed, but installation completed"
    fi
}

#######################################
# Print success message and instructions
#######################################

print_success() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_success "System Health Monitor installed successfully!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "📁 Installation directory: $INSTALL_DIR"
    echo "🔗 Command available: $SCRIPT_NAME"
    echo ""
    echo "🚀 Quick Start:"
    echo "   Run health check:        $SCRIPT_NAME"
    echo "   JSON output:             $SCRIPT_NAME --json"
    echo "   Specific component:      $SCRIPT_NAME --component cpu"
    echo "   Continuous monitoring:   $SCRIPT_NAME --monitor 60"
    echo ""

    if [[ -f /etc/systemd/system/health-check.timer ]]; then
        echo "⏰ Systemd Timer:"
        echo "   Enable automatic checks: sudo systemctl enable --now health-check.timer"
        echo "   Check timer status:      sudo systemctl status health-check.timer"
        echo "   View logs:               sudo journalctl -u health-check.service"
        echo ""
    fi

    echo "📚 Documentation: $INSTALL_DIR/README.md"
    echo "🐛 Report issues: https://github.com/calounx/pmanalysis/issues"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

#######################################
# Main installation flow
#######################################

main() {
    echo ""
    echo "╔════════════════════════════════════════════════════╗"
    echo "║     System Health Monitor - Installation          ║"
    echo "║     Version 1.3.0                                  ║"
    echo "╚════════════════════════════════════════════════════╝"
    echo ""

    # Check root privileges
    check_root

    # Detect OS
    detect_os

    # Install dependencies
    install_dependencies

    # Download repository
    download_repo

    # Set up script
    setup_script

    # Ask about systemd timer
    echo ""
    read -p "Do you want to set up automated health checks (systemd timer)? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        setup_systemd_timer
    fi

    # Test installation
    test_installation

    # Print success message
    print_success

    echo ""
    log_info "Installation complete! Run '$SCRIPT_NAME' to start monitoring."
    echo ""
}

# Run main function
main "$@"
