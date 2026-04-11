#!/usr/bin/env bash
set -e

# --- Colored output helpers ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info()    { echo -e "${BLUE}i${NC} $1"; }
print_success() { echo -e "${GREEN}+${NC} $1"; }
print_warning() { echo -e "${YELLOW}!${NC} $1"; }
print_error()   { echo -e "${RED}x${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_NAME="better-notion"

# --- Dependency check ---

check_dependencies() {
    print_info "Checking dependencies..."

    if ! command -v cargo >/dev/null 2>&1; then
        print_error "cargo is not installed"
        print_info "Install Rust: https://rustup.rs/"
        exit 1
    fi

    print_success "Dependencies check passed"
}

# --- Build ---

build_release() {
    print_info "Building release binary..."
    cd "$SCRIPT_DIR"

    if [ "$1" = "--clean" ]; then
        cargo clean
    fi

    if ! cargo build --release; then
        print_error "Build failed"
        exit 1
    fi

    print_success "Release binary built successfully"
}

# --- Install binary ---

install_binary() {
    local binary_path="$SCRIPT_DIR/target/release/$BINARY_NAME"
    local install_path="/usr/local/bin/$BINARY_NAME"

    if [ ! -f "$binary_path" ]; then
        print_error "Binary not found at $binary_path. Build first."
        exit 1
    fi

    if cp "$binary_path" "$install_path" 2>/dev/null; then
        print_success "Installed to $install_path"
    else
        print_info "Administrator privileges required"
        sudo cp "$binary_path" "$install_path"
        print_success "Installed to $install_path (with sudo)"
    fi

    chmod +x "$install_path" 2>/dev/null || sudo chmod +x "$install_path"
}

# --- Shell completions ---

detect_shell() {
    case "$SHELL" in
        */bash) echo "bash" ;;
        */zsh)  echo "zsh" ;;
        */fish) echo "fish" ;;
        *)      echo "unknown" ;;
    esac
}

install_bash_completion() {
    local dirs=(
        "/usr/local/etc/bash_completion.d"
        "/etc/bash_completion.d"
        "$HOME/.local/share/bash-completion/completions"
    )
    for dir in "${dirs[@]}"; do
        if [ -d "$dir" ] && [ -w "$dir" ]; then
            $BINARY_NAME completions bash > "$dir/$BINARY_NAME"
            print_success "Bash completions installed to $dir/$BINARY_NAME"
            return
        fi
    done
    print_warning "No writable bash completion directory found"
    print_info "Run manually: $BINARY_NAME completions bash > ~/.bash_completion.d/$BINARY_NAME"
}

install_zsh_completion() {
    local dir="$HOME/.zsh/completions"
    mkdir -p "$dir"
    $BINARY_NAME completions zsh > "$dir/_$BINARY_NAME"
    print_success "Zsh completions installed to $dir/_$BINARY_NAME"

    if ! grep -q "fpath=(.*\.zsh/completions" "$HOME/.zshrc" 2>/dev/null; then
        print_info "Add to your ~/.zshrc:"
        echo '    fpath=(~/.zsh/completions $fpath)'
        echo '    autoload -Uz compinit && compinit'
    fi
}

install_fish_completion() {
    local dir="$HOME/.config/fish/completions"
    mkdir -p "$dir"
    $BINARY_NAME completions fish > "$dir/$BINARY_NAME.fish"
    print_success "Fish completions installed to $dir/$BINARY_NAME.fish"
}

install_completions() {
    if ! command -v $BINARY_NAME >/dev/null 2>&1; then
        print_error "$BINARY_NAME not found in PATH. Install binary first."
        return 1
    fi

    local shell
    shell=$(detect_shell)
    case "$shell" in
        bash) install_bash_completion ;;
        zsh)  install_zsh_completion ;;
        fish) install_fish_completion ;;
        *)    print_info "Generate manually: $BINARY_NAME completions <bash|zsh|fish>" ;;
    esac
}

# --- Usage ---

show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Install the better-notion CLI.

Options:
  --clean             Clean build artifacts before building
  --binary-only       Install only the binary, skip completions
  --completions-only  Install only completions (binary must be in PATH)
  -h, --help          Show this help message
EOF
}

# --- Main ---

main() {
    local clean=false
    local binary_only=false
    local completions_only=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --clean)            clean=true; shift ;;
            --binary-only)      binary_only=true; shift ;;
            --completions-only) completions_only=true; shift ;;
            -h|--help)          show_usage; exit 0 ;;
            *)                  print_error "Unknown option: $1"; show_usage; exit 1 ;;
        esac
    done

    echo ""
    print_info "Installing $BINARY_NAME"
    echo ""

    if [ "$completions_only" = true ]; then
        install_completions
    else
        check_dependencies

        if [ "$clean" = true ]; then
            build_release --clean
        else
            build_release
        fi

        install_binary

        if [ "$binary_only" = false ]; then
            install_completions
        fi
    fi

    echo ""
    print_success "Done!"
}

main "$@"
