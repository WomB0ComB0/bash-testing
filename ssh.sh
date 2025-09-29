#!/usr/bin/env bash

# SSH Key Setup Automation Script
# Works on Linux/Unix systems, package manager agnostic
# Automates SSH key generation with security best practices

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SSH_DIR="$HOME/.ssh"
DEFAULT_KEY_TYPE="ed25519"
DEFAULT_KEY_SIZE="4096"  # For RSA fallback

# Helper functions
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        print_error "$1 is not installed. Please install it first."
        exit 1
    fi
}

# Check prerequisites
check_prerequisites() {
    print_info "Checking prerequisites..."
    check_command "ssh-keygen"
    check_command "ssh-agent"
    check_command "ssh-add"
    print_success "All prerequisites met"
}

# Create and secure SSH directory
setup_ssh_directory() {
    print_info "Setting up SSH directory..."
    
    if [[ ! -d "$SSH_DIR" ]]; then
        mkdir -p "$SSH_DIR"
        print_success "Created $SSH_DIR"
    fi
    
    # Set proper permissions (700 for directory)
    chmod 700 "$SSH_DIR"
    print_success "Secured SSH directory permissions (700)"
}

# Get user input for key generation
get_user_input() {
    echo ""
    echo "=== SSH Key Generation Setup ==="
    echo ""
    
    # Key type
    echo "Select key type:"
    echo "1) ED25519 (recommended - modern, secure, fast)"
    echo "2) RSA 4096 (compatible with older systems)"
    read -rp "Choice [1]: " key_type_choice
    key_type_choice=${key_type_choice:-1}
    
    if [[ "$key_type_choice" == "2" ]]; then
        KEY_TYPE="rsa"
        KEY_SIZE="$DEFAULT_KEY_SIZE"
    else
        KEY_TYPE="$DEFAULT_KEY_TYPE"
        KEY_SIZE=""
    fi
    
    # Email/comment
    read -rp "Enter your email (for key comment) [$(whoami)@$(hostname)]: " email
    email=${email:-"$(whoami)@$(hostname)"}
    
    # Key filename
    default_filename="id_${KEY_TYPE}"
    read -rp "Enter key filename [$default_filename]: " key_filename
    key_filename=${key_filename:-$default_filename}
    KEY_PATH="$SSH_DIR/$key_filename"
    
    # Check if key already exists
    if [[ -f "$KEY_PATH" ]]; then
        print_warning "Key file $KEY_PATH already exists!"
        read -rp "Overwrite? (yes/no) [no]: " overwrite
        if [[ "$overwrite" != "yes" ]]; then
            print_error "Aborted by user"
            exit 1
        fi
    fi
    
    # Passphrase
    echo ""
    print_info "A passphrase adds an extra layer of security to your private key."
    read -rsp "Enter passphrase (empty for no passphrase): " passphrase
    echo ""
    
    if [[ -n "$passphrase" ]]; then
        read -rsp "Confirm passphrase: " passphrase_confirm
        echo ""
        
        if [[ "$passphrase" != "$passphrase_confirm" ]]; then
            print_error "Passphrases do not match!"
            exit 1
        fi
    fi
}

# Generate SSH key
generate_key() {
    print_info "Generating SSH key..."
    
    if [[ "$KEY_TYPE" == "rsa" ]]; then
        ssh-keygen -t rsa -b "$KEY_SIZE" -C "$email" -f "$KEY_PATH" -N "$passphrase"
    else
        ssh-keygen -t ed25519 -C "$email" -f "$KEY_PATH" -N "$passphrase"
    fi
    
    # Set proper permissions
    chmod 600 "$KEY_PATH"
    chmod 644 "${KEY_PATH}.pub"
    
    print_success "SSH key pair generated successfully"
    print_info "Private key: $KEY_PATH"
    print_info "Public key: ${KEY_PATH}.pub"
}

# Configure SSH config file
configure_ssh_config() {
    local config_file="$SSH_DIR/config"
    
    echo ""
    read -rp "Would you like to add this key to an SSH config entry? (yes/no) [no]: " add_to_config
    
    if [[ "$add_to_config" == "yes" ]]; then
        read -rp "Enter host alias (e.g., github, myserver): " host_alias
        read -rp "Enter hostname/IP: " hostname
        read -rp "Enter username: " username
        read -rp "Enter port [22]: " port
        port=${port:-22}
        
        # Create config file if it doesn't exist
        if [[ ! -f "$config_file" ]]; then
            touch "$config_file"
            chmod 600 "$config_file"
        fi
        
        # Add entry to config
        cat >> "$config_file" << EOF

Host $host_alias
    HostName $hostname
    User $username
    Port $port
    IdentityFile $KEY_PATH
    IdentitiesOnly yes
EOF
        
        print_success "Added configuration for host: $host_alias"
    fi
}

# Start SSH agent and add key
setup_ssh_agent() {
    echo ""
    read -rp "Would you like to add the key to ssh-agent? (yes/no) [yes]: " add_to_agent
    add_to_agent=${add_to_agent:-yes}
    
    if [[ "$add_to_agent" == "yes" ]]; then
        # Check if ssh-agent is running
        if [[ -z "${SSH_AGENT_PID:-}" ]] || ! ps -p "$SSH_AGENT_PID" > /dev/null 2>&1; then
            print_info "Starting ssh-agent..."
            eval "$(ssh-agent -s)"
        fi
        
        # Add key to agent
        if [[ -n "$passphrase" ]]; then
            # Use expect if available for automated passphrase entry
            if command -v expect &> /dev/null; then
                expect << EOF
                    spawn ssh-add "$KEY_PATH"
                    expect "Enter passphrase"
                    send "$passphrase\r"
                    expect eof
EOF
            else
                print_info "Please enter your passphrase when prompted:"
                ssh-add "$KEY_PATH"
            fi
        else
            ssh-add "$KEY_PATH"
        fi
        
        print_success "Key added to ssh-agent"
    fi
}

# Display public key
display_public_key() {
    echo ""
    echo "=== Your Public Key ==="
    echo ""
    cat "${KEY_PATH}.pub"
    echo ""
    print_info "Copy this public key to add to remote servers or services"
    echo ""
}

# Copy to clipboard if possible
copy_to_clipboard() {
    local clipboard_cmd=""
    
    if command -v xclip &> /dev/null; then
        clipboard_cmd="xclip -selection clipboard"
    elif command -v xsel &> /dev/null; then
        clipboard_cmd="xsel --clipboard"
    elif command -v pbcopy &> /dev/null; then
        clipboard_cmd="pbcopy"
    fi
    
    if [[ -n "$clipboard_cmd" ]]; then
        read -rp "Copy public key to clipboard? (yes/no) [no]: " copy_clip
        if [[ "$copy_clip" == "yes" ]]; then
            cat "${KEY_PATH}.pub" | $clipboard_cmd
            print_success "Public key copied to clipboard"
        fi
    fi
}

# Provide next steps
show_next_steps() {
    echo ""
    echo "=== Next Steps ==="
    echo ""
    echo "1. Copy your public key to remote servers:"
    echo "   ssh-copy-id -i ${KEY_PATH}.pub user@hostname"
    echo ""
    echo "2. Or manually append to remote ~/.ssh/authorized_keys:"
    echo "   cat ${KEY_PATH}.pub | ssh user@hostname 'cat >> ~/.ssh/authorized_keys'"
    echo ""
    echo "3. For GitHub/GitLab, add the public key to your account settings"
    echo ""
    echo "4. Test your connection:"
    echo "   ssh -i $KEY_PATH user@hostname"
    echo ""
    print_success "SSH key setup complete!"
}

# Main execution
main() {
    echo ""
    echo "========================================"
    echo "  SSH Key Setup Automation Script"
    echo "========================================"
    echo ""
    
    check_prerequisites
    setup_ssh_directory
    get_user_input
    generate_key
    configure_ssh_config
    setup_ssh_agent
    display_public_key
    copy_to_clipboard
    show_next_steps
}

# Run main function
main