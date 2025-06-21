#!/bin/bash

# ==============================================================================
#   สคริปต์ปรับจูน MariaDB 11 และ AlmaLinux อัตโนมัติ
#   - ตรวจสอบ Hardware (RAM, CPU, SSD/HDD)
#   - คำนวณและสร้าง Config ที่เหมาะสม
#   - สำรองข้อมูลเก่าและใส่คำอธิบายครบทุกบรรทัด
#   - ต้องรันด้วยสิทธิ์ root เท่านั้น
# ==============================================================================

# --- 0. ตรวจสอบสิทธิ์ Root ---
if [[ $EUID -ne 0 ]]; then
   echo "❌ กรุณารันสคริปต์นี้ด้วยสิทธิ์ root หรือใช้คำสั่ง sudo"
   exit 1
fi

echo "✅ สิทธิ์ถูกต้อง เริ่มการทำงาน..."
echo ""

# --- 1. ตรวจสอบ Hardware ---
echo "🧠 กำลังตรวจสอบ Hardware ของเครื่อง..."

# ตรวจสอบ RAM (GB) และ CPU Cores
TOTAL_RAM_GB=$(free -g | awk '/^Mem:/ {print $2}')
CPU_CORES=$(nproc)
echo "   - ตรวจพบ RAM: ${TOTAL_RAM_GB} GB"
echo "   - ตรวจพบ CPU: ${CPU_CORES} Cores"

# ตรวจสอบชนิดของดิสก์ (SSD หรือ HDD)
DATA_DIR_DEVICE=$(df /var/lib/mysql | awk 'NR==2 {print $1}')
if [[ -z "$DATA_DIR_DEVICE" ]]; then
    echo "⚠️ ไม่สามารถหา Device ที่ติดตั้ง /var/lib/mysql ได้"
    DISK_TYPE="UNKNOWN"
else
    # หาชื่อ Device หลัก (เช่น sda จาก sda1)
    DISK_NAME=$(lsblk -no pkname "$DATA_DIR_DEVICE" | head -n 1)
    if [[ -z "$DISK_NAME" ]]; then
        DISK_NAME=$(lsblk -no name "$DATA_DIR_DEVICE" | sed 's/.*\///' | head -n 1 | tr -d '0-9')
    fi
    
    # อ่านค่า rotational
    ROTATIONAL=$(cat /sys/block/${DISK_NAME}/queue/rotational 2>/dev/null)

    if [[ "$ROTATIONAL" == "0" ]]; then
        DISK_TYPE="SSD"
        echo "   - ตรวจพบ Disk Type: SSD (Non-rotational)"
    else
        DISK_TYPE="HDD"
        echo "   - ตรวจพบ Disk Type: HDD/SAS (Rotational)"
    fi
fi
echo ""


# --- 2. สำรองไฟล์ Config เดิม ---
BACKUP_DIR="/root/config_backup_$(date +%Y-%m-%d_%H%M%S)"
echo "🛡️ กำลังสำรองไฟล์ Config ไปที่ ${BACKUP_DIR}..."
mkdir -p "$BACKUP_DIR"

if [ -f /etc/my.cnf ]; then
    cp /etc/my.cnf "${BACKUP_DIR}/my.cnf.bak"
    echo "   - สำรอง /etc/my.cnf เรียบร้อย"
fi
if [ -f /etc/sysctl.conf ]; then
    cp /etc/sysctl.conf "${BACKUP_DIR}/sysctl.conf.bak"
    echo "   - สำรอง /etc/sysctl.conf เรียบร้อย"
fi
echo ""


# --- 3. คำนวณค่า Config ตาม Hardware ---
echo "🧮 กำลังคำนวณค่า Config ที่เหมาะสม..."

# คำนวณ InnoDB Buffer Pool Size (ประมาณ 65% ของ RAM)
BUFFER_POOL_SIZE=$(echo "scale=0; ${TOTAL_RAM_GB} * 0.65 / 1" | bc)G

# คำนวณ InnoDB Buffer Pool Instances (ประมาณ 1 instance ต่อ 1GB, สูงสุด 64)
BUFFER_POOL_INSTANCES=$(echo "scale=0; ${BUFFER_POOL_SIZE%G} / 1" | bc)
if (( BUFFER_POOL_INSTANCES < 1 )); then BUFFER_POOL_INSTANCES=1; fi
if (( BUFFER_POOL_INSTANCES > 64 )); then BUFFER_POOL_INSTANCES=64; fi

# คำนวณ Thread & IO Threads (ปรับตามจำนวน Core)
if (( CPU_CORES >= 32 )); then
    READ_IO_THREADS=16
    WRITE_IO_THREADS=16
    THREAD_CACHE_SIZE=128
elif (( CPU_CORES >= 16 )); then
    READ_IO_THREADS=8
    WRITE_IO_THREADS=8
    THREAD_CACHE_SIZE=64
else
    READ_IO_THREADS=4
    WRITE_IO_THREADS=4
    THREAD_CACHE_SIZE=32
fi

# คำนวณค่าสำหรับ HugePages
SHMMAX=$(echo "scale=0; ${TOTAL_RAM_GB} * 1024 * 1024 * 1024 * 0.85 / 1" | bc)
SHMALL=$(echo "scale=0; ${SHMMAX} / 4096" | bc)
NR_HUGEPAGES=$(echo "scale=0; ${BUFFER_POOL_SIZE%G} * 1024 / 2" | bc)

echo "   - InnoDB Buffer Pool Size: ${BUFFER_POOL_SIZE}"
echo "   - InnoDB Read/Write IO Threads: ${READ_IO_THREADS}"
echo ""


# --- 4. สร้างไฟล์ Kernel Tuning (`sysctl.conf`) ---
echo "✍️ กำลังเขียนไฟล์ /etc/sysctl.conf..."
sudo tee /etc/sysctl.conf > /dev/null <<EOF
# ========================================================
# ⚙️ การตั้งค่า Kernel สำหรับ MariaDB Production Server (สร้างโดยสคริปต์)
# ========================================================
fs.suid_dumpable = 1                  # อนุญาตให้ทำการ dump memory เมื่อเกิดปัญหาเพื่อการวิเคราะห์
fs.aio-max-nr = 1048576               # จำนวนสูงสุดของ Asynchronous I/O operations ที่รองรับ
fs.file-max = 6815744                 # จำนวนไฟล์สูงสุดที่ระบบสามารถเปิดได้พร้อมกัน
kernel.shmmax = ${SHMMAX}             # ขนาดสูงสุดของ Shared Memory 1 segment (คำนวณจาก RAM)
kernel.shmall = ${SHMALL}              # จำนวนหน้าของ Shared Memory ทั้งหมด (คำนวณจาก RAM)
vm.nr_hugepages = ${NR_HUGEPAGES}               # จำนวน HugePages ที่จองไว้ (คำนวณสำหรับ Buffer Pool)
vm.hugetlb_shm_group = 1001           # GID ของกลุ่มผู้ใช้ที่สามารถใช้ HugePages ได้ (ตรวจสอบให้ตรงกับ GID ของ mysql)
net.ipv4.ip_local_port_range = 2000 65535  # ช่วงของพอร์ตที่ใช้งานได้
net.core.somaxconn = 4096             # จำนวนสูงสุดของ connection ที่รอการ accept
net.ipv4.tcp_tw_reuse = 1             # อนุญาตให้ใช้ซ็อกเก็ตในสถานะ TIME-WAIT ซ้ำได้
kernel.io_uring_disabled = 0          # เปิดใช้งาน io_uring API เพื่อประสิทธิภาพ I/O สูงสุด
EOF

# สั่งให้ Kernel โหลดค่าใหม่
echo "   - กำลังใช้คำสั่ง sysctl -p เพื่อโหลดค่าใหม่"
sudo sysctl -p
echo ""


# --- 5. สร้างไฟล์ Systemd Override ---
echo "✍️ กำลังเขียนไฟล์ Systemd Override สำหรับ MariaDB..."
sudo mkdir -p /etc/systemd/system/mariadb.service.d
sudo tee /etc/systemd/system/mariadb.service.d/override.conf > /dev/null <<'EOF'
[Service]
LimitNOFILE=100000          # จำนวนไฟล์สูงสุดที่ MariaDB process สามารถเปิดได้
LimitMEMLOCK=infinity       # อนุญาตให้ MariaDB ล็อกหน่วยความจำใน RAM ได้ไม่จำกัด (จำเป็นสำหรับ HugePages)
EOF
echo ""


# --- 6. สร้างไฟล์ MariaDB Config (`my.cnf`) ---
echo "✍️ กำลังสร้างไฟล์ /etc/my.cnf พร้อมปรับจูนสำหรับ ${DISK_TYPE}..."
sudo tee /etc/my.cnf > /dev/null <<EOF
# ===================================================================
# 🔧 Configuration File สำหรับ MariaDB 11 (สร้างและปรับจูนอัตโนมัติ)
#    - Hardware: RAM ${TOTAL_RAM_GB}GB, CPU ${CPU_CORES} Cores, Disk ${DISK_TYPE}
#    - เน้นประสิทธิภาพสูงสุดสำหรับ InnoDB และรองรับภาษาไทย TIS-620
# ===================================================================

[xtrabackup]
datadir=/var/lib/mysql                      # ระบุตำแหน่งข้อมูลสำหรับ XtraBackup

[client]
port=3306                                   # พอร์ตที่ Client ใช้เชื่อมต่อ
socket=/var/lib/mysql/mysql.sock            # ตำแหน่งไฟล์ Socket สำหรับการเชื่อมต่อภายในเครื่อง
default-character-set=tis620                # Character Set เริ่มต้นสำหรับ Client

[mysqld]
# ---------------------------------
# 📦 การตั้งค่าพื้นฐานของเซิร์ฟเวอร์
# ---------------------------------
port=3306                                   # พอร์ตที่ Server รับการเชื่อมต่อ
datadir=/var/lib/mysql                      # โฟลเดอร์หลักสำหรับเก็บข้อมูลฐานข้อมูล
socket=/var/lib/mysql/mysql.sock            # ตำแหน่งไฟล์ Socket ของ Server
tmpdir=/tmp                                 # โฟลเดอร์สำหรับไฟล์ชั่วคราว
bind-address=0.0.0.0                        # รับการเชื่อมต่อจากทุก IP Address
lower_case_table_names=1                    # ทำให้ชื่อตารางไม่ขึ้นกับตัวพิมพ์ใหญ่-เล็ก (สำคัญสำหรับระบบที่ย้ายมาจาก Windows)
skip-name-resolve                           # ไม่ต้องแปลง IP เป็น Hostname เพื่อลด Latency ในการเชื่อมต่อ

# ---------------------------------
# 🈶 การตั้งค่าภาษาไทย (TIS-620)
# ---------------------------------
character-set-server=tis620                 # Character Set ของเซิร์ฟเวอร์
collation-server=tis620_thai_ci             # การเรียงลำดับข้อมูลภาษาไทย
init_connect='SET NAMES tis620'             # สั่งให้ทุก Connection ใหม่ใช้ TIS-620
skip-character-set-client-handshake         # บังคับใช้ Character Set ของ Server เสมอ

# ---------------------------------
# 🔗 การจัดการ Thread และ Connection
# ---------------------------------
thread_handling=pool-of-threads             # ใช้ Thread Pool เหมาะสำหรับ CPU หลายคอร์และ Connection จำนวนมาก
max_connections=1000                        # จำนวน Connection สูงสุดที่รับได้พร้อมกัน
thread_cache_size=${THREAD_CACHE_SIZE}      # Cache Thread ที่ไม่ได้ใช้งานไว้ (คำนวณจาก CPU Cores)
wait_timeout=300                            # เวลา (วินาที) ที่จะตัดการเชื่อมต่อที่ไม่มีการใช้งาน
interactive_timeout=600                     # Timeout สำหรับ Interactive Connection
connect_timeout=60                          # Timeout สำหรับการพยายามเชื่อมต่อ
net_read_timeout=600                        # Timeout สำหรับการรอรับข้อมูล
net_write_timeout=600                       # Timeout สำหรับการรอส่งข้อมูล

# ---------------------------------
# 🗃️ การจัดการ Table Cache และ Files
# ---------------------------------
table_open_cache=8000                       # Cache ตารางที่เปิดแล้วในหน่วยความจำ
table_definition_cache=8000                 # Cache โครงสร้างของตาราง
table_open_cache_instances=32               # แบ่ง Cache ของตารางที่เปิดแล้วออกเป็นส่วนๆ เพื่อลดการแย่งชิง (Contention)
open_files_limit=100000                     # จำนวนไฟล์สูงสุดที่ MariaDB สามารถเปิดได้ (ต้องสัมพันธ์กับ LimitNOFILE ใน systemd)

# ---------------------------------
# 🧠 Memory Buffers สำหรับ Query
# ---------------------------------
sort_buffer_size=2M                         # Buffer สำหรับการเรียงลำดับข้อมูล (Sort)
read_buffer_size=2M                         # Buffer สำหรับการอ่านข้อมูลแบบ Sequential
read_rnd_buffer_size=4M                     # Buffer สำหรับการอ่านข้อมูลแบบสุ่ม (Random)
join_buffer_size=4M                         # Buffer สำหรับการ Join ตารางที่ไม่มี Index
tmp_table_size=512M                         # ขนาดสูงสุดของตารางชั่วคราวบน Memory ก่อนจะเขียนลง Disk
max_heap_table_size=512M                    # ขนาดสูงสุดของตารางประเภท MEMORY

# ---------------------------------
# 🔁 การตั้งค่า Replication และ Binary Logs
# ---------------------------------
server-id=1                                 # ID ที่ไม่ซ้ำกันของ Server ในกลุ่ม Replication (ควรเปลี่ยนหากมีหลายเครื่อง)
log-bin=/var/lib/mysql/mysql-bin.log        # เปิดใช้งาน Binary Log และระบุตำแหน่งไฟล์
log_error=/var/log/mysqld.log               # ตำแหน่งไฟล์สำหรับเก็บ Log ข้อผิดพลาด
binlog_format=ROW                           # รูปแบบของ Binary Log (ROW ปลอดภัยที่สุดสำหรับ Replication)
expire_logs_days=14                         # จำนวนวันที่จะเก็บ Binary Log ไว้ก่อนลบอัตโนมัติ
log_bin_trust_function_creators=1           # อนุญาตให้สร้าง Stored Function ที่อาจไม่ปลอดภัยในบางกรณีได้
slave-skip-errors=all                       # (สำหรับ Slave) ให้ข้าม Error ทั้งหมดเพื่อไม่ให้ Replication หยุดทำงาน
relay-log=/var/lib/mysql/relay-bin          # (สำหรับ Slave) ตำแหน่งไฟล์ Relay Log
relay-log-index=/var/lib/mysql/relay-bin.index # (สำหรับ Slave) ตำแหน่งไฟล์ Index ของ Relay Log
read_only=0                                 # อนุญาตให้เขียนข้อมูลได้ (สำหรับ Master)
skip-slave-start=1                          # ไม่เริ่มการทำงานของ Slave Thread อัตโนมัติเมื่อ Server เริ่มทำงาน

# ---------------------------------
# ⚙️ การปรับแต่ง Query และ SQL Mode
# ---------------------------------
sql-mode="NO_ENGINE_SUBSTITUTION,STRICT_TRANS_TABLES" # ป้องกันการใช้ Engine อื่นแทนถ้า Engine ที่ระบุไม่พร้อมใช้งาน และเปิด Strict Mode
query_cache_type=0                          # ปิด Query Cache (เลิกใช้แล้วและไม่แนะนำสำหรับ InnoDB)
query_cache_size=0                          # ปิด Query Cache

# ---------------------------------
# 🧱 การตั้งค่า InnoDB Engine (ส่วนที่สำคัญที่สุด)
# ---------------------------------
default_storage_engine=InnoDB               # กำหนดให้ InnoDB เป็น Storage Engine เริ่มต้น
innodb_file_per_table=1                     # สร้างไฟล์ .ibd แยกสำหรับแต่ละตาราง
innodb_buffer_pool_size=${BUFFER_POOL_SIZE} # ขนาดของ Buffer Pool (คำนวณจาก RAM) สำหรับเก็บข้อมูลและ Index
#innodb_buffer_pool_instances=${BUFFER_POOL_INSTANCES} # ❌ เลิกใช้แล้วใน MariaDB 11.x (ระบบจัดการเอง)
innodb_log_file_size=4G                     # ขนาดของ Redo Log File (ไฟล์ใหญ่ช่วยลด I/O แต่ทำให้ Recovery ช้าลง)
#innodb_log_files_in_group=2                # ❌ เลิกใช้แล้วใน MariaDB 11.x (ระบบจัดการเอง)
innodb_log_buffer_size=64M                  # Buffer สำหรับพัก Transaction ก่อนเขียนลง Redo Log
innodb_flush_log_at_trx_commit=2            # ลดความเข้มงวดในการเขียน Log ลงดิสก์ เพื่อเพิ่มความเร็ว (เสี่ยงข้อมูลหาย 1 วินาทีหากไฟดับ)
innodb_flush_method=O_DIRECT_NO_FSYNC       # วิธีการเขียนข้อมูลลงดิสก์ เหมาะสำหรับ SSD และ Direct I/O
innodb_doublewrite=1                        # เปิด Doublewrite Buffer เพื่อป้องกัน Page เสียหายระหว่างการเขียน
#innodb_thread_concurrency=0                # ❌ เลิกใช้แล้วใน MariaDB 11.x (0=ไม่จำกัด, ระบบจัดการเอง)
innodb_read_io_threads=${READ_IO_THREADS}   # จำนวน Thread สำหรับการอ่านข้อมูล (คำนวณจาก CPU)
innodb_write_io_threads=${WRITE_IO_THREADS} # จำนวน Thread สำหรับการเขียนข้อมูล (คำนวณจาก CPU)
innodb_io_capacity=2000                     # จำนวน I/O Operations Per Second (IOPS) ที่คาดว่า Disk ทำได้ (2000 สำหรับ SSD)
innodb_io_capacity_max=4000                 # IOPS สูงสุดที่ยอมให้ InnoDB ใช้
innodb_open_files=65535                     # จำนวนไฟล์ .ibd สูงสุดที่ InnoDB สามารถเปิดได้พร้อมกัน
innodb_max_dirty_pages_pct=80               # เปอร์เซ็นต์สูงสุดของหน้าใน Buffer Pool ที่ยอมให้เป็น "Dirty" ก่อนจะเร่ง Flush
innodb_max_dirty_pages_pct_lwm=10           # "Low Water Mark" เมื่อ Dirty Pages ต่ำกว่าค่านี้จะลดการ Flush ลง
#innodb_page_cleaners=4                     # ❌ เลิกใช้แล้วใน MariaDB 11.x (ระบบจัดการเอง)
innodb_lru_scan_depth=4096                  # ความลึกในการสแกน LRU list เพื่อหาหน้าว่าง
innodb_purge_threads=4                      # จำนวน Thread สำหรับลบข้อมูลเก่า (Undo Log)
innodb_purge_batch_size=300                 # จำนวนหน้าที่ Purge Thread จะเคลียร์ในแต่ละรอบ
innodb_flush_neighbors=$( [[ "$DISK_TYPE" == "SSD" ]] && echo 0 || echo 1 ) # ปิดการ Flush หน้าข้างเคียงสำหรับ SSD, เปิดสำหรับ HDD
innodb_adaptive_flushing=1                  # เปิดให้ InnoDB ปรับอัตราการ Flush ตาม Workload
innodb_adaptive_hash_index=0                # ปิด Adaptive Hash Index เพื่อลด Contention บนระบบ Multi-core
innodb_use_native_aio=1                     # ใช้ Native Asynchronous I/O ของ Linux
innodb_stats_persistent=1                   # เก็บสถิติตารางไว้ใน Disk เพื่อความแม่นยำหลัง Restart
innodb_monitor_enable=all                   # เปิดการเก็บข้อมูล Monitor ของ InnoDB ทั้งหมด
max_prepared_stmt_count=1000000             # จำนวน Prepared Statement สูงสุดที่เก็บได้

# ---------------------------------
# 🧠 การตั้งค่า HugePages และ Memory Lock
# ---------------------------------
large_pages=1                               # เปิดใช้งาน HugePages (ต้องตั้งค่าใน Kernel และ Systemd ก่อน)
memlock=1                                   # ล็อกหน่วยความจำของ MariaDB ไว้ใน RAM ป้องกันการ Swap

# ---------------------------------
# 🐢 การตั้งค่า Logging และ Debug
# ---------------------------------
slow_query_log=1                            # เปิดการเก็บ Log สำหรับ Query ที่ทำงานช้า
slow_query_log_file=/var/log/mariadb-slow.log # ตำแหน่งไฟล์ Slow Query Log
long_query_time=1                           # Query ที่ทำงานนานกว่า 1 วินาทีจะถูกบันทึก
log_queries_not_using_indexes=1             # บันทึก Query ที่ไม่ได้ใช้ Index

# ---------------------------------
# 🔐 ความปลอดภัยและ Packet
# ---------------------------------
max_allowed_packet=512M                     # ขนาด Packet สูงสุดที่รับส่งได้
skip-external-locking                       # ปิดการล็อกไฟล์ในระดับ OS
slave_compressed_protocol=1                 # บีบอัดข้อมูลระหว่าง Master-Slave

# ---------------------------------
# 🧪 การตั้งค่า Performance Schema
# ---------------------------------
performance_schema=ON                       # เปิด Performance Schema เพื่อการวิเคราะห์ประสิทธิภาพเชิงลึก

[mysqldump]
quick                                       # ทำงานแบบ Quick mode ไม่ล็อกตารางนาน
max_allowed_packet=512M                     # ขนาด Packet สูงสุดสำหรับ mysqldump

[mysql]
no-auto-rehash                              # ปิดการ Rehash อัตโนมัติเพื่อเพิ่มความเร็วในการใช้ mysql client
default-character-set=tis620                # Character Set เริ่มต้น

[myisamchk]
key_buffer_size=256M                        # Buffer สำหรับ Index ของ MyISAM
sort_buffer_size=256M                       # Buffer สำหรับเรียงลำดับของ MyISAM
read_buffer=2M
write_buffer=2M
EOF
echo ""


# --- 7. สร้างไฟล์ Log และกำหนดสิทธิ์ ---
echo "✍️ กำลังสร้างไฟล์ Log และกำหนดสิทธิ์..."
sudo touch /var/log/mysqld.log /var/log/mariadb-slow.log
sudo chown mysql:mysql /var/log/mysqld.log /var/log/mariadb-slow.log
sudo chmod 640 /var/log/mysqld.log /var/log/mariadb-slow.log
echo ""


# --- 8. Reload และ Restart Services ---
echo "🚀 กำลัง Reload Systemd และ Restart MariaDB..."
sudo systemctl daemon-reload
sudo systemctl restart mariadb
echo ""

# --- 9. สรุปและขั้นตอนตรวจสอบ ---
echo "✅ การปรับจูนเสร็จสมบูรณ์!"
echo "   - ไฟล์ Backup ถูกเก็บไว้ที่: ${BACKUP_DIR}"
echo "   - ระบบถูกปรับแต่งสำหรับ: RAM ${TOTAL_RAM_GB}GB, CPU ${CPU_CORES} Cores, Disk ${DISK_TYPE}"
echo ""
echo "   👉 คำแนะนำในการตรวจสอบ:"
echo "      1. ตรวจสอบสถานะ: sudo systemctl status mariadb"
echo "      2. ตรวจสอบ Log: sudo journalctl -u mariadb -n 50 --no-pager"
echo "      3. ตรวจสอบการใช้ HugePages (ควรมีค่าใกล้เคียง ${BUFFER_POOL_SIZE}):"
echo "         grep Huge /proc/\$(pidof mariadbd)/smaps | awk '{sum += \$2} END {print sum / 1024 \" MB\"}'"
echo ""