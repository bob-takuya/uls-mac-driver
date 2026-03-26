#!/bin/bash
#
# ULS CUPS Virtual Printer Installation Script
#
# Installs the ULS CUPS backend and registers the "ULS VLS 6.0" printer.
# Must be run as root (sudo).
#
# Usage:
#   sudo ./scripts/install_cups.sh [install|uninstall]
#
# Copyright (c) 2026 Contributors - MIT License
#

set -e

# Configuration
BACKEND_NAME="uls"
PRINTER_NAME="ULS_VLS_6.0"
PRINTER_DESC="ULS VLS 6.0 Laser Cutter"
PRINTER_LOCATION="Laser Lab"
PPD_NAME="ULS-VLS60.ppd"

# Paths
CUPS_BACKEND_DIR="/usr/libexec/cups/backend"
CUPS_PPD_DIR="/Library/Printers/PPDs/Contents/Resources"
BUILD_DIR="build"
CUPS_DIR="cups"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Print colored messages
info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run as root. Use: sudo $0"
    fi
}

# Check if backend binary exists
check_binary() {
    if [ ! -f "${BUILD_DIR}/${BACKEND_NAME}" ]; then
        error "Backend binary not found. Run 'make cups' first."
    fi
}

# Install the CUPS backend and printer
install_cups() {
    info "Installing ULS CUPS Virtual Printer..."

    # Check prerequisites
    check_root
    check_binary

    # Create PPD directory if it doesn't exist
    if [ ! -d "${CUPS_PPD_DIR}" ]; then
        info "Creating PPD directory..."
        mkdir -p "${CUPS_PPD_DIR}"
    fi

    # Stop CUPS to avoid conflicts during installation
    info "Stopping CUPS service..."
    launchctl stop org.cups.cupsd 2>/dev/null || true
    sleep 1

    # Install backend
    info "Installing backend to ${CUPS_BACKEND_DIR}/${BACKEND_NAME}..."
    cp "${BUILD_DIR}/${BACKEND_NAME}" "${CUPS_BACKEND_DIR}/${BACKEND_NAME}"
    chown root:wheel "${CUPS_BACKEND_DIR}/${BACKEND_NAME}"
    chmod 755 "${CUPS_BACKEND_DIR}/${BACKEND_NAME}"

    # Install PPD file (gzip compressed as CUPS prefers)
    info "Installing PPD file..."
    if [ -f "${CUPS_DIR}/${PPD_NAME}" ]; then
        gzip -c "${CUPS_DIR}/${PPD_NAME}" > "${CUPS_PPD_DIR}/${PPD_NAME}.gz"
        chmod 644 "${CUPS_PPD_DIR}/${PPD_NAME}.gz"
    else
        error "PPD file not found: ${CUPS_DIR}/${PPD_NAME}"
    fi

    # Start CUPS
    info "Starting CUPS service..."
    launchctl start org.cups.cupsd
    sleep 2

    # Remove existing printer if it exists
    if lpstat -p "${PRINTER_NAME}" 2>/dev/null; then
        info "Removing existing printer..."
        lpadmin -x "${PRINTER_NAME}" 2>/dev/null || true
    fi

    # Register the printer
    info "Registering printer '${PRINTER_NAME}'..."
    lpadmin -p "${PRINTER_NAME}" \
            -D "${PRINTER_DESC}" \
            -L "${PRINTER_LOCATION}" \
            -v "${BACKEND_NAME}://default" \
            -P "${CUPS_PPD_DIR}/${PPD_NAME}.gz" \
            -E

    # Enable the printer
    info "Enabling printer..."
    cupsenable "${PRINTER_NAME}"
    cupsaccept "${PRINTER_NAME}"

    info "Installation complete!"
    echo ""
    echo "The printer '${PRINTER_DESC}' is now available."
    echo "You can select it from any macOS application's print dialog."
    echo ""
    echo "To test: lpr -P ${PRINTER_NAME} test.pdf"
    echo "To check status: lpstat -p ${PRINTER_NAME}"
    echo ""
}

# Uninstall the CUPS backend and printer
uninstall_cups() {
    info "Uninstalling ULS CUPS Virtual Printer..."

    check_root

    # Remove printer
    if lpstat -p "${PRINTER_NAME}" 2>/dev/null; then
        info "Removing printer '${PRINTER_NAME}'..."
        lpadmin -x "${PRINTER_NAME}"
    else
        warn "Printer '${PRINTER_NAME}' not found."
    fi

    # Remove backend
    if [ -f "${CUPS_BACKEND_DIR}/${BACKEND_NAME}" ]; then
        info "Removing backend..."
        rm -f "${CUPS_BACKEND_DIR}/${BACKEND_NAME}"
    else
        warn "Backend not found at ${CUPS_BACKEND_DIR}/${BACKEND_NAME}"
    fi

    # Remove PPD file
    if [ -f "${CUPS_PPD_DIR}/${PPD_NAME}.gz" ]; then
        info "Removing PPD file..."
        rm -f "${CUPS_PPD_DIR}/${PPD_NAME}.gz"
    else
        warn "PPD file not found."
    fi

    # Restart CUPS
    info "Restarting CUPS service..."
    launchctl stop org.cups.cupsd 2>/dev/null || true
    sleep 1
    launchctl start org.cups.cupsd

    info "Uninstallation complete!"
}

# Show status
status_cups() {
    echo "=== ULS CUPS Backend Status ==="
    echo ""

    # Check backend
    if [ -f "${CUPS_BACKEND_DIR}/${BACKEND_NAME}" ]; then
        echo -e "Backend: ${GREEN}Installed${NC} (${CUPS_BACKEND_DIR}/${BACKEND_NAME})"
    else
        echo -e "Backend: ${RED}Not installed${NC}"
    fi

    # Check PPD
    if [ -f "${CUPS_PPD_DIR}/${PPD_NAME}.gz" ]; then
        echo -e "PPD:     ${GREEN}Installed${NC} (${CUPS_PPD_DIR}/${PPD_NAME}.gz)"
    else
        echo -e "PPD:     ${RED}Not installed${NC}"
    fi

    # Check printer
    if lpstat -p "${PRINTER_NAME}" 2>/dev/null; then
        echo -e "Printer: ${GREEN}Registered${NC}"
        lpstat -p "${PRINTER_NAME}"
    else
        echo -e "Printer: ${RED}Not registered${NC}"
    fi

    echo ""
}

# Show usage
usage() {
    echo "Usage: $0 [install|uninstall|status]"
    echo ""
    echo "Commands:"
    echo "  install     Install the ULS CUPS backend and register the printer"
    echo "  uninstall   Remove the ULS CUPS backend and printer"
    echo "  status      Show installation status"
    echo ""
    echo "This script must be run as root (sudo)."
    echo ""
}

# Main
case "${1:-install}" in
    install)
        install_cups
        ;;
    uninstall)
        uninstall_cups
        ;;
    status)
        status_cups
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        error "Unknown command: $1"
        usage
        exit 1
        ;;
esac
