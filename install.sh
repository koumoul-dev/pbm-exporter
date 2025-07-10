#!/bin/bash

# pbm-exporter installation script
# This script downloads and installs the latest pbm-exporter binary

set -e

# Configuration
REPO="pbm-exporter"
BINARY_NAME="pbm-exporter"
INSTALL_DIR="/usr/local/bin"
SERVICE_DIR="/etc/systemd/system"
USER="pbm-exporter"
GROUP="pbm-exporter"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "This script should not be run as root"
        log_info "Please run as a regular user with sudo access"
        exit 1
    fi
    
    if ! sudo -n true 2>/dev/null; then
        log_error "This script requires sudo access"
        exit 1
    fi
}

# Detect system architecture
detect_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) 
            log_error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
}

# Detect operating system
detect_os() {
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case $os in
        linux) echo "linux" ;;
        darwin) echo "darwin" ;;
        *)
            log_error "Unsupported operating system: $os"
            exit 1
            ;;
    esac
}

# Create user and group for the service
create_user() {
    if ! id "$USER" &>/dev/null; then
        log_info "Creating user $USER..."
        sudo useradd --system --no-create-home --shell /bin/false "$USER"
    else
        log_info "User $USER already exists"
    fi
}

# Install binary from local build or download from GitHub
install_binary() {
    local os=$(detect_os)
    local arch=$(detect_arch)
    local binary_name="${BINARY_NAME}-${os}-${arch}"
    
    # Check if we have a local build directory
    if [[ -f "build/${BINARY_NAME}" ]]; then
        log_info "Installing from local build..."
        sudo cp "build/${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"
    elif [[ -f "build/${binary_name}" ]]; then
        log_info "Installing from local cross-compiled build..."
        sudo cp "build/${binary_name}" "${INSTALL_DIR}/${BINARY_NAME}"
    else
        log_error "No binary found in build/ directory"
        log_info "Please run 'make build' or 'make cross-compile' first"
        exit 1
    fi
    
    sudo chmod +x "${INSTALL_DIR}/${BINARY_NAME}"
    log_info "Binary installed to ${INSTALL_DIR}/${BINARY_NAME}"
}

# Create systemd service file
create_service() {
    log_info "Creating systemd service..."
    
    sudo tee "$SERVICE_DIR/${BINARY_NAME}.service" > /dev/null <<EOF
[Unit]
Description=PBM Prometheus Exporter
Documentation=https://github.com/your-org/pbm-exporter
After=network.target

[Service]
Type=simple
User=$USER
Group=$GROUP
ExecStart=${INSTALL_DIR}/${BINARY_NAME}
Restart=always
RestartSec=5
Environment=PORT=9090
EnvironmentFile=-/etc/default/${BINARY_NAME}

# Security settings
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/tmp

# Resource limits
LimitNOFILE=65536
LimitNPROC=4096

[Install]
WantedBy=multi-user.target
EOF

    log_info "Systemd service created"
}

# Create configuration file
create_config() {
    local config_file="/etc/default/${BINARY_NAME}"
    
    if [[ ! -f "$config_file" ]]; then
        log_info "Creating configuration file..."
        sudo tee "$config_file" > /dev/null <<EOF
# PBM Exporter Configuration
# MongoDB connection URI (REQUIRED)
PBM_MONGODB_URI=mongodb://localhost:27017

# Port to listen on (default: 9090)
PORT=9090

# Enable debug logging (optional)
# DEBUG=1
EOF
        log_info "Configuration file created at $config_file"
        log_warn "Please edit $config_file to set your MongoDB URI"
    else
        log_info "Configuration file already exists at $config_file"
    fi
}

# Enable and start service
enable_service() {
    log_info "Enabling and starting service..."
    sudo systemctl daemon-reload
    sudo systemctl enable "${BINARY_NAME}.service"
    
    if [[ "$1" == "--start" ]]; then
        sudo systemctl start "${BINARY_NAME}.service"
        log_info "Service started"
        
        # Show status
        sleep 2
        if sudo systemctl is-active --quiet "${BINARY_NAME}.service"; then
            log_info "Service is running successfully"
            log_info "Metrics available at: http://localhost:9090/metrics"
        else
            log_error "Service failed to start"
            sudo systemctl status "${BINARY_NAME}.service"
        fi
    else
        log_info "Service enabled but not started"
        log_info "To start the service: sudo systemctl start ${BINARY_NAME}.service"
    fi
}

# Uninstall function
uninstall() {
    log_info "Uninstalling pbm-exporter..."
    
    # Stop and disable service
    if sudo systemctl is-active --quiet "${BINARY_NAME}.service"; then
        sudo systemctl stop "${BINARY_NAME}.service"
    fi
    sudo systemctl disable "${BINARY_NAME}.service" 2>/dev/null || true
    
    # Remove files
    sudo rm -f "${INSTALL_DIR}/${BINARY_NAME}"
    sudo rm -f "${SERVICE_DIR}/${BINARY_NAME}.service"
    
    # Remove user (optional)
    if id "$USER" &>/dev/null; then
        read -p "Remove user $USER? [y/N]: " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo userdel "$USER"
            log_info "User $USER removed"
        fi
    fi
    
    sudo systemctl daemon-reload
    log_info "Uninstall completed"
}

# Show usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --start     Start the service after installation"
    echo "  --uninstall Remove pbm-exporter from the system"
    echo "  --help      Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                # Install but don't start"
    echo "  $0 --start        # Install and start service"
    echo "  $0 --uninstall    # Remove from system"
}

# Main installation function
main() {
    local start_service=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --start)
                start_service=true
                shift
                ;;
            --uninstall)
                uninstall
                exit 0
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    log_info "Installing pbm-exporter..."
    
    check_root
    create_user
    install_binary
    create_service
    create_config
    
    if [[ "$start_service" == true ]]; then
        enable_service --start
    else
        enable_service
    fi
    
    log_info "Installation completed successfully!"
    log_info ""
    log_info "Next steps:"
    log_info "1. Edit /etc/default/${BINARY_NAME} to configure MongoDB URI"
    log_info "2. Start the service: sudo systemctl start ${BINARY_NAME}.service"
    log_info "3. Check status: sudo systemctl status ${BINARY_NAME}.service"
    log_info "4. View logs: sudo journalctl -u ${BINARY_NAME}.service -f"
}

# Run main function
main "$@"
