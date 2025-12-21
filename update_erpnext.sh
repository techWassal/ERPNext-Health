#!/bin/bash
# =============================================================================
# ERPNext + Healthcare + HRMS + Helpdesk + Insights + ZATCA Safe Update Script
# =============================================================================
# Features:
#   - Automatic pre-update backup
#   - Image build BEFORE maintenance mode (minimizes downtime)
#   - Database migration with explicit warnings
#   - Comprehensive health verification
#   - Explicit rollback limitations documented
#   - Logging with timestamps
# =============================================================================
#
# ⚠️  IMPORTANT: DATABASE MIGRATIONS ARE NOT AUTOMATICALLY REVERSIBLE
#     This script can revert the Docker image, but database schema changes
#     require manual restore from backup if migration fails.
#
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/.env" 2>/dev/null || true

# Settings
SITE_NAME="${SITE_NAME:-frontend}"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
BACKUP_DIR="${BACKUP_DIR:-/opt/erpnext-backups}"
LOG_FILE="${SCRIPT_DIR}/update.log"

# Image settings
IMAGE_NAME="${ERPNEXT_IMAGE:-erpnext-healthcare}"
NEW_VERSION="${1:-}"
PREVIOUS_VERSION="${ERPNEXT_VERSION:-v15-healthcare}"

# Tracking
APPLICATION_ROLLBACK_NEEDED=false
BACKUP_CREATED=""
MAINTENANCE_ENABLED=false
MIGRATION_STARTED=false

# Timeouts
HEALTH_CHECK_TIMEOUT=120
HEALTH_CHECK_INTERVAL=5

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_success() { log "SUCCESS" "$@"; }

# -----------------------------------------------------------------------------
# Cleanup Handler
# -----------------------------------------------------------------------------
cleanup() {
    local exit_code=$?

    if [[ "${APPLICATION_ROLLBACK_NEEDED}" == "true" ]]; then
        log_error "Update failed, initiating APPLICATION rollback..."
        application_rollback
    fi

    if [[ "${MAINTENANCE_ENABLED}" == "true" ]]; then
        log_info "Disabling maintenance mode..."
        disable_maintenance || true
    fi

    if [[ ${exit_code} -ne 0 ]]; then
        log_error "Update script exited with code: ${exit_code}"
        echo ""
        echo "=========================================="
        echo "UPDATE FAILED"
        echo "=========================================="
        echo "Check ${LOG_FILE} for details"
        echo ""
        if [[ "${MIGRATION_STARTED}" == "true" ]]; then
            echo "⚠️  DATABASE MIGRATION WAS STARTED"
            echo "   Schema changes may not be reversible."
            echo "   To fully restore, run:"
            echo "   ./backup_script.sh test-restore ${BACKUP_CREATED:-latest-backup}"
            echo ""
        fi
        echo "=========================================="
    fi
}

trap cleanup EXIT

# -----------------------------------------------------------------------------
# Utility Functions
# -----------------------------------------------------------------------------
confirm_action() {
    local message="$1"
    local default="${2:-n}"

    if [[ "${FORCE:-false}" == "true" ]]; then
        return 0
    fi

    echo ""
    read -rp "${message} [y/N]: " response
    case "${response}" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# Health Check Functions (Improved)
# -----------------------------------------------------------------------------
wait_for_backend_health() {
    local timeout="${1:-${HEALTH_CHECK_TIMEOUT}}"
    local elapsed=0

    log_info "Waiting for backend to be healthy (timeout: ${timeout}s)..."

    while [[ ${elapsed} -lt ${timeout} ]]; do
        if check_backend_health; then
            log_success "Backend is healthy after ${elapsed}s"
            return 0
        fi
        sleep "${HEALTH_CHECK_INTERVAL}"
        elapsed=$((elapsed + HEALTH_CHECK_INTERVAL))
        log_info "Still waiting... (${elapsed}s/${timeout}s)"
    done

    log_error "Backend health check timed out after ${timeout}s"
    return 1
}

check_backend_health() {
    # Check 1: HTTP ping
    if ! docker compose -f "${COMPOSE_FILE}" exec -T backend \
        curl -sf http://localhost:8000/api/method/ping >/dev/null 2>&1; then
        return 1
    fi

    # Check 2: Database connectivity via bench doctor
    if ! docker compose -f "${COMPOSE_FILE}" exec -T backend \
        bench doctor 2>&1 | grep -q "Background workers" ; then
        # bench doctor may not exist in all versions, fallback to list-apps
        if ! docker compose -f "${COMPOSE_FILE}" exec -T backend \
            bench --site "${SITE_NAME}" list-apps >/dev/null 2>&1; then
            return 1
        fi
    fi

    return 0
}

check_services_comprehensive() {
    log_info "Running comprehensive health checks..."
    local issues=0

    # Check all expected containers are running
    local expected_services="backend frontend db redis-cache redis-queue websocket scheduler queue-long"
    for service in ${expected_services}; do
        if ! docker compose -f "${COMPOSE_FILE}" ps --status running 2>/dev/null | grep -q "${service}"; then
            log_warn "Service not running: ${service}"
            ((issues++)) || true
        fi
    done

    # Check backend health
    if ! docker compose -f "${COMPOSE_FILE}" exec -T backend \
        curl -sf http://localhost:8000/api/method/ping >/dev/null 2>&1; then
        log_warn "Backend HTTP ping failed"
        ((issues++)) || true
    fi

    # Check apps are installed
    log_info "Checking installed apps..."
    docker compose -f "${COMPOSE_FILE}" exec -T backend \
        bench --site "${SITE_NAME}" list-apps 2>&1 | tee -a "${LOG_FILE}" || ((issues++)) || true

    # Check scheduler (optional, may not always be running)
    if docker compose -f "${COMPOSE_FILE}" exec -T backend \
        bench --site "${SITE_NAME}" doctor 2>&1 | grep -q "Background workers not running"; then
        log_warn "Background workers may not be running"
    fi

    if [[ ${issues} -gt 0 ]]; then
        log_warn "Found ${issues} potential issues - review recommended"
        return 1
    fi

    log_success "All health checks passed"
    return 0
}

# -----------------------------------------------------------------------------
# Maintenance Mode
# -----------------------------------------------------------------------------
enable_maintenance() {
    log_info "Enabling maintenance mode..."
    log_warn "Database writes are blocked only by maintenance mode (application-level)"
    
    if docker compose -f "${COMPOSE_FILE}" exec -T backend \
        bench --site "${SITE_NAME}" set-maintenance-mode on 2>&1 | tee -a "${LOG_FILE}"; then
        MAINTENANCE_ENABLED=true
        log_success "Maintenance mode enabled"
    else
        log_warn "Failed to enable maintenance mode (site may not be responding)"
    fi
}

disable_maintenance() {
    log_info "Disabling maintenance mode..."
    
    docker compose -f "${COMPOSE_FILE}" exec -T backend \
        bench --site "${SITE_NAME}" set-maintenance-mode off 2>&1 | tee -a "${LOG_FILE}" || true
    
    MAINTENANCE_ENABLED=false
    log_success "Maintenance mode disabled"
}

# -----------------------------------------------------------------------------
# Backup
# -----------------------------------------------------------------------------
create_pre_update_backup() {
    log_info "Creating pre-update backup..."
    
    if [[ -x "${SCRIPT_DIR}/backup_script.sh" ]]; then
        if "${SCRIPT_DIR}/backup_script.sh" daily 2>&1 | tee -a "${LOG_FILE}"; then
            BACKUP_CREATED=$(find "${BACKUP_DIR}/daily" -name "*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null | \
                sort -n | tail -1 | cut -d' ' -f2-)
            log_success "Pre-update backup created: ${BACKUP_CREATED}"
        else
            log_error "Backup failed"
            return 1
        fi
    else
        # Fallback: use bench backup
        log_info "Using bench backup (backup_script.sh not found)"
        docker compose -f "${COMPOSE_FILE}" exec -T backend \
            bench --site "${SITE_NAME}" backup --with-files --compress 2>&1 | tee -a "${LOG_FILE}"
        BACKUP_CREATED="bench-backup-$(date +%Y%m%d_%H%M%S)"
        log_success "Bench backup created"
    fi
}

# -----------------------------------------------------------------------------
# Image Build (now happens BEFORE maintenance mode)
# -----------------------------------------------------------------------------
rebuild_image() {
    local version="$1"
    
    log_info "Rebuilding Docker image with version: ${version}"
    log_info "This happens BEFORE maintenance mode to minimize downtime"
    
    # Check if frappe_docker exists
    if [[ ! -d "${SCRIPT_DIR}/frappe_docker" ]]; then
        log_info "Cloning frappe_docker repository..."
        git clone --depth 1 https://github.com/frappe/frappe_docker.git "${SCRIPT_DIR}/frappe_docker"
    fi
    
    cd "${SCRIPT_DIR}/frappe_docker"
    
    # Pull latest changes
    git pull origin main 2>&1 | tee -a "${LOG_FILE}" || true
    
    # Create Containerfile with all 7 apps
    # Version tag includes date for audit clarity
    cat > Containerfile << 'EOF'
FROM docker.io/frappe/erpnext:v15.92.3

USER frappe
# Stage 1: Install Base Dependencies
RUN bench get-app --skip-assets --branch=version-15 payments https://github.com/frappe/payments
RUN bench get-app --skip-assets --branch=develop telephony https://github.com/frappe/telephony

# Stage 2: Install HRMS (before Healthcare)
RUN bench get-app --skip-assets --branch=version-15 hrms https://github.com/frappe/hrms

# Stage 3: Install Healthcare
RUN bench get-app --skip-assets --branch=version-15 healthcare https://github.com/earthians/marley

# Stage 4: Install Helpdesk, Insights, and ZATCA
RUN bench get-app --skip-assets --branch=main helpdesk https://github.com/frappe/helpdesk
RUN bench get-app --skip-assets --branch=main insights https://github.com/frappe/insights
RUN bench get-app --skip-assets --branch=main zatca_erpgulf https://github.com/ERPGulf/zatca_erpgulf
EOF
    
    # Build the image
    log_info "Building image (this may take 15-30 minutes)..."
    log_info "Site remains accessible during image build"
    
    if docker build --no-cache \
        --tag "${IMAGE_NAME}:${version}" \
        --file Containerfile . 2>&1 | tee -a "${LOG_FILE}"; then
        log_success "Image built successfully: ${IMAGE_NAME}:${version}"
    else
        log_error "Image build failed"
        return 1
    fi
    
    cd "${SCRIPT_DIR}"
}

# -----------------------------------------------------------------------------
# Update Process (Reordered for minimal downtime)
# -----------------------------------------------------------------------------
update_services() {
    local version="$1"
    
    log_info "Updating services to version: ${version}"
    
    # Update .env file with new version
    if grep -q "ERPNEXT_VERSION=" "${SCRIPT_DIR}/.env" 2>/dev/null; then
        sed -i "s/ERPNEXT_VERSION=.*/ERPNEXT_VERSION=${version}/" "${SCRIPT_DIR}/.env"
    else
        echo "ERPNEXT_VERSION=${version}" >> "${SCRIPT_DIR}/.env"
    fi
    
    # Recreate only essential services first (not Redis, not workers during initial swap)
    log_info "Recreating backend and frontend containers..."
    docker compose -f "${COMPOSE_FILE}" up -d --force-recreate backend frontend 2>&1 | tee -a "${LOG_FILE}"
    
    # Wait for backend to start
    if ! wait_for_backend_health 120; then
        log_error "Backend failed to start after container update"
        APPLICATION_ROLLBACK_NEEDED=true
        return 1
    fi
    
    # Run migrations
    log_warn "=========================================="
    log_warn "STARTING DATABASE MIGRATION"
    log_warn "⚠️  This operation may NOT be automatically reversible"
    log_warn "⚠️  If migration fails, manual DB restore may be required"
    log_warn "=========================================="
    MIGRATION_STARTED=true
    
    if docker compose -f "${COMPOSE_FILE}" exec -T backend \
        bench --site "${SITE_NAME}" migrate 2>&1 | tee -a "${LOG_FILE}"; then
        log_success "Migrations completed successfully"
    else
        log_error "DATABASE MIGRATION FAILED"
        log_error "Database schema may be in inconsistent state"
        log_error "Manual restore from backup is recommended"
        APPLICATION_ROLLBACK_NEEDED=true
        return 1
    fi
    
    # Clear cache (always safe)
    log_info "Clearing cache..."
    docker compose -f "${COMPOSE_FILE}" exec -T backend \
        bench --site "${SITE_NAME}" clear-cache 2>&1 | tee -a "${LOG_FILE}" || true
    
    # NOTE: Removed bench build - assets should be built at image build time
    # Runtime build increases downtime and breaks immutable image principle
    # Only uncomment if you know assets changed dynamically:
    # log_info "Building assets..."
    # docker compose -f "${COMPOSE_FILE}" exec -T backend \
    #     bench --site "${SITE_NAME}" build 2>&1 | tee -a "${LOG_FILE}" || true

    # Now update other services
    log_info "Updating remaining services..."
    docker compose -f "${COMPOSE_FILE}" up -d 2>&1 | tee -a "${LOG_FILE}"

    # Build and sync frontend apps
    log_info "Building frontend apps and syncing assets..."
    docker compose -f "${COMPOSE_FILE}" exec -T backend bench build --production 2>&1 | tee -a "${LOG_FILE}" || true
    docker compose -f "${COMPOSE_FILE}" exec -T backend bench --site "${SITE_NAME}" build --app helpdesk 2>&1 | tee -a "${LOG_FILE}" || true
    docker compose -f "${COMPOSE_FILE}" exec -T backend bench --site "${SITE_NAME}" build --app insights 2>&1 | tee -a "${LOG_FILE}" || true
    
    # Sync and resolve assets (Host-Mediated Force Sync)
    log_info "Regenerating and force-syncing assets via host..."
    docker compose -f "${COMPOSE_FILE}" exec -T backend bench build --production --force 2>&1 | tee -a "${LOG_FILE}" || true
    
    # Resolve backend symlinks
    docker compose -f "${COMPOSE_FILE}" exec -T -u root backend bash -c "
        cd /home/frappe/frappe-bench/sites/ && \
        if [ -L assets ]; then 
            cp -rL assets assets_resolved
            rm assets
            mv assets_resolved assets
        else
            rm -rf assets_real && \
            mkdir -p assets_real && \
            cp -rL assets/* assets_real/ && \
            rm -rf assets/* && \
            cp -r assets_real/* assets/ && \
            rm -rf assets_real
        fi && \
        chown -R 1000:1000 assets
    " 2>/dev/null || true

    # Extract to Host
    rm -rf "${SCRIPT_DIR}/asset_sync_temp"
    docker compose cp backend:/home/frappe/frappe-bench/sites/assets/. "${SCRIPT_DIR}/asset_sync_temp" 2>/dev/null || true
    
    # Inject into Frontend (Nginx Root)
    docker compose -f "${COMPOSE_FILE}" exec -T -u root frontend rm -rf /home/frappe/frappe-bench/sites/assets 2>/dev/null || true
    docker compose -f "${COMPOSE_FILE}" exec -T -u root frontend mkdir -p /home/frappe/frappe-bench/sites/assets 2>/dev/null || true
    docker compose -f "${COMPOSE_FILE}" cp "${SCRIPT_DIR}/asset_sync_temp/." frontend:/home/frappe/frappe-bench/sites/assets/ 2>/dev/null || true
    docker compose -f "${COMPOSE_FILE}" exec -T -u root frontend chown -R 101:101 /home/frappe/frappe-bench/sites/assets 2>/dev/null || true
    
    # Inject into Frontend (Fallback)
    docker compose -f "${COMPOSE_FILE}" exec -T -u root frontend rm -rf /usr/share/nginx/html/assets 2>/dev/null || true
    docker compose -f "${COMPOSE_FILE}" exec -T -u root frontend mkdir -p /usr/share/nginx/html/assets 2>/dev/null || true
    docker compose -f "${COMPOSE_FILE}" cp "${SCRIPT_DIR}/asset_sync_temp/." frontend:/usr/share/nginx/html/assets/ 2>/dev/null || true
    docker compose -f "${COMPOSE_FILE}" exec -T -u root frontend chown -R 101:101 /usr/share/nginx/html/assets 2>/dev/null || true
    
    rm -rf "${SCRIPT_DIR}/asset_sync_temp" 2>/dev/null || true

    # Final site cache clear
    docker compose -f "${COMPOSE_FILE}" exec -T backend bench --site "${SITE_NAME}" clear-cache 2>&1 | tee -a "${LOG_FILE}"
}

verify_update() {
    log_info "Verifying update..."
    
    # Wait for all services
    if ! wait_for_backend_health 60; then
        log_error "Backend unhealthy after update"
        return 1
    fi
    
    # Comprehensive health check
    if ! check_services_comprehensive; then
        log_warn "Some services may have issues - verify manually"
    fi
    
    # List installed apps and versions
    log_info "Installed apps and versions:"
    docker compose -f "${COMPOSE_FILE}" exec -T backend \
        bench version 2>/dev/null | tee -a "${LOG_FILE}" || echo "Version check failed"
    
    log_success "Update verification completed"
    return 0
}

# -----------------------------------------------------------------------------
# Application Rollback (NOT full database rollback)
# -----------------------------------------------------------------------------
application_rollback() {
    log_warn "=========================================="
    log_warn "INITIATING APPLICATION ROLLBACK"
    log_warn "=========================================="
    log_error "⚠️  THIS ONLY REVERTS THE DOCKER IMAGE"
    log_error "⚠️  DATABASE SCHEMA CHANGES ARE NOT REVERSED"
    log_error "⚠️  IF MIGRATION RAN, MANUAL DB RESTORE IS REQUIRED"
    log_warn "=========================================="
    
    # Revert to previous version
    if [[ -n "${PREVIOUS_VERSION}" ]]; then
        log_info "Reverting to previous image version: ${PREVIOUS_VERSION}"
        
        if grep -q "ERPNEXT_VERSION=" "${SCRIPT_DIR}/.env" 2>/dev/null; then
            sed -i "s/ERPNEXT_VERSION=.*/ERPNEXT_VERSION=${PREVIOUS_VERSION}/" "${SCRIPT_DIR}/.env"
        fi
        
        docker compose -f "${COMPOSE_FILE}" up -d --force-recreate 2>&1 | tee -a "${LOG_FILE}" || true
    fi
    
    # Explicit instructions for database restore
    if [[ "${MIGRATION_STARTED}" == "true" ]]; then
        echo ""
        echo "=========================================="
        echo "DATABASE RESTORE REQUIRED"
        echo "=========================================="
        echo ""
        echo "The database migration was started and may have modified the schema."
        echo "To fully restore to pre-update state:"
        echo ""
        echo "1. Get your backup file:"
        if [[ -n "${BACKUP_CREATED}" && "${BACKUP_CREATED}" != "bench-backup"* ]]; then
            echo "   ${BACKUP_CREATED}"
        else
            echo "   ls -la ${BACKUP_DIR}/daily/"
        fi
        echo ""
        echo "2. Extract the SQL file:"
        echo "   tar -xzf backup.tar.gz"
        echo ""
        echo "3. Restore the database:"
        echo "   docker compose exec backend bench --site ${SITE_NAME} restore SQL_FILE.sql.gz --force"
        echo ""
        echo "4. Restart services:"
        echo "   docker compose restart"
        echo ""
        echo "=========================================="
    fi
    
    APPLICATION_ROLLBACK_NEEDED=false
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
show_usage() {
    echo "Usage: $0 [OPTIONS] [VERSION]"
    echo ""
    echo "Update ERPNext with minimal downtime and explicit rollback limitations."
    echo ""
    echo "⚠️  IMPORTANT: Database migrations are NOT automatically reversible."
    echo "    If migration fails, manual database restore from backup is required."
    echo ""
    echo "Installed Apps (in order):"
    echo "  1. ERPNext"
    echo "  2. Frappe Payments"
    echo "  3. Frappe HRMS"
    echo "  4. Frappe Healthcare (Marley)"
    echo "  5. Frappe Telephony"
    echo "  6. Frappe Helpdesk"
    echo "  7. Frappe Insights"
    echo "  8. ZATCA e-invoicing"
    echo ""
    echo "Options:"
    echo "  -f, --force     Skip confirmation prompts"
    echo "  -h, --help      Show this help message"
    echo "  --rebuild       Force image rebuild even if version exists"
    echo "  --no-backup     Skip pre-update backup (NOT RECOMMENDED)"
    echo ""
    echo "Examples:"
    echo "  $0 v15-20231219              # Update with date-based version"
    echo "  $0 --rebuild v15-20231219    # Rebuild image and update"
    echo "  $0                           # Auto-generate version tag"
    echo ""
}

main() {
    local force_rebuild=false
    local skip_backup=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--force)
                FORCE=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            --rebuild)
                force_rebuild=true
                shift
                ;;
            --no-backup)
                skip_backup=true
                shift
                ;;
            -*)
                echo "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                NEW_VERSION="$1"
                shift
                ;;
        esac
    done
    
    # FIX: Use date-based version for audit clarity
    if [[ -z "${NEW_VERSION}" ]]; then
        NEW_VERSION="v15-$(date +%Y%m%d)"
    fi
    
    log_info "=========================================="
    log_info "ERPNext Update Script"
    log_info "Site: ${SITE_NAME}"
    log_info "Current Version: ${PREVIOUS_VERSION}"
    log_info "Target Version: ${NEW_VERSION}"
    log_info "=========================================="
    log_warn ""
    log_warn "⚠️  DATABASE MIGRATIONS ARE NOT AUTOMATICALLY REVERSIBLE"
    log_warn "    Manual restore from backup required if migration fails"
    log_warn ""
    
    # Confirmation
    if ! confirm_action "Proceed with update to ${NEW_VERSION}?"; then
        log_info "Update cancelled by user"
        exit 0
    fi
    
    # Step 1: Create backup FIRST
    if [[ "${skip_backup}" != "true" ]]; then
        create_pre_update_backup || exit 1
    else
        log_warn "Skipping backup as requested (--no-backup)"
        log_error "THIS IS EXTREMELY RISKY FOR PRODUCTION SYSTEMS"
    fi
    
    # Step 2: Build image BEFORE maintenance mode (minimizes downtime)
    if [[ "${force_rebuild}" == "true" ]] || ! docker image inspect "${IMAGE_NAME}:${NEW_VERSION}" >/dev/null 2>&1; then
        rebuild_image "${NEW_VERSION}" || exit 1
    else
        log_info "Image ${IMAGE_NAME}:${NEW_VERSION} already exists, skipping build"
    fi
    
    # Step 3: NOW enable maintenance mode (site was up during build)
    enable_maintenance
    
    # Step 4: Update services
    APPLICATION_ROLLBACK_NEEDED=true
    update_services "${NEW_VERSION}" || exit 1
    
    # Step 5: Verify update
    if verify_update; then
        APPLICATION_ROLLBACK_NEEDED=false
        disable_maintenance
        
        log_success "=========================================="
        log_success "UPDATE COMPLETED SUCCESSFULLY"
        log_success "New Version: ${NEW_VERSION}"
        log_success "=========================================="
    else
        log_error "Update verification failed"
        exit 1
    fi
}

main "$@"
