#!/bin/bash
set -e

# =============================================================================
# ERPNext + Healthcare + HRMS + Helpdesk + ZATCA Production Deployment
# =============================================================================
# This script deploys a complete ERPNext installation with:
# - ERPNext (Core ERP)
# - Frappe Payments (Payment Gateway Integration)
# - Frappe HRMS (Human Resources)
# - Frappe Healthcare (Marley)
# - Frappe Telephony (Call Management)
# - Frappe Helpdesk (Support Tickets)
# - Frappe Insights (Business Intelligence)
# - ZATCA e-invoicing (Saudi Arabia)
# =============================================================================

# CONFIGURATION
DEPLOY_DIR="/opt/erpnext"
IMAGE_NAME="erpnext-healthcare"
IMAGE_TAG="v15-healthcare"
DB_ROOT_PASSWORD="SecureRootPassword456!"
ADMIN_PASSWORD="admin123"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# =============================================================================
# INSTALL DOCKER
# =============================================================================
install_docker() {
    if command -v docker &> /dev/null; then
        success "Docker already installed"
        return 0
    fi
    
    log "Installing Docker..."
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl start docker
    systemctl enable docker
    success "Docker installed"
}

# =============================================================================
# SETUP FIREWALL
# =============================================================================
setup_firewall() {
    log "Configuring firewall..."
    if ! ufw status | grep -q "Status: active"; then
        ufw --force enable
    fi
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 8080/tcp
    ufw reload
    success "Firewall configured"
}

# =============================================================================
# BUILD CUSTOM IMAGE
# =============================================================================
build_image() {
    log "Building custom image..."
    
    mkdir -p "${DEPLOY_DIR}" && cd "${DEPLOY_DIR}"
    rm -rf frappe_docker 2>/dev/null || true
    
    git clone --depth 1 https://github.com/frappe/frappe_docker.git
    
    # Create Containerfile with all apps
    # Installation order: payments -> hrms -> healthcare -> telephony -> helpdesk -> zatca
    cat > "${DEPLOY_DIR}/frappe_docker/Containerfile" << 'EOF'
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
RUN bench get-app --skip-assets --branch=main telehealth_platform https://github.com/techWassal/telehealth-frappe-platform
EOF

    cd "${DEPLOY_DIR}/frappe_docker"
    docker build --no-cache --tag "${IMAGE_NAME}:${IMAGE_TAG}" --file Containerfile .
    
    success "Image built"
}

# =============================================================================
# CREATE DOCKER COMPOSE
# =============================================================================
create_docker_compose() {
    log "Creating docker-compose.yml..."
    
    cat > "${DEPLOY_DIR}/docker-compose.yml" << 'EOF'
services:
  backend:
    image: erpnext-healthcare:\${ERPNEXT_VERSION}
    restart: on-failure
    volumes: [sites:/home/frappe/frappe-bench/sites, logs:/home/frappe/frappe-bench/logs]

  configurator:
    image: erpnext-healthcare:\${ERPNEXT_VERSION}
    restart: "no"
    entrypoint: ["bash", "-c"]
    command:
      - >
        ls -1 apps > sites/apps.txt;
        bench set-config -g db_host $$DB_HOST;
        bench set-config -gp db_port $$DB_PORT;
        bench set-config -g redis_cache "redis://$$REDIS_CACHE";
        bench set-config -g redis_queue "redis://$$REDIS_QUEUE";
        bench set-config -g redis_socketio "redis://$$REDIS_QUEUE";
        bench set-config -gp socketio_port $$SOCKETIO_PORT;
    environment:
      DB_HOST: db
      DB_PORT: "3306"
      REDIS_CACHE: redis-cache:6379
      REDIS_QUEUE: redis-queue:6379
      SOCKETIO_PORT: "9000"
    volumes: [sites:/home/frappe/frappe-bench/sites]

  create-site:
    image: erpnext-healthcare:\${ERPNEXT_VERSION}
    restart: "no"
    volumes: [sites:/home/frappe/frappe-bench/sites]
    entrypoint: ["bash", "-c"]
    command:
      - >
        wait-for-it -t 120 db:3306;
        wait-for-it -t 120 redis-cache:6379;
        wait-for-it -t 120 redis-queue:6379;
        until [[ -n `grep -hs ^ sites/common_site_config.json | jq -r ".db_host // empty"` ]]; do sleep 5; done;
        bench new-site --mariadb-root-password=SecureRootPassword456! --admin-password=admin123 --install-app erpnext --install-app payments --install-app hrms --install-app healthcare --install-app telephony --install-app helpdesk --install-app insights --install-app zatca_erpgulf --install-app telehealth_platform frontend || true;

  db:
    image: mariadb:10.6
    restart: on-failure
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --skip-character-set-client-handshake
      - --skip-innodb-read-only-compressed
    environment:
      MYSQL_ROOT_PASSWORD: "SecureRootPassword456!"
    volumes: [db-data:/var/lib/mysql]

  frontend:
    image: erpnext-healthcare:\${ERPNEXT_VERSION}
    restart: on-failure
    command: ["nginx-entrypoint.sh"]
    environment:
      BACKEND: backend:8000
      FRAPPE_SITE_NAME_HEADER: frontend
      SOCKETIO: websocket:9000
    volumes: [sites:/home/frappe/frappe-bench/sites]
    ports: ["8080:8080"]

  queue-long:
    image: erpnext-healthcare:\${ERPNEXT_VERSION}
    restart: on-failure
    command: ["bench", "worker", "--queue", "long,default,short"]
    volumes: [sites:/home/frappe/frappe-bench/sites, logs:/home/frappe/frappe-bench/logs]

  scheduler:
    image: erpnext-healthcare:\${ERPNEXT_VERSION}
    restart: on-failure
    command: ["bench", "schedule"]
    volumes: [sites:/home/frappe/frappe-bench/sites, logs:/home/frappe/frappe-bench/logs]

  redis-cache:
    image: redis:6.2-alpine
    restart: on-failure

  redis-queue:
    image: redis:6.2-alpine
    restart: on-failure

  websocket:
    image: erpnext-healthcare:\${ERPNEXT_VERSION}
    restart: on-failure
    command: ["node", "/home/frappe/frappe-bench/apps/frappe/socketio.js"]
    volumes: [sites:/home/frappe/frappe-bench/sites]

volumes:
  db-data:
  sites:
  logs:
EOF
    
    success "docker-compose.yml created"
}

# =============================================================================
# DEPLOY SERVICES
# =============================================================================
deploy_services() {
    log "Deploying services..."
    
    cd "${DEPLOY_DIR}"
    docker compose down -v 2>/dev/null || true
    docker compose up -d
    
    log "Waiting for site creation (this takes 5-10 minutes)..."
    
    local timeout=600
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if docker compose logs create-site 2>&1 | grep -q "Scheduler is disabled\|exited with code 0"; then
            success "Site creation completed"
            break
        fi
        sleep 15
        elapsed=$((elapsed + 15))
        log "Still waiting... (${elapsed}s/${timeout}s)"
    done
    
    success "Services deployed"
}

# =============================================================================
# FIX DATABASE CREDENTIALS
# =============================================================================
fix_database_credentials() {
    log "Fixing database credentials..."
    
    cd "${DEPLOY_DIR}"
    sleep 10
    
    # Get the generated DB name from site_config
    local db_name=$(docker compose exec backend cat /home/frappe/frappe-bench/sites/frontend/site_config.json 2>/dev/null | grep -o '"db_name": "[^"]*"' | cut -d'"' -f4)
    
    if [[ -n "$db_name" ]]; then
        log "Found database: $db_name"
        
        # Drop all existing users and recreate with correct password
        docker compose exec db mysql -uroot -p${DB_ROOT_PASSWORD} -e "
            DROP USER IF EXISTS '${db_name}'@'%';
            DROP USER IF EXISTS '${db_name}'@'localhost';
            CREATE USER '${db_name}'@'%' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
            GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_name}'@'%';
            FLUSH PRIVILEGES;
        " 2>/dev/null || true
        
        # Update site_config with matching password
        docker compose exec backend bash -c "echo '{\"db_name\": \"${db_name}\", \"db_password\": \"${DB_ROOT_PASSWORD}\", \"db_type\": \"mariadb\", \"db_host\": \"db\"}' > /home/frappe/frappe-bench/sites/frontend/site_config.json"
        
        # Set default site using recommended method
        docker compose exec backend bench use frontend
        
        docker compose restart backend
        sleep 10
    fi
    
    success "Database credentials fixed"
}

# =============================================================================
fix_assets() {
    log "Fixing assets with Force-Sync (Host-Mediated)..."
    
    cd "${DEPLOY_DIR}"
    
    # 1. Regenerate assets to ensure they exist
    log "Regenerating assets..."
    docker compose exec backend bench build --production --force 2>/dev/null || true
    
    # 2. Resolve symlinks in Backend (Content Swap)
    log "Resolving backend symlinks..."
    docker compose exec -u root backend bash -c "
        cd /home/frappe/frappe-bench/sites/ && \
        if [ -L assets ]; then 
            cp -rL assets assets_resolved
            rm assets
            mv assets_resolved assets
        else
            # Even if not a symlink, ensure contents are real files
            rm -rf assets_real && \
            mkdir -p assets_real && \
            cp -rL assets/* assets_real/ && \
            rm -rf assets/* && \
            cp -r assets_real/* assets/ && \
            rm -rf assets_real
        fi && \
        chown -R 1000:1000 assets
    " 2>/dev/null || true
    
    # 3. Extract to Host (Bypassing Volume Issues)
    log "Extracting assets to host..."
    rm -rf ./asset_sync_temp
    docker compose cp backend:/home/frappe/frappe-bench/sites/assets/. ./asset_sync_temp 2>/dev/null || true
    
    # 4. Inject into Frontend (Both paths)
    log "Injecting assets into Frontend..."
    
    # Path A: Nginx Root
    docker compose exec -u root frontend rm -rf /home/frappe/frappe-bench/sites/assets 2>/dev/null || true
    docker compose exec -u root frontend mkdir -p /home/frappe/frappe-bench/sites/assets 2>/dev/null || true
    docker compose cp ./asset_sync_temp/. frontend:/home/frappe/frappe-bench/sites/assets/ 2>/dev/null || true
    docker compose exec -u root frontend chown -R 101:101 /home/frappe/frappe-bench/sites/assets 2>/dev/null || true
    
    # Path B: Fallback
    docker compose exec -u root frontend rm -rf /usr/share/nginx/html/assets 2>/dev/null || true
    docker compose exec -u root frontend mkdir -p /usr/share/nginx/html/assets 2>/dev/null || true
    docker compose cp ./asset_sync_temp/. frontend:/usr/share/nginx/html/assets/ 2>/dev/null || true
    docker compose exec -u root frontend chown -R 101:101 /usr/share/nginx/html/assets 2>/dev/null || true
    
    # Cleanup
    rm -rf ./asset_sync_temp
    
    # 5. Refresh Cache
    docker compose exec backend bench --site frontend clear-cache 2>/dev/null || true
    
    success "Assets force-synced via host"
}

# =============================================================================
# BUILD FRONTEND APPS
# =============================================================================
build_frontend_apps() {
    log "Building frontend applications (Helpdesk & Insights)..."
    
    cd "${DEPLOY_DIR}"
    # Build core assets first to be safe
    docker compose exec backend bench build --production 2>/dev/null || true
    # Build specific apps
    docker compose exec backend bench --site frontend build --app helpdesk 2>/dev/null || true
    docker compose exec backend bench --site frontend build --app insights 2>/dev/null || true
    
    # Re-sync assets after app builds
    fix_assets
    
    success "Frontend apps built"
}

# =============================================================================
# SET ADMIN PASSWORD
# =============================================================================
set_admin_password() {
    log "Setting admin password..."
    
    cd "${DEPLOY_DIR}"
    docker compose exec backend bench --site frontend set-admin-password ${ADMIN_PASSWORD} 2>/dev/null || true
    
    success "Admin password set"
}

# =============================================================================
# PRINT SUMMARY
# =============================================================================
print_summary() {
    local server_ip=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    
    echo ""
    echo "============================================================================="
    echo -e "${GREEN}ERPNext Deployment Complete!${NC}"
    echo "============================================================================="
    echo ""
    echo "Access your ERPNext instance:"
    echo "  URL: http://${server_ip}:8080"
    echo ""
    echo "Login credentials:"
    echo "  Username: Administrator"
    echo "  Password: ${ADMIN_PASSWORD}"
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
    echo "  9. Telehealth Platform"
    echo ""
    echo "IMPORTANT: Change the admin password immediately!"
    echo ""
    echo "Useful commands:"
    echo "  cd ${DEPLOY_DIR}"
    echo "  docker compose ps"
    echo "  docker compose logs -f"
    echo "  docker compose restart"
    echo "============================================================================="
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    echo ""
    echo "============================================================================="
    echo "ERPNext + Healthcare + HRMS + Helpdesk + Insights + ZATCA"
    echo "============================================================================="
    echo ""
    
    install_docker
    setup_firewall
    build_image
    create_docker_compose
    deploy_services
    fix_database_credentials
    fix_assets
    build_frontend_apps
    set_admin_password
    print_summary
}

main "$@"
