#!/bin/bash
# =============================================================================
# ERPNext + Healthcare + HRMS + Helpdesk + ZATCA Automated Backup Script
# =============================================================================
# Features:
#   - Database and site files backup with compression
#   - Proper backup file collection from container
#   - Rotation policy (daily, weekly, monthly)
#   - Backup verification
#   - Off-site sync (optional S3 with date-based structure)
#   - Logging with timestamps
#   - Email notification on failure
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration - Edit these or source from .env
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/.env" 2>/dev/null || true

# Backup settings
BACKUP_DIR="${BACKUP_DIR:-/opt/erpnext-backups}"
SITE_NAME="${SITE_NAME:-frontend}"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"

# Retention settings
RETENTION_DAILY="${BACKUP_RETENTION_DAILY:-7}"
RETENTION_WEEKLY="${BACKUP_RETENTION_WEEKLY:-4}"
RETENTION_MONTHLY="${BACKUP_RETENTION_MONTHLY:-3}"

# Notification settings
NOTIFY_EMAIL="${BACKUP_NOTIFY_EMAIL:-}"
NOTIFY_ON_SUCCESS="${BACKUP_NOTIFY_SUCCESS:-false}"

# S3 settings (optional)
S3_ENABLED="${S3_ENABLED:-false}"
S3_BUCKET="${S3_BUCKET:-}"
S3_ENDPOINT="${S3_ENDPOINT:-}"

# -----------------------------------------------------------------------------
# Logging Functions
# -----------------------------------------------------------------------------
LOG_FILE="${BACKUP_DIR}/backup.log"

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
# Notification Function
# -----------------------------------------------------------------------------
send_notification() {
    local subject="$1"
    local body="$2"
    local is_error="${3:-false}"

    if [[ -n "${NOTIFY_EMAIL}" ]]; then
        if [[ "${is_error}" == "true" ]] || [[ "${NOTIFY_ON_SUCCESS}" == "true" ]]; then
            echo "${body}" | mail -s "${subject}" "${NOTIFY_EMAIL}" 2>/dev/null || \
                log_warn "Failed to send email notification"
        fi
    fi
}

# -----------------------------------------------------------------------------
# Pre-flight Checks
# -----------------------------------------------------------------------------
preflight_checks() {
    log_info "Running pre-flight checks..."

    # Check if running as root or with sudo
    if [[ $EUID -ne 0 ]] && ! groups | grep -q docker; then
        log_error "Script must be run as root or by a user in the docker group"
        exit 1
    fi

    # Create backup directory if it doesn't exist
    mkdir -p "${BACKUP_DIR}"/{daily,weekly,monthly}

    # Ensure log file exists
    touch "${LOG_FILE}"

    # Check disk space (require at least 10GB free)
    local free_space
    free_space=$(df -BG "${BACKUP_DIR}" | awk 'NR==2 {print $4}' | tr -d 'G')
    if [[ ${free_space} -lt 10 ]]; then
        log_error "Insufficient disk space: ${free_space}GB available, 10GB required"
        send_notification "ERPNext Backup FAILED" "Insufficient disk space for backup" "true"
        exit 1
    fi

    # Check if Docker is running
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker is not running"
        send_notification "ERPNext Backup FAILED" "Docker is not running" "true"
        exit 1
    fi

    # Check if containers are running
    if ! docker compose -f "${COMPOSE_FILE}" ps --status running | grep -q backend; then
        log_warn "Backend container is not running, backup may fail"
    fi

    log_info "Pre-flight checks passed"
}

# -----------------------------------------------------------------------------
# Backup Functions
# -----------------------------------------------------------------------------
create_backup() {
    local backup_type="$1"
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_name="${SITE_NAME}_${timestamp}"
    local backup_path="${BACKUP_DIR}/${backup_type}/${backup_name}"

    log_info "Creating ${backup_type} backup: ${backup_name}"

    mkdir -p "${backup_path}"

    # Clear old backups in container first to avoid confusion
    log_info "Clearing old backup files in container..."
    docker compose -f "${COMPOSE_FILE}" exec -T backend \
        rm -rf /home/frappe/frappe-bench/sites/${SITE_NAME}/private/backups/* 2>/dev/null || true

    # Create database backup using bench with compression
    # Using --compress for faster backup and reduced risk of partial file states
    log_info "Backing up database with compression..."
    if ! docker compose -f "${COMPOSE_FILE}" exec -T backend \
        bench --site "${SITE_NAME}" backup --with-files --compress 2>&1 | tee -a "${LOG_FILE}"; then
        log_error "Database backup failed"
        return 1
    fi

    # FIX: Always copy the full backups directory (files, not directories)
    log_info "Copying backup files from container..."
    if ! docker compose -f "${COMPOSE_FILE}" cp \
        backend:/home/frappe/frappe-bench/sites/${SITE_NAME}/private/backups \
        "${backup_path}/" 2>&1 | tee -a "${LOG_FILE}"; then
        log_error "Failed to copy backup files from container"
        return 1
    fi

    # Verify backup files exist
    local backup_count
    backup_count=$(find "${backup_path}/backups" -type f \( -name "*.sql.gz" -o -name "*.tar" -o -name "*.gz" \) 2>/dev/null | wc -l)
    if [[ ${backup_count} -eq 0 ]]; then
        log_error "No backup files found in ${backup_path}/backups"
        return 1
    fi
    log_info "Found ${backup_count} backup files"

    # Also backup site config
    log_info "Backing up site configuration..."
    docker compose -f "${COMPOSE_FILE}" cp \
        backend:/home/frappe/frappe-bench/sites/${SITE_NAME}/site_config.json \
        "${backup_path}/" 2>/dev/null || true

    # Copy common_site_config
    docker compose -f "${COMPOSE_FILE}" cp \
        backend:/home/frappe/frappe-bench/sites/common_site_config.json \
        "${backup_path}/" 2>/dev/null || true

    # Create tarball
    log_info "Creating compressed archive..."
    cd "${BACKUP_DIR}/${backup_type}"
    tar -czf "${backup_name}.tar.gz" "${backup_name}"
    rm -rf "${backup_name}"

    # Verify backup
    if verify_backup "${BACKUP_DIR}/${backup_type}/${backup_name}.tar.gz"; then
        log_success "Backup created successfully: ${BACKUP_DIR}/${backup_type}/${backup_name}.tar.gz"
        echo "${BACKUP_DIR}/${backup_type}/${backup_name}.tar.gz"
        return 0
    else
        log_error "Backup verification failed"
        return 1
    fi
}

verify_backup() {
    local backup_file="$1"

    log_info "Verifying backup integrity..."

    # Check file exists and has size > 0
    if [[ ! -s "${backup_file}" ]]; then
        log_error "Backup file is empty or does not exist: ${backup_file}"
        return 1
    fi

    # Verify tarball integrity
    if ! tar -tzf "${backup_file}" >/dev/null 2>&1; then
        log_error "Backup archive is corrupted: ${backup_file}"
        return 1
    fi

    # Check that backup contains expected files
    local sql_count
    sql_count=$(tar -tzf "${backup_file}" 2>/dev/null | grep -c "\.sql\.gz$" || true)
    if [[ ${sql_count} -eq 0 ]]; then
        log_warn "Backup does not contain .sql.gz file - verify manually"
    else
        log_info "Found ${sql_count} database backup file(s)"
    fi

    local size
    size=$(du -h "${backup_file}" | cut -f1)
    log_info "Backup verified: ${backup_file} (${size})"

    # NOTE: This verifies integrity but NOT recoverability
    # For healthcare/compliance systems, periodically test restore to staging

    return 0
}

# -----------------------------------------------------------------------------
# Restore Test (for compliance-sensitive systems)
# -----------------------------------------------------------------------------
test_restore() {
    local backup_file="$1"
    local test_site="${2:-test-restore}"

    log_info "Testing restore to site: ${test_site}"
    log_warn "This is a destructive operation for ${test_site}"

    # Extract backup
    local temp_dir
    temp_dir=$(mktemp -d)
    tar -xzf "${backup_file}" -C "${temp_dir}"

    # Find the SQL file
    local sql_file
    sql_file=$(find "${temp_dir}" -name "*.sql.gz" | head -1)

    if [[ -z "${sql_file}" ]]; then
        log_error "No SQL file found in backup"
        rm -rf "${temp_dir}"
        return 1
    fi

    log_info "SQL file found: ${sql_file}"
    log_info "To complete restore test, run:"
    echo "  1. bench --site ${test_site} restore ${sql_file}"
    echo "  2. Verify data integrity"
    echo "  3. Drop test site when done"

    rm -rf "${temp_dir}"
    return 0
}

# -----------------------------------------------------------------------------
# Rotation Functions
# -----------------------------------------------------------------------------
rotate_backups() {
    log_info "Rotating old backups..."

    # Daily rotation
    find "${BACKUP_DIR}/daily" -name "*.tar.gz" -mtime "+${RETENTION_DAILY}" -delete 2>/dev/null || true
    local daily_count
    daily_count=$(find "${BACKUP_DIR}/daily" -name "*.tar.gz" 2>/dev/null | wc -l)
    log_info "Daily backups retained: ${daily_count}"

    # Weekly rotation
    find "${BACKUP_DIR}/weekly" -name "*.tar.gz" -mtime "+$((RETENTION_WEEKLY * 7))" -delete 2>/dev/null || true
    local weekly_count
    weekly_count=$(find "${BACKUP_DIR}/weekly" -name "*.tar.gz" 2>/dev/null | wc -l)
    log_info "Weekly backups retained: ${weekly_count}"

    # Monthly rotation
    find "${BACKUP_DIR}/monthly" -name "*.tar.gz" -mtime "+$((RETENTION_MONTHLY * 30))" -delete 2>/dev/null || true
    local monthly_count
    monthly_count=$(find "${BACKUP_DIR}/monthly" -name "*.tar.gz" 2>/dev/null | wc -l)
    log_info "Monthly backups retained: ${monthly_count}"
}

promote_backup() {
    local source_dir="$1"
    local target_dir="$2"

    # Get the latest backup from source
    local latest
    latest=$(find "${BACKUP_DIR}/${source_dir}" -name "*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null | \
        sort -n | tail -1 | cut -d' ' -f2-)

    if [[ -n "${latest}" ]]; then
        local filename
        filename=$(basename "${latest}")
        cp "${latest}" "${BACKUP_DIR}/${target_dir}/${filename}"
        log_info "Promoted backup to ${target_dir}: ${filename}"
    fi
}

# -----------------------------------------------------------------------------
# Offsite Sync (S3-compatible with date-based structure)
# -----------------------------------------------------------------------------
sync_to_s3() {
    local backup_file="$1"

    if [[ "${S3_ENABLED}" != "true" ]]; then
        return 0
    fi

    log_info "Syncing backup to S3..."

    if ! command -v rclone &>/dev/null; then
        log_warn "rclone not installed, skipping S3 sync"
        return 0
    fi

    local filename
    filename=$(basename "${backup_file}")
    
    # FIX: Use date-based structure for better organization and compliance
    # Structure: s3://bucket/site-name/YYYY/MM/backup-file
    local year
    year=$(date '+%Y')
    local month
    month=$(date '+%m')
    local s3_path="s3:${S3_BUCKET}/${SITE_NAME}/${year}/${month}/"

    if rclone copy "${backup_file}" "${s3_path}" --progress 2>&1 | tee -a "${LOG_FILE}"; then
        log_success "Backup synced to S3: ${s3_path}${filename}"
    else
        log_error "Failed to sync backup to S3"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# List Backups
# -----------------------------------------------------------------------------
list_backups() {
    echo "=== Daily Backups ==="
    ls -lh "${BACKUP_DIR}/daily"/*.tar.gz 2>/dev/null || echo "No daily backups"
    echo ""
    echo "=== Weekly Backups ==="
    ls -lh "${BACKUP_DIR}/weekly"/*.tar.gz 2>/dev/null || echo "No weekly backups"
    echo ""
    echo "=== Monthly Backups ==="
    ls -lh "${BACKUP_DIR}/monthly"/*.tar.gz 2>/dev/null || echo "No monthly backups"
}

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------
main() {
    local backup_type="${1:-daily}"

    log_info "=========================================="
    log_info "ERPNext Backup Script Started"
    log_info "Type: ${backup_type}"
    log_info "Site: ${SITE_NAME}"
    log_info "Apps: ERPNext, Payments, HRMS, Healthcare, Telephony, Helpdesk, ZATCA"
    log_info "=========================================="

    # Run checks
    preflight_checks

    # Create backup
    local backup_file
    if backup_file=$(create_backup "${backup_type}"); then
        # Rotate old backups
        rotate_backups

        # Weekly promotion (on Sundays)
        if [[ $(date +%u) -eq 7 ]]; then
            promote_backup "daily" "weekly"
        fi

        # Monthly promotion (on 1st of month)
        if [[ $(date +%d) -eq 01 ]]; then
            promote_backup "weekly" "monthly"
        fi

        # Sync to S3
        sync_to_s3 "${backup_file}"

        # Success notification
        local size
        size=$(du -h "${backup_file}" | cut -f1)
        send_notification \
            "ERPNext Backup SUCCESS" \
            "Backup completed successfully.\nFile: ${backup_file}\nSize: ${size}" \
            "false"

        log_success "Backup completed successfully"
        log_info "=========================================="
        exit 0
    else
        send_notification \
            "ERPNext Backup FAILED" \
            "Backup failed. Check logs at ${LOG_FILE}" \
            "true"

        log_error "Backup failed"
        log_info "=========================================="
        exit 1
    fi
}

# Handle script arguments
case "${1:-daily}" in
    daily|weekly|monthly)
        main "$1"
        ;;
    verify)
        if [[ -z "${2:-}" ]]; then
            echo "Usage: $0 verify <backup-file>"
            exit 1
        fi
        verify_backup "$2"
        ;;
    test-restore)
        if [[ -z "${2:-}" ]]; then
            echo "Usage: $0 test-restore <backup-file> [test-site-name]"
            exit 1
        fi
        test_restore "$2" "${3:-test-restore}"
        ;;
    rotate)
        preflight_checks
        rotate_backups
        ;;
    list)
        list_backups
        ;;
    *)
        echo "Usage: $0 {daily|weekly|monthly|verify|test-restore|rotate|list}"
        echo ""
        echo "ERPNext + Healthcare + HRMS + Helpdesk + ZATCA Backup"
        echo ""
        echo "Commands:"
        echo "  daily        - Create a daily backup (default)"
        echo "  weekly       - Create a weekly backup"
        echo "  monthly      - Create a monthly backup"
        echo "  verify FILE  - Verify a backup file integrity"
        echo "  test-restore FILE [SITE] - Test restore to staging site"
        echo "  rotate       - Rotate old backups"
        echo "  list         - List all backups"
        echo ""
        echo "For healthcare/compliance systems, run 'test-restore' periodically"
        exit 1
        ;;
esac
