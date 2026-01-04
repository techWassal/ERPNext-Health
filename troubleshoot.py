#!/usr/bin/env python3
import subprocess
import json
import sys
import time
import os
import argparse

# Configuration
COMPOSE_FILE = "docker-compose.yml"
SITE_NAME = "frontend"
CONTAINER_BACKEND = "backend"
CONTAINER_DB = "db"

def print_header(title):
    print("\n" + "=" * 60)
    print(f" {title}")
    print("=" * 60 + "\n")

def run_command(command, shell=False, return_output=True, ignore_errors=False):
    """Run a shell command and return the output."""
    try:
        result = subprocess.run(
            command, 
            shell=shell, 
            check=not ignore_errors, 
            stdout=subprocess.PIPE if return_output else None, 
            stderr=subprocess.PIPE if return_output else None,
            text=True
        )
        if return_output:
            return result.stdout.strip()
        return True
    except subprocess.CalledProcessError as e:
        if not ignore_errors:
            print(f"Error running command: {command}")
            if return_output:
                print(f"Stderr: {e.stderr}")
        return None

def get_docker_status(service_name):
    """Get the status of a docker container."""
    cmd = ["docker", "compose", "-f", COMPOSE_FILE, "ps", "--format", "json", service_name]
    output = run_command(cmd)
    if not output:
        return "not_found"
    try:
        # Docker compose ps json output can be a list or single object lines
        data = json.loads(output)
        if isinstance(data, list):
            if not data: return "stopped"
            return data[0].get("State", "unknown")
        return data.get("State", "unknown")
    except json.JSONDecodeError:
        return "parse_error"

# ==========================================
# Diagnostics
# ==========================================

def check_general_health():
    print_header("Running General Health Check")
    
    services = ["backend", "frontend", "db", "redis-cache", "redis-queue"]
    all_up = True
    
    print(f"{'Service':<20} {'Status':<15}")
    print("-" * 35)
    
    for service in services:
        status = get_docker_status(service)
        print(f"{service:<20} {status:<15}")
        if status != "running":
            all_up = False
            
    if not all_up:
        print("\n[!] CRITICAL: Some essential services are not running.")
        return False
    
    print("\nAll essential containers are running.")
    return True

def diagnose_db_access():
    print_header("Diagnosing Database Access")
    
    print("Checking database connectivity from backend...")
    
    # 1. Check if DB is reachable via bench
    # We use a simple python command inside the container to check connection
    check_cmd = [
        "docker", "compose", "-f", COMPOSE_FILE, "exec", "-T", CONTAINER_BACKEND,
        "python3", "-c", 
        "import frappe; frappe.connect(); print('Connected')"
    ]
    
    output = run_command(check_cmd, ignore_errors=True)
    
    if output and "Connected" in output:
        print("[OK] Backend can connect to Database.")
        return True
    else:
        print("[!] Backend CANNOT connect to Database.")
        print("\nPossible Causes:")
        print("1. Database container is initializing (Wait 60s)")
        print("2. Password mismatch in .env vs Database")
        print("3. User permissions (Access Denied)")
        
        print("\nDetailed Error (from Logs):")
        logs = run_command(["docker", "compose", "-f", COMPOSE_FILE, "logs", "--tail", "20", "backend"])
        if logs:
            if "Access denied for user" in logs:
                print(">> DETECTED: Access Denied Error")
                return "access_denied"
            elif "Can't connect to MySQL" in logs:
                print(">> DETECTED: Connection Refused")
                return "conn_refused"
        
        return "unknown_db_error"

def diagnose_assets():
    print_header("Diagnosing Asset Issues")
    print("If your site loads but looks broken (no CSS/JS), this tool can fix it.")
    
    choice = input("Do you want to rebuild assets and fix permissions now? (y/n): ")
    if choice.lower() == 'y':
        fix_assets()

# ==========================================
# Fixes
# ==========================================

def fix_db_permissions():
    print_header("Fixing Database Permissions")
    print("[SAFE] This function only modifies data inside your CURRENT containers.")
    print("[SAFE] It will NOT create new volumes or delete any data.")
    print("-" * 60)
    print("This will recreate the database user with the password from site_config.json")
    
    # 1. Get DB Name
    cmd_get_name = f"docker compose -f {COMPOSE_FILE} exec -T backend cat /home/frappe/frappe-bench/sites/{SITE_NAME}/site_config.json"
    config_str = run_command(cmd_get_name, shell=True)
    
    try:
        config = json.loads(config_str)
        db_name = config.get('db_name')
        db_pass = config.get('db_password')
        
        if not db_name or not db_pass:
            print("Could not parse db_name or db_password from site_config.json")
            return
            
        print(f"Found DB Name: {db_name}")
        
        print("\nOptions:")
        print("1. [Safe] Recreate user with EXISTING password from site_config.json")
        print("2. [Force] Sync password to PROJECT DEFAULT (SecureRootPassword456!)")
        print("0. Cancel")
        
        db_choice = input("\nSelect option: ")
        
        target_pass = db_pass
        sync_config = False
        
        if db_choice == '2':
            target_pass = "SecureRootPassword456!"
            sync_config = True
        elif db_choice != '1':
            return

        # 2. SQL Commands
        sql = f"""
        DROP USER IF EXISTS '{db_name}'@'%';
        CREATE USER '{db_name}'@'%' IDENTIFIED BY '{target_pass}';
        GRANT ALL PRIVILEGES ON `{db_name}`.* TO '{db_name}'@'%';
        FLUSH PRIVILEGES;
        """
        
        if sync_config:
            print(f">> Updating site_config.json with new password...")
            new_config = config.copy()
            new_config['db_password'] = target_pass
            new_config_json = json.dumps(new_config, indent=1)
            # Escaping for shell
            escaped_json = new_config_json.replace('"', '\\"')
            update_config_cmd = [
                "docker", "compose", "-f", COMPOSE_FILE, "exec", "-T", CONTAINER_BACKEND,
                "bash", "-c", f"echo '{escaped_json}' > /home/frappe/frappe-bench/sites/{SITE_NAME}/site_config.json"
            ]
            run_command(update_config_cmd)

        print(f"Executing SQL fix (using {'DEFAULT' if sync_config else 'EXISTING'} password)...")
        # Note: We assume root password is in .env or default. 
        # For safety/simplicity in this script, we ask user or try default from known content
        # In a real script we might parse .env
        
        fix_cmd = [
            "docker", "compose", "-f", COMPOSE_FILE, "exec", "-T", "db",
            "mysql", "-uroot", "-pSecureRootPassword456!", "-e", sql
        ]
        
        run_command(fix_cmd)
        print("Permissions updated. Restarting backend...")
        run_command(["docker", "compose", "-f", COMPOSE_FILE, "restart", "backend"])
        print("[OK] Done.")
        
    except Exception as e:
        print(f"Error parsing site config: {e}")

def fix_assets():
    print_header("Fixing Assets (Force Sync via Host)")
    print("[SAFE] This function only syncs files between your CURRENT backend/frontend.")
    print("[SAFE] It will NOT create new volumes or delete site data.")
    print("-" * 60)
    print("This will regenerate assets, resolve symlinks, and force-copy them to the frontend.")
    
    # 1. Regenerate
    print(">> Regenerating assets (bench build)...")
    run_command(["docker", "compose", "-f", COMPOSE_FILE, "exec", "-T", "backend", "bench", "build", "--production", "--force"])
    
    # 2. Resolve Symlinks in Backend
    print(">> Resolving symlinks in backend...")
    resolve_cmd = """
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
    """
    run_command(["docker", "compose", "-f", COMPOSE_FILE, "exec", "-T", "-u", "root", "backend", "bash", "-c", resolve_cmd])
    
    # 3. Copy to Host (Temp)
    print(">> Extracting assets to host...")
    if os.path.exists("asset_sync_temp"):
        import shutil
        shutil.rmtree("asset_sync_temp")
    run_command(["docker", "compose", "-f", COMPOSE_FILE, "cp", "backend:/home/frappe/frappe-bench/sites/assets/.", "asset_sync_temp"])
    
    # 4. Inject to Frontend (Both Paths)
    print(">> Injecting assets into Frontend...")
    
    # Path A: Nginx Root
    run_command(["docker", "compose", "-f", COMPOSE_FILE, "exec", "-T", "-u", "root", "frontend", "rm", "-rf", "/home/frappe/frappe-bench/sites/assets"])
    run_command(["docker", "compose", "-f", COMPOSE_FILE, "exec", "-T", "-u", "root", "frontend", "mkdir", "-p", "/home/frappe/frappe-bench/sites/assets"])
    run_command(["docker", "compose", "-f", COMPOSE_FILE, "cp", "asset_sync_temp/.", "frontend:/home/frappe/frappe-bench/sites/assets/"])
    run_command(["docker", "compose", "-f", COMPOSE_FILE, "exec", "-T", "-u", "root", "frontend", "chown", "-R", "101:101", "/home/frappe/frappe-bench/sites/assets"])
    
    # Path B: Fallback
    run_command(["docker", "compose", "-f", COMPOSE_FILE, "exec", "-T", "-u", "root", "frontend", "rm", "-rf", "/usr/share/nginx/html/assets"])
    run_command(["docker", "compose", "-f", COMPOSE_FILE, "exec", "-T", "-u", "root", "frontend", "mkdir", "-p", "/usr/share/nginx/html/assets"])
    run_command(["docker", "compose", "-f", COMPOSE_FILE, "cp", "asset_sync_temp/.", "frontend:/usr/share/nginx/html/assets/"])
    run_command(["docker", "compose", "-f", COMPOSE_FILE, "exec", "-T", "-u", "root", "frontend", "chown", "-R", "101:101", "/usr/share/nginx/html/assets"])
    
    # Clean host temp
    import shutil
    if os.path.exists("asset_sync_temp"):
        shutil.rmtree("asset_sync_temp")
        
    # 5. Clear Cache
    print(">> Clearing Site Cache...")
    run_command(["docker", "compose", "-f", COMPOSE_FILE, "exec", "-T", "backend", "bench", "--site", SITE_NAME, "clear-cache"])
    
    print("\n[OK] Assets force-synced. Try reloading your browser (Hard Refresh: Ctrl+Shift+R).")

def fix_hrms_install():
    print_header("Fixing HRMS/Expense Claim Issue")
    print("This fixes the 'Module import failed' error during installation.")
    
    steps = [
        ("Removing stale .pyc files...", 
         ["docker", "compose", "-f", COMPOSE_FILE, "exec", "-T", "backend", "find", ".", "-name", "*.pyc", "-delete"]),
        ("Running migration...", 
         ["docker", "compose", "-f", COMPOSE_FILE, "exec", "-T", "backend", "bench", "--site", SITE_NAME, "migrate"]),
        ("Restarting backend...",
         ["docker", "compose", "-f", COMPOSE_FILE, "restart", "backend"])
    ]
    
    for msg, cmd in steps:
        print(f">> {msg}")
        run_command(cmd)
        
    print("\n[OK] Cleanup done. You can now try installing the app again.")

# ==========================================
# Main Menu
# ==========================================

def menu():
    while True:
        print_header("ERPNext Doctor - Troubleshooting Wizard")
        print("1. [Auto] Run General Health Check")
        print("2. [Diagnosis] Check Database Connection")
        print("3. [Fix] 'Access Denied' / Database Permissions")
        print("4. [Fix] Broken CSS / Assets Not Loading")
        print("5. [Fix] HRMS Installation Error")
        print("6. [Logs] View Backend Logs")
        print("0. Exit")
        
        choice = input("\nEnter choice: ")
        
        if choice == '1':
            check_general_health()
        elif choice == '2':
            res = diagnose_db_access()
            if res == "access_denied":
                 if input(">> Fix Access Denied now? (y/n): ").lower() == 'y':
                     fix_db_permissions()
        elif choice == '3':
            fix_db_permissions()
        elif choice == '4':
            fix_assets()
        elif choice == '5':
            fix_hrms_install()
        elif choice == '6':
            print(run_command(["docker", "compose", "-f", COMPOSE_FILE, "logs", "--tail", "50", "backend"]))
        elif choice == '0':
            sys.exit(0)
        else:
            print("Invalid choice.")
        
        input("\nPress Enter to continue...")

if __name__ == "__main__":
    try:
        menu()
    except KeyboardInterrupt:
        print("\nExiting...")
        sys.exit(0)
