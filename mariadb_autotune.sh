#!/bin/bash

# ==============================================================================
#   สคริปต์ปรับจูน MariaDB อัจฉริยะสำหรับ AlmaLinux 9 (โปรไฟล์ HOSxP)
# ==============================================================================
#
#   ผู้จัดทำ: ChonLaWan & Gemini
#   เวอร์ชัน: 12.1 (The True Final Standalone Script)
#
#   คุณสมบัติ:
#   - ใช้สูตรคำนวณ RAM แบบขั้นบันไดที่ปลอดภัยที่สุด
#   - สร้างไฟล์ Config ฉบับเต็มพร้อมคอมเมนต์อธิบายทุกบรรทัด
#   - เป็นเวอร์ชันสมบูรณ์แบบ All-in-One ที่ป้องกันความผิดพลาดจากมนุษย์
#   - แก้ไขลำดับการทำงานทั้งหมดให้ถูกต้อง: Install -> Stop -> Configure -> Restart
#
# ==============================================================================

# --- โค้ดสีและฟังก์ชันพื้นฐาน ---
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; }

# --- ตัวแปรพื้นฐาน ---
DB_USER="mysql"; DB_GROUP="mysql"
CUSTOM_CNF_FILE="/etc/my.cnf.d/99-custom-tuning.cnf"
MARIADB_VERSION="11.4" # ตั้งเป้าการติดตั้งไปที่ 11.4 ตามข้อจำกัด

update_config() {
    local file="$1"; local key="$2"; local value="$3"
    if [ ! -f "$file" ]; then log_warn "ไม่พบไฟล์ $file, ข้ามการอัปเดต"; return; fi
    if grep -qE "^\s*#?\s*${key}\s*=" "$file"; then
        sudo sed -i -E "s/^(\s*#?\s*${key}\s*=\s*)[^#\s]*(.*)/\\1${value}\\2/" "$file"
        log_info "อัปเดตค่า '$key' ใน $file เป็น '$value'"
    else
        if grep -q "\[mysqld\]" "$file"; then
            sudo sed -i "/\[mysqld\]/a ${key} = ${value}" "$file"
            log_warn "ไม่พบค่า '$key' ใน $file, ทำการเพิ่มค่าใหม่ใต้ [mysqld]"
        else
            echo -e "\n[mysqld]\n${key} = ${value}" | sudo tee -a "$file" > /dev/null
            log_warn "ไม่พบหมวด [mysqld] และค่า '$key' ใน $file, ทำการเพิ่มหมวดและค่าใหม่"
        fi
    fi
}

# --- ตรวจสอบสิทธิ์ Root ---
if [ "$EUID" -ne 0 ]; then log_error "กรุณารันสคริปต์นี้ด้วยสิทธิ์ root หรือใช้คำสั่ง sudo"; exit 1; fi

clear
log_info "======================================================"
log_info "  เริ่มต้นสคริปต์ติดตั้งและปรับจูน MariaDB (v12.1)     "
log_info "======================================================"

# ==================================
#  ขั้นตอนที่ 1: รับค่า Port จากผู้ใช้
# ==================================
read -p "กรุณาใส่หมายเลข Port สำหรับ MariaDB [ค่าเริ่มต้น: 3306]: " DB_PORT
DB_PORT=${DB_PORT:-3306}
log_info "จะทำการติดตั้งและตั้งค่า MariaDB บน Port: ${DB_PORT}"
sleep 2

# ==================================
# ขั้นตอนที่ 2: ติดตั้ง MariaDB (หากยังไม่มี)
# ==================================
if ! command -v mariadbd &> /dev/null; then
    log_info "ขั้นตอนที่ 2: MariaDB ยังไม่ได้ติดตั้ง, เริ่มขั้นตอนการติดตั้งเวอร์ชัน ${MARIADB_VERSION}..."
    sudo tee /etc/yum.repos.d/MariaDB.repo > /dev/null <<EOF
# MariaDB ${MARIADB_VERSION} for AlmaLinux 9
[mariadb]
name = MariaDB
baseurl = https://mirror.kku.ac.th/mariadb/yum/${MARIADB_VERSION}/rhel/9/x86_64
gpgkey=https://rpm.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck=1
enabled=1
EOF
    sudo dnf clean all
    sudo dnf install -y MariaDB-server MariaDB-client MariaDB-backup
    if [ $? -ne 0 ]; then log_error "ติดตั้ง MariaDB ไม่สำเร็จ"; exit 1; fi
    sudo systemctl enable --now mariadb
    if [ $? -ne 0 ]; then log_error "เริ่ม Service MariaDB ครั้งแรกไม่สำเร็จ"; exit 1; fi
    log_info "ติดตั้ง MariaDB และเริ่ม Service ครั้งแรกเรียบร้อยแล้ว"
else
    log_info "ขั้นตอนที่ 2: ตรวจพบ MariaDB ติดตั้งอยู่แล้ว, ข้ามขั้นตอนการติดตั้ง"
fi
log_info "กำลังหยุด MariaDB ชั่วคราวเพื่อเริ่มการปรับจูน..."
sudo systemctl stop mariadb
sleep 2

# ==================================
# ขั้นตอนที่ 3: ตั้งค่าความปลอดภัย (Firewall & SELinux)
# ==================================
log_info "ขั้นตอนที่ 3: ตั้งค่า Firewall และปิดการใช้งาน SELinux..."
# --- จัดการ Firewall ---
if systemctl is-active --quiet firewalld; then
    log_info "Firewalld ทำงานอยู่, กำลังเพิ่ม Port ${DB_PORT}/tcp..."
    if ! sudo firewall-cmd --query-port=${DB_PORT}/tcp --zone=public > /dev/null 2>&1; then
        sudo firewall-cmd --zone=public --add-port=${DB_PORT}/tcp --permanent
        sudo firewall-cmd --reload
        log_info "เปิด Port ${DB_PORT} ใน Firewall เรียบร้อย"
    else
        log_info "Port ${DB_PORT} ถูกเปิดใน Firewall อยู่แล้ว"
    fi
else
    log_warn "ไม่พบ Firewalld หรือไม่ได้ทำงาน, ข้ามขั้นตอนการตั้งค่า Firewall"
fi
# --- ปิดการใช้งาน SELinux อย่างถาวร ---
if sestatus 2>/dev/null | grep -q "Current mode:\s*enforcing"; then
    log_warn "SELinux อยู่ในโหมด Enforcing, กำลังเปลี่ยนเป็น Permissive ชั่วคราว..."
    sudo setenforce 0
    log_info "เปลี่ยนโหมด SELinux เป็น Permissive สำเร็จ"
fi
if [ -f /etc/selinux/config ]; then
    if ! grep -q "SELINUX=disabled" /etc/selinux/config; then
        log_warn "กำลังปิดการใช้งาน SELinux อย่างถาวรใน /etc/selinux/config..."
        sudo sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
        sudo sed -i 's/SELINUX=permissive/SELINUX=disabled/g' /etc/selinux/config
        log_warn "ปิดการใช้งาน SELinux ถาวรเรียบร้อยแล้ว, การเปลี่ยนแปลงนี้จะมีผลสมบูรณ์หลังจากการ Reboot เครื่อง!"
    else
        log_info "SELinux ถูกตั้งค่าให้ปิดการใช้งานอย่างถาวรอยู่แล้ว"
    fi
else
    log_warn "ไม่พบไฟล์ /etc/selinux/config"
fi
sleep 2

# ==================================
#  ขั้นตอนที่ 4: ตรวจสอบ Hardware และคำนวณค่า Config
# ==================================
log_info "ขั้นตอนที่ 4: ตรวจสอบ Hardware และคำนวณค่า Config..."
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$(( (TOTAL_RAM_KB + 524288) / 1048576 ))
CPU_CORES=$(nproc)
log_info "ตรวจพบ RAM ทั้งหมด: ${TOTAL_RAM_GB} GB, CPU Cores: ${CPU_CORES}"

# --- นี่คือส่วนที่ใช้สูตรแตกต่างกันตามขนาด RAM (Conservative Logic) ---
log_info "กำลังคำนวณ Buffer Pool ตามขนาด RAM ที่แตกต่างกัน..."
if [ "$TOTAL_RAM_GB" -lt 32 ]; then
    PERCENTAGE=50 # สำหรับ RAM น้อยกว่า 32GB, ใช้สูตรที่ปลอดภัยมาก
elif [ "$TOTAL_RAM_GB" -lt 128 ]; then
    PERCENTAGE=70 # สำหรับ RAM 32GB - 127GB
else
    PERCENTAGE=80 # สำหรับ RAM 128GB+
fi
log_info "ตรวจพบ RAM ${TOTAL_RAM_GB}GB, ใช้สูตร ${PERCENTAGE}% สำหรับ Buffer Pool"
INNODB_BUFFER_POOL_GB=$((TOTAL_RAM_GB * PERCENTAGE / 100))
[ "$INNODB_BUFFER_POOL_GB" -lt 2 ] && INNODB_BUFFER_POOL_GB=2

SHMMAX=$((TOTAL_RAM_GB * 1024 * 1024 * 1024 * 90 / 100))
SHMALL=$((SHMMAX / 4096))
HUGEPAGES=$((INNODB_BUFFER_POOL_GB * 1024 / 2))

INNODB_LOG_FILE_SIZE_MB=$((INNODB_BUFFER_POOL_GB * 1024 / 4))
if [ "$INNODB_LOG_FILE_SIZE_MB" -gt 4096 ]; then INNODB_LOG_FILE_SIZE="4G"; \
elif [ "$INNODB_LOG_FILE_SIZE_MB" -lt 512 ]; then INNODB_LOG_FILE_SIZE="512M"; \
else INNODB_LOG_FILE_SIZE="${INNODB_LOG_FILE_SIZE_MB}M"; fi

log_info "ค่าที่จะใช้: innodb_buffer_pool_size=${INNODB_BUFFER_POOL_GB}G, innodb_log_file_size=${INNODB_LOG_FILE_SIZE}, vm.nr_hugepages=${HUGEPAGES}"
sleep 2

# ==================================
# ขั้นตอนที่ 5: ตรวจสอบและตั้งค่า Systemd Limits
# ==================================
log_info "ขั้นตอนที่ 5: ตรวจสอบและตั้งค่า Systemd Limits..."
LIMIT_FILE="/etc/systemd/system/mariadb.service.d/override.conf"
sudo mkdir -p /etc/systemd/system/mariadb.service.d
sudo tee "$LIMIT_FILE" > /dev/null <<'EOF'
[Service]
LimitNOFILE=150000
LimitMEMLOCK=infinity
AmbientCapabilities=CAP_SYS_NICE
EOF
log_info "สร้าง/อัปเดตไฟล์ $LIMIT_FILE พร้อมตั้งค่า Capabilities เรียบร้อย"
sudo systemctl daemon-reload

# ==================================
# ขั้นตอนที่ 6: ตรวจสอบและปรับจูน Kernel (sysctl)
# ==================================
log_info "ขั้นตอนที่ 6: ตรวจสอบและปรับจูนค่า Kernel (/etc/sysctl.conf)..."
MYSQL_GID=$(getent group ${DB_GROUP} | cut -d: -f3)

if [ -z "$MYSQL_GID" ]; then
    log_error "ไม่พบ Group ID สำหรับผู้ใช้ '${DB_GROUP}'. ไม่สามารถตั้งค่า Kernel ได้."
    exit 1
fi

if [ ! -f /etc/sysctl.conf ] || ! grep -q "MariaDB Production Server" /etc/sysctl.conf; then
    log_warn "/etc/sysctl.conf ยังไม่เคยถูกตั้งค่า, กำลังสร้างไฟล์ใหม่..."
    sudo cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%F) 2>/dev/null
    sudo tee /etc/sysctl.conf > /dev/null <<EOF
# ========================================================
# ⚙️ การตั้งค่า Kernel สำหรับ MariaDB Production Server (โดยสคริปต์)
# ========================================================
fs.suid_dumpable = 1							# อนุญาตให้ทำการ dump memory เมื่อเกิดปัญหาเพื่อการวิเคราะห์
fs.aio-max-nr = 1048576							# จำนวนสูงสุดของ Asynchronous I/O operations ที่รองรับ
fs.file-max = 6815744							# จำนวนไฟล์สูงสุดที่ระบบสามารถเปิดได้พร้อมกัน
kernel.shmmax = ${SHMMAX}						# ขนาดสูงสุดของ Shared Memory 1 segment (คำนวณจาก RAM)
kernel.shmall = ${SHMALL}						# จำนวนหน้าของ Shared Memory ทั้งหมด (คำนวณจาก RAM)
vm.nr_hugepages = ${HUGEPAGES}					# จำนวน HugePages ที่จองไว้ (คำนวณสำหรับ Buffer Pool)
vm.hugetlb_shm_group = ${MYSQL_GID}				# GID ของกลุ่มผู้ใช้ที่สามารถใช้ HugePages ได้ (mysql)
net.ipv4.ip_local_port_range = 2000 65535		# ช่วงของพอร์ตที่ใช้งานได้
net.core.somaxconn = 4096						# จำนวนสูงสุดของ connection ที่รอการ accept
net.ipv4.tcp_tw_reuse = 1						# อนุญาตให้ใช้ซ็อกเก็ตในสถานะ TIME-WAIT ซ้ำได้
kernel.io_uring_disabled = 0					# เปิดใช้งาน io_uring API เพื่อประสิทธิภาพ I/O สูงสุด
EOF
else
    log_info "ตรวจสอบค่าใน /etc/sysctl.conf..."
    sudo sed -i '/fs.io_uring_group/d' /etc/sysctl.conf
    update_config "/etc/sysctl.conf" "kernel.shmmax" "${SHMMAX}"
    update_config "/etc/sysctl.conf" "kernel.shmall" "${SHMALL}"
    update_config "/etc/sysctl.conf" "vm.nr_hugepages" "${HUGEPAGES}"
    update_config "/etc/sysctl.conf" "vm.hugetlb_shm_group" "${MYSQL_GID}"
fi
sudo sysctl -p

# ==================================
# ขั้นตอนที่ 7: สร้าง/ปรับจูนไฟล์คอนฟิก MariaDB
# ==================================
log_info "ขั้นตอนที่ 7: กำลังปรับจูนไฟล์คอนฟิกที่: ${CUSTOM_CNF_FILE}"

if [ -f "$CUSTOM_CNF_FILE" ]; then
    log_warn "พบไฟล์คอนฟิกเดิม, กำลังสำรองไปที่ ${CUSTOM_CNF_FILE}.bak.$(date +%F)"
    sudo cp "$CUSTOM_CNF_FILE" "${CUSTOM_CNF_FILE}.bak.$(date +%F)"
fi

if [ ! -f "$CUSTOM_CNF_FILE" ]; then
    log_info "ไม่พบไฟล์ ${CUSTOM_CNF_FILE}, กำลังสร้างไฟล์ใหม่ทั้งหมด..."
    
    DISK_TYPE_CODE=$(cat /sys/block/$(lsblk -no pkname "$(df /var/lib/mysql | awk 'NR==2 {print $1}')" | head -n 1)/queue/rotational 2>/dev/null)
    INNODB_FLUSH_NEIGHBORS=${DISK_TYPE_CODE:-0}
    DISK_TYPE_TEXT=$([ "$INNODB_FLUSH_NEIGHBORS" -eq 0 ] && echo "SSD/NVMe" || echo "HDD/SAS")

    sudo tee "$CUSTOM_CNF_FILE" > /dev/null <<EOF
# ===================================================================
# 🔧 Custom Tuning for MariaDB ${MARIADB_VERSION} (สร้างโดยสคริปต์อัตโนมัติ)
#    - Hardware: RAM ${TOTAL_RAM_GB}GB, CPU ${CPU_CORES} Cores, Disk ${DISK_TYPE_TEXT}
# ===================================================================

[client]
port=${DB_PORT}                               # พอร์ตที่ Client ใช้เชื่อมต่อ
socket=/var/lib/mysql/mysql.sock        # ตำแหน่งไฟล์ Socket สำหรับการเชื่อมต่อภายในเครื่อง
default-character-set=tis620            # Character Set เริ่มต้นสำหรับ Client

[mysqld]
# ------------------------------------
# # การตั้งค่าพื้นฐานของเซิร์ฟเวอร์ #
# ------------------------------------
port=${DB_PORT}                               # พอร์ตที่ Server รับการเชื่อมต่อ
datadir=/var/lib/mysql                  # โฟลเดอร์หลักสำหรับเก็บข้อมูลฐานข้อมูล
socket=/var/lib/mysql/mysql.sock        # ตำแหน่งไฟล์ Socket ของ Server
tmpdir=/tmp                             # โฟลเดอร์สำหรับไฟล์ชั่วคราว
bind-address=0.0.0.0                    # รับการเชื่อมต่อจากทุก IP Address
lower_case_table_names=1                # ทำให้ชื่อตารางไม่สนตัวพิมพ์เล็ก-ใหญ่ (สำคัญสำหรับระบบที่ย้ายมาจาก Windows)
skip-name-resolve                       # ไม่ต้องแปลง IP เป็น Hostname เพื่อลด Latency ในการเชื่อมต่อ

# ------------------------------------
# # การตั้งค่าภาษาไทย (TIS-620) #
# ------------------------------------
character-set-server=tis620             # Character Set ของเซิร์ฟเวอร์
collation-server=tis620_thai_ci         # การเรียงลำดับตัวอักษรของภาษาไทย
init_connect='SET NAMES tis620'         # สั่งให้ทุก Connection ใหม่ใช้ TIS-620
skip-character-set-client-handshake     # บังคับใช้ Character Set ของ Server เสมอ (ป้องกัน Client ส่งค่าอื่นมา)

# ------------------------------------
# # Thread & Connection #
# ------------------------------------
thread_handling=pool-of-threads         # ใช้ Thread Pool เพื่อลด Overhead ในการสร้าง/ทำลาย Thread
max_connections=1000                    # จำนวน Connection สูงสุดที่รับได้
thread_cache_size=128                   # เก็บ Thread ที่ไม่ใช้งานไว้ใน Cache เพื่อนำกลับมาใช้ใหม่
wait_timeout=300                        # เวลา (วินาที) ที่จะตัดการเชื่อมต่อที่ไม่มีการใช้งาน
interactive_timeout=600                 # Timeout สำหรับ Interactive Connection
connect_timeout=60                      # เวลาที่รอสำหรับการเชื่อมต่อก่อนจะ Timeout
net_read_timeout=600                    # เวลาที่รอข้อมูลจาก Client ก่อนตัดการเชื่อมต่อ
net_write_timeout=600                   # เวลาที่รอเพื่อส่งข้อมูลให้ Client ก่อนตัดการเชื่อมต่อ

# ------------------------------------
# # Table Cache & Files #
# ------------------------------------
table_open_cache=8000                   # Cache สำหรับตารางที่เปิดแล้ว
table_definition_cache=8000             # Cache สำหรับโครงสร้างตาราง (Metadata)
table_open_cache_instances=${CPU_CORES} # แบ่ง Cache ของตารางตามจำนวน Core เพื่อลด Contention
open_files_limit=100000                 # จำนวนไฟล์สูงสุดที่ MariaDB สามารถเปิดได้

# ------------------------------------
# # Memory Buffers & Query #
# ------------------------------------
sort_buffer_size=2M                     # Buffer สำหรับการเรียงข้อมูล (Sort) ต่อ 1 Thread
read_buffer_size=2M                     # Buffer สำหรับการอ่านข้อมูลแบบ Sequential Scan ต่อ 1 Thread
read_rnd_buffer_size=4M                 # Buffer สำหรับการอ่านข้อมูลแบบสุ่ม (Random Read)
join_buffer_size=4M                     # Buffer สำหรับการ Join ตารางที่ไม่มี Index
tmp_table_size=512M                     # ขนาดสูงสุดของตารางชั่วคราวบน Memory
max_heap_table_size=512M                # ขนาดสูงสุดของตารางประเภท MEMORY

# ------------------------------------
# # InnoDB Engine #
# ------------------------------------
default_storage_engine=InnoDB           # ตั้งให้ InnoDB เป็น Storage Engine เริ่มต้น
innodb_file_per_table=1                 # สร้างไฟล์ .ibd แยกสำหรับแต่ละตาราง
innodb_buffer_pool_size=${INNODB_BUFFER_POOL_GB}G          # ขนาดของ Buffer Pool (หัวใจของ InnoDB) คำนวณจาก RAM
innodb_log_file_size=${INNODB_LOG_FILE_SIZE}                # ขนาดของ Redo Log File คำนวณจาก Buffer Pool
innodb_log_buffer_size=64M              # Buffer สำหรับ Redo Log ก่อนเขียนลงดิสก์
innodb_flush_log_at_trx_commit=2        # เขียน Log ลง OS Cache ทุกครั้งที่ Commit (เพื่อประสิทธิภาพ)
innodb_flush_method=O_DIRECT_NO_FSYNC   # วิธีการเขียนข้อมูลลงดิสก์ (ดีที่สุดสำหรับ Linux ที่ใช้ Hardware RAID/SSD)
innodb_doublewrite=1                    # เปิด Doublewrite Buffer เพื่อป้องกันข้อมูลเสียหาย
innodb_read_io_threads=16               # จำนวน Thread สำหรับการอ่านข้อมูล
innodb_write_io_threads=16              # จำนวน Thread สำหรับการเขียนข้อมูล
innodb_io_capacity=2000                 # IOPS โดยประมาณของดิสก์
innodb_io_capacity_max=4000             # IOPS สูงสุดที่ยอมให้ใช้
innodb_open_files=65535                 # จำนวนไฟล์สูงสุดที่ InnoDB สามารถเปิดได้
innodb_max_dirty_pages_pct=80           # เปอร์เซ็นต์ของข้อมูล "สกปรก" ใน Buffer Pool ก่อนเริ่ม Flush
innodb_lru_scan_depth=4096              # ความลึกในการสแกนหา Page ที่จะนำออกจาก LRU List
innodb_purge_threads=4                  # จำนวน Thread ที่ใช้สำหรับ Purge ข้อมูลเก่า
innodb_flush_neighbors=${INNODB_FLUSH_NEIGHBORS}                # 0 สำหรับ SSD/NVMe, 1 สำหรับ HDD/SAS
innodb_adaptive_flushing=1              # เปิดให้ InnoDB ปรับการ Flush ข้อมูลอัตโนมัติ
innodb_adaptive_hash_index=0            # ปิด Adaptive Hash Index (มักดีกว่าสำหรับ Workload ส่วนใหญ่)
innodb_use_native_aio=1                 # ใช้ Native AIO ของ Linux
innodb_stats_persistent=1               # ทำให้สถิติของตารางคงอยู่หลังรีสตาร์ท
max_prepared_stmt_count=1000000

# ------------------------------------
# # HugePages & Memory Lock #
# ------------------------------------
large_pages=1                           # เปิดใช้งาน HugePages
memlock=1                               # ล็อกหน่วยความจำของ MariaDB เพื่อป้องกันการ Swap

# ------------------------------------
# # Logging & Debug #
# ------------------------------------
slow_query_log=1                        # เปิดใช้งาน Slow Query Log
slow_query_log_file=/var/log/mariadb-slow.log # ตำแหน่งไฟล์ Slow Query Log
long_query_time=1                       # Query ที่นานกว่า 1 วินาทีถือว่าเป็น Slow Query
log_queries_not_using_indexes=1         # บันทึก Query ที่ไม่ได้ใช้ Index

# ------------------------------------
# # Security & Packets #
# ------------------------------------
max_allowed_packet=512M                 # ขนาด Packet สูงสุดที่รับได้
skip-external-locking                   # ปิดการล็อกไฟล์ภายนอก

# --- Performance Schema ---
performance_schema=ON

[mysqldump]
quick
max_allowed_packet=512M

[mysql]
no-auto-rehash                          # ปิดการทำ auto-rehash ของ command line เพื่อความเร็ว
default-character-set=tis620            # Character Set เริ่มต้นสำหรับ command line
EOF
else
    log_info "ไฟล์คอนฟิก ${CUSTOM_CNF_FILE} มีอยู่แล้ว, กำลังตรวจสอบและอัปเดตค่า..."
    update_config "$CUSTOM_CNF_FILE" "port" "${DB_PORT}"
    update_config "$CUSTOM_CNF_FILE" "innodb_buffer_pool_size" "${INNODB_BUFFER_POOL_GB}G"
    update_config "$CUSTOM_CNF_FILE" "innodb_log_file_size" "${INNODB_LOG_FILE_SIZE}"
    update_config "$CUSTOM_CNF_FILE" "table_open_cache_instances" "${CPU_CORES}"
fi

# ==================================
# ขั้นตอนที่ 8: รีสตาร์ทและตรวจสอบ
# ==================================
log_info "ขั้นตอนที่ 8: สร้างไฟล์ Log และรีสตาร์ท MariaDB ด้วยคอนฟิกใหม่..."
sudo touch /var/log/mysqld.log /var/log/mariadb-slow.log
sudo chown ${DB_USER}:${DB_GROUP} /var/log/mysqld.log /var/log/mariadb-slow.log
sudo chmod 640 /var/log/mysqld.log /var/log/mariadb-slow.log

log_info "กำลังรีสตาร์ท MariaDB..."
sudo systemctl restart mariadb
if [ $? -ne 0 ]; then
    log_error "MariaDB รีสตาร์ทไม่สำเร็จ! กรุณาตรวจสอบ Log ด้วย 'journalctl -u mariadb -n 100'"
    exit 1
fi

log_info "รอสักครู่เพื่อให้ service เริ่มทำงานสมบูรณ์..."
sleep 5

# --- การตรวจสอบขั้นสุดท้าย ---
log_info "ตรวจสอบสถานะ MariaDB..."
sudo systemctl status mariadb --no-pager

HUGEPAGES_USED=$(grep Huge /proc/$(pidof mariadbd)/smaps 2>/dev/null | awk '{sum += $2} END {print sum / 1024}')
if [ -n "$HUGEPAGES_USED" ] && [ "$HUGEPAGES_USED" -gt 0 ]; then
    log_info "MariaDB ใช้งาน HugePages อยู่: ${HUGEPAGES_USED} MB"
else
    log_warn "ไม่พบการใช้งาน HugePages อาจมีปัญหาในการตั้งค่าหรือหน่วยความจำไม่พอ"
fi

log_info "${GREEN}=====================================================${NC}"
log_info "${GREEN}   สคริปต์ปรับจูน MariaDB ทำงานเสร็จสมบูรณ์!         ${NC}"
log_info "${GREEN}=====================================================${NC}"
log_warn "สำคัญ: หากเป็นการติดตั้งครั้งแรก กรุณารัน 'sudo mariadb-secure-installation' ทันที"
log_warn "และแนะนำให้ Reboot เครื่องเพื่อให้การตั้งค่า SELinux มีผลสมบูรณ์"
echo ""
