# ERPNext + Healthcare Docker Deployment

Production-ready deployment of ERPNext with multiple Frappe apps on Ubuntu 22.04.

## Installed Apps (in order)

| Order | App | Description | Branch |
|-------|-----|-------------|--------|
| 1 | ERPNext | Core ERP System | version-15 |
| 2 | Frappe Payments | Payment Gateway Integration | version-15 |
| 3 | Frappe HRMS | Human Resource Management | version-15 |
| 4 | Frappe Healthcare (Marley) | Healthcare Module | version-15 |
| 5 | Frappe Telephony | Call Management | develop |
| 6 | Frappe Helpdesk | Support Ticket System | main |
| 7 | Frappe Insights | Business Intelligence | main |
| 8 | ZATCA e-invoicing | Saudi Arabia e-invoicing | main |
| 9 | Telehealth Platform | Core Telehealth Functionality | main |

## Quick Start

```bash
# On a fresh Ubuntu 22.04 server
git clone <this-repo> /opt/erpnext
cd /opt/erpnext
chmod +x deploy_erpnext.sh
sudo ./deploy_erpnext.sh
```

The script will:
1. Install Docker
2. Configure firewall
3. Build custom image with all 7 apps
4. Deploy all services
5. Fix database credentials
6. Build Helpdesk frontend
7. Set admin password

**Access:** `http://YOUR_SERVER_IP:8080`  
**Login:** `Administrator` / `admin123`

## Requirements

- Ubuntu 22.04 LTS
- Minimum 4GB RAM, 2 CPUs, 40GB disk
- Root access

## Files Included

| File | Description |
|------|-------------|
| `deploy_erpnext.sh` | Automated deployment script |
| `docker-compose.yml` | Production docker-compose with all services |
| `apps.json` | All 7 apps configuration |
| `backup_script.sh` | Automated backup with rotation and S3 sync |
| `update_erpnext.sh` | Safe update with explicit rollback limitations |
| `troubleshooting_decision_tree.md` | Common issues and solutions |
| `.env.example` | Environment variables template |

---

## Backup Script

### Features
- Database and site files backup with `--compress` for consistency
- Proper backup file collection from container
- Rotation policy (daily, weekly, monthly)
- Date-based S3 structure: `s3://bucket/site-name/YYYY/MM/`
- Backup verification and restore testing

### Commands

```bash
cd /opt/erpnext

# Create backups
./backup_script.sh daily      # Daily backup (default)
./backup_script.sh weekly     # Weekly backup
./backup_script.sh monthly    # Monthly backup

# Manage backups
./backup_script.sh list       # List all backups
./backup_script.sh verify FILE    # Verify backup integrity
./backup_script.sh test-restore FILE  # Test restore to staging

# Cleanup
./backup_script.sh rotate     # Rotate old backups
```

### Healthcare Compliance Note

For healthcare/HIPAA compliance, periodically run `test-restore` to verify backup recoverability:

```bash
./backup_script.sh test-restore /opt/erpnext-backups/daily/latest.tar.gz
```

---

## Update Script

### ⚠️ IMPORTANT: Database Migrations Are NOT Automatically Reversible

The update script can revert the Docker image, but **database schema changes require manual restore from backup** if migration fails.

### Features
- Image build BEFORE maintenance mode (minimizes downtime)
- Comprehensive health checks (`bench doctor`, `list-apps`)
- Date-based version tags for audit clarity
- Explicit rollback limitations documented
- No runtime `bench build` (assets built at image time)

### Usage

```bash
cd /opt/erpnext

# Update with auto-generated version
./update_erpnext.sh

# Update with specific version
./update_erpnext.sh v15-20231219

# Force rebuild
./update_erpnext.sh --rebuild v15-20231219

# Skip prompts (CI/CD)
./update_erpnext.sh -f v15-20231219
```

### Update Order (Minimal Downtime)

1. **Backup created** (site still accessible)
2. **Image built** (site still accessible, ~30 min)
3. **Maintenance mode ON** (downtime starts)
4. **Containers updated**
5. **Database migrated**
6. **Health verified**
7. **Maintenance mode OFF** (downtime ends)

### If Migration Fails

The script will output explicit restore instructions:

```bash
# 1. Extract backup
tar -xzf /opt/erpnext-backups/daily/backup.tar.gz

# 2. Restore database
docker compose exec backend bench --site frontend restore SQL_FILE.sql.gz --force

# 3. Restart
docker compose restart
```

---

## Common Commands

```bash
cd /opt/erpnext

# Status
docker compose ps

# Logs
docker compose logs -f backend
docker compose logs backend --tail 30

# Restart
docker compose restart

# Stop
docker compose down

# Full reset (DESTRUCTIVE)
docker compose down -v
```

### Bench Commands

```bash
# Clear cache
docker compose exec backend bench --site frontend clear-cache

# Migrate
docker compose exec backend bench --site frontend migrate

# Backup
docker compose exec backend bench --site frontend backup --with-files --compress

# Reset password
docker compose exec backend bench --site frontend set-admin-password NewPassword123

# Build Helpdesk (if needed)
docker compose exec backend bench --site frontend build --app helpdesk

# Check health
docker compose exec backend bench doctor
docker compose exec backend bench --site frontend list-apps
```

---

## Troubleshooting

### Internal Server Error (500)

```bash
docker compose logs backend --tail 30
```

### 502 Bad Gateway

```bash
docker compose restart
sleep 20
```

### Database Access Denied

```bash
# Get db_name
DB_NAME=$(docker compose exec backend cat /home/frappe/frappe-bench/sites/frontend/site_config.json | grep -o '"db_name": "[^"]*"' | cut -d'"' -f4)

# Fix credentials
docker compose exec db mysql -uroot -pSecureRootPassword456! -e "
DROP USER IF EXISTS '${DB_NAME}'@'%';
CREATE USER '${DB_NAME}'@'%' IDENTIFIED BY 'SecureRootPassword456!';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_NAME}'@'%';
FLUSH PRIVILEGES;
"

docker compose restart backend
```

### Helpdesk Not Loading

```bash
docker compose exec backend bench --site frontend build --app helpdesk

# Fix assets
docker compose exec frontend rm -rf /usr/share/nginx/html/assets
docker compose exec backend bash -c "mkdir -p /tmp/asset && cp -rL /home/frappe/frappe-bench/sites/assets/* /tmp/asset/"
docker compose cp backend:/tmp/asset ./asset
docker compose cp ./asset frontend:/usr/share/nginx/html/assets
rm -rf ./asset
docker compose restart frontend
```

### Nuclear Reset (Last Resort)

```bash
cd /opt/erpnext
docker compose down -v
docker rm -f $(docker ps -aq) 2>/dev/null || true
docker volume rm $(docker volume ls -q | grep erpnext) 2>/dev/null || true
./deploy_erpnext.sh
```

---

## Security Notes

⚠️ **Change default passwords immediately after deployment!**

1. Change admin password in ERPNext UI
2. Update `MYSQL_ROOT_PASSWORD` in docker-compose.yml
3. Configure SSL/HTTPS for production

---

## Versions

| Component | Version |
|-----------|---------|
| Frappe Framework | version-15 |
| ERPNext | version-15 |
| Healthcare (Marley) | version-15 |
| Frappe HRMS | version-15 |
| Frappe Payments | version-15 |
| Frappe Telephony | develop |
| Frappe Helpdesk | main |
| Frappe Insights | main |
| ZATCA | main |
| MariaDB | 10.6 |
| Redis | 6.2-alpine |

---

## Resources

- **Frappe Documentation**: https://frappeframework.com/docs
- **ERPNext Documentation**: https://docs.erpnext.com
- **ERPNext Community Forum**: https://discuss.frappe.io
- **Healthcare Module**: https://marleyhealth.io/docs
