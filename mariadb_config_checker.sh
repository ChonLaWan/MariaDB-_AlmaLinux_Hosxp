#!/bin/bash
# =============================================================
# 🔍 สคริปต์ตรวจสอบการตั้งค่าระบบ MariaDB บน AlmaLinux
# =============================================================
# ผู้จัดทำ: ChonLaWan (รุ่นตรวจสอบ config)
# เวอร์ชัน: 1.0

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; }

# เช็ค my.cnf
if [ -f /etc/my.cnf ]; then
    log_info "พบไฟล์ /etc/my.cnf"
    grep -E "^innodb_buffer_pool_size|^character-set-server|^collation-server|^open_files_limit" /etc/my.cnf
else
    log_warn "ไม่พบ /etc/my.cnf"
fi

# เช็ค limit ของ systemd
LIMIT_FILE="/etc/systemd/system/mariadb.service.d/override.conf"
if [ -f "$LIMIT_FILE" ]; then
    log_info "ตรวจสอบ Limit ใน $LIMIT_FILE"
    grep -E "^LimitNOFILE|^LimitMEMLOCK" "$LIMIT_FILE"
else
    log_warn "ไม่พบไฟล์ systemd limit config"
fi

# เช็ค sysctl ที่เกี่ยวข้อง
log_info "ตรวจสอบค่า kernel ที่เกี่ยวข้องกับ MariaDB:"
sysctl fs.aio-max-nr fs.file-max kernel.shmmax kernel.shmall vm.nr_hugepages vm.hugetlb_shm_group net.core.somaxconn net.ipv4.tcp_tw_reuse net.ipv4.ip_local_port_range 2>/dev/null

# ตรวจสอบการใช้งาน HugePages จริง
PID=$(pidof mariadbd)
if [ -n "$PID" ]; then
    HP_USED=$(grep Huge /proc/$PID/smaps 2>/dev/null | awk '{sum += $2} END {print sum / 1024}')
    if [ -n "$HP_USED" ] && (( $(echo "$HP_USED > 0" | bc -l) )); then
        log_info "MariaDB ใช้งาน HugePages อยู่: ${HP_USED} MB"
    else
        log_warn "MariaDB ยังไม่ใช้ HugePages"
    fi
else
    log_warn "MariaDB ยังไม่ทำงาน หรือไม่พบ process mariadbd"
fi
