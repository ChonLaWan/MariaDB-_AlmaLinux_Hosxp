#!/bin/bash

# ==============================================================================
#   สคริปต์ปรับจูน MariaDB อัตโนมัติสำหรับ AlmaLinux 9 (โปรไฟล์ HOSxP)
# ==============================================================================
#
#   ผู้จัดทำ: ChonLaWan
#   เวอร์ชัน: 3.0 - Full Installer (ปรับปรุงล่าสุด 2025-06-21)
#
#   สคริปต์นี้จะทำการติดตั้งและปรับจูน MariaDB 11.x โดยอัตโนมัติ
#   สำหรับระบบที่ต้องการประสิทธิภาพสูง (เช่น HOSxP) บนเซิร์ฟเวอร์
#   ที่มี RAM 40-60GB และใช้สตอเรจแบบ SSD
#
#   ** คำเตือน **
#   - ควรใช้สคริปต์นี้กับเครื่องที่ติดตั้ง MariaDB ใหม่เท่านั้น
#   - ควรทำ Snapshot หรือสำรองข้อมูลก่อนรันสคริปต์เสมอ
#   - สคริปต์นี้จะเขียนทับไฟล์ /etc/sysctl.conf และ /etc/my.cnf
#
# ==============================================================================

# --- โค้ดสีสำหรับแสดงผล ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # ไม่ใส่สี

# --- ตัวแปรการตั้งค่า ---
MARIADB_VERSION="11.8"
RAM_GB=60 # RAM (GB) ของเครื่องเป้าหมายสำหรับปรับจูน
CPU_CORES=$(nproc)
DB_USER="mysql"
DB_GROUP="mysql"

# --- ฟังก์ชันสำหรับแสดงข้อความ ---
log_info() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

log_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

# --- ตรวจสอบสิทธิ์ Root ---
if [ "$EUID" -ne 0 ]; then
  log_error "กรุณารันสคริปต์นี้ด้วยสิทธิ์ root หรือใช้คำสั่ง sudo"
  exit 1
fi

log_info "เริ่มการตั้งค่าเซิร์ฟเวอร์ MariaDB สำหรับ Production..."
log_info "สเปคเป้าหมาย -> RAM: ${RAM_GB}GB | CPU Cores: ${CPU_CORES}"
sleep 2

# ==================================
# ขั้นตอนที่ 1: ติดตั้ง MariaDB Server
# ==================================
log_info "ขั้นตอนที่ 1: การตั้งค่า Repository ของ MariaDB ${MARIADB_VERSION}..."

# สร้างไฟล์ Repository (.repo) โดยใช้ Mirror ของ ม.ขอนแก่น ตามที่กำหนด
# การใช้วิธีนี้จะทำให้สามารถกำหนด Mirror ที่ต้องการได้โดยตรง
sudo tee /etc/yum.repos.d/MariaDB.repo > /dev/null <<'EOF'
# MariaDB 11.8 RedHatEnterpriseLinux repository list - created 2025-06-21 15:27 UTC
# https://mariadb.org/download/
[mariadb]
name = MariaDB
# rpm.mariadb.org is a dynamic mirror if your preferred mirror goes offline. See https://mariadb.org/mirrorbits/ for details.
# baseurl = https://rpm.mariadb.org/11.8/rhel/$releasever/$basearch
baseurl = https://mirror.kku.ac.th/mariadb/yum/11.8/rhel/$releasever/$basearch
# gpgkey = https://rpm.mariadb.org/RPM-GPG-KEY-MariaDB
gpgkey = https://mirror.kku.ac.th/mariadb/yum/RPM-GPG-KEY-MariaDB
gpgcheck = 1
EOF

if [ $? -ne 0 ]; then
    log_error "ล้มเหลวในการสร้างไฟล์ MariaDB repository"
    exit 1
fi

log_info "กำลังติดตั้ง MariaDB Server, Client, และ Backup..."
dnf install MariaDB-server MariaDB-client MariaDB-backup -y
if [ $? -ne 0 ]; then
    log_error "ล้มเหลวในการติดตั้งแพ็กเกจ MariaDB"
    exit 1
fi

log_info "กำลังเปิดใช้งานและเริ่ม service ของ MariaDB..."
systemctl enable --now mariadb
if [ $? -ne 0 ]; then
    log_error "ล้มเหลวในการเริ่ม service ของ MariaDB"
    exit 1
fi

log_warn "ติดตั้ง MariaDB เรียบร้อยแล้ว กรุณารัน 'mariadb-secure-installation' ด้วยตนเองหลังสคริปต์นี้ทำงานเสร็จ"
sleep 3

# ==================================
# ขั้นตอนที่ 2: ปรับจูน Kernel (sysctl)
# ==================================
log_info "ขั้นตอนที่ 2: การปรับจูนค่า Kernel..."
BACKUP_SYSCTL="/etc/sysctl.conf.bak.$(date +%F)"
log_info "กำลังสำรองไฟล์ /etc/sysctl.conf ไปที่ ${BACKUP_SYSCTL}"
cp /etc/sysctl.conf "${BACKUP_SYSCTL}"

# คำนวณค่า shmmax และ shmall จาก RAM
SHMMAX=$(( RAM_GB * 1024 * 1024 * 1024 * 85 / 100 ))
SHMALL=$(( SHMMAX / 4096 ))

# คำนวณ HugePages (จากขนาด Page 2M)
INNODB_BUFFER_POOL_GB=38
HUGEPAGES=$(( INNODB_BUFFER_POOL_GB * 1024 / 2 ))

tee /etc/sysctl.conf > /dev/null <<EOF
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

log_info "กำลัง 적용การตั้งค่า kernel ใหม่..."
sysctl -p
if [ $? -ne 0 ]; then
    log_error "ล้มเหลวในการ 적용ค่า kernel กรุณาตรวจสอบไฟล์ /etc/sysctl.conf"
    exit 1
fi

# ==================================
# ขั้นตอนที่ 3: ตั้งค่า Systemd Limits
# ==================================
log_info "ขั้นตอนที่ 3: การตั้งค่า Limits ของ Systemd สำหรับ MariaDB..."
mkdir -p /etc/systemd/system/mariadb.service.d

tee /etc/systemd/system/mariadb.service.d/override.conf > /dev/null <<'EOF'
[Service]
LimitNOFILE=100000
LimitMEMLOCK=infinity
EOF

log_info "กำลังโหลดการตั้งค่าของ systemd ใหม่..."
systemctl daemon-reload

# ==================================
# ขั้นตอนที่ 4: ตั้งค่า MariaDB (my.cnf)
# ==================================
log_info "ขั้นตอนที่ 4: การสร้างไฟล์ my.cnf ที่ปรับจูนแล้ว..."
BACKUP_MYCNF="/etc/my.cnf.bak.$(date +%F)"
log_info "กำลังสำรองไฟล์ /etc/my.cnf ไปที่ ${BACKUP_MYCNF}"
if [ -f /etc/my.cnf ]; then
    cp /etc/my.cnf "${BACKUP_MYCNF}"
fi

# ตรวจสอบชนิดของดิสก์เพื่อตั้งค่า innodb_flush_neighbors (0 สำหรับ SSD, 1 สำหรับ HDD)
DISK_TYPE=$(cat /sys/block/$(lsblk -no pkname "$(df /var/lib/mysql | awk 'NR==2 {print $1}')" | head -n 1)/queue/rotational 2>/dev/null)
INNODB_FLUSH_NEIGHBORS=${DISK_TYPE:-0} # หากตรวจไม่พบ ให้ใช้ค่า 0 (SSD) เป็นค่าเริ่มต้น
log_info "ชนิดของดิสก์ที่ตรวจพบ: $([ "$INNODB_FLUSH_NEIGHBORS" -eq 0 ] && echo "SSD/NVMe" || echo "HDD/SAS"). ตั้งค่า innodb_flush_neighbors=${INNODB_FLUSH_NEIGHBORS}."

tee /etc/my.cnf > /dev/null <<EOF
# ===================================================================
# 🔧 Configuration File สำหรับ MariaDB 11 (ปรับจูนโดยสคริปต์สำหรับ HOSxP)
#    - Hardware: RAM \${RAM_GB}GB, CPU \${CPU_CORES} Cores, Disk $([ "$INNODB_FLUSH_NEIGHBORS" -eq 0 ] && echo "SSD/NVMe" || echo "HDD/SAS")
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
innodb_buffer_pool_size=${INNODB_BUFFER_POOL_GB}G          # ขนาดของ Buffer Pool (หัวใจของ InnoDB) ประมาณ 60-70% ของ RAM
innodb_log_file_size=4G                 # ขนาดของ Redo Log File
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
slave_compressed_protocol=1             # บีบอัดข้อมูลระหว่าง Master-Slave

[mysqldump]
quick                                   # ให้ mysqldump อ่านข้อมูลทีละแถวเพื่อลดการใช้ Memory
max_allowed_packet=512M                 # ขนาด Packet สูงสุดสำหรับ mysqldump

[mysql]
no-auto-rehash                          # ปิดการทำ auto-rehash ของ command line เพื่อความเร็ว
default-character-set=tis620            # Character Set เริ่มต้นสำหรับ command line
EOF

# ==================================
# ขั้นตอนที่ 5: สร้างไฟล์ Log และกำหนดสิทธิ์
# ==================================
log_info "ขั้นตอนที่ 5: การสร้างไฟล์ Log และกำหนดสิทธิ์การเข้าถึง..."
touch /var/log/mysqld.log /var/log/mariadb-slow.log
chown ${DB_USER}:${DB_GROUP} /var/log/mysqld.log /var/log/mariadb-slow.log
chmod 640 /var/log/mysqld.log /var/log/mariadb-slow.log

# ==================================
# ขั้นตอนที่ 6: รีสตาร์ทและขั้นตอนสุดท้าย
# ==================================
log_info "ขั้นตอนที่ 6: การรีสตาร์ท MariaDB เพื่อใช้ค่าคอนฟิกใหม่ทั้งหมด..."
systemctl restart mariadb
if [ $? -ne 0 ]; then
    log_error "MariaDB รีสตาร์ทไม่สำเร็จ กรุณาตรวจสอบ log ด้วยคำสั่ง 'journalctl -u mariadb -n 100'"
    log_error "ปัญหาที่พบบ่อย: permission ของไฟล์ log ไม่ถูกต้อง หรือพิมพ์ผิดใน /etc/my.cnf"
    exit 1
fi

log_info "รอสักครู่เพื่อให้ service เริ่มทำงานสมบูรณ์..."
sleep 5

# --- การตรวจสอบขั้นสุดท้าย ---
systemctl status mariadb --no-pager

# ตรวจสอบการใช้งาน HugePages
HUGEPAGES_USED=$(grep Huge /proc/$(pidof mariadbd)/smaps 2>/dev/null | awk '{sum += $2} END {print sum / 1024}')
if [ -n "$HUGEPAGES_USED" ] && [ "$HUGEPAGES_USED" -gt 0 ]; then
    log_info "MariaDB ใช้งาน HugePages อยู่: ${HUGEPAGES_USED} MB"
else
    log_warn "ไม่พบการใช้งาน HugePages อาจมีปัญหาในการตั้งค่า vm.hugetlb_shm_group หรือหน่วยความจำไม่พอ"
fi


log_info "${GREEN}=====================================================${NC}"
log_info "${GREEN}   สคริปต์ปรับจูน MariaDB ทำงานเสร็จสมบูรณ์!         ${NC}"
log_info "${GREEN}=====================================================${NC}"
log_warn "สำคัญ: กรุณารัน 'sudo mariadb-secure-installation' ทันที"
log_warn "เพื่อตั้งรหัสผ่าน root และทำให้เซิร์ฟเวอร์ปลอดภัย"
echo ""
```
