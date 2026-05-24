#!/bin/bash

# Docker Compose Dev Container Cleanup Script
# This script stops and removes all containers, images, volumes, and networks
# created by the devcontainer docker-compose setup

set -e  # Exit on any error

# Global flag for volume cleanup
REMOVE_VOLUMES=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
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

# Function to check if docker-compose file exists
check_compose_file() {
    if [[ -f "docker-compose.yml" ]]; then
        COMPOSE_FILE="docker-compose.yml"
    elif [[ -f "docker-compose.yaml" ]]; then
        COMPOSE_FILE="docker-compose.yaml"
    elif [[ -f "compose.yml" ]]; then
        COMPOSE_FILE="compose.yml"
    elif [[ -f "compose.yaml" ]]; then
        COMPOSE_FILE="compose.yaml"
    else
        print_error "No docker-compose file found in current directory"
        echo "Looking for: docker-compose.yml, docker-compose.yaml, compose.yml, compose.yaml"
        exit 1
    fi
    print_status "Using compose file: $COMPOSE_FILE"
}

# Function to get project name
get_project_name() {
    # Check if .env file exists and has PROJECT_NAME
    if [[ -f ".env" ]]; then
        ENV_PROJECT_NAME=$(grep -E "^PROJECT_NAME=" .env | cut -d'=' -f2 | tr -d '"' | tr -d "'" || echo "")
        if [[ -n "$ENV_PROJECT_NAME" ]]; then
            PROJECT_NAME="$ENV_PROJECT_NAME"
            print_status "Using project name from .env: $PROJECT_NAME"
        else
            # Default to claude-project if .env exists but has no PROJECT_NAME
            PROJECT_NAME="claude-project"
            print_status "No PROJECT_NAME in .env, using default: $PROJECT_NAME"
        fi
    else
        # Default to claude-project if no .env file exists
        PROJECT_NAME="claude-project"
        print_status "No .env file found, using default project name: $PROJECT_NAME"
    fi
    
    print_status "Project name: $PROJECT_NAME"
}

# Function to show what will be deleted
show_cleanup_preview() {
    print_status "Preview of resources to be cleaned up:"
    echo ""
    
    # Show containers (based on actual docker-compose naming)
    echo "Containers:"
    CONTAINERS=$(docker ps -a --format "{{.Names}}" | grep -E "^(claude-code-container-${PROJECT_NAME}|datadog-agent-${PROJECT_NAME})$" || true)
    if [[ -n "$CONTAINERS" ]]; then
        echo "$CONTAINERS" | while read -r container; do
            STATE=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")
            echo "  - $container (status: $STATE)"
        done
    else
        echo "  None found"
    fi
    echo ""
    
    # Show images
    echo "Images:"
    IMAGES=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -E "^ghcr.io/quantium-enterprise/genaicore-claude-code/(devcontainer|datadog-agent):" || true)
    if [[ -n "$IMAGES" ]]; then
        echo "$IMAGES" | sed 's/^/  - /'
    else
        echo "  None found"
    fi
    echo ""
    
    # Show volumes
    if [[ "$REMOVE_VOLUMES" == "true" ]]; then
        echo "Volumes (will be DELETED):"
    else
        echo "Volumes (will be PRESERVED):"
    fi
    PROJECT_VOLUMES=$(docker volume ls --format "{{.Name}}" | grep -E "^claude-code-(datadog|bashhistory|config|shared)-${PROJECT_NAME}$" || true)
    if [[ -n "$PROJECT_VOLUMES" ]]; then
        echo "$PROJECT_VOLUMES" | sed 's/^/  - /'
    else
        echo "  None found"
    fi
    echo ""
}

# Function to remove volumes
remove_volumes() {
    print_status "Removing volumes..."

    # Get list of project-specific volumes
    PROJECT_VOLUMES=$(docker volume ls --format "{{.Name}}" | grep -E "^claude-code-(datadog|bashhistory|config|shared)-${PROJECT_NAME}$" || true)

    if [[ -z "$PROJECT_VOLUMES" ]]; then
        print_status "No volumes found to remove"
        return 0
    fi

    while IFS= read -r volume; do
        if ! docker volume rm "$volume" 2>/dev/null; then
            print_warning "Failed to remove volume (may be in use): $volume"
        fi
    done <<< "$PROJECT_VOLUMES"
}

# Main cleanup function
cleanup_resources() {
    print_status "Starting cleanup process..."
    
    # Step 1: Stop containers using docker-compose
    print_status "Stopping docker-compose containers..."
    # Export PROJECT_NAME so docker-compose uses it
    export PROJECT_NAME
    docker-compose -f "$COMPOSE_FILE" stop 2>/dev/null || print_warning "No compose containers to stop"
    
    # Step 2: Remove containers using docker-compose
    print_status "Removing docker-compose containers..."
    docker-compose -f "$COMPOSE_FILE" rm -f 2>/dev/null || print_warning "No compose containers to remove"
    
    # Step 3: Remove any remaining containers with our naming pattern (backup cleanup)
    print_status "Removing any remaining containers..."
    docker ps -a --format "{{.Names}}" | grep -E "^(claude-code-container-${PROJECT_NAME}|datadog-agent-${PROJECT_NAME})$" | xargs -r docker rm -f || true

    # Step 4: Remove volumes (if requested)
    if [[ "$REMOVE_VOLUMES" == "true" ]]; then
        remove_volumes
    fi

    # Step 5: Remove images
    print_status "Removing devcontainer images..."
    # Remove the specific images used by this devcontainer
    docker images --format "{{.Repository}}:{{.Tag}}" | grep -E "^ghcr.io/quantium-enterprise/genaicore-claude-code/(devcontainer|datadog-agent):" | xargs -r docker rmi -f || true

    # Step 6: Final cleanup with docker-compose
    print_status "Final cleanup with docker-compose..."
    docker-compose -f "$COMPOSE_FILE" down --remove-orphans 2>/dev/null || true

    print_success "Cleanup completed!"
}

# Main script execution
main() {
    echo "=== Docker Compose Dev Container Cleanup ==="
    echo ""
    
    # Check if Docker is running
    if ! docker info >/dev/null 2>&1; then
        print_error "Docker is not running. Please start Docker and try again."
        exit 1
    fi
    
    # Check for compose file
    check_compose_file
    
    # Get project name
    get_project_name
    
    # Show what will be deleted
    show_cleanup_preview
    
    # Confirm with user
    echo ""
    print_warning "This will permanently delete containers, images, and network for project: $PROJECT_NAME"
    if [[ "$REMOVE_VOLUMES" == "true" ]]; then
        print_warning "This will also PERMANENTLY DELETE all volumes"
    else
        print_status "NOTE: All volumes will be PRESERVED"
    fi
    read -p "Are you sure you want to continue? (y/N): " -r
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_status "Cleanup cancelled."
        exit 0
    fi
    
    # Perform cleanup
    cleanup_resources
}

# Handle script arguments
# Parse all arguments to support multiple flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            echo "Docker Compose Cleanup Script"
            echo ""
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --help, -h       Show this help message"
            echo "  --force, -f      Skip confirmation prompts"
            echo "  --preview, -p    Show what will be deleted without performing cleanup"
            echo "  --volumes, -v    Also remove volumes (DELETES ALL DATA)"
            echo ""
            echo "This script will:"
            echo "  1. Stop all containers defined in docker-compose.yml"
            echo "  2. Remove containers (claude-code-container-*, datadog-agent-*)"
            echo "  3. Optionally remove volumes (with --volumes flag)"
            echo "  4. Remove devcontainer images from ghcr.io/quantium-enterprise"
            echo "  5. Remove the claude-code-network"
            echo ""
            echo "WARNING: Using --volumes will permanently delete:"
            echo "  - Bash history"
            echo "  - Claude Code configuration"
            echo "  - All persistent data in volumes"
            echo ""
            echo "Note: This script must be run from the .devcontainer directory."
            echo ""
            exit 0
            ;;
        --force|-f)
            FORCE_MODE=true
            ;;
        --preview|-p)
            PREVIEW_MODE=true
            ;;
        --volumes|-v)
            REMOVE_VOLUMES=true
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
    shift
done

# Execute based on flags
if [[ "${PREVIEW_MODE:-false}" == "true" ]]; then
    print_status "Preview mode: showing resources without cleanup"
    check_compose_file
    get_project_name
    show_cleanup_preview
    exit 0
elif [[ "${FORCE_MODE:-false}" == "true" ]]; then
    print_status "Force mode: skipping confirmations"
    if [[ "$REMOVE_VOLUMES" == "true" ]]; then
        print_warning "Force mode with volume removal enabled"
    fi
    check_compose_file
    get_project_name
    cleanup_resources
    exit 0
else
    main
fi
