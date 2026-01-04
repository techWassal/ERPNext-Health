# ERPNext Troubleshooting Decision Tree

> [!TIP]
> **Automated Fixer Available**
> A Python script is available to automate many of these checks and fixes.
> Run: `python3 troubleshoot.py`


## Quick Diagnosis Flowchart

```
Start: Application Not Working?
    │
    ├─► Can you access the URL? ──► NO ──► Check Firewall/Ports
    │                                        └─► ufw status
    │                                        └─► docker ps (check port mappings)
    │
    └─► YES ──► Getting Error Page?
                    │
                    ├─► 502 Bad Gateway ──► Backend Not Ready
                    │                        └─► docker compose logs backend
                    │                        └─► Wait 2-3 minutes
                    │
                    ├─► 503 Service Unavailable ──► Service Down
                    │                                └─► docker compose ps
                    │                                └─► docker compose up -d
                    │
                    ├─► 500 Internal Error ──► Application Error
                    │                           └─► Check backend logs
                    │                           └─► Check database connection
                    │
                    └─► Page loads but broken CSS ──► Asset Issue
                                                      └─► bench build
                                                      └─► Clear browser cache
```

---

## Installed Apps (Installation Order)

| Order | App | Description | Branch |
|-------|-----|-------------|--------|
| 1 | ERPNext | Core ERP System | version-15 |
| 2 | Frappe Payments | Payment Gateway Integration | version-15 |
| 3 | Frappe HRMS | Human Resource Management | version-15 |
| 4 | Healthcare (Marley) | Healthcare Module | version-15 |
| 5 | Telephony | Call Management | develop |
| 6 | Helpdesk | Support Ticket System | main |
| 7 | Frappe Insights | Business Intelligence & Analytics | main |
| 8 | ZATCA | Saudi Arabia e-invoicing | main |

---

## Common Issues by Category

### 1. Startup/Installation Issues

#### Database Connection Refused

**Symptoms:**
- Error: `Can't connect to MySQL server`
- Backend container keeps restarting

**Diagnosis:**
```bash
# Check database container status
docker compose ps db

# Check database logs
docker compose logs db --tail 100

# Test database connectivity
docker compose exec db mysql -uroot -pSecureRootPassword456!
```

**Solutions:**
1. Database not ready yet - wait 30-60 seconds
2. Wrong password - check `.env` file matches
3. Database corrupted - restore from backup

---

#### Access Denied for Database User

**Symptoms:**
- Error: `Access denied for user '_xxxxx'@'172.x.x.x' (using password: YES)`
- Internal Server Error after deployment

**Diagnosis:**
```bash
# Check what users exist
docker compose exec db mysql -uroot -pSecureRootPassword456! -e "SELECT User, Host FROM mysql.user;"

# Check site config
docker compose exec backend cat /home/frappe/frappe-bench/sites/frontend/site_config.json
```

**Solution (Automated):**
Run `python3 troubleshoot.py` and select **Option 3**. Choose the **[Force]** option to sync credentials to project defaults.

**Solution (Manual Deep Reset):**
If the automated tool fails, run these steps manually to forcefully sync credentials:

1. **Get your DB Name** from `site_config.json`:
   ```bash
   docker compose exec backend cat /home/frappe/frappe-bench/sites/frontend/site_config.json
   ```

2. **Reset the Database User** (Replace `${DB_NAME}` with the name from step 1):
   ```bash
   docker compose exec db mysql -uroot -pSecureRootPassword456! -e "
   DROP USER IF EXISTS '${DB_NAME}'@'%';
   CREATE USER '${DB_NAME}'@'%' IDENTIFIED BY 'SecureRootPassword456!';
   GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_NAME}'@'%';
   FLUSH PRIVILEGES;
   "
   ```

3. **Force Update `site_config.json`**:
   ```bash
   docker compose exec backend bash -c "echo '{\"db_name\": \"${DB_NAME}\", \"db_password\": \"SecureRootPassword456!\", \"db_type\": \"mariadb\", \"db_host\": \"db\"}' > /home/frappe/frappe-bench/sites/frontend/site_config.json"
   ```

4. **Restart core services**:
   ```bash
   docker compose restart backend
   ```

---

#### Site Creation Fails

**Symptoms:**
- Error during `bench new-site`
- `Access denied for user 'root'`

**Diagnosis:**
```bash
# Check if database is accessible
docker compose exec backend bench mariadb

# Verify site config
docker compose exec backend cat sites/common_site_config.json
```

**Solutions:**
1. Verify `DB_ROOT_PASSWORD` in `.env`
2. Check database is healthy: `docker compose exec db healthcheck.sh --connect`
3. Ensure sites volume is writable

---

#### Permission Denied on Volumes

**Symptoms:**
- Errors about file permissions
- Cannot write to `/home/frappe/frappe-bench/sites`

**Solutions:**
```bash
# Fix volume permissions (Linux)
sudo chown -R 1000:1000 ./volumes/sites

# Or set in docker-compose.yml
# user: "1000:1000"
```

---

#### HRMS Installation Error

**Symptoms:**
- `Module import failed for Expense Claim Type`
- Installation fails halfway

**Issue:**
Conflict between ERPNext and HRMS versions where Expense Claim doctype exists in both old and new schemas.

**Fix:**
```bash
# Clear Python cache
docker compose exec backend find . -name "*.pyc" -delete

# Migrate to sync doctypes
docker compose exec backend bench --site frontend migrate

# Restart to clear memory cache
docker compose restart backend

# Wait 10s then install
docker compose exec backend bench --site frontend install-app hrms
```

---

### 2. Helpdesk Issues

#### Helpdesk Page Not Loading

**Symptoms:**
- `/helpdesk` shows blank page
- 404 on helpdesk assets

**Solutions:**
```bash
# Build Helpdesk frontend
docker compose exec backend bench --site frontend build --app helpdesk

# Fix assets
docker compose exec frontend rm -rf /usr/share/nginx/html/assets
docker compose exec backend bash -c "mkdir -p /tmp/asset_copy && cp -rL /home/frappe/frappe-bench/sites/assets/* /tmp/asset_copy/"
docker compose cp backend:/tmp/asset_copy ./asset_copy
docker compose cp ./asset_copy frontend:/usr/share/nginx/html/assets
rm -rf ./asset_copy

# Restart frontend
docker compose restart frontend
```

---

### 3. Frappe Insights Issues

#### Insights Page Not Loading (404)

**Symptoms:**
- `/insights` shows "Page Not Found"
- Assets for Insights are missing on the frontend

**Solution:**
The automated build for Insights is memory-intensive and may fail silently. You need to force-build it manually.

```bash
# 1. Force build Insights assets
docker compose exec backend bench --site frontend build --app insights --force

# 2. Re-apply the Host-Mediated Force Sync
docker compose exec -u root backend bash -c "cp -rL /home/frappe/frappe-bench/sites/assets /tmp/assets_real && rm -rf /home/frappe/frappe-bench/sites/assets/* && cp -r /tmp/assets_real/* /home/frappe/frappe-bench/sites/assets/ && rm -rf /tmp/assets_real"
rm -rf asset_sync_temp
docker compose cp backend:/home/frappe/frappe-bench/sites/assets/. ./asset_sync_temp
docker compose cp ./asset_sync_temp/. frontend:/home/frappe/frappe-bench/sites/assets/
docker compose exec -u root frontend chown -R 101:101 /home/frappe/frappe-bench/sites/assets
rm -rf asset_sync_temp

# 3. Clear Cache
docker compose exec backend bench --site frontend clear-cache
```

---


### 4. Runtime Issues

#### Slow Performance

**Symptoms:**
- Pages take >5 seconds to load
- Timeouts on reports

**Diagnosis:**
```bash
# Check resource usage
docker stats

# Check Redis
docker compose exec redis-cache redis-cli ping

# Check database slow queries
docker compose exec db mysql -e "SHOW PROCESSLIST"
```

**Solutions:**
1. Increase memory limits in `docker-compose.yml`
2. Add database indexes
3. Increase worker count
4. Check disk I/O (use SSD)

---

#### Background Jobs Not Running

**Symptoms:**
- Emails not sending
- Scheduled reports not generating
- Queue length increasing

**Diagnosis:**
```bash
# Check scheduler
docker compose logs scheduler

# Check queue workers
docker compose logs queue-long

# View pending jobs
docker compose exec backend bench show-pending-jobs --site frontend
```

**Solutions:**
1. Restart scheduler: `docker compose restart scheduler`
2. Restart workers: `docker compose restart queue-long`
3. Check Redis queue: `docker compose exec redis-queue redis-cli llen rq:queue:default`

---

#### WebSocket Not Connecting

**Symptoms:**
- Real-time updates not working
- "Reconnecting..." message in UI

**Diagnosis:**
```bash
# Check websocket container
docker compose logs websocket

# Test socket.io endpoint
curl http://localhost:8080/socket.io/
```

**Solutions:**
1. Ensure websocket container is running
2. Check nginx proxy configuration
3. Verify SOCKETIO_PORT environment variable

---

### 5. Database Issues

#### Database Size Growing Rapidly

**Symptoms:**
- Disk space filling up
- Slow backups

**Diagnosis:**
```bash
# Check database size
docker compose exec db mysql -e "
SELECT table_schema, 
       ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'Size (MB)'
FROM information_schema.tables 
GROUP BY table_schema;"

# Find largest tables
docker compose exec db mysql -e "
SELECT table_name, 
       ROUND((data_length + index_length) / 1024 / 1024, 2) AS 'Size (MB)'
FROM information_schema.tables 
WHERE table_schema = 'your_site_db'
ORDER BY (data_length + index_length) DESC
LIMIT 10;"
```

**Solutions:**
1. Clear old error logs: Settings > Error Log > Delete
2. Clear old activity logs
3. Optimize tables: `bench --site sitename optimize-tables`

---

#### Database Corruption

**Symptoms:**
- Table crashes
- InnoDB errors in logs

**Diagnosis:**
```bash
# Check for crashed tables
docker compose exec db mysql -e "
SELECT table_name, engine 
FROM information_schema.tables 
WHERE table_schema = 'your_db' AND engine IS NULL;"
```

**Solutions:**
1. **STOP ALL SERVICES FIRST**
2. Restore from backup (recommended)
3. Attempt repair: `mysqlcheck --repair --all-databases`

---

### 6. Update/Migration Issues

#### Migration Fails

**Symptoms:**
- Error during `bench migrate`
- Database schema mismatch

**Diagnosis:**
```bash
# Check migration status
docker compose exec backend bench --site sitename migrate --dry-run

# View error details
docker compose logs backend --tail 500
```

**Solutions:**
1. Check error message for specific patch
2. Restore pre-update backup
3. Run specific patch manually:
   ```bash
   bench --site sitename run-patch patch.name --force
   ```

---

#### Assets Not Building

**Symptoms:**
- CSS/JS errors
- Old UI after update

**Solutions:**
```bash
# Rebuild assets
docker compose exec backend bench --site frontend build --force

# Clear cache
docker compose exec backend bench --site frontend clear-cache

# Restart services
docker compose restart frontend
```

---

## Quick Reference Commands

### Service Management
```bash
# View all containers
docker compose ps

# Start services
docker compose up -d

# Stop services
docker compose down

# Restart specific service
docker compose restart backend

# View logs
docker compose logs -f backend
docker compose logs --tail 100 db
```

### Bench Commands (run inside backend container)
```bash
# Enter container
docker compose exec backend bash

# Clear cache
bench --site frontend clear-cache

# Rebuild
bench --site frontend build

# Migrate
bench --site frontend migrate

# Backup
bench --site frontend backup

# Reset password
bench --site frontend set-admin-password NewPassword123

# Build specific app
bench --site frontend build --app helpdesk
```

### Database Commands
```bash
# MySQL shell
docker compose exec db mysql -uroot -pSecureRootPassword456!

# Database dump
docker compose exec db mysqldump -uroot -p database_name > backup.sql

# Check table sizes
docker compose exec db mysql -e "SELECT table_name, round(((data_length + index_length) / 1024 / 1024), 2) 'Size MB' FROM information_schema.tables WHERE table_schema = 'database_name';"
```

---

## Nuclear Reset (Last Resort)

If nothing else works, perform a complete reset:

```bash
cd /opt/erpnext

# Stop everything and remove volumes
docker compose down -v

# Remove all containers
docker rm -f $(docker ps -aq) 2>/dev/null || true

# Remove all volumes
docker volume rm $(docker volume ls -q | grep erpnext) 2>/dev/null || true

# Rebuild and start fresh
docker compose up -d
```

---

## When to Call for Professional Help

### Call Support When:

1. **Data Corruption** - Any signs of corrupted data that backup restore doesn't fix
2. **Performance Issues** - After exhausting optimization options
3. **Custom Development** - Need custom modules or integrations
4. **Major Upgrades** - Before upgrading major versions (v14 → v15)
5. **Compliance** - Healthcare data compliance requirements (HIPAA, etc.)
6. **Scaling** - Planning for 500+ users or high availability

### Resources:

- **Official Documentation**: https://frappeframework.com/docs
- **ERPNext Community Forum**: https://discuss.frappe.io
- **Healthcare Module Docs**: https://marleyhealth.io/docs
- **Frappe Partners**: https://frappe.io/partners
