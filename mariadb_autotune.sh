#!/bin/bash

# ==============================================================================
#   สคริปต์ปรับจูน MariaDB อัจฉริยะสำหรับ AlmaLinux 9 (โปรไฟล์ HOSxP)
# ==============================================================================
#
#   ผู้จัดทำ: ChonLaWan & Gemini
#   เวอร์ชัน: 3.2 (ปรับปรุงล่าสุด 2025-06-22) - แก้ไข Bug และใส่ Config แบบเต็ม
#
#   คุณสมบัติ:
#   - ตรวจสอบ RAM ของเครื่องและคำนวณค่า Config ที่เหมาะสมอัตโนมัติ
#   - หากรันครั้งแรก: จะทำการติดตั้งและสร้างไฟล์ Config ที่ดีที่สุดให้ (แบบเต็ม)
#   - หากรันซ้ำ: จะตรวจสอบและแก้ไขเฉพาะค่าที่ยังไม่ถูกต้อง โดยไม่ลบ
#     คอมเมนต์หรือการตั้งค่าอื่นๆ ที่มีอยู่เดิม ทำให้ปลอดภัยในการรันซ้ำ
#
# ==============================================================================

# --- โค้ดสีสำหรับแสดงผล ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- ตัวแปรพื้นฐาน ---
DB_USER="mysql"
DB_GROUP="mysql"

# --- ฟังก์ชันสำหรับแสดงข้อความ ---
log_info() { echo -e "${GREEN}[INFO] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; }

# --- ฟังก์ชันสำหรับแก้ไขค่าในไฟล์ Config (เวอร์ชันแก้ไข Bug) ---
update_config() {
    local file="$1"
    local key="$2"
    local value="$3"
    
    if [ ! -f "$file" ]; then
        log_warn "ไม่พบไฟล์ $file, ข้ามการอัปเดต"
        return
    fi

    if grep -qE "^\s*#?\s*${key}\s*=" "$file"; then
        sudo sed -i -E "s/^(\s*#?\s*${key}\s*=\s*)[^#\s]*(.*)/\\1${value}\\2/" "$file"
        log_info "อัปเดตค่า '$key' ใน $file เป็น '$value'"
    else
        echo "$key = $value" | sudo tee -a "$file" > /dev/null
        log_warn "ไม่พบค่า '$key' ใน $file, ทำการเพิ่มค่าใหม่"
    fi
}

# --- ตรวจสอบสิทธิ์ Root ---
if [ "$EUID" -ne 0 ]; then
  log_error "กรุณารันสคริปต์นี้ด้วยสิทธิ์ root หรือใช้คำสั่ง sudo"
  exit 1
fi

# ==================================
#  ขั้นตอนที่ 1: ตรวจสอบ Hardware และคำนวณค่า Config
# ==================================
log_info "ขั้นตอนที่ 1: ตรวจสอบ Hardware และคำนวณค่า Config ที่เหมาะสม..."

TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$(( (TOTAL_RAM_KB + 524288) / 1048576 )) # ปัดเศษให้ใกล้เคียงที่สุด
CPU_CORES=$(nproc)

log_info "ตรวจพบ RAM ทั้งหมด: ${TOTAL_RAM_GB} GB"
log_info "ตรวจพบ CPU Cores: ${CPU_CORES} Cores"

# --- คำนวณค่า Config แบบไดนามิก ---
if [ "$TOTAL_RAM_GB" -lt 32 ]; then
    INNODB_BUFFER_POOL_GB=$((TOTAL_RAM_GB * 70 / 100))
elif [ "$TOTAL_RAM_GB" -lt 128 ]; then
    INNODB_BUFFER_POOL_GB=$((TOTAL_RAM_GB * 65 / 100))
else
    INNODB_BUFFER_POOL_GB=$((TOTAL_RAM_GB * 60 / 100))
fi
[ "$INNODB_BUFFER_POOL_GB" -lt 2 ] && INNODB_BUFFER_POOL_GB=2 # ค่าต่ำสุดคือ 2G

SHMMAX=$((TOTAL_RAM_GB * 1024 * 1024 * 1024 * 90 / 100))
SHMALL=$((SHMMAX / 4096))
HUGEPAGES=$((INNODB_BUFFER_POOL_GB * 1024 / 2))

INNODB_LOG_FILE_SIZE_MB=$((INNODB_BUFFER_POOL_GB * 1024 / 4))
if [ "$INNODB_LOG_FILE_SIZE_MB" -gt 4096 ]; then
    INNODB_LOG_FILE_SIZE="4G"
elif [ "$INNODB_LOG_FILE_SIZE_MB" -lt 512 ]; then
    INNODB_LOG_FILE_SIZE="512M"
else
    INNODB_LOG_FILE_SIZE="${INNODB_LOG_FILE_SIZE_MB}M"
fi

log_info "ค่าที่จะใช้ในการปรับจูน:"
log_info "  - innodb_buffer_pool_size: ${INNODB_BUFFER_POOL_GB}G"
log_info "  - innodb_log_file_size: ${INNODB_LOG_FILE_SIZE}"
log_info "  - vm.nr_hugepages: ${HUGEPAGES}"
sleep 3

# ==================================
# ขั้นตอนที่ 2: ติดตั้ง MariaDB (หากยังไม่มี)
# ==================================
if ! command -v mariadbd &> /dev/null; then
    log_info "MariaDB ยังไม่ได้ติดตั้ง, เริ่มขั้นตอนการติดตั้ง..."
    sudo tee /etc/yum.repos.d/MariaDB.repo > /dev/null <<'EOF'
# MariaDB 11.8 RedHatEnterpriseLinux repository list
[mariadb]
name = MariaDB
baseurl = https://mirror.kku.ac.th/mariadb/yum/11.8/rhel/$releasever/$basearch
gpgkey = https://mirror.kku.ac.th/mariadb/yum/RPM-GPG-KEY-MariaDB
gpgcheck = 1
EOF
    sudo dnf install MariaDB-server MariaDB-client MariaDB-backup -y
    sudo systemctl enable --now mariadb
    log_warn "ติดตั้ง MariaDB เรียบร้อยแล้ว กรุณารัน 'mariadb-secure-installation' ด้วยตนเองหลังสคริปต์นี้ทำงานเสร็จ"
else
    log_info "ตรวจพบ MariaDB ติดตั้งอยู่แล้ว, ข้ามขั้นตอนการติดตั้ง"
fi

# ==================================
# ขั้นตอนที่ 3: ตรวจสอบและปรับจูน Kernel (sysctl)
# ==================================
log_info "ขั้นตอนที่ 3: ตรวจสอบและปรับจูนค่า Kernel (/etc/sysctl.conf)..."
if [ ! -f /etc/sysctl.conf ] || ! grep -q "MariaDB Production Server" /etc/sysctl.conf; then
    log_warn "/etc/sysctl.conf ยังไม่เคยถูกตั้งค่าโดยสคริปต์, กำลังสร้างไฟล์ใหม่..."
    sudo cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%F) 2>/dev/null
    sudo tee /etc/sysctl.conf > /dev/null <<EOF
# ========================================================
# ⚙️ การตั้งค่า Kernel สำหรับ MariaDB Production Server (โดยสคริปต์)
# ========================================================
fs.suid_dumpable = 1            # อนุญาตให้ทำการ dump memory เมื่อเกิดปัญหาเพื่อการวิเคราะห์
fs.aio-max-nr = 1048576         # จำนวนสูงสุดของ Asynchronous I/O operations ที่รองรับ
fs.file-max = 6815744           # จำนวนไฟล์สูงสุดที่ระบบสามารถเปิดได้พร้อมกัน
kernel.shmmax = ${SHMMAX}     # ขนาดสูงสุดของ Shared Memory 1 segment (คำนวณจาก RAM)
kernel.shmall = ${SHMALL}     # จำนวนหน้าของ Shared Memory ทั้งหมด (คำนวณจาก RAM)
vm.nr_hugepages = ${HUGEPAGES}        # จำนวน HugePages ที่จองไว้ (คำนวณสำหรับ Buffer Pool)
vm.hugetlb_shm_group = $(getent group ${DB_GROUP} | cut -d: -f3) # GID ของกลุ่มผู้ใช้ที่สามารถใช้ HugePages ได้ (mysql)
net.ipv4.ip_local_port_range = 2000 65535 # ช่วงของพอร์ตที่ใช้งานได้
net.core.somaxconn = 4096         # จำนวนสูงสุดของ connection ที่รอการ accept
net.ipv4.tcp_tw_reuse = 1         # อนุญาตให้ใช้ซ็อกเก็ตในสถานะ TIME-WAIT ซ้ำได้
kernel.io_uring_disabled = 0    # เปิดใช้งาน io_uring API เพื่อประสิทธิภาพ I/O สูงสุด
EOF
else
    log_info "ตรวจสอบค่าใน /etc/sysctl.conf..."
    update_config "/etc/sysctl.conf" "kernel.shmmax" "${SHMMAX}"
    update_config "/etc/sysctl.conf" "kernel.shmall" "${SHMALL}"
    update_config "/etc/sysctl.conf" "vm.nr_hugepages" "${HUGEPAGES}"
fi
sudo sysctl -p

# ==================================
# ขั้นตอนที่ 4: ตรวจสอบและตั้งค่า Systemd Limits
# ==================================
log_info "ขั้นตอนที่ 4: ตรวจสอบและตั้งค่า Systemd Limits..."
LIMIT_FILE="/etc/systemd/system/mariadb.service.d/override.conf"
sudo mkdir -p /etc/systemd/system/mariadb.service.d
# สร้างไฟล์ใหม่เสมอเพื่อความแน่นอน
sudo tee "$LIMIT_FILE" > /dev/null <<'EOF'
[Service]
LimitNOFILE=150000
LimitMEMLOCK=infinity
EOF
log_info "สร้าง/อัปเดตไฟล์ $LIMIT_FILE เรียบร้อย"
sudo systemctl daemon-reload

# ==================================
# ขั้นตอนที่ 5: ตรวจสอบและตั้งค่า MariaDB (my.cnf)
# ==================================
log_info "ขั้นตอนที่ 5: ตรวจสอบและปรับจูน /etc/my.cnf..."
if [ ! -f /etc/my.cnf ]; then
    log_warn "/etc/my.cnf ไม่พบไฟล์, กำลังสร้างไฟล์ใหม่ทั้งหมด..."
    sudo cp /etc/my.cnf /etc/my.cnf.bak.$(date +%F) 2>/dev/null
    
    # ตรวจสอบชนิดของดิสก์
    DISK_TYPE_CODE=$(cat /sys/block/$(lsblk -no pkname "$(df /var/lib/mysql | awk 'NR==2 {print $1}')" | head -n 1)/queue/rotational 2>/dev/null)
    INNODB_FLUSH_NEIGHBORS=${DISK_TYPE_CODE:-0}
    DISK_TYPE_TEXT=$([ "$INNODB_FLUSH_NEIGHBORS" -eq 0 ] && echo "SSD/NVMe" || echo "HDD/SAS")

    sudo tee /etc/my.cnf > /dev/null <<EOF
# ===================================================================
# 🔧 Configuration File สำหรับ MariaDB 11 (สร้างโดยสคริปต์อัตโนมัติ)
#    - Hardware: RAM ${TOTAL_RAM_GB}GB, CPU ${CPU_CORES} Cores, Disk ${DISK_TYPE_TEXT}
#    - เน้นประสิทธิภาพสูงสุดสำหรับ InnoDB และรองรับภาษาไทย TIS-620
# ===================================================================

[xtrabackup]
datadir=/var/lib/mysql                  # ระบุตำแหน่งข้อมูลสำหรับ XtraBackup

[client]
port=3306                               # พอร์ตที่ Client ใช้เชื่อมต่อ
socket=/var/lib/mysql/mysql.sock        # ตำแหน่งไฟล์ Socket สำหรับการเชื่อมต่อภายในเครื่อง
default-character-set=tis620            # Character Set เริ่มต้นสำหรับ Client

[mysqld]
# ------------------------------------
# # การตั้งค่าพื้นฐานของเซิร์ฟเวอร์ #
# ------------------------------------
port=3306                               # พอร์ตที่ Server รับการเชื่อมต่อ
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
# # Replication & Binary Logs #
# ------------------------------------
server-id=1                             # ID ของเซิร์ฟเวอร์สำหรับ Replication
log-bin=/var/lib/mysql/mysql-bin.log    # เปิดใช้งาน Binary Log สำหรับ Replication และ Point-in-Time Recovery
log_error=/var/log/mysqld.log           # ไฟล์สำหรับเก็บ Error Log
binlog_format=ROW                       # รูปแบบของ Binary Log (ROW ปลอดภัยที่สุด)
expire_logs_days=14                     # จำนวนวันที่จะเก็บ Binary Log ไว้
log_bin_trust_function_creators=1       # อนุญาตให้สร้าง Stored Function ที่อาจไม่ปลอดภัย (จำเป็นสำหรับบางแอปฯ)
slave-skip-errors=all                   # (สำหรับ Slave) ให้ข้าม Error ทั้งหมดเพื่อไม่ให้ Replication หยุด
read_only=0                             # ตั้งค่าให้เซิร์ฟเวอร์นี้สามารถเขียนได้ (0 = OFF)
skip-slave-start=1                      # ไม่เริ่ม Replication โดยอัตโนมัติเมื่อเปิดเซิร์ฟเวอร์

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
slave_compressed_protocol=1

# --- Performance Schema ---
performance_schema=ON

[mysqldump]
quick
max_allowed_packet=512M

[mysql]
no-auto-rehash
default-character-set=tis620
EOF
else
    log_info "ไฟล์ /etc/my.cnf มีอยู่แล้ว, กำลังตรวจสอบและอัปเดตค่าที่สำคัญ..."
    update_config "/etc/my.cnf" "innodb_buffer_pool_size" "${INNODB_BUFFER_POOL_GB}G"
    update_config "/etc/my.cnf" "innodb_log_file_size" "${INNODB_LOG_FILE_SIZE}"
    update_config "/etc/my.cnf" "table_open_cache_instances" "${CPU_CORES}"
fi

# ==================================
# ขั้นตอนที่ 6: รีสตาร์ทและตรวจสอบ
# ==================================
log_info "ขั้นตอนที่ 6: สร้างไฟล์ Log (หากยังไม่มี) และรีสตาร์ท MariaDB..."
sudo touch /var/log/mysqld.log /var/log/mariadb-slow.log
sudo chown ${DB_USER}:${DB_GROUP} /var/log/mysqld.log /var/log/mariadb-slow.log
sudo chmod 640 /var/log/mysqld.log /var/log/mariadb-slow.log

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
echo ""
